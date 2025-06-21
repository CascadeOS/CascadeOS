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
address_arena: kernel.mem.ResourceArena = undefined,

mode: kernel.Mode,

page_table: kernel.arch.paging.PageTable,

/// Protects the `page_table` field.
page_table_lock: kernel.sync.Mutex = .{},

/// The map entries in this address space.
///
/// Called a `vm_map` in uvm.
///
/// Sorted by `base`.
entries: std.ArrayListUnmanaged(*Entry) = .empty, // TODO: better data structure

/// Protects the `entries` field.
entries_lock: kernel.sync.RwLock = .{},

/// Used to detect changes to the entries list while it is unlocked.
///
/// Incremented when the entries list is modified.
entries_version: u32 = 0,

pub const InitOptions = struct {
    name: Name,

    range: core.VirtualRange,

    page_table: kernel.arch.paging.PageTable,

    mode: kernel.Mode,
};

pub fn init(
    address_space: *AddressSpace,
    current_task: *kernel.Task,
    options: InitOptions,
) !void {
    log.debug("{s}: init with {} mode {s}", .{
        options.name.constSlice(),
        options.range,
        @tagName(options.mode),
    });

    address_space.* = .{
        ._name = options.name,
        .page_table = options.page_table,
        .mode = options.mode,
    };

    var address_space_name: kernel.mem.ResourceArena.Name = .{};
    address_space_name.appendSliceAssumeCapacity(options.name.constSlice());
    address_space_name.appendSliceAssumeCapacity("_address_arena");

    try address_space.address_arena.init(
        .{
            .name = address_space_name,
            .quantum = kernel.arch.paging.standard_page_size.value,
            .quantum_caching = .no,
        },
    );
    errdefer address_space.address_arena.deinit(current_task);

    try address_space.address_arena.addSpan(
        current_task,
        options.range.address.value,
        options.range.size.value,
    );
}

