// SPDX-License-Identifier: MIT

const std = @import("std");
const containers = @import("containers");
const core = @import("core");
const kernel = @import("kernel");

const MemoryRegion = kernel.vmm.MemoryRegion;

const RedBlack = containers.RedBlack;
const MemoryRegionRedBlackTree = RedBlack.Tree(memoryRegionAddressCompare);

var memory_region_pool: kernel.heap.DirectObjectPool(MemoryRegionWithNode, .memory_region_pool) = .{};

const AddressSpace = @This();

range_allocator: kernel.heap.RangeAllocator = .{},
memory_region_tree: MemoryRegionRedBlackTree = .{},

/// Initialize an address space.
///
/// **REQUIREMENTS**:
/// - size of `total_range` must be non-zero
/// - address of `total_range` must be aligned to `kernel.arch.paging.standard_page_size`
/// - size of `total_range` must be aligned to `kernel.arch.paging.standard_page_size`
pub fn init(total_range: kernel.VirtualRange) error{OutOfMemory}!AddressSpace {
    core.assert(total_range.size.bytes != 0);
    core.assert(total_range.address.isAligned(kernel.arch.paging.standard_page_size));
    core.assert(total_range.size.isAligned(kernel.arch.paging.standard_page_size));

    return .{
        .range_allocator = try kernel.heap.RangeAllocator.init(total_range),
    };
}

pub const AllocateError = error{
    /// The address space is exhausted.
    AddressSpaceExhausted,

    /// A pool was unable to satisfy a request for an object.
    OutOfMemory,
};

/// Allocate a memory region.
///
/// **REQUIREMENTS**:
/// - `size` must be non-zero
/// - `size` must be aligned to `kernel.arch.paging.standard_page_size`
pub fn allocate(self: *AddressSpace, size: core.Size, map_type: kernel.vmm.MapType) AllocateError!kernel.VirtualRange {
    core.assert(size.bytes != 0);
    core.assert(size.isAligned(kernel.arch.paging.standard_page_size));

    const virtual_range = self.range_allocator.allocateRange(size) catch return error.AddressSpaceExhausted;
    errdefer self.range_allocator.deallocateRange(virtual_range) catch {
        // FIXME: we have no way to recover from this
        core.panic("deallocateRange failed, this AddressSpace may now be in an invalid state");
    };

    try self.allocateMemoryRegion(.{ .range = virtual_range, .map_type = map_type });

    return virtual_range;
}

/// Deallocate a previously allocated memory region.
///
/// **REQUIREMENTS**:
/// - `range` must have been previously allocated by this address space, it can be a sub-range of a previously allocated range
/// - size of `range` must be non-zero
/// - address of `range` must be aligned to `kernel.arch.paging.standard_page_size`
/// - size of `range` must be aligned to `kernel.arch.paging.standard_page_size`
pub fn deallocate(self: *AddressSpace, range: kernel.VirtualRange) void {
    core.assert(range.size.bytes != 0);
    core.assert(range.address.isAligned(kernel.arch.paging.standard_page_size));
    core.assert(range.size.isAligned(kernel.arch.paging.standard_page_size));

    // TODO: support failure below, we need to have a way to rollback the changes from `allocateVirtualRange`

    self.range_allocator.deallocateRange(range) catch unreachable;
    self.deallocateMemoryRegion(range) catch unreachable;
}

fn allocateMemoryRegion(
    self: *AddressSpace,
    memory_region: MemoryRegion,
) error{OutOfMemory}!void {
    // find pre-existing memory region that directly precedes the new region
    if (self.memory_region_tree.findFirstMatch(memory_region, memoryRegionDirectlyFollowsCompare)) |matching_region_node| {
        // situation: |matching_region| |memory_region|
        // so increase the size of the matching region to encompass the new region

        const matching_region = MemoryRegionWithNode.fromNode(matching_region_node);

        matching_region.memory_region.range.size.addInPlace(memory_region.range.size);

        if (self.memory_region_tree.findFirstMatch(matching_region.memory_region, memoryRegionDirectlyPrecedesCompare)) |following_region_node| {
            // situation: |matching_region (matching_region + memory_region)| |following_region|
            // so increase the size of the matching region to encompass the following region and remove the
            // following region from the tree and return it to the pool

            const following_region = MemoryRegionWithNode.fromNode(following_region_node);

            matching_region.memory_region.range.size.addInPlace(following_region.memory_region.range.size);

            self.memory_region_tree.remove(following_region_node);
            memory_region_pool.give(following_region);
        }

        return;
    }

    // find pre-existing memory region that directly follows the new region
    if (self.memory_region_tree.findFirstMatch(memory_region, memoryRegionDirectlyPrecedesCompare)) |matching_region_node| {
        // situation: |memory_region| |matching_region|
        // so change the the matching region's address and size to encompass the memory region, as the address is
        // changing it needs to be removed from the tree and re-inserted

        const matching_region = MemoryRegionWithNode.fromNode(matching_region_node);

        // remove the matching region from the tree
        self.memory_region_tree.remove(matching_region_node);

        // change the address and size of the matching region to encompass the memory region
        matching_region.memory_region.range.address = memory_region.range.address;
        matching_region.memory_region.range.size.addInPlace(memory_region.range.size);

        if (self.memory_region_tree.findFirstMatch(matching_region.memory_region, memoryRegionDirectlyFollowsCompare)) |previous_region_node| {
            // situation: |previous_region| |matching_region (matching_region + memory_region)|
            // so increase the size of the previous region to encompass the matching region then return the
            // matching to the pool

            const previous_region = MemoryRegionWithNode.fromNode(previous_region_node);

            // increase the size of the previous region to encompass the matching region
            previous_region.memory_region.range.size.addInPlace(matching_region.memory_region.range.size);

            // give the matching region back to the pool
            memory_region_pool.give(matching_region);
        } else {
            // reinsert the range into the size tree with the new size
            self.memory_region_tree.insert(&matching_region.address_ordered_node) catch unreachable;
        }

        return;
    }

    // no pre-existing memory region can be extended to cover the new memory region, so we have to insert it
    // into the tree

    const memory_region_with_node = try memory_region_pool.get();

    memory_region_with_node.* = .{
        .memory_region = memory_region,
    };

    self.memory_region_tree.insert(&memory_region_with_node.address_ordered_node) catch unreachable;
}

