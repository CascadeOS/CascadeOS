// SPDX-License-Identifier: MIT and BSD-2-Clause
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: Copyright (c) 1997 Charles D. Cranor and Washington University.

//! A virtual address space.
//!
//! Called a `vmspace` in uvm.
//!
//! Based on UVM:
//!   * [Design and Implementation of the UVM Virtual Memory System](https://chuck.cranor.org/p/diss.pdf) by Charles D. Cranor
//!   * [Zero-Copy Data Movement Mechanisms for UVM](https://citeseerx.ist.psu.edu/document?repid=rep1&type=pdf&doi=8961abccddf8ff24f7b494cd64d5cf62604b0018) by Charles D. Cranor and Gurudatta M. Parulkar
//!   * [The UVM Virtual Memory System](https://www.usenix.org/legacy/publications/library/proceedings/usenix99/full_papers/cranor/cranor.pdf) by Charles D. Cranor and Gurudatta M. Parulkar
//!
//! Made with reference to [OpenBSD implementation of UVM](https://github.com/openbsd/src/tree/master/sys/uvm)
//!

const AddressSpace = @This();

_name: Name,

/// Used as the source of addresses in this address space.
address_arena: cascade.mem.resource_arena.Arena(.none),

environment: cascade.Environment,

page_table: arch.paging.PageTable,

/// Protects the `page_table` field.
page_table_lock: cascade.sync.Mutex = .{},

/// The map entries in this address space.
///
/// Called a `vm_map` in uvm.
///
/// Sorted by `base`.
entries: std.ArrayListUnmanaged(*Entry), // TODO: better data structure

/// Protects the `entries` field.
entries_lock: cascade.sync.RwLock = .{},

/// Used to detect changes to the entries list while it is unlocked.
///
/// Incremented when the entries list is modified.
entries_version: u32,

pub const InitOptions = struct {
    name: Name,

    range: core.VirtualRange,

    page_table: arch.paging.PageTable,

    environment: cascade.Environment,
};

pub fn init(
    address_space: *AddressSpace,
    context: *cascade.Context,
    options: InitOptions,
) !void {
    log.debug(context, "{s}: init with {f} environment {t}", .{
        options.name.constSlice(),
        options.range,
        options.environment,
    });

    address_space.* = .{
        .address_arena = undefined, // initialized below
        ._name = options.name,
        .page_table = options.page_table,
        .environment = options.environment,
        .entries = .empty,
        .entries_version = 0,
    };

    try address_space.address_arena.init(
        context,
        .{
            .name = resourceArenaName(options.name),
            .quantum = arch.paging.standard_page_size.value,
        },
    );
    errdefer address_space.address_arena.deinit(context);

    try address_space.address_arena.addSpan(
        context,
        options.range.address.value,
        options.range.size.value,
    );
}

/// Reinitialize the address space back to its initial state including unmapping everything.
///
/// The address space must not be in use by any tasks when this function is called as everything is unmapped without
/// flushing.
pub fn reinitializeAndUnmapAll(address_space: *AddressSpace, context: *cascade.Context) void {
    log.debug(context, "{s}: reinitializeAndUnmapAll", .{address_space.name()});

    std.debug.assert(!address_space.page_table_lock.isLocked());
    std.debug.assert(!address_space.entries_lock.isReadLocked() and !address_space.entries_lock.isWriteLocked());

    @panic("NOT IMPLEMENTED"); // TODO
}

/// This leaves the address space in an invalid state, if it will be reused see `reinitializeAndUnmapAll`.
///
/// `reinitializeAndUnmapAll` is expected to have been called before calling this function.
///
/// The address space must not be in use by any tasks when this function is called.
pub fn deinit(address_space: *AddressSpace, context: *cascade.Context) void {
    // cannot use the name as it will reference a defunct process that this address space is now unrelated to
    log.debug(context, "deinit", .{});

    std.debug.assert(!address_space.page_table_lock.isLocked());
    std.debug.assert(!address_space.entries_lock.isReadLocked() and !address_space.entries_lock.isWriteLocked());
    std.debug.assert(address_space.entries.items.len == 0);
    std.debug.assert(address_space.entries.capacity == 0);

    address_space.address_arena.deinit(context);

    address_space.* = undefined;
}

/// Rename the address space.
pub fn rename(address_space: *AddressSpace, new_name: Name) void {
    address_space._name = new_name;
    address_space.address_arena._name = resourceArenaName(new_name);
}

pub fn name(address_space: *const AddressSpace) []const u8 {
    return address_space._name.constSlice();
}

pub const MapOptions = struct {
    /// The number of pages to map.
    ///
    /// Must be greater than 0.
    number_of_pages: u32,

    protection: Protection,

    type: Type,

    pub const Type = union(enum) {
        zero_fill,
        object: Object.Reference,
    };
};

pub const MapError = error{
    ZeroLength,
    OutOfMemory,
};

