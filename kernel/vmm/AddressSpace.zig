// SPDX-License-Identifier: MIT

const std = @import("std");
const containers = @import("containers");
const core = @import("core");
const kernel = @import("kernel");

const MemoryRegion = kernel.vmm.MemoryRegion;

const RedBlack = containers.RedBlack;
const RegionAddressRedBlackTree = RedBlack.Tree(rangeAddressCompare);
const RegionSizeRedBlackTree = RedBlack.Tree(rangeSizeCompare);
const MemoryRegionRedBlackTree = RedBlack.Tree(memoryRegionAddressCompare);

const DirectObjectPool = @import("DirectObjectPool.zig").DirectObjectPool;
var range_pool: DirectObjectPool(RangeWithNodes, .range_pool) = .{};
var memory_region_pool: DirectObjectPool(MemoryRegionWithNode, .memory_region_pool) = .{};

const AddressSpace = @This();

range_address_tree: RegionAddressRedBlackTree = .{},
range_size_tree: RegionSizeRedBlackTree = .{},
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

    const range_with_nodes = try range_pool.get();
    errdefer range_pool.give(range_with_nodes);

    range_with_nodes.* = .{
        .range = total_range,
    };

    var address_space: AddressSpace = .{};

    address_space.range_address_tree.insert(&range_with_nodes.address_ordered_node) catch unreachable;
    address_space.range_size_tree.insert(&range_with_nodes.size_ordered_node) catch unreachable;

    return address_space;
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

    const virtual_range = try self.allocateVirtualRange(size);
    errdefer self.deallocateVirtualRange(virtual_range) catch {
        // FIXME: we have no way to recover from this
        core.panic("deallocateVirtualRange failed, this AddressSpace may now be in an invalid state");
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

    self.deallocateVirtualRange(range) catch unreachable;
    self.deallocateMemoryRegion(range) catch unreachable;
}

fn allocateVirtualRange(self: *AddressSpace, size: core.Size) error{AddressSpaceExhausted}!kernel.VirtualRange {
    // we use `findLastMatch` so we don't immediately grab the first large range we see when there are smaller ones
    // available, we prefer to continue searching in hopes of finding a range with an exact size match or as close as possible
    const matching_range_size_ordered_node = self.range_size_tree.findLastMatch(size, rangeSizeEqualOrGreater) orelse return error.AddressSpaceExhausted;

    // remove the matching range from the size tree
    self.range_size_tree.remove(matching_range_size_ordered_node);

    const matching_range_with_nodes = RangeWithNodes.fromSizeNode(matching_range_size_ordered_node);
    core.debugAssert(matching_range_with_nodes.range.size.greaterThanOrEqual(size));

    // moving back from the end means we don't modify the address of the matching range, meaning it is still in the
    // correct location in the address tree.
    const address = matching_range_with_nodes.range.end().moveBackward(size);

    // shorten the matching range
    matching_range_with_nodes.range.size.subtractInPlace(size);

    if (matching_range_with_nodes.range.size.equal(core.Size.zero)) {
        // if the range is now empty, we remove it from the address tree and give it back to the pool
        self.range_address_tree.remove(&matching_range_with_nodes.address_ordered_node);
        range_pool.give(matching_range_with_nodes);
    } else {
        // reinsert the range into the size tree with the new size
        self.range_size_tree.insert(&matching_range_with_nodes.size_ordered_node) catch unreachable;
    }

    return kernel.VirtualRange.fromAddr(address, size);
}

