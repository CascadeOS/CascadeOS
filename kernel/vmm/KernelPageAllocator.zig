// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const vmm = @import("vmm.zig");

const log = kernel.log.scoped(.kernel_heap);

const KernelPageAllocator = @This();

pub const kernel_page_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    },
};

/// Attempt to allocate exactly `len` bytes aligned to `1 << ptr_align`.
///
/// `ret_addr` is optionally provided as the first return address of the
/// allocation call stack. If the value is `0` it means no return address
/// has been provided.
fn alloc(_: *anyopaque, len: usize, _: u8, _: usize) ?[*]u8 {
    log.debug("alloc - len: {}", .{len});

    core.debugAssert(len != 0);
    const result = allocImpl(len) catch |err| {
        log.err("{s}", .{@errorName(err)});
        return null;
    };

    log.debug("result: {any}", .{result});

    return result;
}

const heap_map_type: vmm.MapType = .{ .global = true, .writeable = true };

inline fn allocImpl(len: usize) !?[*]u8 {
    const aligned_size = core.Size.from(len, .byte).alignForward(kernel.arch.paging.standard_page_size);

    const allocated_range = blk: {
        const held = vmm.kernel_heap_address_space_lock.lock();
        defer held.unlock();

        break :blk vmm.kernel_heap_address_space.allocate(
            aligned_size,
            heap_map_type,
        ) catch return null;
    };
    errdefer {
        const held = vmm.kernel_heap_address_space_lock.lock();
        defer held.unlock();
        vmm.kernel_heap_address_space.deallocate(allocated_range);
    }

    const allocated_range_end = allocated_range.end();

    var current_virtual_range = kernel.VirtualRange.fromAddr(allocated_range.address, kernel.arch.paging.standard_page_size);
    errdefer {
        while (current_virtual_range.address.greaterThanOrEqual(allocated_range.address)) {
            vmm.unmapRange(vmm.kernel_root_page_table, current_virtual_range);
            current_virtual_range.address.moveBackwardInPlace(kernel.arch.paging.standard_page_size);
        }
    }

    while (!current_virtual_range.address.equal(allocated_range_end)) {
        const physical_range = kernel.pmm.allocatePage() orelse return error.OutOfMemory;

        try vmm.mapRange(
            vmm.kernel_root_page_table,
            current_virtual_range,
            physical_range,
            heap_map_type,
        );

        current_virtual_range.address.moveForwardInPlace(kernel.arch.paging.standard_page_size);
    }

    return allocated_range.address.toPtr([*]u8);
}

fn resize(_: *anyopaque, buf: []u8, _: u8, new_len: usize, _: usize) bool {
    log.debug("resize - old buf: {*} - new len: {}", .{ buf, new_len });

    const old_aligned_size = core.Size.from(buf.len, .byte).alignForward(kernel.arch.paging.standard_page_size);

    const new_aligned_size = core.Size.from(new_len, .byte).alignForward(kernel.arch.paging.standard_page_size);

    if (new_aligned_size.equal(old_aligned_size)) return true;

    if (new_aligned_size.greaterThan(old_aligned_size)) return false;

    const unallocated_size = new_aligned_size.subtract(old_aligned_size);
    core.debugAssert(unallocated_size.isAligned(kernel.arch.paging.standard_page_size));

    const unallocated_range = kernel.VirtualRange.fromAddr(
        kernel.VirtualRange.fromSlice(buf).end().moveBackward(unallocated_size),
        unallocated_size,
    );

    const held = vmm.kernel_heap_address_space_lock.lock();
    defer held.unlock();
    vmm.kernel_heap_address_space.deallocate(unallocated_range);
    vmm.unmapRange(vmm.kernel_root_page_table, unallocated_range);

    // TODO: Cache needs to be flushed on this core and others.

    return true;
}

fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    log.debug("free - buf: {*}", .{buf});

    var unallocated_range = kernel.VirtualRange.fromSlice(buf);
    unallocated_range.size = unallocated_range.size.alignForward(kernel.arch.paging.standard_page_size);

    const held = vmm.kernel_heap_address_space_lock.lock();
    defer held.unlock();
    vmm.kernel_heap_address_space.deallocate(unallocated_range);
    vmm.unmapRange(vmm.kernel_root_page_table, unallocated_range);

    // TODO: Cache needs to be flushed on this core and others.
}