/// Map a range of pages into the address space.
pub fn map(
    address_space: *AddressSpace,
    context: *cascade.Context,
    options: MapOptions,
) MapError!core.VirtualRange {
    errdefer |err| log.debug(context, "{s}: map failed {t}", .{ address_space.name(), err });

    if (options.number_of_pages == 0) return error.ZeroLength;

    log.verbose(context, "{s}: map {} pages with protection {t} of type {t}", .{
        address_space.name(),
        options.number_of_pages,
        options.protection,
        options.type,
    });

    const allocated_range = address_space.address_arena.allocate(
        context,
        options.number_of_pages * arch.paging.standard_page_size.value,
        .instant_fit,
    ) catch |err| switch (err) {
        error.ZeroLength => unreachable, // `options.number_of_pages` is greater than 0
        error.RequestedLengthUnavailable, error.OutOfBoundaryTags => return error.OutOfMemory,
    };
    errdefer address_space.address_arena.deallocate(context, allocated_range);

    const local_entry: Entry = .{
        .base = .fromInt(allocated_range.base),
        .number_of_pages = options.number_of_pages,
        .protection = options.protection,
        .anonymous_map_reference = .{
            .anonymous_map = null,
            .start_offset = undefined,
        },
        .object_reference = switch (options.type) {
            .object => |object_reference| object_reference,
            .zero_fill => .{
                .object = null,
                .start_offset = undefined,
            },
        },
        .copy_on_write = switch (options.type) {
            .zero_fill => true,
            .object => @panic("NOT IMPLEMENTED"), // TODO
        },
        .needs_copy = switch (options.type) {
            .zero_fill => true,
            .object => @panic("NOT IMPLEMENTED"), // TODO
        },
    };

    const entry_merge = blk: {
        address_space.entries_lock.writeLock(context);
        defer address_space.entries_lock.writeUnlock(context);

        const entry_merge = local_entry.determineEntryMerge(
            context,
            address_space.entries.items,
        );

        switch (entry_merge) {
            .new => |index| {
                const new_entry: *Entry = try .create(context);
                errdefer new_entry.destroy(context);

                new_entry.* = local_entry;

                address_space.entries.insert(
                    cascade.mem.heap.allocator,
                    index,
                    new_entry,
                ) catch return error.OutOfMemory;
            },
            .extend => |extend| {
                if (extend.before) |before_entry| {
                    // merge the local entry into the before entry

                    const old_number_of_pages = before_entry.number_of_pages;
                    before_entry.number_of_pages = old_number_of_pages + local_entry.number_of_pages;

                    if (before_entry.anonymous_map_reference.anonymous_map) |anonymous_map| {
                        anonymous_map.lock.writeLock(context);
                        defer anonymous_map.lock.writeUnlock(context);

                        std.debug.assert(anonymous_map.reference_count == 1);
                        std.debug.assert(anonymous_map.number_of_pages == old_number_of_pages);

                        anonymous_map.number_of_pages = before_entry.number_of_pages;
                    }
                }

                if (extend.after) |after_entry| {
                    if (extend.before) |before_entry| {
                        _ = before_entry;
                        // merge the after entry into the before entry, then remove and free the after entry

                        @panic("NOT IMPLEMENTED"); // TODO: implement merging the entry with both the before and after entry
                    } else {
                        // merge the locak entry into the after entry

                        const old_number_of_pages = after_entry.number_of_pages;
                        after_entry.number_of_pages = old_number_of_pages + local_entry.number_of_pages;
                        after_entry.base.moveBackwardInPlace(
                            arch.paging.standard_page_size.multiplyScalar(local_entry.number_of_pages),
                        );

                        if (after_entry.anonymous_map_reference.anonymous_map) |anonymous_map| {
                            anonymous_map.lock.writeLock(context);
                            defer anonymous_map.lock.writeUnlock(context);

                            std.debug.assert(anonymous_map.reference_count == 1);
                            std.debug.assert(anonymous_map.number_of_pages == old_number_of_pages);
                            std.debug.assert(after_entry.anonymous_map_reference.start_offset >= local_entry.number_of_pages);

                            anonymous_map.number_of_pages = after_entry.number_of_pages;
                            after_entry.anonymous_map_reference.start_offset -= local_entry.number_of_pages;
                        }
                    }
                }
            },
        }

        switch (options.type) {
            .zero_fill => {},
            .object => @panic("HANDLE OBJECT REFERENCE COUNT"), // TODO: is this only for new entries?
        }

        address_space.entries_version +%= 1;

        break :blk entry_merge;
    };

    const result = local_entry.range();

    switch (entry_merge) {
        .new => log.verbose(context, "{s}: inserted new entry", .{address_space.name()}),
        .extend => |extend| {
            if (extend.before != null) {
                if (extend.after != null) {
                    log.verbose(context, "{s}: merged two entries and expanded by {} pages", .{
                        address_space.name(),
                        local_entry.number_of_pages,
                    });
                } else {
                    log.verbose(context, "{s}: extended entry by {} pages", .{
                        address_space.name(),
                        local_entry.number_of_pages,
                    });
                }
            } else if (extend.after != null) {
                log.verbose(context, "{s}: extended entry by {} pages", .{
                    address_space.name(),
                    local_entry.number_of_pages,
                });
            } else unreachable;
        },
    }

    log.verbose(context, "{s}: mapped {f}", .{ address_space.name(), result });

    return result;
}