pub fn deinit(address_space: *AddressSpace, current_task: *kernel.Task) void {
    log.debug("{s}: deinit", .{address_space.name()});

    _ = current_task;
    @panic("NOT IMPLEMENTED"); // TODO
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
    current_task: *kernel.Task,
    options: MapOptions,
) MapError!core.VirtualRange {
    errdefer |err| log.debug("{s}: map failed {s}", .{ address_space.name(), @errorName(err) });

    if (options.number_of_pages == 0) return error.ZeroLength;

    log.verbose("{s}: map {} pages with protection {s} of type {s}", .{
        address_space.name(),
        options.number_of_pages,
        @tagName(options.protection),
        @tagName(options.type),
    });

    const allocated_range = address_space.address_arena.allocate(
        current_task,
        options.number_of_pages * kernel.arch.paging.standard_page_size.value,
        .instant_fit,
    ) catch |err| switch (err) {
        error.ZeroLength => unreachable, // `options.number_of_pages` is greater than 0
        error.RequestedLengthUnavailable, error.OutOfBoundaryTags => return error.OutOfMemory,
    };
    errdefer address_space.address_arena.deallocate(current_task, allocated_range);

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
        address_space.entries_lock.writeLock(current_task);
        defer address_space.entries_lock.writeUnlock(current_task);

        const entry_merge = local_entry.determineEntryMerge(
            current_task,
            address_space.entries.items,
        );

        switch (entry_merge) {
            .new => |index| {
                const new_entry: *Entry = try .create(current_task);
                errdefer new_entry.destroy(current_task);

                new_entry.* = local_entry;

                address_space.entries.insert(
                    kernel.mem.heap.allocator,
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
                        anonymous_map.lock.writeLock(current_task);
                        defer anonymous_map.lock.writeUnlock(current_task);

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
                            kernel.arch.paging.standard_page_size.multiplyScalar(local_entry.number_of_pages),
                        );

                        if (after_entry.anonymous_map_reference.anonymous_map) |anonymous_map| {
                            anonymous_map.lock.writeLock(current_task);
                            defer anonymous_map.lock.writeUnlock(current_task);

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
        .new => log.verbose("{s}: inserted new entry", .{address_space.name()}),
        .extend => |extend| {
            if (extend.before != null) {
                if (extend.after != null) {
                    log.verbose("{s}: merged two entries and expanded by {} pages", .{
                        address_space.name(),
                        local_entry.number_of_pages,
                    });
                } else {
                    log.verbose("{s}: extended entry by {} pages", .{
                        address_space.name(),
                        local_entry.number_of_pages,
                    });
                }
            } else if (extend.after != null) {
                log.verbose("{s}: extended entry by {} pages", .{
                    address_space.name(),
                    local_entry.number_of_pages,
                });
            } else unreachable;
        },
    }

    log.verbose("{s}: mapped {}", .{ address_space.name(), result });

    return result;
}

pub const UnmapError = error{};

/// Unmap a range of pages from the address space.
///
/// The size and address of the range must be aligned to the page size.
pub fn unmap(address_space: *AddressSpace, current_task: *kernel.Task, range: core.VirtualRange) UnmapError!void {
    errdefer |err| log.debug("{s}: unmap failed {s}", .{ address_space.name(), @errorName(err) });

    std.debug.assert(range.address.isAligned(kernel.arch.paging.standard_page_size));
    std.debug.assert(range.size.isAligned(kernel.arch.paging.standard_page_size));

    log.verbose("{s}: unmap {}", .{ address_space.name(), range });

    _ = current_task;

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
    current_task: *kernel.Task,
    page_fault_details: kernel.mem.PageFaultDetails,
) HandlePageFaultError!void {
    errdefer |err| log.debug("{s}: page fault failed {s}", .{ address_space.name(), @errorName(err) });

    log.verbose("{s}: page fault {}", .{
        address_space.name(),
        page_fault_details,
    });

    var fault_info: FaultInfo = .{
        .address_space = address_space,
        .faulting_address = page_fault_details.faulting_address.alignBackward(
            kernel.arch.paging.standard_page_size,
        ),
        .access_type = page_fault_details.access_type,
    };

    while (true) {
        var opt_anonymous_page: ?*AnonymousPage = null;

        fault_info.faultCheck(
            current_task,
            &opt_anonymous_page,
            page_fault_details.fault_type,
        ) catch |err| switch (err) {
            error.Restart => {
                log.verbose("restarting fault", .{});
                continue;
            },
            else => |narrow_err| return @errorCast(narrow_err), // TODO: why is this `@errorCast` needed?
        };

        if (opt_anonymous_page) |anonymous_page| {
            _ = anonymous_page;
            @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L685
        } else {
            fault_info.faultObjectOrZeroFill(current_task) catch |err| switch (err) {
                error.Restart => {
                    log.verbose("restarting fault", .{});
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
pub fn print(address_space: *AddressSpace, current_task: *kernel.Task, writer: std.io.AnyWriter, indent: usize) !void {
    address_space.entries_lock.readLock(current_task);
    defer address_space.entries_lock.readUnlock(current_task);

    const new_indent = indent + 2;

    try writer.writeAll("AddressSpace{\n");

    try writer.writeByteNTimes(' ', new_indent);
    try writer.print("mode: {s},\n", .{@tagName(address_space.mode)});

    try writer.writeByteNTimes(' ', new_indent);
    try writer.print("entries_version: {d},\n", .{address_space.entries_version});

    if (address_space.entries.items.len != 0) {
        try writer.writeByteNTimes(' ', new_indent);
        try writer.writeAll("entries: {\n");

        for (address_space.entries.items) |entry| {
            try writer.writeByteNTimes(' ', new_indent + 2);
            try entry.print(current_task, writer, new_indent + 2);
            try writer.writeAll(",\n");
        }

        try writer.writeByteNTimes(' ', new_indent);
        try writer.writeAll("},\n");
    } else {
        try writer.writeByteNTimes(' ', new_indent);
        try writer.writeAll("entries: {},\n");
    }

    try writer.writeByteNTimes(' ', indent);
    try writer.writeAll("}");
}

pub inline fn format(
    _: *const AddressSpace,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    _: anytype,
) !void {
    @compileError("use `AddressSpace.print` instead");
}

pub const Name = std.BoundedArray(u8, kernel.config.address_space_name_length);

pub const global_init = struct {
    pub fn initializeCaches() !void {
        try AnonymousMap.global_init.initializeCache();
        try AnonymousPage.global_init.initializeCache();
        try Entry.global_init.initializeCache();
    }
};

const AnonymousMap = @import("AnonymousMap.zig");
const AnonymousPage = @import("AnonymousPage.zig");
const Entry = @import("Entry.zig");
const Page = kernel.mem.Page; // called a `vm_page` in uvm
const FaultInfo = @import("FaultInfo.zig");
const Object = @import("Object.zig");

const Protection = kernel.mem.MapType.Protection;

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const builtin = @import("builtin");
const log = kernel.debug.log.scoped(.address_space);
