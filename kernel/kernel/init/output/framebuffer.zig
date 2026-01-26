// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const boot = @import("boot");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");

const c = @cImport({
    @cDefine("FLANTERM_IN_FLANTERM", "1"); // needed to enable including 'fb_private.h'
    @cInclude("flanterm.h");
    @cInclude("flanterm_backends/fb.h");
    @cInclude("flanterm_backends/fb_private.h"); // needed to reach into the context and remap the framebuffer
});

pub fn tryGetFramebufferOutput() ?kernel.init.Output {
    const framebuffer = boot.framebuffer() orelse return null;

    const flanterm_context = c.flanterm_fb_init(
        null,
        null,
        @volatileCast(framebuffer.ptr),
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
    ) orelse return null;

    return .{
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
        .remapFn = remapFramebuffer,
        .state = flanterm_context,
    };
}

/// Map the framebuffer into the special heap as write combining.
fn remapFramebuffer(con: *anyopaque) !void {
    const framebuffer = boot.framebuffer().?;

    const physical_address: core.PhysicalAddress = try kernel.mem.physicalFromDirectMap(.fromPtr(@volatileCast(framebuffer.ptr)));
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

    const fb_context: *c.flanterm_fb_context = @ptrCast(@alignCast(con));
    fb_context.framebuffer = virtual_range.address.toPtr([*]u32);
}

const font = @embedFile("simple.font");
