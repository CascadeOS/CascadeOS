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
        .wired_count = 0,
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

    fn toRequest(change: ChangeProtection) Request {
        return switch (change) {
            .protection => |new_protection| .{
                .protection = new_protection,
                .max_protection = null,
            },
            .max_protection => |new_max_protection| .{
                .protection = null,
                .max_protection = new_max_protection,
            },
            .both => |both| .{
                .protection = both.protection,
                .max_protection = both.max_protection,
            },
        };
    }

    const Request = struct {
        protection: ?Protection,
        max_protection: ?Protection,

        fn toInts(request: Request) struct { ?u8, ?u8 } {
            return .{
                if (request.protection) |protection| @intFromEnum(protection) else null,
                if (request.max_protection) |max_protection| @intFromEnum(max_protection) else null,
            };
        }

        pub fn format(
            request: Request,
            writer: *std.Io.Writer,
        ) !void {
            try writer.print(
                "protection: {?t} - max_protection: {?t}",
                .{
                    request.protection,
                    request.max_protection,
                },
            );
        }
    };
};

pub const ChangeProtectionError = error{
    /// The requested change would result in the maximum protection of an entry in the range being increased.
    MaxProtectionIncreased,

    /// The requested change would result in the protection of an entry in the range exceeding its maximum protection.
    MaxProtectionExceeded,

    /// No memory available.
    OutOfMemory,
};

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

    const request = change.toRequest();

    log.verbose(context, "{s}: change protection of {f} to {f}", .{ address_space.name(), range, request });

    std.debug.assert(range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(range.size.isAligned(arch.paging.standard_page_size));
    if (request.max_protection) |max_protection| std.debug.assert(max_protection != .none);

    const result: ChangeProtectionResult = blk: {
        if (range.size.equal(.zero)) {
            @branchHint(.cold);
            break :blk .none;
        }

        address_space.entries_lock.writeLock(context);
        defer address_space.entries_lock.writeUnlock(context);

        const entry_range = address_space.entryRange(range) orelse {
            // no entries overlap the range
            break :blk .none;
        };
        std.debug.assert(entry_range.length != 0);

        if (!try address_space.validateChangeProtection(entry_range, request)) {
            // there is no work to do
            break :blk .none;
        }

        // preallocate the worse-case number of entries we might need and ensure sufficent capacity in the entries array
        // only entries that straddle the start or end of the range might require a new entry, so we will need at most 2
        var new_entries: NewEntries = .{};
        defer for (new_entries.constSlice()) |entry| {
            entry.destroy(context); // free any preallocated entries that we didn't use
        };

        worse_case_new_entries: {
            var worse_case_new_entries: usize = 0;

            if (entry_range.first_straddles) worse_case_new_entries += 1;
            if (entry_range.last_straddles) worse_case_new_entries += 1;
            if (worse_case_new_entries == 0) break :worse_case_new_entries;

            try Entry.createMany(context, new_entries.unusedCapacitySlice()[0..worse_case_new_entries]);
            new_entries.resize(worse_case_new_entries) catch unreachable;

            try address_space.entries.ensureUnusedCapacity(
                cascade.mem.heap.allocator,
                worse_case_new_entries,
            );
        }
        errdefer comptime unreachable;

        const result = address_space.performChangeProtection(
            context,
            entry_range,
            range,
            request,
            &new_entries,
        );

        if (result.need_remap) {
            // TODO: as we have a write lock to the entries do we need to lock the page table?
            address_space.page_table_lock.lock(context);
            defer address_space.page_table_lock.unlock(context);

            @panic("NOT IMPLEMENTED"); // TODO: support remapping the page table
        }

        address_space.entries_version +%= 1;

        break :blk result;
    };

    log.verbose(
        context,
        "{s}: change protection of {f} resulted in {} split, {} modified and {} merged entries",
        .{
            address_space.name(),
            range,
            result.entries_split,
            result.entries_modified,
            result.entries_merged,
        },
    );
}

