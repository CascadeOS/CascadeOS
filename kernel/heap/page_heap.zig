// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.page_heap);

const map_type: kernel.vmm.MapType = .{ .global = true, .writeable = true };

var mutex: kernel.sync.Mutex = .{};
var address_space: kernel.vmm.AddressSpace = undefined; // Initialized in `initPageHeap`

pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    },
};

fn alloc(_: *anyopaque, len: usize, _: u8, _: usize) ?[*]u8 {
    core.debugAssert(len != 0);

    const aligned_size = core.Size.from(len, .byte)
        .alignForward(kernel.arch.paging.standard_page_size);

    blk: {
        const opt_range = allocImpl(aligned_size) catch break :blk;
        const range = opt_range orelse break :blk;
        log.debug("allocated - {}", .{range});
        return range.address.toPtr([*]u8);
    }

    log.warn("failed to allocate - size {}", .{aligned_size});
    return null;
}

// A seperate function is used to allow for the usage of `errdefer`.
inline fn allocImpl(aligned_size: core.Size) !?core.VirtualRange {
    const held = mutex.acquire();
    defer held.release();

    const allocated_range = address_space.allocate(
        aligned_size,
        map_type,
    ) catch return null;
    errdefer address_space.deallocate(allocated_range);

    try kernel.vmm.mapRange(
        kernel.vmm.kernelPageTable(),
        allocated_range,
        map_type,
    );

    return allocated_range;
}

fn resize(_: *anyopaque, buf: []u8, _: u8, new_len: usize, _: usize) bool {
    const old_aligned_size = core.Size.from(buf.len, .byte)
        .alignForward(kernel.arch.paging.standard_page_size);

    const new_aligned_size = core.Size.from(new_len, .byte)
        .alignForward(kernel.arch.paging.standard_page_size);

    // If the new size is the same as the old size after alignment, then we can just return.
    if (new_aligned_size.equal(old_aligned_size)) return true;

    // If the new size is larger than the old size after alignment then a resize in place is not possible.
    if (new_aligned_size.greaterThan(old_aligned_size)) return false;

    // If the new size is smaller than the old size after alignment then we need to unmap the extra pages.
    const unallocated_size = old_aligned_size.subtract(new_aligned_size);
    core.debugAssert(unallocated_size.isAligned(kernel.arch.paging.standard_page_size));

    const unallocated_range = core.VirtualRange.fromAddr(
        core.VirtualAddress.fromPtr(buf.ptr)
            .moveForward(old_aligned_size)
            .moveBackward(unallocated_size),
        unallocated_size,
    );

    freeImpl(unallocated_range);

    log.debug("resized allocation from {} to {}", .{ old_aligned_size, new_aligned_size });

    return true;
}

fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    var allocated_range = core.VirtualRange.fromSlice(u8, buf);

    allocated_range.size = allocated_range.size.alignForward(kernel.arch.paging.standard_page_size);

    freeImpl(allocated_range);

    log.debug("freed allocation {}", .{allocated_range});
}

fn freeImpl(range: core.VirtualRange) void {
    const held = mutex.acquire();
    defer held.release();

    address_space.deallocate(range);

    kernel.vmm.unmapRange(kernel.vmm.kernelPageTable(), range);

    // TODO: Cache needs to be flushed on this core and others.
}

pub const init = struct {
    pub fn initPageHeap(kernel_page_heap_range: core.VirtualRange) !void {
        core.debugAssert(kernel_page_heap_range.size.isAligned(kernel.arch.paging.standard_page_size));
        core.debugAssert(kernel_page_heap_range.address.isAligned(kernel.arch.paging.standard_page_size));

        address_space = try kernel.vmm.AddressSpace.init(kernel_page_heap_range);
    }
};
