// SPDX-License-Identifier: LicenseRef-NON-AI-MIT and BSD-2-Clause
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: Copyright (c) 1997 Charles D. Cranor and Washington University.

//! A virtual address space entry.
//!
//! Called a `vm_map_entry` in uvm.
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
const Cache = cascade.mem.cache.Cache;
const Protection = cascade.mem.MapType.Protection;
const core = @import("core");

const AnonymousMap = @import("AnonymousMap.zig");
const Object = @import("Object.zig");

const log = cascade.debug.log.scoped(.address_space);

const Entry = @This();

range: core.VirtualRange,

protection: Protection,
max_protection: Protection,

anonymous_map_reference: AnonymousMap.Reference,
object_reference: Object.Reference,

/// If `true` all writes must occur in anonymous memory.
///
/// If `false` then this is a shared mapping and writes should occur in the object's memory.
copy_on_write: bool,

/// If `true` this entry needs is own private `AnonymousMap` but it has not been created yet.
///
/// Either the entry has no anonymous map or it has a reference to an anonymous map that should be copied on first
/// write.
needs_copy: bool,

wired_count: u32,

pub fn create(current_task: Task.Current) !*Entry {
    var entry: [1]*Entry = undefined;
    try createMany(current_task, &entry);
    return entry[0];
}

pub fn createMany(current_task: Task.Current, items: []*Entry) !void {
    return globals.entry_cache.allocateMany(current_task, items) catch |err| switch (err) {
        error.SlabAllocationFailed => return error.OutOfMemory,
        error.ItemConstructionFailed => unreachable, // no constructor is provided
        error.LargeItemAllocationFailed => unreachable, // `Entry` is not a large entry - checked in `global_init.initializeCaches`
    };
}

pub fn destroy(entry: *Entry, current_task: Task.Current) void {
    globals.entry_cache.deallocate(current_task, entry);
}

pub fn anyOverlap(entry: *const Entry, other: *const Entry) bool {
    return entry.range.anyOverlap(other.range);
}

/// Determine if `second_entry` can be merged into `first_entry`.
///
/// This must be observed to be `true` before `merge` is can be called on the entries.
///
/// Can only be `true` when `second_entry` immediately follows `first_entry` in the address space.
pub fn canMerge(first_entry: *const Entry, second_entry: *const Entry) bool {
    if (first_entry.protection != second_entry.protection) return false;
    if (first_entry.max_protection != second_entry.max_protection) return false;
    if (first_entry.copy_on_write != second_entry.copy_on_write) return false;
    if (first_entry.wired_count != second_entry.wired_count) return false;

    if (first_entry.range.endBound().notEqual(second_entry.range.address)) {
        // `second_entry` does not immediately follow `first_entry`
        return false;
    }

    object: {
        const first_object = first_entry.object_reference.object orelse {
            if (second_entry.object_reference.object != null) {
                // `second_entry` has an object reference, `first_entry` has no object reference
                return false;
            }
            // no objects to prevent merging
            break :object;
        };

        const second_object = second_entry.object_reference.object orelse {
            // `first_entry` has an object reference, `second_entry` has no object reference
            return false;
        };

        if (first_object != second_object) {
            // objects dont match
            return false;
        }

        if (first_entry.object_reference.start_offset
            .add(first_entry.range.size)
            .notEqual(second_entry.object_reference.start_offset))
        {
            // `second_entry` object reference does not immediately follow `first_entry` object reference
            return false;
        }
    }

    anonymous_map: {
        const first_anonymous_map = first_entry.anonymous_map_reference.anonymous_map orelse {
            if (second_entry.anonymous_map_reference.anonymous_map != null) {
                // cannot safely move `second_entry` anonymous map reference backwards to cover `first_entry`
                return false;
            }
            // no anonymous maps to prevent merging
            break :anonymous_map;
        };

        const second_anonymous_map = second_entry.anonymous_map_reference.anonymous_map orelse {
            if (first_anonymous_map.number_of_pages.count !=
                first_entry.anonymous_map_reference.start_offset
                    .add(first_entry.range.size)
                    .divide(arch.paging.standard_page_size))
            {
                // `first_entry` anonymous map reference does not extend to the end of the anonymous map, so it is not
                // safe to extend the anonymous map
                return false;
            }

            // `first_entry` anonymous map reference extends to the end of the anonymous map, so it is safe to extend
            // the anonymous map
            break :anonymous_map;
        };

        if (first_anonymous_map != second_anonymous_map) {
            // anonymous maps dont match
            return false;
        }

        if (first_entry.anonymous_map_reference.start_offset
            .add(first_entry.range.size)
            .notEqual(second_entry.anonymous_map_reference.start_offset))
        {
            // `second_entry` anonymous map reference does not immediately follow `first_entry` anonymous map reference
            return false;
        }
    }

    return true;
}

