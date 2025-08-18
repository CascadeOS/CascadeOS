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
//! Made with reference to [OpenBSD implementation of UVM](https://github.com/openbsd/src/tree/master/sys/uvm)
//!

const AnonymousMap = @This();

lock: kernel.sync.RwLock = .{},

reference_count: u32 = 1,

number_of_pages: u32,

pages_in_use: u32 = 0,

anonymous_page_chunks: AnonymousPageChunkMap = .{},

// /// If `true` this anonymous map is shared between multiple entries.
// shared: bool, // TODO: support shared anonymous maps

pub fn create(context: *kernel.Task.Context, number_of_pages: u32) error{NoMemory}!*AnonymousMap {
    const anonymous_map = globals.anonymous_map_cache.allocate(context) catch
        return error.NoMemory;
    anonymous_map.* = .{
        .number_of_pages = number_of_pages,
    };
    return anonymous_map;
}

/// Increment the reference count.
///
/// When called the lock must be held.
pub fn incrementReferenceCount(anonymous_map: *AnonymousMap, context: *kernel.Task.Context) void {
    std.debug.assert(anonymous_map.reference_count != 0);
    std.debug.assert(anonymous_map.lock.isLockedByCurrent(context));

    anonymous_map.reference_count += 1;
}

/// Decrement the reference count.
///
/// When called the lock must be held, upon return the lock is unlocked.
pub fn decrementReferenceCount(anonymous_map: *AnonymousMap, context: *kernel.Task.Context) void {
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
    context: *kernel.Task.Context,
    address_space: *AddressSpace,
    entry: *Entry,
    faulting_address: core.VirtualAddress,
) error{NoMemory}!void {
    _ = address_space;
    _ = faulting_address;

    // is there an anonymous map?
    if (entry.anonymous_map_reference.anonymous_map == null) {
        // no anonymous map, create one

        // FIXME: rather that `try` wait for memory to be available, page memory out?
        entry.anonymous_map_reference.anonymous_map = try create(context, entry.number_of_pages);
        entry.anonymous_map_reference.start_offset = 0;

        // clear `needs_copy` flag
        entry.needs_copy = false;

        return;
    }

    @panic("NOT IMPLEMENTED - AnonymousMap.copy"); // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_amap.c#L576
}

pub const Reference = struct {
    anonymous_map: ?*AnonymousMap,
    start_offset: u32,

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
        std.debug.assert(entry.anonymous_map_reference.anonymous_map == reference.anonymous_map);
        std.debug.assert(entry.anonymous_map_reference.start_offset == reference.start_offset);
        std.debug.assert(faulting_address.isAligned(arch.paging.standard_page_size));
        std.debug.assert(entry.range().containsAddress(faulting_address));

        const anonymous_map = reference.anonymous_map.?;

        const entry_page_index = entry.offsetOfAddressInEntry(faulting_address);

        const target_index = entry_page_index + reference.start_offset;
        std.debug.assert(target_index < anonymous_map.number_of_pages);

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
        context: *kernel.Task.Context,
        entry: *const Entry,
        faulting_address: core.VirtualAddress,
        anonymous_page: *AnonymousPage,
        operation: AddOperation,
    ) error{NoMemory}!void {
        std.debug.assert(reference.anonymous_map != null);
        std.debug.assert(entry.anonymous_map_reference.anonymous_map == reference.anonymous_map);
        std.debug.assert(entry.anonymous_map_reference.start_offset == reference.start_offset);
        std.debug.assert(faulting_address.isAligned(arch.paging.standard_page_size));
        std.debug.assert(entry.range().containsAddress(faulting_address));

        log.verbose(context, "adding anonymous page for {f} to anonymous map", .{faulting_address});

        const anonymous_map = reference.anonymous_map.?;

        const entry_page_index = entry.offsetOfAddressInEntry(faulting_address);

        const target_index = entry_page_index + reference.start_offset;
        std.debug.assert(target_index < anonymous_map.number_of_pages);

        const chunk = anonymous_map.anonymous_page_chunks.ensureChunk(target_index) catch
            return error.NoMemory;

        const chunk_offset = AnonymousPageChunkMap.chunkOffset(target_index);

        switch (operation) {
            .add => {
                std.debug.assert(chunk[chunk_offset] == null);
                anonymous_map.pages_in_use += 1;
            },
            .replace => @panic("NOT IMPLEMENTED"), // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_amap.c#L1223
        }
        chunk[chunk_offset] = anonymous_page;
    }

    /// Prints the anonymous map reference.
    pub fn print(
        anonymous_map_reference: Reference,
        context: *kernel.Task.Context,
        writer: *std.Io.Writer,
        indent: usize,
    ) !void {
        const new_indent = indent + 2;

        if (anonymous_map_reference.anonymous_map) |anonymous_map| {
            try writer.writeAll("AnonymousMap.Reference{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("start_offset: {d}\n", .{anonymous_map_reference.start_offset});

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

/// Prints the anonymous map.
///
/// Locks the spinlock.
pub fn print(
    anonymous_map: *AnonymousMap,
    context: *kernel.Task.Context,
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
    try writer.print("number_of_pages: {d}\n", .{anonymous_map.number_of_pages});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("pages_in_use: {d}\n", .{anonymous_map.pages_in_use});

    try writer.splatByteAll(' ', indent);
    try writer.writeAll("}");
}

pub inline fn format(_: *const *AnonymousMap, _: *std.Io.Writer) !void {
    @compileError("use `AnonymousMap.print` instead");
}

const globals = struct {
    /// Initialized during `init.initializeCache`.
    var anonymous_map_cache: Cache(AnonymousMap, null, null) = undefined;
};

pub const init = struct {
    pub fn initializeCache(context: *kernel.Task.Context) !void {
        globals.anonymous_map_cache.init(context, .{
            .name = try .fromSlice("anonymous map"),
        });
    }
};

const AddressSpace = @import("AddressSpace.zig");
const AnonymousPage = @import("AnonymousPage.zig");
const AnonymousPageChunkMap = @import("chunk_map.zig").ChunkMap(AnonymousPage);
const Entry = @import("Entry.zig");

const arch = @import("arch");
const kernel = @import("kernel");

const Cache = kernel.mem.cache.Cache;
const core = @import("core");
const log = kernel.debug.log.scoped(.address_space);
const std = @import("std");
