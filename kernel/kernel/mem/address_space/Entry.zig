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
//! Made with reference to [OpenBSD implementation of UVM](https://github.com/openbsd/src/tree/master/sys/uvm)
//!

const Entry = @This();

base: core.VirtualAddress,
number_of_pages: u32,

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

pub fn create(context: *kernel.Task.Context) !*Entry {
    return globals.entry_cache.allocate(context) catch |err| switch (err) {
        error.SlabAllocationFailed => return error.OutOfMemory,
        error.ObjectConstructionFailed => unreachable, // no constructor is provided
        error.LargeObjectAllocationFailed => unreachable, // `Entry` is not a large object - checked in `global_init.initializeCaches`
    };
}

pub fn destroy(entry: *Entry, context: *kernel.Task.Context) void {
    globals.entry_cache.deallocate(context, entry);
}

pub fn range(entry: *const Entry) core.VirtualRange {
    return .fromAddr(
        entry.base,
        arch.paging.standard_page_size.multiplyScalar(entry.number_of_pages),
    );
}

pub fn entryIndexByAddress(address: core.VirtualAddress, entries: []const *Entry) ?usize {
    return std.sort.binarySearch(
        *const Entry,
        entries,
        address,
        struct {
            fn addressCompareOrder(addr: core.VirtualAddress, entry: *const Entry) std.math.Order {
                return entry.range().compareAddressOrder(addr);
            }
        }.addressCompareOrder,
    );
}

