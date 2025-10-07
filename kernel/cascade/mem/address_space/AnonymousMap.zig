// SPDX-License-Identifier: MIT and BSD-2-Clause
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: Copyright (c) 1997 Charles D. Cranor and Washington University.

//! An area of anonymous memory.
//!
//! Called a `vm_amap` in uvm.
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
const core = @import("core");

const AddressSpace = @import("AddressSpace.zig");
const AnonymousPage = @import("AnonymousPage.zig");
const Entry = @import("Entry.zig");

const AnonymousPageChunkMap = @import("chunk_map.zig").ChunkMap(AnonymousPage);
const log = cascade.debug.log.scoped(.address_space);

const AnonymousMap = @This();

lock: cascade.sync.RwLock = .{},

reference_count: u32 = 1,

number_of_pages: PageCount,

pages_in_use: PageCount = .zero,

anonymous_page_chunks: AnonymousPageChunkMap = .{},

// /// If `true` this anonymous map is shared between multiple entries.
// shared: bool, // TODO: support shared anonymous maps

pub fn create(context: *cascade.Context, size: core.Size) error{OutOfMemory}!*AnonymousMap {
    std.debug.assert(size.isAligned(arch.paging.standard_page_size));

    const anonymous_map = globals.anonymous_map_cache.allocate(context) catch return error.OutOfMemory;

    anonymous_map.* = .{ .number_of_pages = .fromSize(size) };

    return anonymous_map;
}

/// Increment the reference count.
///
/// When called the lock must be held.
pub fn incrementReferenceCount(anonymous_map: *AnonymousMap, context: *cascade.Context) void {
    std.debug.assert(anonymous_map.reference_count != 0);
    std.debug.assert(anonymous_map.lock.isLockedByCurrent(context));

    anonymous_map.reference_count += 1;
}

/// Decrement the reference count.
///
/// When called the lock must be held, upon return the lock is unlocked.
pub fn decrementReferenceCount(anonymous_map: *AnonymousMap, context: *cascade.Context) void {
    std.debug.assert(anonymous_map.reference_count != 0);
    std.debug.assert(anonymous_map.lock.isLockedByCurrent(context));

    const reference_count = anonymous_map.reference_count;
    anonymous_map.reference_count = reference_count - 1;

    if (reference_count == 1) {
        // reference count is now zero, destroy the anonymous map

        if (true) @panic("NOT IMPLEMENTED"); // TODO

        anonymous_map.lock.unlock(context);

        globals.anonymous_map_cache.deallocate(context, anonymous_map);
    } else {
        anonymous_map.lock.unlock(context);
    }
}

/// Ensure an entries `needs_copy` flag is false, by copying the anonymous map if needed.
///
/// The `entries_lock` must be locked for writing.
///
/// - An entry with no anonymous map will get a new anonymous map.
/// - If the entry has an anonymous map it must be unlocked.
///
/// Called `amap_copy` in OpenBSD uvm.
pub fn copy(
    context: *cascade.Context,
    address_space: *AddressSpace,
    entry: *Entry,
    faulting_address: core.VirtualAddress,
) error{OutOfMemory}!void {
    _ = faulting_address;

    std.debug.assert(address_space.entries_lock.isWriteLocked());

    if (entry.anonymous_map_reference.anonymous_map == null) {
        // no anonymous map, create one

        // FIXME: rather than `try` - wait for memory to be available and trigger memory reclaimation
        entry.anonymous_map_reference.anonymous_map = try create(context, entry.range.size);
        entry.anonymous_map_reference.start_offset = .zero;

        entry.needs_copy = false;

        return;
    }

    @panic("NOT IMPLEMENTED - AnonymousMap.copy"); // TODO https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_amap.c#L576
}