/// Validates the change protection request.
///
/// Returns false if the change protection request is a no-op.
fn validateChangeProtection(
    address_space: *AddressSpace,
    entry_range: EntryRange,
    request: ChangeProtection.Request,
) !bool {
    const opt_new_protection, const opt_new_max_protection = request.toInts();

    var any_changes = false;

    for (address_space.entries.items[entry_range.start..][0..entry_range.length]) |entry| {
        const planned_max_protection = if (opt_new_max_protection) |new_max_protection| blk: {
            const old_max_protection = @intFromEnum(entry.max_protection);

            if (new_max_protection > old_max_protection) {
                @branchHint(.cold);
                return error.MaxProtectionIncreased;
            }

            if (new_max_protection != old_max_protection) any_changes = true;

            break :blk new_max_protection;
        } else @intFromEnum(entry.max_protection);

        const old_protection = @intFromEnum(entry.protection);

        if (opt_new_protection) |new_protection| {
            if (new_protection > planned_max_protection) {
                @branchHint(.cold);
                return error.MaxProtectionExceeded;
            }

            if (new_protection != old_protection) any_changes = true;
        } else {
            if (old_protection > planned_max_protection) {
                @branchHint(.cold);
                return error.MaxProtectionExceeded;
            }
        }
    }

    return any_changes;
}

const ChangeProtectionResult = struct {
    entries_split: usize,
    entries_modified: usize,
    entries_merged: usize,

    /// `true` is the page tables need to be remapped due to changes in the protection of the entries.
    need_remap: bool,

    pub const none: ChangeProtectionResult = .{
        .entries_modified = 0,
        .entries_split = 0,
        .entries_merged = 0,
        .need_remap = false,
    };
};

