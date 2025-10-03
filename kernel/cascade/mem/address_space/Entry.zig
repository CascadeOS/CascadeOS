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
    return globals.entry_cache.allocate(context) catch |err| switch (err) {
        error.SlabAllocationFailed => return error.OutOfMemory,
        error.ItemConstructionFailed => unreachable, // no constructor is provided
        error.LargeItemAllocationFailed => unreachable, // `Entry` is not a large entry - checked in `global_init.initializeCaches`
    };
}

pub fn destroy(entry: *Entry, context: *cascade.Context) void {
    globals.entry_cache.deallocate(context, entry);
}

pub fn entryIndexByAddress(address: core.VirtualAddress, entries: []const *Entry) ?usize {
    return std.sort.binarySearch(
        *const Entry,
        entries,
        address,
        struct {
            fn addressCompareOrder(addr: core.VirtualAddress, entry: *const Entry) std.math.Order {
                return entry.range.compareAddressOrder(addr);
            }
        }.addressCompareOrder,
    );
}

pub const EntryMerge = union(enum) {
    new: usize,
    extend: Extend,

    const Extend = struct {
        before: ?*Entry = null,
        after: ?*Entry = null,
    };
};

/// Determine if and how an entry should be merged into the list of entries.
///
/// The caller must ensure the entries are locked.
pub fn determineEntryMerge(
    entry: *const Entry,
    context: *cascade.Context,
    insertion_index: usize,
    entries: []const *Entry,
) EntryMerge {
    std.debug.assert(insertion_index <= entries.len);

    if (entries.len == 0) return .{ .new = 0 };

    const opt_before_entry: ?*Entry = if (insertion_index != 0) blk: {
        const before_entry = entries[insertion_index - 1];
        std.debug.assert(!entry.anyOverlap(before_entry)); // entry overlaps with the preceding entry

        break :blk if (entry.canMergeInto(context, before_entry, .before))
            before_entry
        else
            null;
    } else null;

    const opt_after_entry: ?*Entry = if (insertion_index != entries.len) blk: {
        const after_entry = entries[insertion_index];
        std.debug.assert(!entry.anyOverlap(after_entry)); // entry overlaps with the following entry

        break :blk if (entry.canMergeInto(context, after_entry, .after))
            after_entry
        else
            null;
    } else null;

    if (opt_before_entry) |before_entry| {
        if (opt_after_entry) |after_entry| {
            _ = after_entry;
            @panic("NOT IMPLEMENTED"); // TODO: determine if we can merge the entry with both the before and after entry
        }

        return .{ .extend = .{ .before = before_entry } };
    } else if (opt_after_entry) |after_entry| {
        return .{ .extend = .{ .after = after_entry } };
    } else {
        return .{ .new = insertion_index };
    }
}

fn anyOverlap(entry: *const Entry, other: *const Entry) bool {
    return entry.range.anyOverlap(other.range);
}

/// Returns true if `entry` can be merged into `other`.
///
/// `order` is the relative location of `other` relative to `entry`.
fn canMergeInto(
    entry: *const Entry,
    context: *cascade.Context,
    other_entry: *const Entry,
    comptime order: enum { before, after },
) bool {
    if (entry.protection != other_entry.protection) return false;
    if (entry.max_protection != other_entry.max_protection) return false;
    if (entry.copy_on_write != other_entry.copy_on_write) return false;
    if (entry.wired_count != other_entry.wired_count) return false;

    switch (order) {
        .before => if (!other_entry.range.endBound().equal(entry.range.address)) {
            // entry does not immediately follow other_entry
            return false;
        },
        .after => if (!entry.range.endBound().equal(other_entry.range.address)) {
            // entry does not immediately proceed other_entry
            return false;
        },
    }

    if (entry.object_reference.object) |entry_object| {
        const other_entry_object = other_entry.object_reference.object orelse {
            // entry has an object reference, other_entry has no object reference
            return false;
        };

        if (entry_object != other_entry_object) {
            // objects dont match
            return false;
        }

        switch (order) {
            .before => if (other_entry.object_reference.start_offset
                .add(other_entry.range.size)
                .notEqual(entry.object_reference.start_offset))
            {
                // entry's object reference does not immediately follow other_entry's object reference
                return false;
            },
            .after => if (entry.object_reference.start_offset
                .add(entry.range.size)
                .notEqual(other_entry.object_reference.start_offset))
            {
                // other_entry's object reference does not immediately follow entry's object reference
                return false;
            },
        }
    } else if (other_entry.object_reference.object != null) {
        // entry has no object reference, other_entry has an object reference
        return false;
    }

    if (entry.anonymous_map_reference.anonymous_map) |entry_anonymous_map| blk: {
        if (other_entry.anonymous_map_reference.anonymous_map) |other_entry_anonymous_map| {
            if (entry_anonymous_map != other_entry_anonymous_map) return false;
            if (entry.needs_copy != other_entry.needs_copy) return false;

            switch (order) {
                .before => if (other_entry.anonymous_map_reference.start_offset
                    .add(other_entry.range.size)
                    .notEqual(entry.anonymous_map_reference.start_offset))
                {
                    // entry's anonymous map reference does not immediately follow other_entry's anonymous map reference
                    return false;
                },
                .after => if (entry.anonymous_map_reference.start_offset
                    .add(entry.range.size)
                    .notEqual(other_entry.anonymous_map_reference.start_offset))
                {
                    // entry's anonymous map reference does not immediately proceed other_entry's anonymous map reference
                    return false;
                },
            }

            break :blk;
        }

        if (entry.needs_copy) {
            // the entries anonymous map needs to be copied as it is shared
            return false;
        }
        std.debug.assert(other_entry.needs_copy);

        switch (order) {
            .before => if (entry.anonymous_map_reference.start_offset.lessThan(other_entry.range.size)) {
                // we can't move the start offset back far enough to cover other_entry
                return false;
            },
            .after => {},
        }

        entry_anonymous_map.lock.readLock(context);
        defer entry_anonymous_map.lock.readUnlock(context);

        if (entry_anonymous_map.reference_count != 1) {
            // TODO: is this the right thing to do?
            // anonymous map is shared
            return false;
        }
    } else blk: {
        const other_entry_anonymous_map = other_entry.anonymous_map_reference.anonymous_map orelse {
            std.debug.assert(entry.needs_copy and other_entry.needs_copy);
            // neither entry has an anonymous map
            break :blk;
        };

        if (other_entry.needs_copy) {
            // the other_entry's anonymous map needs to be copied as it is shared
            return false;
        }
        std.debug.assert(entry.needs_copy);

        switch (order) {
            .before => {},
            .after => if (other_entry.anonymous_map_reference.start_offset.lessThan(entry.range.size)) {
                // we can't move the other_entry's start offset back far enough to cover the entry
                return false;
            },
        }

        other_entry_anonymous_map.lock.readLock(context);
        defer other_entry_anonymous_map.lock.readUnlock(context);

        if (other_entry_anonymous_map.reference_count != 1) {
            // TODO: is this the right thing to do?
            // anonymous map is shared
            return false;
        }
    }

    return true;
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
