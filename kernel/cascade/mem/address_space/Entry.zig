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

protection: Protection, // TODO: eventually we will want a max protection, which is the maximum allowed protection

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
        error.ObjectConstructionFailed => unreachable, // no constructor is provided
        error.LargeObjectAllocationFailed => unreachable, // `Entry` is not a large object - checked in `global_init.initializeCaches`
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

        break :blk if (entry.canMergeWithProceeding(context, before_entry))
            before_entry
        else
            null;
    } else null;

    const opt_after_entry: ?*Entry = if (insertion_index != entries.len) blk: {
        const after_entry = entries[insertion_index];
        std.debug.assert(!entry.anyOverlap(after_entry)); // entry overlaps with the following entry

        break :blk if (entry.canMergeWithFollowing(context, after_entry))
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

/// Returns true if `entry` can be merged with `proceeding_entry`.
fn canMergeWithProceeding(entry: *const Entry, context: *cascade.Context, proceeding_entry: *const Entry) bool {
    if (entry.protection != proceeding_entry.protection) return false;
    if (entry.copy_on_write != proceeding_entry.copy_on_write) return false;
    if (entry.wired_count != proceeding_entry.wired_count) return false;

    if (!proceeding_entry.range.endBound().equal(entry.range.address)) {
        // entry does not immediately follow proceeding_entry
        return false;
    }

    if (entry.object_reference.object) |entry_object| {
        const proceeding_entry_object = proceeding_entry.object_reference.object orelse {
            // entry has an object reference, proceeding_entry has no object reference
            return false;
        };

        if (entry_object != proceeding_entry_object) {
            // objects dont match
            return false;
        }

        if (proceeding_entry.object_reference.start_offset
            .add(proceeding_entry.range.size)
            .notEqual(entry.object_reference.start_offset))
        {
            // entry's object reference does not immediately follow proceeding_entry's object reference
            return false;
        }
    } else if (proceeding_entry.object_reference.object != null) {
        // entry has no object reference, proceeding_entry has an object reference
        return false;
    }

    if (entry.anonymous_map_reference.anonymous_map) |entry_anonymous_map| blk: {
        if (proceeding_entry.anonymous_map_reference.anonymous_map) |proceeding_anonymous_map| {
            if (entry_anonymous_map != proceeding_anonymous_map) return false;
            if (entry.needs_copy != proceeding_entry.needs_copy) return false;

            if (proceeding_entry.anonymous_map_reference.start_offset
                .add(proceeding_entry.range.size)
                .notEqual(entry.anonymous_map_reference.start_offset))
            {
                // entry's anonymous map reference does not immediately follow proceeding_entry's anonymous map reference
                return false;
            }

            break :blk;
        }

        if (entry.needs_copy) {
            // the entries anonymous map needs to be copied as it is shared
            return false;
        }
        std.debug.assert(proceeding_entry.needs_copy);

        if (entry.anonymous_map_reference.start_offset.lessThan(proceeding_entry.range.size)) {
            // we can't move the start offset back far enough to cover the proceeding entry
            return false;
        }

        entry_anonymous_map.lock.readLock(context);
        defer entry_anonymous_map.lock.readUnlock(context);

        if (entry_anonymous_map.reference_count != 1) {
            // TODO: is this the right thing to do?
            // anonymous map is shared
            return false;
        }
    } else blk: {
        const proceeding_anonymous_map = proceeding_entry.anonymous_map_reference.anonymous_map orelse {
            std.debug.assert(entry.needs_copy and proceeding_entry.needs_copy);
            // neither entry has an anonymous map
            break :blk;
        };

        if (proceeding_entry.needs_copy) {
            // the proceeding entries anonymous map needs to be copied as it is shared
            return false;
        }

        proceeding_anonymous_map.lock.readLock(context);
        defer proceeding_anonymous_map.lock.readUnlock(context);

        if (proceeding_anonymous_map.reference_count != 1) {
            // TODO: is this the right thing to do?
            // anonymous map is shared
            return false;
        }
    }

    return true;
}

/// Returns true if `entry` can be merged with `following_entry`.
fn canMergeWithFollowing(entry: *const Entry, context: *cascade.Context, following_entry: *const Entry) bool {
    if (entry.protection != following_entry.protection) return false;
    if (entry.copy_on_write != following_entry.copy_on_write) return false;
    if (entry.wired_count != following_entry.wired_count) return false;

    if (!entry.range.endBound().equal(following_entry.range.address)) {
        // entry does not immediately proceed following_entry
        return false;
    }

    if (entry.object_reference.object) |entry_object| {
        const proceeding_entry_object = following_entry.object_reference.object orelse {
            // entry has an object reference, following_entry has no object reference
            return false;
        };

        if (entry_object != proceeding_entry_object) {
            // objects dont match
            return false;
        }

        if (entry.object_reference.start_offset.add(entry.range.size).notEqual(following_entry.object_reference.start_offset)) {
            // following_entry's object reference does not immediately follow entry's object reference
            return false;
        }
    } else if (following_entry.object_reference.object != null) {
        // entry has no object reference, following_entry has an object reference
        return false;
    }

    if (entry.anonymous_map_reference.anonymous_map) |entry_anonymous_map| blk: {
        if (following_entry.anonymous_map_reference.anonymous_map) |following_anonymous_map| {
            if (entry_anonymous_map != following_anonymous_map) return false;
            if (entry.needs_copy != following_entry.needs_copy) return false;

            if (entry.anonymous_map_reference.start_offset
                .add(entry.range.size)
                .notEqual(following_entry.anonymous_map_reference.start_offset))
            {
                // entry's anonymous map reference does not immediately proceed following_entry's anonymous map reference
                return false;
            }

            break :blk;
        }

        if (entry.needs_copy) {
            // the entries anonymous map needs to be copied as it is shared
            return false;
        }
        std.debug.assert(following_entry.needs_copy);

        entry_anonymous_map.lock.readLock(context);
        defer entry_anonymous_map.lock.readUnlock(context);

        if (entry_anonymous_map.reference_count != 1) {
            // TODO: is this the right thing to do?
            // anonymous map is shared
            return false;
        }
    } else blk: {
        const following_anonymous_map = following_entry.anonymous_map_reference.anonymous_map orelse {
            std.debug.assert(entry.needs_copy and following_entry.needs_copy);
            // neither entry has an anonymous map
            break :blk;
        };

        if (following_entry.needs_copy) {
            // the following entries anonymous map needs to be copied as it is shared
            return false;
        }
        std.debug.assert(entry.needs_copy);

        if (following_entry.anonymous_map_reference.start_offset.lessThan(entry.range.size)) {
            // we can't move the following entry's start offset back far enough to cover the entry
            return false;
        }

        following_anonymous_map.lock.readLock(context);
        defer following_anonymous_map.lock.readUnlock(context);

        if (following_anonymous_map.reference_count != 1) {
            // TODO: is this the right thing to do?
            // anonymous map is shared
            return false;
        }
    }

    return true;
}

/// Prints the entry.
pub fn print(entry: *Entry, context: *cascade.Context, writer: *std.Io.Writer, indent: usize) !void {
    const new_indent = indent + 2;

    try writer.writeAll("Entry{\n");

    try writer.splatByteAll(' ', new_indent);
    try writer.print("range: {f},\n", .{entry.range});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("protection: {t},\n", .{entry.protection});

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

pub inline fn format(_: *const Entry, _: *std.Io.Writer) !void {
    @compileError("use `Entry.print` instead");
}

pub const globals = struct {
    /// Initialized during `init.mem.initializeCaches`.
    pub var entry_cache: Cache(Entry, null, null) = undefined;
};

comptime {
    if (!cascade.mem.cache.isSmallObject(@sizeOf(Entry), .of(Entry))) {
        @compileError("`Entry` is a large cache object");
    }
}