pub const UnmapError = error{};

/// Unmap a range of pages from the address space.
///
/// The size and address of the range must be aligned to the page size.
pub fn unmap(address_space: *AddressSpace, context: *cascade.Context, range: core.VirtualRange) UnmapError!void {
    errdefer |err| log.debug(context, "{s}: unmap failed {t}", .{ address_space.name(), err });

    std.debug.assert(range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(range.size.isAligned(arch.paging.standard_page_size));

    log.verbose(context, "{s}: unmap {f}", .{ address_space.name(), range });

    @panic("NOT IMPLEMENTED"); // TODO
}

pub const HandlePageFaultError = error{
    /// The faulting address is not mapped.
    NotMapped,

    /// Protection violation.
    Protection,

    /// No memory available.
    NoMemory,
};

/// Handle a page fault.
///
/// Called `uvm_fault` in OpenBSD uvm.
pub fn handlePageFault(
    address_space: *AddressSpace,
    context: *cascade.Context,
    page_fault_details: cascade.mem.PageFaultDetails,
) HandlePageFaultError!void {
    errdefer |err| log.debug(context, "{s}: page fault failed {t}", .{ address_space.name(), err });

    log.verbose(context, "{s}: page fault {f}", .{
        address_space.name(),
        page_fault_details,
    });

    var fault_info: FaultInfo = .{
        .address_space = address_space,
        .faulting_address = page_fault_details.faulting_address.alignBackward(
            arch.paging.standard_page_size,
        ),
        .access_type = page_fault_details.access_type,
    };

    while (true) {
        var opt_anonymous_page: ?*AnonymousPage = null;

        fault_info.faultCheck(
            context,
            &opt_anonymous_page,
            page_fault_details.fault_type,
        ) catch |err| switch (err) {
            error.Restart => {
                log.verbose(context, "restarting fault", .{});
                continue;
            },
            else => |narrow_err| return @errorCast(narrow_err), // TODO: why is this `@errorCast` needed?
        };

        if (opt_anonymous_page) |anonymous_page| {
            _ = anonymous_page;
            @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L685
        } else {
            fault_info.faultObjectOrZeroFill(context) catch |err| switch (err) {
                error.Restart => {
                    log.verbose(context, "restarting fault", .{});
                    continue;
                },
                else => |narrow_err| return @errorCast(narrow_err), // TODO: why is this `@errorCast` needed?
            };
        }

        break;
    }
}

/// Prints the address space.
///
/// Locks the entries lock.
pub fn print(address_space: *AddressSpace, context: *cascade.Context, writer: *std.Io.Writer, indent: usize) !void {
    address_space.entries_lock.readLock(context);
    defer address_space.entries_lock.readUnlock(context);

    const new_indent = indent + 2;

    try writer.writeAll("AddressSpace{\n");

    try writer.splatByteAll(' ', new_indent);
    try writer.print("mode: {t},\n", .{address_space.mode});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("entries_version: {d},\n", .{address_space.entries_version});

    if (address_space.entries.items.len != 0) {
        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("entries: {\n");

        for (address_space.entries.items) |entry| {
            try writer.splatByteAll(' ', new_indent + 2);
            try entry.print(context, writer, new_indent + 2);
            try writer.writeAll(",\n");
        }

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("},\n");
    } else {
        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("entries: {},\n");
    }

    try writer.splatByteAll(' ', indent);
    try writer.writeAll("}");
}

pub inline fn format(_: *const AddressSpace, _: *std.Io.Writer) !void {
    @compileError("use `AddressSpace.print` instead");
}

pub const Name = core.containers.BoundedArray(u8, cascade.config.address_space_name_length);

fn resourceArenaName(address_space_name: Name) cascade.mem.resource_arena.Name {
    var resource_arena_name: cascade.mem.resource_arena.Name = .{};
    // these assume capacity calls are safe as the size of an `cascade.mem.resource_arena.Name` is ensured in
    // `cascade.config` to have enough capacity for a `cascade.mem.AddressSpace.Name` along with the `_address_arena` suffix
    resource_arena_name.appendSliceAssumeCapacity(address_space_name.constSlice());
    resource_arena_name.appendSliceAssumeCapacity("_address_arena");
    return resource_arena_name;
}

pub const AnonymousMap = @import("AnonymousMap.zig");
pub const AnonymousPage = @import("AnonymousPage.zig");
pub const Entry = @import("Entry.zig");
const Page = cascade.mem.Page; // called a `vm_page` in uvm
const FaultInfo = @import("FaultInfo.zig");
const Object = @import("Object.zig");

const Protection = cascade.mem.MapType.Protection;

const arch = @import("arch");
const cascade = @import("cascade");

const core = @import("core");
const log = cascade.debug.log.scoped(.address_space);
const std = @import("std");
