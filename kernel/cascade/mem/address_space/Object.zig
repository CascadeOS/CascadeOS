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
//! Made with reference to [OpenBSD implementation of UVM](https://github.com/openbsd/src/tree/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm)
//!

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const Page = cascade.mem.Page;
const core = @import("core");

const PageChunkMap = @import("chunk_map.zig").ChunkMap(Page);

const log = cascade.debug.log.scoped(.address_space);

const Object = @This();

lock: cascade.sync.RwLock = .{},

reference_count: u32 = 1,

page_chunks: PageChunkMap = .{},

/// Increment the reference count.
///
/// When called a write lock must be held.
pub fn incrementReferenceCount(object: *Object) void {
    if (core.is_debug) {
        std.debug.assert(object.reference_count != 0);
        std.debug.assert(object.lock.isWriteLocked());
    }

    object.reference_count += 1;
}

/// Decrement the reference count.
///
/// When called a write lock must be held, upon return the lock is unlocked.
pub fn decrementReferenceCount(object: *Object, current_task: Task.Current) void {
    if (core.is_debug) {
        std.debug.assert(object.reference_count != 0);
        std.debug.assert(object.lock.isWriteLocked());
    }

    const reference_count = object.reference_count;
    object.reference_count = reference_count - 1;
    object.lock.writeUnlock(current_task);

    if (reference_count == 1) {
        // reference count is now zero, destroy the object

        if (true) @panic("NOT IMPLEMENTED"); // TODO
    }
}

pub const Reference = struct {
    object: ?*Object,
    start_offset: core.Size,

    /// Prints the anonymous map reference.
    pub fn print(
        object_reference: Reference,
        current_task: Task.Current,
        writer: *std.Io.Writer,
        indent: usize,
    ) !void {
        const new_indent = indent + 2;

        if (object_reference.object) |object| {
            try writer.writeAll("Object.Reference{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("start_offset: {f}\n", .{object_reference.start_offset});

            try writer.splatByteAll(' ', new_indent);
            try object.print(
                current_task,
                writer,
                new_indent,
            );
            try writer.writeAll(",\n");

            try writer.splatByteAll(' ', indent);
            try writer.writeAll("}");
        } else {
            try writer.writeAll("Object.Reference{ none }");
        }
    }

    pub inline fn format(_: Reference, _: *std.Io.Writer) !void {
        @compileError("use `Reference.print` instead");
    }
};

/// Prints the object.
///
/// Locks the spinlock.
pub fn print(
    object: *Object,
    current_task: Task.Current,
    writer: *std.Io.Writer,
    indent: usize,
) !void {
    const new_indent = indent + 2;

    object.lock.readLock(current_task);
    defer object.lock.readLock(current_task);

    try writer.writeAll("Object{\n");

    try writer.splatByteAll(' ', new_indent);
    try writer.writeAll("TODO\n");
    if (true) @panic("NOT IMPLEMENTED"); // TODO: implement object debug printing

    try writer.splatByteAll(' ', indent);
    try writer.writeAll("}");
}

pub inline fn format(_: *const *Object, _: *std.Io.Writer) !void {
    @compileError("use `Object.print` instead");
}