fn performChangeProtection(
    address_space: *AddressSpace,
    context: *cascade.Context,
    entry_range: EntryRange,
    range: core.VirtualRange,
    request: ChangeProtection.Request,
    new_entries: *NewEntries,
) ChangeProtectionResult {
    var result: ChangeProtectionResult = .none;

    var first_entry_index = entry_range.start;

    // split first entry if necessary
    if (entry_range.first_straddles) no_split_first_entry: {
        const first_entry = address_space.entries.items[first_entry_index];

        split_first_entry: {
            if (request.protection) |new_protection| {
                if (first_entry.protection != new_protection) break :split_first_entry;
            }
            if (request.max_protection) |new_max_protection| {
                if (first_entry.max_protection != new_max_protection) break :split_first_entry;
            }

            // the first entry is already the correct protection so no need to split it
            break :no_split_first_entry;
        }

        const split_offset = range.address.subtract(first_entry.range.address);
        log.verbose(context, "{s}: split first entry {f} at offset {f}", .{
            address_space.name(),
            first_entry.range,
            split_offset,
        });

        // the new entry will be after the first entry, and will become the new first entry in the range
        //
        // | first entry | -> | first entry | new entry |
        const new_entry = new_entries.pop() orelse unreachable;
        first_entry.split(context, new_entry, split_offset);

        // move first entry index forward to as the new entry is now the first entry of the entry range
        first_entry_index += 1;
        address_space.entries.insertAssumeCapacity(first_entry_index, new_entry);

        result.entries_split += 1;
    }

    // split last entry if necessary
    if (entry_range.last_straddles) no_split_last_entry: {
        const last_entry_index = first_entry_index + entry_range.length - 1;
        const last_entry = address_space.entries.items[last_entry_index];

        split_last_entry: {
            if (request.protection) |new_protection| {
                if (last_entry.protection != new_protection) break :split_last_entry;
            }
            if (request.max_protection) |new_max_protection| {
                if (last_entry.max_protection != new_max_protection) break :split_last_entry;
            }

            // the last entry is already the correct protection so no need to split it
            break :no_split_last_entry;
        }

        const split_offset = range.endBound().subtract(last_entry.range.address);
        log.verbose(context, "{s}: split last entry {f} at offset {f}", .{
            address_space.name(),
            last_entry.range,
            split_offset,
        });

        // the new entry will be after last entry, last entry will remain the last entry in the range
        //
        // | last entry | -> | last entry | new entry |
        const new_entry = new_entries.pop() orelse unreachable;
        last_entry.split(context, new_entry, split_offset);

        // `last_entry_index + 1` as the new entry is after the last entry of the entry range
        address_space.entries.insertAssumeCapacity(last_entry_index + 1, new_entry);

        result.entries_split += 1;
    }

    // iterate over entries in range in reverse order, modify and merge them
    var index = first_entry_index + entry_range.length;
    while (index > first_entry_index) {
        index -= 1;

        var modified = false;

        const entry = address_space.entries.items[index];
        if (request.protection) |new_protection| {
            if (entry.protection != new_protection) {
                entry.protection = new_protection;
                result.need_remap = true;
                modified = true;
            }
        }
        if (request.max_protection) |new_max_protection| {
            if (entry.max_protection != new_max_protection) {
                entry.max_protection = new_max_protection;
                modified = true;
            }
        }

        if (modified) result.entries_modified += 1;

        no_following_entry: {
            const following_index = index + 1;

            if (following_index >= address_space.entries.items.len) {
                @branchHint(.unlikely);
                break :no_following_entry;
            }
            const following_entry = address_space.entries.items[following_index];

            if (entry.canMerge(context, following_entry)) {
                entry.merge(context, following_entry);

                _ = address_space.entries.orderedRemove(following_index);
                following_entry.destroy(context);

                result.entries_merged += 1;
            }
        }
    }

    return result;
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
const NewEntries = core.containers.BoundedArray(*Entry, 2);

/// Returns the index of the entry that contains the given address.
///
/// Returns `null` if the address is not mapped.
///
/// Caller must ensure:
///  - the address space entries are atleast read locked
pub fn entryIndexByAddress(address_space: *const AddressSpace, address: core.VirtualAddress) ?usize {
    std.debug.assert(address_space.entries_lock.isReadLocked() or address_space.entries_lock.isWriteLocked());
    return innerEntryIndexByAddress(address_space.entries.items, address);
}

// Exists so that a subslice of entries can be searched unlike with `entryIndexByAddress` which searches the entire slice.
inline fn innerEntryIndexByAddress(entries: []const *const Entry, address: core.VirtualAddress) ?usize {
    return std.sort.binarySearch(
        *const Entry,
        entries,
        address,
        entryAddressCompare,
    );
}

fn entryAddressCompare(addr: core.VirtualAddress, entry: *const Entry) std.math.Order {
    return entry.range.compareAddressOrder(addr);
}

const EntryRange = struct {
    start: usize,
    length: usize,

    first_straddles: bool = false,
    last_straddles: bool = false,
};

/// Return the start index and length of the entries that overlap the given range.
///
/// Also determines if the first and last entries straddle the start and end of the range.
fn entryRange(address_space: *const AddressSpace, range: core.VirtualRange) ?EntryRange {
    const entries = address_space.entries.items;

    var entry_range: EntryRange = blk: {
        const start_index = std.sort.lowerBound(
            *const Entry,
            entries,
            range.address,
            entryAddressCompare,
        );
        if (start_index == entries.len) return null;

        var index = start_index;

        while (index < entries.len) : (index += 1) {
            if (!entries[index].range.anyOverlap(range)) break;
        }
        std.debug.assert(index != start_index);

        break :blk .{
            .start = start_index,
            .length = index - start_index,
        };
    };

    const first_entry = address_space.entries.items[entry_range.start];
    if (first_entry.range.address.lessThan(range.address)) {
        std.debug.assert(first_entry.range.last().greaterThan(range.address));
        entry_range.first_straddles = true;
    }

    const last_entry = address_space.entries.items[entry_range.start + entry_range.length - 1];
    if (last_entry.range.last().greaterThan(range.last())) {
        std.debug.assert(last_entry.range.address.lessThan(range.last()));
        entry_range.last_straddles = true;
    }

    return entry_range;
}