/// !WARNING: this function will panic if the range is not contained in any memory region
fn deallocateMemoryRegion(self: *AddressSpace, range: kernel.VirtualRange) error{OutOfMemory}!void {
    // find a memory region that contains the range
    const matching_region_node = self.memory_region_tree.findFirstMatch(range, memoryRegionContainsRangeCompare) orelse {
        core.panic("no matching memory region found");
    };
    const matching_region = MemoryRegionWithNode.fromNode(matching_region_node);

    // exact match found
    if (matching_region.memory_region.range.equal(range)) {
        // if the memory region's range is the same as the range, we remove it from the tree and give it back to the pool

        self.memory_region_tree.remove(matching_region_node);
        memory_region_pool.give(matching_region);

        return;
    }

    // we are at the end
    if (matching_region.memory_region.range.end().equal(range.end())) {
        // we are at the end of the memory region, so we can just shorten the memory region's range

        matching_region.memory_region.range.size.subtractInPlace(range.size);

        return;
    }

    // we are at the beginning
    if (matching_region.memory_region.range.address.equal(range.address)) {
        // we are at the beginning of the memory region, so we can adjust the memory region's address and size
        // even though we are modifing the address of the matching range it is still in the correct location in the tree

        matching_region.memory_region.range.address = range.end();
        matching_region.memory_region.range.size.subtractInPlace(range.size);

        return;
    }

    // we are somewhere in the middle of the memory region, so we have to split it into two
    // the matching region will be used as the first region, and a proceeding region will be allocated for the second region
    // |matching_region| |unallocated (range)| |proceeding_region|

    const proceeding_region_with_node = try memory_region_pool.get();

    proceeding_region_with_node.* = .{
        .memory_region = .{
            .range = kernel.VirtualRange.fromAddr(
                range.end(),
                core.Size.from(matching_region.memory_region.range.end().value - range.end().value, .byte),
            ),
            .map_type = matching_region.memory_region.map_type,
        },
    };

    // insert the proceeding region into the tree
    self.memory_region_tree.insert(&proceeding_region_with_node.address_ordered_node) catch unreachable;

    // adjust the size of the matching region
    matching_region.memory_region.range.size = core.Size.from(
        range.address.value - matching_region.memory_region.range.address.value,
        .byte,
    );
}

const MemoryRegionWithNode = struct {
    memory_region: MemoryRegion,

    address_ordered_node: RedBlack.Node = .{},

    inline fn fromNode(node: *RedBlack.Node) *MemoryRegionWithNode {
        return @fieldParentPtr(MemoryRegionWithNode, "address_ordered_node", node);
    }

    inline fn fromNodeConst(node: *const RedBlack.Node) *const MemoryRegionWithNode {
        return @fieldParentPtr(MemoryRegionWithNode, "address_ordered_node", node);
    }
};

fn memoryRegionDirectlyFollowsCompare(memory_region: MemoryRegion, other_node: *const RedBlack.Node) core.OrderedComparison {
    const other_memory_region = MemoryRegionWithNode.fromNodeConst(other_node).memory_region;

    const other_end = other_memory_region.range.end();

    if (memory_region.range.address.equal(other_end) and
        memory_region.map_type.equal(other_memory_region.map_type)) return .match;

    return if (memory_region.range.address.lessThanOrEqual(other_memory_region.range.address)) .less else .greater;
}

fn memoryRegionDirectlyPrecedesCompare(memory_region: MemoryRegion, other_node: *const RedBlack.Node) core.OrderedComparison {
    const other_memory_region = MemoryRegionWithNode.fromNodeConst(other_node).memory_region;

    const end = memory_region.range.end();

    if (other_memory_region.range.address.equal(end) and
        memory_region.map_type.equal(other_memory_region.map_type)) return .match;

    return if (memory_region.range.address.lessThanOrEqual(other_memory_region.range.address)) .less else .greater;
}

fn memoryRegionAddressCompare(node: *const RedBlack.Node, other_node: *const RedBlack.Node) core.OrderedComparison {
    const memory_region = MemoryRegionWithNode.fromNodeConst(node).memory_region;
    const other_memory_region = MemoryRegionWithNode.fromNodeConst(other_node).memory_region;

    return memory_region.range.address.compare(other_memory_region.range.address);
}

fn memoryRegionContainsRangeCompare(range: kernel.VirtualRange, other_node: *const RedBlack.Node) core.OrderedComparison {
    const other_range = MemoryRegionWithNode.fromNodeConst(other_node).memory_region.range;

    if (range.address.lessThan(other_range.address)) return .less;

    if (range.end().greaterThan(other_range.end())) return .greater;

    return .match;
}
