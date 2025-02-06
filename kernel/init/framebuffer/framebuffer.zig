// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

// Does not scroll instead wraps to the top of the screen.
// Due to this is needs to clear the entire line with when a new line is started.
// TODO: This entire thing needs to be rewritten.

/// Writes the given string to the framebuffer using the SSFN console bitmap font.
fn write(_: *anyopaque, str: []const u8) void {
    var iter: std.unicode.Utf8Iterator = .{
        .bytes = str,
        .i = 0,
    };

    while (iter.nextCodepoint()) |codepoint| {
        switch (codepoint) {
            '\r' => c.ssfn_dst.x = 0,
            '\n' => newLine(),
            '\t' => {
                for (0..4) |_| {
                    if (c.ssfn_putc(' ') != c.SSFN_OK) return;
                }
                maybeNewLine();
            },
            else => {
                if (c.ssfn_putc(codepoint) != c.SSFN_OK) return;
                maybeNewLine();
            },
        }
    }
}

inline fn maybeNewLine() void {
    if (c.ssfn_dst.x >= c.ssfn_dst.w) {
        newLine();
    }
}

fn newLine() void {
    c.ssfn_dst.x = 0;
    c.ssfn_dst.y += font.height;
    if (c.ssfn_dst.y + font.height >= c.ssfn_dst.h) {
        c.ssfn_dst.y = 0;
    }

    const x = c.ssfn_dst.x;
    const y = c.ssfn_dst.y;

    defer c.ssfn_dst.x = x;
    defer c.ssfn_dst.y = y;

    while (c.ssfn_dst.x < c.ssfn_dst.w) {
        _ = c.ssfn_putc(' ');
    }
}

/// Map the framebuffer into the special heap as write combining.
pub fn remapFramebuffer(current_task: *kernel.Task) !void {
    const framebuffer = kernel.boot.framebuffer() orelse return;

    const exact_framebuffer_physical_base: core.PhysicalAddress = try kernel.vmm.physicalFromDirectMap(.fromPtr(@volatileCast(framebuffer.ptr)));
    const aligned_framebuffer_physical_base = exact_framebuffer_physical_base.alignBackward(kernel.arch.paging.standard_page_size);

    const offset: core.Size = .from(exact_framebuffer_physical_base.value - aligned_framebuffer_physical_base.value, .byte);

    const exact_framebuffer_size: core.Size = .from(framebuffer.height * @sizeOf(u32) * framebuffer.pixels_per_row, .byte);
    const aligned_framebuffer_size = exact_framebuffer_size.alignForward(kernel.arch.paging.standard_page_size);

    const virtual_range = try kernel.heap.allocateSpecial(
        current_task,
        aligned_framebuffer_size,
        .fromAddr(
            exact_framebuffer_physical_base,
            exact_framebuffer_size,
        ),
        .{ .writeable = true, .global = true, .write_combining = true },
    );

    global.frame_buffer_range = virtual_range;
    c.ssfn_dst.ptr = virtual_range.address.moveForward(offset).toPtr([*]u8);
}

pub fn registerInitOutput() void {
    const framebuffer = kernel.boot.framebuffer() orelse return;

    c.ssfn_src = @constCast(font);
    c.ssfn_dst = .{
        .ptr = @ptrCast(@volatileCast(framebuffer.ptr)),
        .w = @intCast(framebuffer.width),
        .h = @intCast(framebuffer.height),
        .p = @intCast(framebuffer.pixels_per_row * @sizeOf(u32)),
        .x = 0,
        .y = 0,
        .fg = 0x00FFFFFF,
        .bg = 0xFF000000,
    };

    kernel.init.Output.registerOutput(.{
        .writeFn = write,
        .context = undefined,
    });
}

const global = struct {
    var frame_buffer_range: ?core.VirtualRange = null;
};

const font: *const c.ssfn_font_t = blk: {
    break :blk @ptrCast(@embedFile("ter-v14n.sfn"));
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const c = @cImport({
    @cInclude("ssfn.h");
});