/// Merge `second_entry` into `first_entry`.
///
/// Caller must ensure:
///  - the entries are mergable, see `canMerge`
///  - the `second_entry` immediately follows` `first_entry` in the address space
///  - after this function `second_entry` is no longer treated as valid
pub fn merge(first_entry: *Entry, current_task: Task.Current, second_entry: *const Entry) void {
    object: {
        const object = first_entry.object_reference.object orelse {
            if (core.is_debug) std.debug.assert(second_entry.object_reference.object == null);
            break :object;
        };

        const second_entry_object = second_entry.object_reference.object.?;
        if (core.is_debug) std.debug.assert(object == second_entry_object);

        object.lock.writeLock(current_task);
        defer object.lock.writeUnlock(current_task);
        if (core.is_debug) std.debug.assert(object.reference_count >= 2);

        object.reference_count -= 1;
    }

    anonymous_map: {
        const anonymous_map = first_entry.anonymous_map_reference.anonymous_map orelse {
            if (core.is_debug) std.debug.assert(second_entry.anonymous_map_reference.anonymous_map == null);
            break :anonymous_map;
        };

        anonymous_map.lock.writeLock(current_task);
        defer anonymous_map.lock.writeUnlock(current_task);

        if (second_entry.anonymous_map_reference.anonymous_map) |second_entry_anonymous_map| {
            if (core.is_debug) {
                std.debug.assert(anonymous_map == second_entry_anonymous_map);
                std.debug.assert(anonymous_map.reference_count >= 2);
            }

            anonymous_map.reference_count -= 1;
        } else {
            anonymous_map.number_of_pages.increaseBySize(second_entry.range.size);
        }
    }

    first_entry.range.size.addInPlace(second_entry.range.size);
}

/// Split `first_entry` at `split_offset` into its range.
///
/// `first_entry` is modified to cover the range before `split_offset` and `new_second_entry` is filled in to cover the
/// range after `split_offset`.
///
/// Caller must ensure:
///  - `first_entry` and `new_second_entry` are not the same entry
///  - `split_offset` is not `.zero`
///  - `split_offset` is less than or equal to `first_entry.range.size`
///  - `split_offset` is a multiple of the standard page size
pub fn split(first_entry: *Entry, current_task: Task.Current, new_second_entry: *Entry, split_offset: core.Size) void {
    if (core.is_debug) {
        std.debug.assert(first_entry != new_second_entry);
        std.debug.assert(first_entry.range.size.notEqual(.zero));
        std.debug.assert(split_offset.lessThanOrEqual(first_entry.range.size));
        std.debug.assert(split_offset.isAligned(arch.paging.standard_page_size));
    }

    new_second_entry.* = .{
        .range = .fromAddr(
            first_entry.range.address.moveForward(split_offset),
            first_entry.range.size.subtract(split_offset),
        ),
        .protection = first_entry.protection,
        .max_protection = first_entry.max_protection,

        .copy_on_write = first_entry.copy_on_write,
        .needs_copy = first_entry.needs_copy,
        .wired_count = first_entry.wired_count,

        .anonymous_map_reference = first_entry.anonymous_map_reference,
        .object_reference = first_entry.object_reference,
    };

    if (first_entry.anonymous_map_reference.anonymous_map) |anonymous_map| {
        new_second_entry.anonymous_map_reference.start_offset.addInPlace(split_offset);

        anonymous_map.lock.writeLock(current_task);
        defer anonymous_map.lock.writeUnlock(current_task);

        anonymous_map.reference_count += 1;
    }

    if (first_entry.object_reference.object) |object| {
        new_second_entry.object_reference.start_offset.addInPlace(split_offset);

        object.lock.writeLock(current_task);
        defer object.lock.writeUnlock(current_task);

        object.reference_count += 1;
    }

    first_entry.range.size = split_offset;
}