fn deallocateVirtualRange(self: *AddressSpace, range: kernel.VirtualRange) error{OutOfMemory}!void {
    // find pre-existing range that directly precedes the new range
    if (self.range_address_tree.findFirstMatch(range, rangeDirectlyFollowsCompare)) |matching_range_address_node| {
        // situation: |matching_range| |range|
        // so increase the size of the matching range to encompass the new range, as the size is changing the matching
        // range must be removed from then re-added to the size tree

        const matching_range = RangeWithNodes.fromAddressNode(matching_range_address_node);

        // remove the matching range from the size tree
        self.range_size_tree.remove(&matching_range.size_ordered_node);

        // increase the size of the matching range to encompass the new range
        matching_range.range.size.addInPlace(range.size);

        if (self.range_address_tree.findFirstMatch(matching_range.range, rangeDirectlyPrecedesCompare)) |following_range_node| {
            // situation: |matching_range (matching_range + range)| |following_range|
            // so increase the size of the matching range to encompass the following range and remove the
            // following range from the trees and return it to the pool

            const following_range = RangeWithNodes.fromAddressNode(following_range_node);

            // increase the size of the matching range to encompass the following range
            matching_range.range.size.addInPlace(following_range.range.size);

            // remove the following range from the trees
            self.range_address_tree.remove(following_range_node);
            self.range_size_tree.remove(following_range_node);

            // give the following range back to the pool
            range_pool.give(following_range);
        }

        // reinsert the range into the size tree with the new size
        self.range_size_tree.insert(&matching_range.size_ordered_node) catch unreachable;

        return;
    }

    // find pre-existing range that directly follows the new range
    if (self.range_address_tree.findFirstMatch(range, rangeDirectlyPrecedesCompare)) |matching_range_address_node| {
        // situation: |range| |matching_range|
        // so change the the matching range's address and size to encompass the range, as the address and size is
        // changing it needs to be removed and re-inserted into both trees

        const matching_range = RangeWithNodes.fromAddressNode(matching_range_address_node);

        // remove the matching range from the trees
        self.range_address_tree.remove(&matching_range.address_ordered_node);
        self.range_size_tree.remove(&matching_range.size_ordered_node);

        // change the address and size of the matching range to encompass the range
        matching_range.range.address = range.address;
        matching_range.range.size.addInPlace(range.size);

        if (self.range_address_tree.findFirstMatch(matching_range.range, rangeDirectlyFollowsCompare)) |previous_range_address_node| {
            // situation: |previous_range| |matching_range (matching_range + range)|
            // so increase the size of the previous range to encompass the matching range then return the
            // matching to the pool, as the size is changing the previous range must be removed and re-inserted into
            // the size tree

            const previous_range = RangeWithNodes.fromAddressNode(previous_range_address_node);

            // remove the previous range from the size tree
            self.range_size_tree.remove(&previous_range.size_ordered_node);

            // increase the size of the previous range to encompass the matching range
            previous_range.range.size.addInPlace(matching_range.range.size);

            // reinsert the previous range into the size tree with the new size
            self.range_size_tree.insert(&previous_range.size_ordered_node) catch unreachable;

            // give the matching range back to the pool
            range_pool.give(matching_range);
        } else {
            // reinsert the range into the trees
            self.range_address_tree.insert(&matching_range.address_ordered_node) catch unreachable;
            self.range_size_tree.insert(&matching_range.size_ordered_node) catch unreachable;
        }

        return;
    }

    // no pre-existing range can be extended to cover the new range, so we have to insert it into the trees

    const range_with_nodes = try range_pool.get();

    range_with_nodes.* = .{
        .range = range,
    };

    self.range_address_tree.insert(&range_with_nodes.address_ordered_node) catch unreachable;
    self.range_size_tree.insert(&range_with_nodes.size_ordered_node) catch unreachable;
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

const RangeWithNodes = struct {
    range: kernel.VirtualRange,

    address_ordered_node: RedBlack.Node = .{},
    size_ordered_node: RedBlack.Node = .{},

    inline fn fromAddressNode(node: *RedBlack.Node) *RangeWithNodes {
        return @fieldParentPtr(RangeWithNodes, "address_ordered_node", node);
    }

    inline fn fromAddressNodeConst(node: *const RedBlack.Node) *const RangeWithNodes {
        return @fieldParentPtr(RangeWithNodes, "address_ordered_node", node);
    }

    inline fn fromSizeNode(node: *RedBlack.Node) *RangeWithNodes {
        return @fieldParentPtr(RangeWithNodes, "size_ordered_node", node);
    }

    inline fn fromSizeNodeConst(node: *const RedBlack.Node) *const RangeWithNodes {
        return @fieldParentPtr(RangeWithNodes, "size_ordered_node", node);
    }
};

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

fn rangeAddressCompare(node: *const RedBlack.Node, other_node: *const RedBlack.Node) core.OrderedComparison {
    const range = RangeWithNodes.fromAddressNodeConst(node).range;
    const other_range = RangeWithNodes.fromAddressNodeConst(other_node).range;

    return range.address.compare(other_range.address);
}

fn rangeSizeCompare(node: *const RedBlack.Node, other_node: *const RedBlack.Node) core.OrderedComparison {
    const range = RangeWithNodes.fromSizeNodeConst(node).range;
    const other_range = RangeWithNodes.fromSizeNodeConst(other_node).range;

    const size_compare = range.size.compare(other_range.size);

    if (size_compare == .match) return range.address.compare(other_range.address);

    return size_compare;
}

fn rangeSizeEqualOrGreater(size: core.Size, other_node: *const RedBlack.Node) RedBlack.ComparisonAndMatch {
    const other_range = RangeWithNodes.fromSizeNodeConst(other_node).range;

    const greater_than_or_equal = other_range.size.greaterThanOrEqual(size);

    return .{
        .comparison = if (greater_than_or_equal) .greater else .less,
        .counts_as_a_match = greater_than_or_equal,
    };
}

fn rangeDirectlyFollowsCompare(range: kernel.VirtualRange, other_node: *const RedBlack.Node) core.OrderedComparison {
    const other_range = RangeWithNodes.fromAddressNodeConst(other_node).range;

    const other_end = other_range.end();

    if (range.address.equal(other_end)) return .match;

    return if (range.address.lessThanOrEqual(other_range.address)) .less else .greater;
}

fn rangeDirectlyPrecedesCompare(range: kernel.VirtualRange, other_node: *const RedBlack.Node) core.OrderedComparison {
    const other_range = RangeWithNodes.fromAddressNodeConst(other_node).range;

    const end = range.end();

    if (other_range.address.equal(end)) return .match;

    return if (range.address.lessThanOrEqual(other_range.address)) .less else .greater;
}

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
