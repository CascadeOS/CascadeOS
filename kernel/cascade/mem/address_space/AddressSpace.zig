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
//! Made with reference to [OpenBSD implementation of UVM](https://github.com/openbsd/src/tree/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm)
//!

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Page = cascade.mem.Page; // called a `vm_page` in uvm
const Protection = cascade.mem.MapType.Protection;
const core = @import("core");

pub const AnonymousMap = @import("AnonymousMap.zig");
pub const AnonymousPage = @import("AnonymousPage.zig");
pub const Entry = @import("Entry.zig");
const FaultInfo = @import("FaultInfo.zig");
const Object = @import("Object.zig");

const log = cascade.debug.log.scoped(.address_space);
const AddressSpace = @This();

_name: Name,

range: core.VirtualRange,

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
        .range = options.range,
        ._name = options.name,
        .environment = options.environment,
        .page_table = options.page_table,
        .entries = .empty,
        .entries_version = 0,
    };
}

/// Retarget the address space to a new process.
///
/// Caller must ensure:
///  - the address space is not in use by any tasks
///  - the address space is empty
pub fn retarget(address_space: *AddressSpace, new_process: *cascade.Process) void {
    std.debug.assert(address_space.environment == .user);
    std.debug.assert(!address_space.page_table_lock.isLocked());
    std.debug.assert(!address_space.entries_lock.isReadLocked() and !address_space.entries_lock.isWriteLocked());
    std.debug.assert(address_space.entries.items.len == 0);
    std.debug.assert(address_space.entries.capacity == 0);
    std.debug.assert(address_space.entries_version == 0);

    address_space._name = cascade.mem.AddressSpace.Name.fromSlice(
        new_process.name.constSlice(),
    ) catch unreachable; // ensured in `cascade.config`
    address_space.environment = .{ .user = new_process };
}

/// Reinitialize the address space back to its initial state including unmapping everything.
///
/// Caller must ensure:
///  - the address space is not in use by any tasks
pub fn reinitializeAndUnmapAll(address_space: *AddressSpace, context: *cascade.Context) void {
    log.debug(context, "{s}: reinitializeAndUnmapAll", .{address_space.name()});

    std.debug.assert(!address_space.page_table_lock.isLocked());
    std.debug.assert(!address_space.entries_lock.isReadLocked() and !address_space.entries_lock.isWriteLocked());

    try address_space.unmap(context, address_space.range);

    address_space.entries_version = 0;
}

/// This leaves the address space in an invalid state, if it will be reused see `reinitializeAndUnmapAll`.
///
/// Caller must ensure:
///  - the address space is not in use by any tasks
///  - the address space is empty
pub fn deinit(address_space: *AddressSpace, context: *cascade.Context) void {
    // cannot use the name as it will reference a defunct process that this address space is now unrelated to
    log.debug(context, "deinit", .{});

    std.debug.assert(!address_space.page_table_lock.isLocked());
    std.debug.assert(!address_space.entries_lock.isReadLocked() and !address_space.entries_lock.isWriteLocked());
    std.debug.assert(address_space.entries.items.len == 0);
    std.debug.assert(address_space.entries.capacity == 0);
    std.debug.assert(address_space.entries_version == 0);

    address_space.* = undefined;
}

pub fn name(address_space: *const AddressSpace) []const u8 {
    return address_space._name.constSlice();
}

pub const MapOptions = struct {
    /// The size of the range to map.
    ///
    /// Caller must ensure:
    ///  - the size is not `.zero`
    ///  - the size is aligned to the standard page size
    size: core.Size,

    /// The protection of the range.
    ///
    /// Caller must ensure:
    ///  - this value does not exceed `max_protection` if it is provided
    protection: Protection,

    /// The maximum allowed protection of the range.
    ///
    /// The protection of the range cannot exceed this value.
    ///
    /// If `null` then the maximum protection is the same as the `protection`.
    ///
    /// Caller must ensure:
    ///  - the maximum protection is not `.none`
    max_protection: ?Protection = null,

    type: Type,

    pub const Type = union(enum) {
        zero_fill,
        object: Object.Reference,
    };
};

pub const MapError = error{
    /// The requested size is zero.
    ZeroSize,

    /// The requested size is not available.
    RequestedSizeUnavailable,

    /// No memory available.
    OutOfMemory,

    /// The requested map would result in the protection of an entry in the range exceeding its maximum protection.
    MaxProtectionExceeded,
};

