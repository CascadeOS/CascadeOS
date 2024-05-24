// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.eternal_heap);

const map_type: kernel.vmm.MapType = .{ .global = true, .writeable = true };

var lock: kernel.sync.TicketSpinLock = .{};
var next_address: core.VirtualAddress = undefined; // Initialized in `initEternalHeap`
var last_address: core.VirtualAddress = undefined; // Initialized in `initEternalHeap`

pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    },
};

fn alloc(_: *anyopaque, len: usize, log2_ptr_align: u8, _: usize) ?[*]u8 {
    core.debugAssert(len != 0);

    const aligned_size = core.Size.from(len, .byte)
        .alignForward(kernel.arch.paging.standard_page_size);

    const ptr_align = core.Size.from(
        @as(usize, 1) << @as(std.mem.Allocator.Log2Align, @intCast(log2_ptr_align)),
        .byte,
    );

    const address = blk: {
        const held = lock.acquire();
        defer held.release();

        var new_next_address = next_address;

        new_next_address.alignForwardInPlace(ptr_align);

        const address = new_next_address;

        new_next_address.moveForwardInPlace(aligned_size);

        if (new_next_address.greaterThan(last_address)) {
            log.warn("eternal heap unable to allocate - size {} - align {}", .{ aligned_size, ptr_align });
            return null;
        }

        const allocated_range = core.VirtualRange.fromAddr(address, aligned_size);

        kernel.vmm.mapRange(
            kernel.vmm.kernel_page_table,
            allocated_range,
            map_type,
        ) catch |err| {
            log.warn("eternal heap unable to map - size {} - align {} - {s}", .{
                aligned_size,
                ptr_align,
                @errorName(err),
            });
        };

        next_address = new_next_address;

        break :blk address;
    };

    log.debug("allocated - {}", .{core.VirtualRange.fromAddr(address, aligned_size)});

    return address.toPtr([*]u8);
}

fn resize(_: *anyopaque, buf: []u8, _: u8, new_len: usize, _: usize) bool {
    const old_aligned_size = core.Size.from(buf.len, .byte)
        .alignForward(kernel.arch.paging.standard_page_size);

    const new_aligned_size = core.Size.from(new_len, .byte)
        .alignForward(kernel.arch.paging.standard_page_size);

    // allow anything to shrink as we don't need to free anything
    return new_aligned_size.lessThanOrEqual(old_aligned_size);
}

fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {
    core.panic("free called on eternal heap allocator");
}

pub const init = struct {
    pub fn initEternalHeap(kernel_eternal_heap_range: core.VirtualRange) void {
        core.debugAssert(kernel_eternal_heap_range.size.isAligned(kernel.arch.paging.standard_page_size));
        core.debugAssert(kernel_eternal_heap_range.address.isAligned(kernel.arch.paging.standard_page_size));

        next_address = kernel_eternal_heap_range.address;
        last_address = kernel_eternal_heap_range.last();
    }
};
