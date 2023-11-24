// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const vmm = kernel.vmm;

// Initialized by `vmm.init`
pub var address_space: vmm.AddressSpace = undefined;
var address_space_lock: kernel.sync.SpinLock = .{};

pub const page_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = PageAllocator.alloc,
        .resize = PageAllocator.resize,
        .free = PageAllocator.free,
    },
};

const PageAllocator = struct {
    const heap_map_type: vmm.MapType = .{ .global = true, .writeable = true };

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

        const allocated_range_end = allocated_range.end();
        var current_virtual_range = kernel.VirtualRange.fromAddr(allocated_range.address, kernel.arch.paging.standard_page_size);

        errdefer {
            // Unmap all pages that have been mapped.
            while (current_virtual_range.address.greaterThanOrEqual(allocated_range.address)) {
                vmm.unmapStandardRange(vmm.kernel_root_page_table, current_virtual_range);
                current_virtual_range.address.moveBackwardInPlace(kernel.arch.paging.standard_page_size);
            }
        }

        // Map all pages that were allocated.
        while (!current_virtual_range.address.equal(allocated_range_end)) {
            const physical_range = kernel.pmm.allocatePage() orelse return error.OutOfMemory;

            try vmm.mapStandardRange(
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

        const unallocated_range = kernel.VirtualRange.fromAddr(
            kernel.VirtualAddress.fromPtr(buf.ptr)
                .moveForward(old_aligned_size)
                .moveBackward(unallocated_size),
            unallocated_size,
        );

        freeImpl(unallocated_range);

        return true;
    }

    fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
        var unallocated_range = kernel.VirtualRange.fromSlice(buf);
        unallocated_range.size = unallocated_range.size.alignForward(kernel.arch.paging.standard_page_size);

        freeImpl(unallocated_range);
    }

    fn freeImpl(range: kernel.VirtualRange) void {
        const range_end = range.end();
        var current_virtual_range = kernel.VirtualRange.fromAddr(range.address, kernel.arch.paging.standard_page_size);

        {
            const held = address_space_lock.lock();
            defer held.unlock();

            address_space.deallocate(range);
        }

        while (!current_virtual_range.address.equal(range_end)) {
            vmm.unmapStandardRange(vmm.kernel_root_page_table, range);

            current_virtual_range.address.moveForwardInPlace(kernel.arch.paging.standard_page_size);
        }

        // TODO: Cache needs to be flushed on this core and others.
    }
};