/// Map a range into the address space.
///
/// Caller must ensure:
///  - the size is aligned to the standard page size
///  - the size is not `.zero`
///  - the `max_protection` if provided is not `.none`
pub fn map(
    address_space: *AddressSpace,
    context: *cascade.Context,
    options: MapOptions,
) MapError!core.VirtualRange {
    errdefer |err| log.debug(context, "{s}: map failed {t}", .{ address_space.name(), err });

    log.verbose(context, "{s}: map {f} - {t} - {t}", .{
        address_space.name(),
        options.size,
        options.protection,
        options.type,
    });

    std.debug.assert(options.size.isAligned(arch.paging.standard_page_size));

    if (options.size.equal(.zero)) {
        @branchHint(.cold);
        return error.ZeroSize;
    }

    if (options.max_protection) |max_protection| {
        std.debug.assert(max_protection != .none);
        if (@intFromEnum(options.protection) > @intFromEnum(max_protection)) {
            @branchHint(.cold);
            return error.MaxProtectionExceeded;
        }
    }

    var local_entry: Entry = .{
        .range = undefined, // set below
        .protection = options.protection,
        .max_protection = options.max_protection orelse options.protection,
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

    var merges: usize = 0;

    {
        address_space.entries_lock.writeLock(context);
        defer address_space.entries_lock.writeUnlock(context);

        const free_range = address_space.findFreeRange(options.size) orelse {
            @branchHint(.cold);
            return error.RequestedSizeUnavailable;
        };

        const insertion_index = free_range.insertion_index;
        local_entry.range = free_range.range;

        // following entry
        if (insertion_index != address_space.entries.items.len) {
            const following_entry = address_space.entries.items[insertion_index];
            std.debug.assert(!local_entry.anyOverlap(following_entry)); // entry overlaps with the following entry

            if (local_entry.canMerge(context, following_entry)) {
                local_entry.merge(context, following_entry);
                following_entry.* = local_entry;
                merges += 1;
            }
        }

        // preceding entry
        if (insertion_index != 0) {
            const preceding_entry = address_space.entries.items[insertion_index - 1];
            std.debug.assert(!local_entry.anyOverlap(preceding_entry)); // entry overlaps with the preceding entry

            if (preceding_entry.canMerge(context, &local_entry)) {
                preceding_entry.merge(context, &local_entry);

                if (merges != 0) {
                    // the local entry was merged into the following entry above, so we need to remove it
                    const following_entry = address_space.entries.orderedRemove(insertion_index);
                    following_entry.destroy(context);
                }

                merges += 1;
            }
        }

        if (merges == 0) {
            const new_entry: *Entry = try .create(context);
            errdefer new_entry.destroy(context);

            new_entry.* = local_entry;

            address_space.entries.insert(
                cascade.mem.heap.allocator,
                insertion_index,
                new_entry,
            ) catch {
                @branchHint(.cold);
                return error.OutOfMemory;
            };
        }
        errdefer comptime unreachable;

        switch (options.type) {
            .zero_fill => {},
            .object => @panic("HANDLE OBJECT REFERENCE COUNT"), // TODO: is this only for new entries?
        }

        address_space.entries_version +%= 1;
    }
    errdefer comptime unreachable;

    switch (merges) {
        0 => log.verbose(context, "{s}: inserted new entry", .{address_space.name()}),
        1 => log.verbose(context, "{s}: merged with pre-existing entry", .{address_space.name()}),
        2 => log.verbose(context, "{s}: merged with 2 pre-existing entries", .{address_space.name()}),
        else => unreachable,
    }

    log.verbose(context, "{s}: mapped {f}", .{ address_space.name(), local_entry.range });

    return local_entry.range;
}

const FreeRange = struct {
    range: core.VirtualRange,
    insertion_index: usize,
};

/// Find a free range in the address space of the given size.
fn findFreeRange(address_space: *AddressSpace, size: core.Size) ?FreeRange {
    // TODO: we could seperately track the free ranges in the address space

    var candidate_insertion_index: usize = 0;
    var candidate_range: core.VirtualRange = .fromAddr(address_space.range.address, size);
    var candidate_range_last_address = candidate_range.last();

    for (address_space.entries.items) |entry| {
        if (candidate_range_last_address.lessThan(entry.range.address)) {
            @branchHint(.unlikely);
            // the candidate range is entirely before the entry
            break;
        }

        candidate_range.address = entry.range.endBound();
        candidate_range_last_address = candidate_range.last();
        candidate_insertion_index += 1;
    }

    if (candidate_range_last_address.lessThanOrEqual(address_space.range.last())) {
        // the candidate range does not extend past the end of the address space
        @branchHint(.likely);
        return .{
            .range = candidate_range,
            .insertion_index = candidate_insertion_index,
        };
    }

    return null;
}

pub const ChangeProtection = union(enum) {
    /// The protection to change the range to.
    protection: Protection,

    /// The maximum protection to change the range to.
    ///
    /// The maximum protection of entries in the range cannot be increased only decreased or unchanged.
    ///
    /// Caller must ensure:
    ///  - the maximum protection is not `.none`
    max_protection: Protection,

    /// Modify both the protection and the maximum protection.
    ///
    /// This is more efficient than modifying each separately.
    both: Both,

    const Both = struct {
        /// The protection to change the range to.
        protection: Protection,

        /// The maximum protection to change the range to.
        ///
        /// The maximum protection of entries in the range cannot be increased only decreased or unchanged.
        ///
        /// Caller must ensure:
        ///  - the maximum protection is not `.none`
        max_protection: Protection,
    };
};

pub const ChangeProtectionError = error{};

/// Change the protection and/or maximum protection of a range in the address space.
///
/// Caller must ensure:
///  - the size and address of the range are aligned to the standard page size
///  - the `max_protection` if provided is not `.none`
pub fn changeProtection(
    address_space: *AddressSpace,
    context: *cascade.Context,
    range: core.VirtualRange,
    change: ChangeProtection,
) ChangeProtectionError!void {
    errdefer |err| log.debug(context, "{s}: change protection failed {t}", .{ address_space.name(), err });

    switch (change) {
        .protection => |new_protection| log.verbose(
            context,
            "{s}: change protection of {f} to {t}",
            .{
                address_space.name(),
                range,
                new_protection,
            },
        ),
        .max_protection => |new_max_protection| {
            log.verbose(
                context,
                "{s}: change max protection of {f} to {t}",
                .{
                    address_space.name(),
                    range,
                    new_max_protection,
                },
            );

            std.debug.assert(new_max_protection != .none);
        },
        .both => |both| {
            log.verbose(
                context,
                "{s}: change protection and max protection of {f} to {t} / {t}",
                .{
                    address_space.name(),
                    range,
                    both.protection,
                    both.max_protection,
                },
            );

            std.debug.assert(both.max_protection != .none);
        },
    }

    std.debug.assert(range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(range.size.isAligned(arch.paging.standard_page_size));

    if (range.size.equal(.zero)) {
        @branchHint(.cold);
        return;
    }

    @panic("NOT IMPLEMENTED"); // TODO
}

pub const UnmapError = error{};

/// Unmap a range from the address space.
///
/// Caller must ensure:
///  - the size and address of the range are aligned to the standard page size
pub fn unmap(address_space: *AddressSpace, context: *cascade.Context, range: core.VirtualRange) UnmapError!void {
    errdefer |err| log.debug(context, "{s}: unmap failed {t}", .{ address_space.name(), err });

    log.verbose(context, "{s}: unmap {f}", .{ address_space.name(), range });

    std.debug.assert(range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(range.size.isAligned(arch.paging.standard_page_size));

    if (range.size.equal(.zero)) {
        @branchHint(.cold);
        return;
    }

    @panic("NOT IMPLEMENTED"); // TODO
}

pub const HandlePageFaultError = error{
    /// The faulting address is not mapped.
    NotMapped,

    /// Protection violation.
    Protection,

    /// No memory available.
    OutOfMemory,
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
            @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/9222ee7ab44f0e3155b861a0c0a6dd8396d03df3/sys/uvm/uvm_fault.c#L685
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
    try writer.print("environment: {t},\n", .{address_space.environment});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("range: {f},\n", .{address_space.range});

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

pub inline fn format(address_space: *AddressSpace, writer: *std.Io.Writer) !void {
    return address_space.print(.current(), writer, 0);
}

pub const Name = core.containers.BoundedArray(u8, cascade.config.address_space_name_length);

/// Returns the index of the entry that contains the given address.
///
/// Returns `null` if the address is not mapped.
///
/// Caller must ensure:
///  - the address space entries are atleast read locked
pub fn entryIndexByAddress(address_space: *const AddressSpace, address: core.VirtualAddress) ?usize {
    std.debug.assert(address_space.entries_lock.isReadLocked() or address_space.entries_lock.isWriteLocked());

    return std.sort.binarySearch(
        *const Entry,
        address_space.entries.items,
        address,
        entryAddressCompare,
    );
}

fn entryAddressCompare(addr: core.VirtualAddress, entry: *const Entry) std.math.Order {
    return entry.range.compareAddressOrder(addr);
}
