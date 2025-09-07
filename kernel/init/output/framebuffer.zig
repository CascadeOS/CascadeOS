// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const boot = @import("boot");
const cascade = @import("cascade");
const core = @import("core");
const init = @import("init");

// Does not scroll instead wraps to the top of the screen.
// Due to this is needs to clear the entire line with when a new line is started.

pub fn tryGetFramebufferOutput() ?init.Output {
    const framebuffer = boot.framebuffer() orelse return null;

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

    return .{
        .writeFn = struct {
            fn writeFn(_: *anyopaque, str: []const u8) void {
                writeSlice(str);
            }
        }.writeFn,
        .splatFn = struct {
            fn splatFn(_: *anyopaque, str: []const u8, splat: usize) void {
                for (0..splat) |_| writeSlice(str);
            }
        }.splatFn,
        .remapFn = remapFramebuffer,
        .state = undefined,
    };
}

/// Writes the given string to the framebuffer using the SSFN console bitmap font.
fn writeSlice(str: []const u8) void {
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

    const y: usize = @intCast(c.ssfn_dst.y);
    const height: usize = @intCast(font.height);

    const offset = (y * c.ssfn_dst.p) / @sizeOf(u32);
    const len = (height * c.ssfn_dst.p) / @sizeOf(u32);

    const ptr: [*]volatile u32 = @ptrCast(@alignCast(c.ssfn_dst.ptr));
    const slice: []volatile u32 = ptr[offset..][0..len];

    @memset(slice, 0);
}

/// Map the framebuffer into the special heap as write combining.
fn remapFramebuffer(_: *anyopaque, context: *cascade.Context) !void {
    const framebuffer = boot.framebuffer().?;

    const physical_address: core.PhysicalAddress = try cascade.mem.physicalFromDirectMap(.fromPtr(@volatileCast(framebuffer.ptr)));
    if (!physical_address.isAligned(arch.paging.standard_page_size)) @panic("framebuffer is not aligned");

    const framebuffer_size: core.Size = .from(framebuffer.height * @sizeOf(u32) * framebuffer.pixels_per_row, .byte);

    const virtual_range = try cascade.mem.heap.allocateSpecial(
        context,
        framebuffer_size,
        .fromAddr(
            physical_address,
            framebuffer_size,
        ),
        .{
            .environment_type = .kernel,
            .protection = .read_write,
            .cache = .write_combining,
        },
    );

    c.ssfn_dst.ptr = virtual_range.address.toPtr([*]u8);
}

const font: *const c.ssfn_font_t = blk: {
    break :blk @ptrCast(@embedFile("ter-v14n.sfn"));
};

const c = @cImport({
    @cInclude("ssfn.h");
});