/// Returns the page offset of the given address in the given entry.
///
/// Asserts that the address is within the entry's range.
pub fn offsetOfAddressInEntry(entry: *const Entry, address: core.VirtualAddress) u32 {
    std.debug.assert(entry.range().containsAddress(address));

    return @intCast(address
        .subtract(entry.base)
        .divide(arch.paging.standard_page_size)
        .value);
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
pub fn determineEntryMerge(entry: *const Entry, context: *kernel.Task.Context, entries: []const *Entry) EntryMerge {
    if (entries.len == 0) return .{ .new = 0 };

    const insertion_index = entry.insertionIndex(entries);

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

fn insertionIndex(entry: *const Entry, entries: []const *Entry) usize {
    return std.sort.lowerBound(
        *const Entry,
        entries,
        entry,
        struct {
            fn compareOrder(compare_entry: *const Entry, e: *const Entry) std.math.Order {
                return e.range().compareAddressOrder(compare_entry.base);
            }
        }.compareOrder,
    );
}

fn anyOverlap(entry: *const Entry, other: *const Entry) bool {
    return entry.range().anyOverlap(other.range());
}

/// Returns true if `entry` can be merged with `proceeding_entry`.
///
/// It is the caller's responsibility to ensure that `proceeding_entry` immediately precedes `entry`.
///
/// Asserts that `entry` does not have an anonymous map.
fn canMergeWithProceeding(entry: *const Entry, curent_task: *kernel.Task, proceeding_entry: *const Entry) bool {
    std.debug.assert(proceeding_entry.range().endBound().equal(entry.range().address));
    std.debug.assert(entry.anonymous_map_reference.anonymous_map == null);

    if (entry.protection != proceeding_entry.protection) return false;
    if (entry.copy_on_write != proceeding_entry.copy_on_write) return false;
    if (entry.needs_copy != proceeding_entry.needs_copy) return false; // TODO: is this correct?
    if (entry.wired_count != proceeding_entry.wired_count) return false;

    if (entry.object_reference.object) |entry_object| {
        const proceeding_entry_object = proceeding_entry.object_reference.object orelse {
            // entry has an object reference, proceeding_entry has no object reference
            return false;
        };

        if (entry_object != proceeding_entry_object) {
            // objects dont match
            return false;
        }

        if (proceeding_entry.object_reference.start_offset + proceeding_entry.number_of_pages !=
            entry.object_reference.start_offset)
        {
            // entry's object reference does not immediately follow proceeding_entry's object reference
            return false;
        }
    } else if (proceeding_entry.object_reference.object != null) {
        // entry has no object reference, proceeding_entry has an object reference
        return false;
    }

    if (proceeding_entry.anonymous_map_reference.anonymous_map) |proceeding_anonymous_map| {
        proceeding_anonymous_map.lock.readLock(curent_task);
        defer proceeding_anonymous_map.lock.readUnlock(curent_task);

        if (proceeding_anonymous_map.reference_count != 1) {
            // TODO: is this the right thing to do?
            // anonymous map is shared
            return false;
        }
    }

    return true;
}

/// Returns true if `entry` can be merged with `following_entry`.
///
/// It is the caller's responsibility to ensure that `following_entry` immediately follows `entry`.
///
/// Asserts that `entry` does not have an anonymous map.
fn canMergeWithFollowing(entry: *const Entry, curent_task: *kernel.Task, following_entry: *const Entry) bool {
    std.debug.assert(entry.range().endBound().equal(following_entry.range().address));
    std.debug.assert(entry.anonymous_map_reference.anonymous_map == null);

    if (entry.protection != following_entry.protection) return false;
    if (entry.copy_on_write != following_entry.copy_on_write) return false;
    if (entry.needs_copy != following_entry.needs_copy) return false; // TODO: is this correct?
    if (entry.wired_count != following_entry.wired_count) return false;

    if (entry.object_reference.object) |entry_object| {
        const proceeding_entry_object = following_entry.object_reference.object orelse {
            // entry has an object reference, following_entry has no object reference
            return false;
        };

        if (entry_object != proceeding_entry_object) {
            // objects dont match
            return false;
        }

        if (entry.object_reference.start_offset + entry.number_of_pages !=
            following_entry.object_reference.start_offset)
        {
            // following_entry's object reference does not immediately follow entry's object reference
            return false;
        }
    } else if (following_entry.object_reference.object != null) {
        // entry has no object reference, following_entry has an object reference
        return false;
    }

    if (following_entry.anonymous_map_reference.anonymous_map) |following_anonymous_map| {
        following_anonymous_map.lock.readLock(curent_task);
        defer following_anonymous_map.lock.readUnlock(curent_task);

        if (following_entry.anonymous_map_reference.start_offset < entry.number_of_pages) {
            // we can't move the start offset back far enough to cover the new entry
            return false;
        }

        if (following_anonymous_map.reference_count != 1) {
            // TODO: is this the right thing to do?
            // anonymous map is shared
            return false;
        }
    }

    return true;
}

/// Prints the entry.
pub fn print(entry: *Entry, context: *kernel.Task.Context, writer: *std.Io.Writer, indent: usize) !void {
    const new_indent = indent + 2;

    try writer.writeAll("Entry{\n");

    try writer.splatByteAll(' ', new_indent);
    if (entry.number_of_pages == 1) {
        try writer.print("range: {f} (1 page),\n", .{entry.range()});
    } else {
        try writer.print("range: {f} ({} pages),\n", .{ entry.range(), entry.number_of_pages });
    }

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

const globals = struct {
    /// Initialized during `init.initializeCache`.
    var entry_cache: Cache(Entry, null, null) = undefined;
};

pub const init = struct {
    pub fn initializeCache(context: *kernel.Task.Context) !void {
        if (!kernel.mem.cache.isSmallObject(@sizeOf(Entry), .of(Entry))) {
            @panic("`Entry` is a large cache object");
        }

        globals.entry_cache.init(context, .{
            .name = try .fromSlice("address space entry"),
        });
    }
};

const AnonymousMap = @import("AnonymousMap.zig");
const Object = @import("Object.zig");

const Protection = kernel.mem.MapType.Protection;

const arch = @import("arch");
const kernel = @import("kernel");

const Cache = kernel.mem.cache.Cache;
const core = @import("core");
const log = kernel.debug.log.scoped(.address_space);
const std = @import("std");
