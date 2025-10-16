// SPDX-License-Identifier: MIT and BSD-2-Clause
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

wired_count: u32 = 0,

pub fn create(context: *cascade.Context) !*Entry {
    var entry: [1]*Entry = undefined;
    try createMany(context, &entry);
    return entry[0];
}

pub fn createMany(context: *cascade.Context, items: []*Entry) !void {
    return globals.entry_cache.allocateMany(context, items) catch |err| switch (err) {
        error.SlabAllocationFailed => return error.OutOfMemory,
        error.ItemConstructionFailed => unreachable, // no constructor is provided
        error.LargeItemAllocationFailed => unreachable, // `Entry` is not a large entry - checked in `global_init.initializeCaches`
    };
}

pub fn destroy(entry: *Entry, context: *cascade.Context) void {
    globals.entry_cache.deallocate(context, entry);
}

pub fn anyOverlap(entry: *const Entry, other: *const Entry) bool {
    return entry.range.anyOverlap(other.range);
}

/// Determine if `second_entry` can be merged into `first_entry`.
///
/// This must be observed to be `true` before `merge` is can be called on the entries.
///
/// Can only be `true` when `second_entry` immediately follows `first_entry` in the address space.
pub fn canMerge(first_entry: *const Entry, context: *cascade.Context, second_entry: *const Entry) bool {
    if (first_entry.protection != second_entry.protection) return false;
    if (first_entry.max_protection != second_entry.max_protection) return false;
    if (first_entry.copy_on_write != second_entry.copy_on_write) return false;
    if (first_entry.wired_count != second_entry.wired_count) return false;

    if (first_entry.range.endBound().notEqual(second_entry.range.address)) {
        // `second_entry` does not immediately follow `first_entry`
        return false;
    }

    if (first_entry.object_reference.object) |first_entry_object| {
        const second_entry_object = second_entry.object_reference.object orelse {
            // first_entry has an object reference, second_entry has no object reference
            return false;
        };

        if (first_entry_object != second_entry_object) {
            // objects dont match
            return false;
        }

        if (first_entry.object_reference.start_offset
            .add(first_entry.range.size)
            .notEqual(second_entry.object_reference.start_offset))
        {
            // second_entry's object reference does not immediately follow first_entry's object reference
            return false;
        }
    } else if (second_entry.object_reference.object != null) {
        // first_entry has no object reference, second_entry has an object reference
        return false;
    }

    if (first_entry.anonymous_map_reference.anonymous_map) |first_entry_anonymous_map| {
        if (second_entry.anonymous_map_reference.anonymous_map) |second_entry_anonymous_map| {
            if (first_entry_anonymous_map != second_entry_anonymous_map) {
                return false;
            }
            if (first_entry.needs_copy != second_entry.needs_copy) {
                return false;
            }

            if (first_entry.anonymous_map_reference.start_offset
                .add(first_entry.range.size)
                .notEqual(second_entry.anonymous_map_reference.start_offset))
            {
                // second_entry's anonymous map reference does not immediately follow first_entry's anonymous map reference
                return false;
            }
        } else {
            std.debug.assert(second_entry.needs_copy);

            if (first_entry.needs_copy) {
                first_entry_anonymous_map.lock.readLock(context);
                defer first_entry_anonymous_map.lock.readUnlock(context);

                if (first_entry_anonymous_map.reference_count > 1) {
                    // the first entry's anonymous map is shared
                    return false;
                }
            }
        }
    } else if (second_entry.anonymous_map_reference.anonymous_map) |second_entry_anonymous_map| {
        std.debug.assert(first_entry.needs_copy);

        if (second_entry.anonymous_map_reference.start_offset.lessThan(first_entry.range.size)) {
            // we can't move the second entry's start offset back far enough to cover the first entry
            return false;
        }

        if (second_entry.needs_copy) {
            second_entry_anonymous_map.lock.readLock(context);
            defer second_entry_anonymous_map.lock.readUnlock(context);

            if (second_entry_anonymous_map.reference_count > 1) {
                // the second entry's anonymous map is shared
                return false;
            }
        }
    } else {
        // neither entry has an anonymous map
        std.debug.assert(first_entry.needs_copy and second_entry.needs_copy);
    }

    return true;
}

/// Merge `second_entry` into `first_entry`.
///
/// Caller must ensure:
///  - the entries are mergable, see `canMerge`
///  - the `second_entry` immediately follows` `first_entry` in the address space
///  - after this function `second_entry` is no longer treated as valid
pub fn merge(first_entry: *Entry, context: *cascade.Context, second_entry: *const Entry) void {
    const new_size = first_entry.range.size.add(second_entry.range.size);

    if (first_entry.anonymous_map_reference.anonymous_map) |anonymous_map| {
        anonymous_map.lock.writeLock(context);
        defer anonymous_map.lock.writeUnlock(context);

        if (second_entry.anonymous_map_reference.anonymous_map) |second_entry_anonymous_map| {
            std.debug.assert(anonymous_map == second_entry_anonymous_map); // checked by `canMerge`
            std.debug.assert(anonymous_map.reference_count >= 2);

            anonymous_map.reference_count -= 1;
        } else {
            const size_of_anonymous_map = anonymous_map.number_of_pages.toSize();
            const size_after_offset = size_of_anonymous_map.subtract(
                first_entry.anonymous_map_reference.start_offset,
            );
            std.debug.assert(size_after_offset.greaterThanOrEqual(first_entry.range.size));

            if (size_after_offset.lessThan(new_size)) {
                // we must extend the anonymous map to cover the second entries range
                anonymous_map.number_of_pages.increaseBySize(new_size.subtract(size_after_offset));
            }
        }
    } else if (second_entry.anonymous_map_reference.anonymous_map) |anonymous_map| {
        std.debug.assert(second_entry.anonymous_map_reference.start_offset.greaterThanOrEqual(first_entry.range.size));

        // we take over the anonymous map reference from the second entry and move the start offset back to cover the
        // first entries range
        first_entry.anonymous_map_reference.anonymous_map = anonymous_map;
        first_entry.anonymous_map_reference.start_offset = second_entry.anonymous_map_reference.start_offset
            .subtract(first_entry.range.size);

        first_entry.needs_copy = false;
    }

    object: {
        const object = first_entry.object_reference.object orelse {
            std.debug.assert(second_entry.object_reference.object == null);
            break :object;
        };

        const second_entry_object = second_entry.object_reference.object.?;
        std.debug.assert(object == second_entry_object);

        object.lock.writeLock(context);
        defer object.lock.writeUnlock(context);
        std.debug.assert(object.reference_count >= 2);

        object.reference_count -= 1;
    }

    first_entry.range.size = new_size;
}

/// Prints the entry.
pub fn print(entry: *const Entry, context: *cascade.Context, writer: *std.Io.Writer, indent: usize) !void {
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
            context,
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
            context,
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
    pub fn initializeCaches(context: *cascade.Context) !void {
        globals.entry_cache.init(context, .{
            .name = try .fromSlice("address space entry"),
        });
    }
};

comptime {
    if (!cascade.mem.cache.isSmallItem(@sizeOf(Entry), .of(Entry))) {
        @compileError("`Entry` is a large cache item");
    }
}
