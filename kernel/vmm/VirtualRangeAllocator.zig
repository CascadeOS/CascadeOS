// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const containers = @import("containers");

const RedBlack = containers.RedBlack;
const RegionAddressRedBlackTree = RedBlack.Tree(rangeAddressCompare);
const RegionSizeRedBlackTree = RedBlack.Tree(rangeSizeCompare);

const VirtualRangePool = kernel.vmm.DirectMapPool(
    RangeWithNodes,
    kernel.config.number_of_bucket_groups_in_virtual_range_pool,
    .virtual_range_pool,
);
var virtual_range_pool: VirtualRangePool = .{};

const log = kernel.log.scoped(.virtual_range_allocator);

const VirtualRangeAllocator = @This();

range_address_tree: RegionAddressRedBlackTree = .{},
range_size_tree: RegionSizeRedBlackTree = .{},

/// Initialize a virtual range allocator.
///
/// **REQUIREMENTS**:
/// - size of `total_range` must be non-zero
pub fn init(total_range: core.VirtualRange) VirtualRangePool.GetError!VirtualRangeAllocator {
    core.assert(total_range.size.value != 0);

    const range_with_nodes = try virtual_range_pool.get();
    errdefer virtual_range_pool.give(range_with_nodes);

    range_with_nodes.* = .{
        .range = total_range,
    };

    var range_allocator: VirtualRangeAllocator = .{};

    range_allocator.range_address_tree.insert(&range_with_nodes.address_ordered_node) catch unreachable;
    range_allocator.range_size_tree.insert(&range_with_nodes.size_ordered_node) catch unreachable;

    return range_allocator;
}

pub const AllocateRangeError = error{VirtualRangeAllocatorExhausted};

pub fn allocateRange(self: *VirtualRangeAllocator, size: core.Size) AllocateRangeError!core.VirtualRange {
    // we use `findLastMatch` so we don't immediately grab the first large range we see when there are smaller ones
    // available, we prefer to continue searching in hopes of finding a range with an exact size match or as close as possible
    const matching_range_size_ordered_node = self.range_size_tree.findLastMatch(
        size,
        rangeSizeEqualOrGreater,
    ) orelse return error.VirtualRangeAllocatorExhausted;

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
        virtual_range_pool.give(matching_range_with_nodes);
    } else {
        // reinsert the range into the size tree with the new size
        self.range_size_tree.insert(&matching_range_with_nodes.size_ordered_node) catch unreachable;
    }

    const range = core.VirtualRange.fromAddr(address, size);

    log.debug("allocated: {}", .{range});

    return range;
}

pub const DeallocateRangeError = VirtualRangePool.GetError;

pub fn deallocateRange(self: *VirtualRangeAllocator, range: core.VirtualRange) DeallocateRangeError!void {
    defer log.debug("deallocated: {}", .{range});

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
            virtual_range_pool.give(following_range);
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

        if (self.range_address_tree.findFirstMatch(
            matching_range.range,
            rangeDirectlyFollowsCompare,
        )) |previous_range_address_node| {
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
            virtual_range_pool.give(matching_range);
        } else {
            // reinsert the range into the trees
            self.range_address_tree.insert(&matching_range.address_ordered_node) catch unreachable;
            self.range_size_tree.insert(&matching_range.size_ordered_node) catch unreachable;
        }

        return;
    }

    // no pre-existing range can be extended to cover the new range, so we have to insert it into the trees

    const range_with_nodes = try virtual_range_pool.get();

    range_with_nodes.* = .{
        .range = range,
    };

    self.range_address_tree.insert(&range_with_nodes.address_ordered_node) catch unreachable;
    self.range_size_tree.insert(&range_with_nodes.size_ordered_node) catch unreachable;
}

const RangeWithNodes = struct {
    range: core.VirtualRange,

    address_ordered_node: RedBlack.Node = .{},
    size_ordered_node: RedBlack.Node = .{},

    inline fn fromAddressNode(node: *RedBlack.Node) *RangeWithNodes {
        return @fieldParentPtr("address_ordered_node", node);
    }

    inline fn fromAddressNodeConst(node: *const RedBlack.Node) *const RangeWithNodes {
        return @fieldParentPtr("address_ordered_node", node);
    }

    inline fn fromSizeNode(node: *RedBlack.Node) *RangeWithNodes {
        return @fieldParentPtr("size_ordered_node", node);
    }

    inline fn fromSizeNodeConst(node: *const RedBlack.Node) *const RangeWithNodes {
        return @fieldParentPtr("size_ordered_node", node);
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

fn rangeDirectlyFollowsCompare(range: core.VirtualRange, other_node: *const RedBlack.Node) core.OrderedComparison {
    const other_range = RangeWithNodes.fromAddressNodeConst(other_node).range;

    const other_end = other_range.end();

    if (range.address.equal(other_end)) return .match;

    return if (range.address.lessThanOrEqual(other_range.address)) .less else .greater;
}

fn rangeDirectlyPrecedesCompare(range: core.VirtualRange, other_node: *const RedBlack.Node) core.OrderedComparison {
    const other_range = RangeWithNodes.fromAddressNodeConst(other_node).range;

    const end = range.end();

    if (other_range.address.equal(end)) return .match;

    return if (range.address.lessThanOrEqual(other_range.address)) .less else .greater;
}
