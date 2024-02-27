// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

pub const AddressSpace = @import("AddressSpace.zig");
pub const DirectObjectPool = @import("DirectObjectPool.zig").DirectObjectPool;
pub const RangeAllocator = @import("RangeAllocator.zig");

var address_space: AddressSpace = undefined; // Initialised in `initHeap`
var address_space_lock: kernel.SpinLock = .{};

pub const page_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = PageAllocator.alloc,
        .resize = PageAllocator.resize,
        .free = PageAllocator.free,
    },
};

const PageAllocator = struct {
    const heap_map_type: kernel.memory.virtual.MapType = .{ .global = true, .writeable = true };

    fn alloc(_: *anyopaque, len: usize, _: u8, _: usize) ?[*]u8 {
        core.debugAssert(len != 0);
        return allocImpl(len) catch return null;
    }

    // A seperate function is used to allow for the usage of `errdefer`.
    inline fn allocImpl(len: usize) !?[*]u8 {
        const aligned_size = core.Size.from(len, .byte)
            .alignForward(kernel.arch.paging.standard_page_size);

        const allocated_range = blk: {
            const held = address_space_lock.lock();
            defer held.unlock();

            break :blk address_space.allocate(
                aligned_size,
                heap_map_type,
            ) catch return null;
        };
        errdefer {
            const held = address_space_lock.lock();
            defer held.unlock();
            address_space.deallocate(allocated_range);
        }

        try kernel.memory.virtual.mapRange(
            kernel.kernel_process.page_table,
            allocated_range,
            heap_map_type,
        );

        return allocated_range.address.toPtr([*]u8);
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

        return true;
    }

    fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
        var allocated_range = core.VirtualRange.fromSlice(u8, buf);
        allocated_range.size = allocated_range.size.alignForward(kernel.arch.paging.standard_page_size);

        freeImpl(allocated_range);
    }

    fn freeImpl(range: core.VirtualRange) void {
        {
            const held = address_space_lock.lock();
            defer held.unlock();

            address_space.deallocate(range);
        }

        kernel.memory.virtual.unmap(kernel.kernel_process.page_table, range);

        // TODO: Cache needs to be flushed on this core and others.
    }
};

pub const init = struct {
    pub fn initHeap(kernel_heap_range: core.VirtualRange) linksection(kernel.info.init_code) !void {
        address_space = try AddressSpace.init(kernel_heap_range);
    }
};
