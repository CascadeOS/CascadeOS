// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const boot = @import("boot");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");

const init_log = kernel.debug.log.scoped(.output_init);

const c = @cImport({
    @cInclude("flanterm.h");
    @cInclude("flanterm_backends/fb.h");
});

pub fn tryGetFramebufferOutput(memory_system_available: bool) ?kernel.init.Output {
    return tryGetFramebufferOutputInner(memory_system_available) catch |err| {
        init_log.err("failed to initialize serial output: {}", .{err});
        return null;
    };
}

fn tryGetFramebufferOutputInner(memory_system_available: bool) !?kernel.init.Output {
    if (!memory_system_available) return null;

    const framebuffer = boot.framebuffer() orelse return null;

    const physical_address: core.PhysicalAddress = try kernel.mem.physicalFromDirectMap(
        .fromPtr(@volatileCast(framebuffer.ptr)),
    );

    if (!physical_address.isAligned(arch.paging.standard_page_size)) @panic("framebuffer is not aligned");

    const framebuffer_size: core.Size = .from(framebuffer.height * framebuffer.pitch, .byte);

    const virtual_range = try kernel.mem.heap.allocateSpecial(
        framebuffer_size,
        .fromAddr(
            physical_address,
            framebuffer_size,
        ),
        .{
            .type = .kernel,
            .protection = .read_write,
            .cache = .write_combining,
        },
    );
    errdefer kernel.mem.heap.deallocateSpecial(virtual_range);

    const flanterm_context = c.flanterm_fb_init(
        flantermMalloc,
        flantermFree,
        virtual_range.address.toPtr([*]u32),
        framebuffer.width,
        framebuffer.height,
        framebuffer.pitch,
        framebuffer.red_mask_size,
        framebuffer.red_mask_shift,
        framebuffer.green_mask_size,
        framebuffer.green_mask_shift,
        framebuffer.blue_mask_size,
        framebuffer.blue_mask_shift,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        @constCast(font),
        8,
        16,
        1,
        1,
        1,
        0,
        0,
    ) orelse return error.FailedToInitializeFramebuffer;

    return .{
        .name = arch.init.InitOutput.Output.Name.fromSlice("flanterm framebuffer") catch unreachable,
        .writeFn = struct {
            fn writeFn(con: *anyopaque, str: []const u8) void {
                c.flanterm_write(@ptrCast(@alignCast(con)), str.ptr, str.len);
            }
        }.writeFn,
        .splatFn = struct {
            fn splatFn(con: *anyopaque, str: []const u8, splat: usize) void {
                const context: *c.flanterm_context = @ptrCast(@alignCast(con));
                for (0..splat) |_| c.flanterm_write(context, str.ptr, str.len);
            }
        }.splatFn,
        .state = flanterm_context,
    };
}

fn flantermMalloc(size: usize) callconv(.c) ?*anyopaque {
    const buf = kernel.mem.heap.allocator.alloc(u8, size) catch return null;
    return buf.ptr;
}

fn flantermFree(raw_ptr: ?*anyopaque, size: usize) callconv(.c) void {
    const ptr: [*]u8 = @ptrCast(raw_ptr orelse {
        @branchHint(.unlikely);
        return;
    });
    kernel.mem.heap.allocator.free(ptr[0..size]);
}

const font = @embedFile("simple.font");
