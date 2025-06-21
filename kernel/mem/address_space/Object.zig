// SPDX-License-Identifier: MIT and BSD-2-Clause
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: Copyright (c) 1997 Charles D. Cranor and Washington University.

//! A memory object describing a file or device.
//!
//! Called a `uvm_object` in uvm.
//!
//! Based on UVM:
//!   * [Design and Implementation of the UVM Virtual Memory System](https://chuck.cranor.org/p/diss.pdf) by Charles D. Cranor
//!   * [Zero-Copy Data Movement Mechanisms for UVM](https://citeseerx.ist.psu.edu/document?repid=rep1&type=pdf&doi=8961abccddf8ff24f7b494cd64d5cf62604b0018) by Charles D. Cranor and Gurudatta M. Parulkar
//!   * [The UVM Virtual Memory System](https://www.usenix.org/legacy/publications/library/proceedings/usenix99/full_papers/cranor/cranor.pdf) by Charles D. Cranor and Gurudatta M. Parulkar
//!
//! Made with reference to [OpenBSD implementation of UVM](https://github.com/openbsd/src/tree/master/sys/uvm)
//!

const Object = @This();

lock: kernel.sync.RwLock = .{},

reference_count: u32 = 1,

page_chunks: PageChunkMap = .{},

pub const Reference = struct {
    object: ?*Object,
    start_offset: u32,

    /// Prints the anonymous map reference.
    pub fn print(
        object_reference: Reference,
        current_task: *kernel.Task,
        writer: std.io.AnyWriter,
        indent: usize,
    ) !void {
        const new_indent = indent + 2;

        if (object_reference.object) |object| {
            try writer.writeAll("Object.Reference{\n");

            try writer.writeByteNTimes(' ', new_indent);
            try writer.print("start_offset: {d}\n", .{object_reference.start_offset});

            try writer.writeByteNTimes(' ', new_indent);
            try object.print(
                current_task,
                writer,
                new_indent,
            );
            try writer.writeAll(",\n");

            try writer.writeByteNTimes(' ', indent);
            try writer.writeAll("}");
        } else {
            try writer.writeAll("Object.Reference{ none }");
        }
    }

    pub inline fn format(
        _: Reference,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        _: anytype,
    ) !void {
        @compileError("use `Reference.print` instead");
    }
};

/// Prints the object.
///
/// Locks the spinlock.
pub fn print(
    object: *Object,
    current_task: *kernel.Task,
    writer: std.io.AnyWriter,
    indent: usize,
) !void {
    const new_indent = indent + 2;

    object.lock.readLock(current_task);
    defer object.lock.readLock(current_task);

    try writer.writeAll("Object{\n");

    try writer.writeByteNTimes(' ', new_indent);
    try writer.writeAll("TODO\n");
    if (true) @panic("NOT IMPLEMENTED"); // TODO: implement object debug printing

    try writer.writeByteNTimes(' ', indent);
    try writer.writeAll("}");
}

pub inline fn format(
    _: *const *Object,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    _: anytype,
) !void {
    @compileError("use `Object.print` instead");
}

const PageChunkMap = @import("chunk_map.zig").ChunkMap(Page);
const Page = kernel.mem.Page; // called a `vm_page` in uvm

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.address_space);