const ShrinkDirection = enum {
    beginning,
    end,
};

/// Shrink the entry.
///
/// If `direction` is `.beginning` the entry is shrunk from the beginning.
/// If `direction` is `.end` the entry is shrunk from the end.
///
/// Caller must ensure:
///  - `new_size` is not `.zero`
///  - `new_size` is less than the entry's size
///  - `new_size` is a multiple of the standard page size
pub fn shrink(
    entry: *Entry,
    direction: ShrinkDirection,
    new_size: core.Size,
) void {
    if (core.is_debug) {
        std.debug.assert(new_size.notEqual(.zero));
        std.debug.assert(new_size.lessThan(entry.range.size));
        std.debug.assert(new_size.isAligned(arch.paging.standard_page_size));
    }

    const size_change = entry.range.size.subtract(new_size);

    switch (direction) {
        .beginning => {
            entry.range.address.moveForwardInPlace(size_change);
            entry.range.size = new_size;

            if (entry.anonymous_map_reference.anonymous_map) |_| {
                entry.anonymous_map_reference.start_offset.addInPlace(size_change);
            }
            if (entry.object_reference.object) |_| {
                entry.object_reference.start_offset.addInPlace(size_change);
            }
        },
        .end => {},
    }

    entry.range.size = new_size;
}

/// Prints the entry.
pub fn print(entry: *const Entry, current_task: Task.Current, writer: *std.Io.Writer, indent: usize) !void {
    const new_indent = indent + 2;

    try writer.writeAll("Entry{\n");

    try writer.splatByteAll(' ', new_indent);
    try writer.print("range: {f},\n", .{entry.range});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("protection: {t},\n", .{entry.protection});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("max_protection: {t},\n", .{entry.max_protection});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("copy_on_write: {},\n", .{entry.copy_on_write});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("needs_copy: {},\n", .{entry.needs_copy});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("wired_count: {},\n", .{entry.wired_count});

    try writer.splatByteAll(' ', new_indent);
    if (entry.anonymous_map_reference.anonymous_map != null) {
        try writer.writeAll("anonymous_map: ");
        try entry.anonymous_map_reference.print(
            current_task,
            writer,
            new_indent,
        );
        try writer.writeAll(",\n");
    } else {
        try writer.writeAll("anonymous_map: null,\n");
    }

    try writer.splatByteAll(' ', new_indent);
    if (entry.object_reference.object != null) {
        try writer.writeAll("object: ");
        try entry.object_reference.print(
            current_task,
            writer,
            new_indent,
        );
        try writer.writeAll(",\n");
    } else {
        try writer.writeAll("object: null,\n");
    }

    try writer.splatByteAll(' ', indent);
    try writer.writeAll("}");
}

pub inline fn format(entry: *const Entry, writer: *std.Io.Writer) !void {
    return entry.print(.current(), writer, 0);
}

const globals = struct {
    /// Initialized during `init.initializeCaches`.
    var entry_cache: Cache(Entry, null, null) = undefined;
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.address_space_entry_init);

    pub fn initializeCaches(current_task: Task.Current) !void {
        init_log.debug(current_task, "initializing address space entry cache", .{});

        globals.entry_cache.init(current_task, .{
            .name = try .fromSlice("address space entry"),
        });
    }
};

comptime {
    if (!cascade.mem.cache.isSmallItem(@sizeOf(Entry), .of(Entry))) {
        @compileError("`Entry` is a large cache item");
    }
}