pub const Reference = struct {
    anonymous_map: ?*AnonymousMap,
    start_offset: core.Size,

    /// Lookup up a page in the referenced anonymous map for the given entry and faulting address.
    ///
    /// The anonymous map is asserted to be non-null.
    /// The faulting address is asserted to be within the entry's range and aligned to the page size.
    ///
    /// The anonymous map must be locked by the caller. (read or write)
    ///
    /// Called `amap_lookups` in OpenBSD uvm, but this implementation only returns a single page.
    pub fn lookup(reference: Reference, entry: *const Entry, faulting_address: core.VirtualAddress) ?*AnonymousPage {
        std.debug.assert(reference.anonymous_map != null);
        std.debug.assert(reference.start_offset.isAligned(arch.paging.standard_page_size));
        std.debug.assert(entry.anonymous_map_reference.anonymous_map == reference.anonymous_map);
        std.debug.assert(entry.anonymous_map_reference.start_offset.equal(reference.start_offset));
        std.debug.assert(faulting_address.isAligned(arch.paging.standard_page_size));
        std.debug.assert(entry.range.containsAddress(faulting_address));

        const anonymous_map = reference.anonymous_map.?;

        const target_index = targetIndex(entry, reference, faulting_address);
        std.debug.assert(target_index < anonymous_map.number_of_pages.count);

        return anonymous_map.anonymous_page_chunks.get(target_index);
    }

    pub const AddOperation = enum {
        add,
        replace,
    };

    /// Add or replace an anonymous page in the referenced anonymous map.
    ///
    /// The anonymous map must be locked by the caller.
    ///
    /// Called `amap_add` in OpenBSD uvm.
    pub fn add(
        reference: Reference,
        context: *cascade.Context,
        entry: *const Entry,
        faulting_address: core.VirtualAddress,
        anonymous_page: *AnonymousPage,
        operation: AddOperation,
    ) error{OutOfMemory}!void {
        std.debug.assert(reference.anonymous_map != null);
        std.debug.assert(entry.anonymous_map_reference.anonymous_map == reference.anonymous_map);
        std.debug.assert(entry.anonymous_map_reference.start_offset.equal(reference.start_offset));
        std.debug.assert(faulting_address.isAligned(arch.paging.standard_page_size));
        std.debug.assert(entry.range.containsAddress(faulting_address));

        log.verbose(context, "adding anonymous page for {f} to anonymous map", .{faulting_address});

        const anonymous_map = reference.anonymous_map.?;

        const target_index = targetIndex(entry, reference, faulting_address);
        std.debug.assert(target_index < anonymous_map.number_of_pages.count);

        const chunk = anonymous_map.anonymous_page_chunks.ensureChunk(target_index) catch
            return error.OutOfMemory;

        const chunk_offset = AnonymousPageChunkMap.chunkOffset(target_index);

        switch (operation) {
            .add => {
                std.debug.assert(chunk[chunk_offset] == null);
                anonymous_map.pages_in_use.increment();
            },
            .replace => @panic("NOT IMPLEMENTED"), // TODO https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_amap.c#L1223
        }
        chunk[chunk_offset] = anonymous_page;
    }

    /// Returns the page offset of the given address in the given entry.
    ///
    /// Asserts that the address is within the entry's range.
    fn targetIndex(entry: *const Entry, reference: Reference, faulting_address: core.VirtualAddress) u32 {
        std.debug.assert(entry.range.containsAddress(faulting_address));

        return @intCast(
            faulting_address
                .subtract(entry.range.address)
                .divide(arch.paging.standard_page_size)
                .add(
                    reference.start_offset
                        .divide(arch.paging.standard_page_size),
                ).value,
        );
    }

    /// Prints the anonymous map reference.
    pub fn print(
        anonymous_map_reference: Reference,
        context: *cascade.Context,
        writer: *std.Io.Writer,
        indent: usize,
    ) !void {
        const new_indent = indent + 2;

        if (anonymous_map_reference.anonymous_map) |anonymous_map| {
            try writer.writeAll("AnonymousMap.Reference{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("start_offset: {f}\n", .{anonymous_map_reference.start_offset});

            try writer.splatByteAll(' ', new_indent);
            try anonymous_map.print(
                context,
                writer,
                new_indent,
            );
            try writer.writeAll(",\n");

            try writer.splatByteAll(' ', indent);
            try writer.writeAll("}");
        } else {
            try writer.writeAll("AnonymousMap.Reference{ none }");
        }
    }

    pub inline fn format(_: Reference, _: *std.Io.Writer) !void {
        @compileError("use `Reference.print` instead");
    }
};

pub const PageCount = extern struct {
    count: u32,

    pub const zero: PageCount = .{ .count = 0 };

    pub inline fn increment(page_count: *PageCount) void {
        page_count.count += 1;
    }

    pub fn equal(page_count: PageCount, other: PageCount) bool {
        return page_count.count == other.count;
    }

    pub fn fromSize(size: core.Size) PageCount {
        return .{
            .count = @intCast(size.divide(arch.paging.standard_page_size).value),
        };
    }
};

/// Prints the anonymous map.
///
/// Locks the spinlock.
pub fn print(
    anonymous_map: *AnonymousMap,
    context: *cascade.Context,
    writer: *std.Io.Writer,
    indent: usize,
) !void {
    const new_indent = indent + 2;

    anonymous_map.lock.readLock(context);
    defer anonymous_map.lock.readUnlock(context);

    try writer.writeAll("AnonymousMap{\n");

    try writer.splatByteAll(' ', new_indent);
    try writer.print("reference_count: {d}\n", .{anonymous_map.reference_count});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("number_of_pages: {d}\n", .{anonymous_map.number_of_pages.count});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("pages_in_use: {d}\n", .{anonymous_map.pages_in_use.count});

    try writer.splatByteAll(' ', indent);
    try writer.writeAll("}");
}

pub inline fn format(_: *const *AnonymousMap, _: *std.Io.Writer) !void {
    @compileError("use `AnonymousMap.print` instead");
}

const globals = struct {
    /// Initialized during `init.initializeCaches`.
    var anonymous_map_cache: Cache(AnonymousMap, null, null) = undefined;
};

pub const init = struct {
    pub fn initializeCaches(context: *cascade.Context) !void {
        globals.anonymous_map_cache.init(context, .{
            .name = try .fromSlice("anonymous map"),
        });
    }
};
