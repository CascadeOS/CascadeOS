// SPDX-License-Identifier: MIT and BSD-2-Clause
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: Copyright (c) 1997 Charles D. Cranor and Washington University.

//! A memory object describing a file or device.
//!
//! A combination of `uvm_faultinfo` and `uvm_faultctx` from OpenBSD uvm.
//!
//! Based on UVM:
//!   * [Design and Implementation of the UVM Virtual Memory System](https://chuck.cranor.org/p/diss.pdf) by Charles D. Cranor
//!   * [Zero-Copy Data Movement Mechanisms for UVM](https://citeseerx.ist.psu.edu/document?repid=rep1&type=pdf&doi=8961abccddf8ff24f7b494cd64d5cf62604b0018) by Charles D. Cranor and Gurudatta M. Parulkar
//!   * [The UVM Virtual Memory System](https://www.usenix.org/legacy/publications/library/proceedings/usenix99/full_papers/cranor/cranor.pdf) by Charles D. Cranor and Gurudatta M. Parulkar
//!
//! Made with reference to [OpenBSD implementation of UVM](https://github.com/openbsd/src/tree/master/sys/uvm)
//!

const FaultInfo = @This();

address_space: *AddressSpace,

/// The access type of the fault
access_type: kernel.mem.PageFaultDetails.AccessType,

/// The address that caused the fault rouded down to the nearest page.
faulting_address: core.VirtualAddress,

entry: *Entry = undefined,
entries_version: u32 = undefined,

/// The protection we want to enter the page in at.
///
/// This protection can be more restrictive than the protection of the entry.
enter_protection: kernel.mem.MapType.Protection = undefined,

wired: bool = false,

promote_to_anonymous_map: bool = false,

anonymous_map_lock_type: LockType = .read,
object_lock_type: LockType = .read,

const LockType = enum {
    read,
    write,
};

const FaultCheckError =
    AddressSpace.HandlePageFaultError ||
    error{
        /// Restart the fault check.
        Restart,
    };

/// Look up entry, check protection, handle needs-copy.
///
///  - Lookup the entry that containing the faulting address.
///  - Check the protection of the entry.
///  - Handle the `needs_copy` flag of the entry.
///  - Lookup anons (if AnonymousMap exists).
///
/// Called `uvm_faultcheck` in OpenBSD uvm.
pub fn faultCheck(
    fault_info: *FaultInfo,
    current_task: *kernel.Task,
    anonymous_page: *?*AnonymousPage,
    fault_type: kernel.mem.PageFaultDetails.FaultType,
) FaultCheckError!void {
    _ = fault_type;

    // lookup entry and lock `entries_lock` for reading
    if (!fault_info.faultLookup(current_task, .read)) {
        return error.NotMapped;
    }

    log.verbose("fault_lookup found entry with range {f} and protection {t}", .{
        fault_info.entry.range(),
        fault_info.entry.protection,
    });

    // check protection
    {
        errdefer fault_info.address_space.entries_lock.readUnlock(current_task);
        switch (fault_info.entry.protection) {
            .none => return error.Protection,
            .read => if (fault_info.access_type != .read) return error.Protection,
            .read_write => if (fault_info.access_type != .read and fault_info.access_type != .write) return error.Protection,
            .executable => if (fault_info.access_type != .execute) return error.Protection, // TODO: x86 allows read on executable memory
        }
    }

    // set the protection we want to enter the page in at
    fault_info.enter_protection = fault_info.entry.protection;
    if (fault_info.entry.wired_count != 0) {
        fault_info.wired = true;
        // wired needs full access
        switch (fault_info.enter_protection) {
            .none => unreachable, // `error.Protection` is returned earlier if protection is `.none`
            .read => fault_info.access_type = .read,
            .read_write => fault_info.access_type = .write,
            .executable => fault_info.access_type = .execute,
        }
        // wiring needs write lock
        fault_info.anonymous_map_lock_type = .write;
        fault_info.object_lock_type = .write;
    }

    // handle `needs_copy`
    if (fault_info.entry.needs_copy) {
        if (fault_info.access_type == .write or fault_info.entry.object_reference.object == null) {
            fault_info.address_space.entries_lock.readUnlock(current_task);

            log.verbose("clearing needs_copy by copying anonymous map", .{});

            try fault_info.anonymousMapCopy(current_task);

            return error.Restart;
        } else if (fault_info.enter_protection == .read_write and fault_info.access_type == .read) {
            // ensure the page is entered read only since `needs_copy` is still true
            fault_info.enter_protection = .read;
        }
    }

    log.verbose("page enter protection: {t}", .{fault_info.enter_protection});

    const anonymous_map_reference = fault_info.entry.anonymous_map_reference;
    const object_reference = fault_info.entry.object_reference;

    std.debug.assert(anonymous_map_reference.anonymous_map != null or object_reference.object != null);

    if (anonymous_map_reference.anonymous_map) |anonymous_map| {
        // we have an anonymous map so lock it and try to extract the page

        if (fault_info.access_type == .write) {
            // assume we are going to COW
            fault_info.anonymous_map_lock_type = .write;
        }
        switch (fault_info.anonymous_map_lock_type) {
            .read => anonymous_map.lock.readLock(current_task),
            .write => anonymous_map.lock.writeLock(current_task),
        }

        anonymous_page.* = anonymous_map_reference.lookup(
            fault_info.entry,
            fault_info.faulting_address,
        );

        if (anonymous_page.* == null) {
            log.verbose("anonymous page not found in anonymous map", .{});
        } else {
            log.verbose("anonymous page found in anonymous map", .{});
        }
    } else {
        log.verbose("anonymous page not found in anonymous map", .{});
        anonymous_page.* = null;
    }

    if (fault_info.access_type == .write) {
        // if we have an object we are going to dirty it so acquire a write lock
        fault_info.object_lock_type = .write;
    }
}

/// Handle a object or zero fill fault.
///
/// Called `uvm_fault_lower` in OpenBSD uvm.
pub fn faultObjectOrZeroFill(
    fault_info: *FaultInfo,
    current_task: *kernel.Task,
) error{ Restart, NoMemory }!void {
    log.verbose("handling object or zero fill fault", .{});

    const opt_anonymous_map = fault_info.entry.anonymous_map_reference.anonymous_map;
    const opt_object = fault_info.entry.object_reference.object;

    std.debug.assert(opt_anonymous_map == null or switch (fault_info.anonymous_map_lock_type) {
        .read => opt_anonymous_map.?.lock.isReadLocked(),
        .write => opt_anonymous_map.?.lock.isWriteLocked(),
    });

    const object_page: ObjectPage = if (opt_object) |object| blk: {
        const object_page: ObjectPage = if (true) {
            @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L1370
        } else .need_io;

        std.debug.assert(switch (fault_info.object_lock_type) {
            .read => object.lock.isReadLocked(),
            .write => object.lock.isWriteLocked(),
        });

        // we have a backing object are we going to promote to an anonymous page?
        fault_info.promote_to_anonymous_map = fault_info.access_type == .write and fault_info.entry.copy_on_write;

        break :blk object_page;
    } else blk: {
        // need an anonymous page for zero fill
        fault_info.promote_to_anonymous_map = true;
        break :blk .zero_fill;
    };

    log.verbose(
        "determined object page {t} with promote_to_anonymous_map {}",
        .{ object_page, fault_info.promote_to_anonymous_map },
    );

    switch (object_page) {
        .page => {
            @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L1414-L1416
        },
        .zero_fill => {},
        .need_io => {
            @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L1419-L1421
        },
    }

    std.debug.assert(object_page != .need_io);

    var anonymous_page: *AnonymousPage = undefined;
    var page: *Page = undefined;

    if (fault_info.promote_to_anonymous_map) {
        const anonymous_map = opt_anonymous_map.?;

        // promoting requires a write lock
        if (!fault_info.faultAnonymousMapLockUpgrade(current_task, anonymous_map)) {
            log.verbose("anonymous map lock upgrade failed", .{});

            // lock upgrade failed, `faultAnonymousMapLockUpgrade` left the anonymous_map lock unlocked
            // unlock everything else and restart the fault
            fault_info.unlockAll(
                current_task,
                null, // left unlocked by `faultAnonymousMapLockUpgrade`
                opt_object,
            );
            return error.Restart;
        }
        std.debug.assert(anonymous_map.lock.isWriteLocked());
        std.debug.assert(opt_object == null or switch (fault_info.object_lock_type) {
            .read => opt_object.?.lock.isReadLocked(),
            .write => opt_object.?.lock.isWriteLocked(),
        });

        try fault_info.promote(
            current_task,
            object_page,
            &anonymous_page,
            &page,
        );

        switch (object_page) {
            .zero_fill => {},
            .page => @panic("NOT IMPLEMENTED"), // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L1473
            .need_io => unreachable,
        }

        try fault_info.entry.anonymous_map_reference.add(
            fault_info.entry,
            fault_info.faulting_address,
            anonymous_page,
            .add,
        ); // TODO: on error maybe we need https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L1508-L1523
    } else {
        @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L1430
    }

    std.debug.assert(opt_anonymous_map == null or switch (fault_info.anonymous_map_lock_type) {
        .read => opt_anonymous_map.?.lock.isReadLocked(),
        .write => opt_anonymous_map.?.lock.isWriteLocked(),
    });
    std.debug.assert(opt_object == null or switch (fault_info.object_lock_type) {
        .read => opt_object.?.lock.isReadLocked(),
        .write => opt_object.?.lock.isWriteLocked(),
    });

    {
        const map_type: kernel.mem.MapType = .{
            .context = fault_info.address_space.context,
            .protection = switch (fault_info.enter_protection) {
                .none => unreachable, // `error.Protection` is returned by `faultCheck` if protection is `.none`
                .read => .read,
                .read_write => .read_write,
                .executable => .executable,
            },
        };

        log.verbose("mapping {f} with {f}", .{ fault_info.faulting_address, map_type });

        fault_info.address_space.page_table_lock.lock(current_task);
        defer fault_info.address_space.page_table_lock.unlock(current_task);

        // all resources are present time to actually map them in
        kernel.mem.mapSinglePage(
            fault_info.address_space.page_table,
            fault_info.faulting_address,
            page.physical_frame,
            map_type,
            kernel.mem.phys.allocator,
        ) catch {
            @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L1545-L1568
        };
    }

    if (fault_info.wired) {
        @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L1573-L1589
    }

    // TODO: might need https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L1571-L1604

    fault_info.unlockAll(current_task, opt_anonymous_map, opt_object);
}

/// Look up the entry that contains the faulting address.
///
/// If entry is found returns `true`, fills in `fault_info.entry` and `entries_lock` is left locked.
///
/// If `write_lock` is `true` the `entries_lock` is acquired in write mode.
///
/// Called `uvmfault_lookup` in OpenBSD uvm.
fn faultLookup(fault_info: *FaultInfo, current_task: *kernel.Task, lock_type: LockType) bool {
    switch (lock_type) {
        .read => fault_info.address_space.entries_lock.readLock(current_task),
        .write => fault_info.address_space.entries_lock.writeLock(current_task),
    }

    const entry_index = Entry.entryIndexByAddress(
        fault_info.faulting_address,
        fault_info.address_space.entries.items,
    ) orelse {
        switch (lock_type) {
            .read => fault_info.address_space.entries_lock.readUnlock(current_task),
            .write => fault_info.address_space.entries_lock.writeUnlock(current_task),
        }

        return false;
    };

    fault_info.entry = fault_info.address_space.entries.items[entry_index];

    return true;
}

/// Promote data to a new anonymous page.
///  - Allocate an anonymous page and a page.
///  - Fill its contents
///
/// If the promotion was successful `anonymous_page` and `page` are filled.
///
/// On error everything is unlocked.
///
/// Called `uvmfault_promote` in OpenBSD uvm.
fn promote(
    fault_info: *FaultInfo,
    current_task: *kernel.Task,
    object_page: ObjectPage,
    anonymous_page: **AnonymousPage,
    page: **Page,
) error{ Restart, NoMemory }!void {
    log.verbose("promoting to an anonymous page", .{});

    const anonymous_map = fault_info.entry.anonymous_map_reference.anonymous_map.?;
    std.debug.assert(anonymous_map.lock.isWriteLocked());

    const opt_object = switch (object_page) {
        .zero_fill => null,
        .page => fault_info.entry.object_reference.object,
        .need_io => unreachable,
    };
    std.debug.assert(opt_object == null or (opt_object.?.lock.isReadLocked() or opt_object.?.lock.isWriteLocked()));

    const allocated_frame = kernel.mem.phys.allocator.allocate() catch {
        @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L520
    };
    page.* = allocated_frame.page().?;

    anonymous_page.* = AnonymousPage.create(current_task, page.*) catch {
        @panic("NOT IMPLEMENTED"); // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L520
        // MUST clean up `page` as well
    };

    log.verbose(
        "allocated anonymous page for {f} at {f}",
        .{ fault_info.faulting_address, allocated_frame.baseAddress() },
    );

    switch (object_page) {
        .zero_fill => {
            log.verbose("zero filling anonymous page", .{});
            const mapped_frame = kernel.mem
                .directMapFromPhysical(allocated_frame.baseAddress())
                .toPtr(*[kernel.arch.paging.standard_page_size.value]u8);
            @memset(mapped_frame, 0);
        },
        .page => @panic("NOT IMPLEMENTED"), // TODO https://github.com/openbsd/src/blob/master/sys/uvm/uvm_fault.c#L545
        .need_io => unreachable,
    }
}

/// Clear the `needs_copy` flag.
///
/// Lock is unlocked on successful return.
///
/// The `entries_lock` must be unlocked.
///
/// Called `uvmfault_amapcopy` in OpenBSD uvm.
fn anonymousMapCopy(fault_info: *FaultInfo, current_task: *kernel.Task) error{ NotMapped, NoMemory }!void {
    // lookup entry and lock `entries_lock` for writing
    if (!fault_info.faultLookup(current_task, .write)) return error.NotMapped;
    defer fault_info.address_space.entries_lock.writeUnlock(current_task);

    if (!fault_info.entry.needs_copy) return; // someone else already copied the anonymous map

    try AnonymousMap.copy(
        current_task,
        fault_info.address_space,
        fault_info.entry,
        fault_info.faulting_address,
    );
}

/// Upgrade the anonymous map lock from read to write.
///
/// Returns `true` if the upgrade was successful.
///
/// Returns `false` if the upgrade failed, in this case the lock is left unlocked.
///
/// Called `uvm_fault_upper_upgrade` in OpenBSD uvm.
fn faultAnonymousMapLockUpgrade(
    fault_info: *FaultInfo,
    current_task: *kernel.Task,
    anonymous_map: *AnonymousMap,
) bool {
    std.debug.assert(switch (fault_info.anonymous_map_lock_type) {
        .read => anonymous_map.lock.isReadLocked(),
        .write => anonymous_map.lock.isWriteLocked(),
    });

    // fast path
    if (fault_info.anonymous_map_lock_type == .write) {
        return true;
    }

    // try for upgrade
    // if we don't succeed unlock everything and restart the fault and next time get a write lock
    fault_info.anonymous_map_lock_type = .write;
    if (!anonymous_map.lock.tryUpgradeLock(current_task)) {
        // `tryUpgradeLock` leaves the lock unlocked if it fails
        return false;
    }

    std.debug.assert(switch (fault_info.anonymous_map_lock_type) {
        .read => anonymous_map.lock.isReadLocked(),
        .write => anonymous_map.lock.isWriteLocked(),
    });

    return true;
}

/// Unlock everything passed in.
///
/// Called `uvmfault_unlockall` in OpenBSD uvm.
fn unlockAll(
    fault_info: *FaultInfo,
    current_task: *kernel.Task,
    opt_anonymous_map: ?*AnonymousMap,
    opt_object: ?*Object,
) void {
    if (opt_object) |object| {
        switch (fault_info.object_lock_type) {
            .read => object.lock.readUnlock(current_task),
            .write => object.lock.writeUnlock(current_task),
        }
    }

    if (opt_anonymous_map) |anonymous_map| {
        switch (fault_info.anonymous_map_lock_type) {
            .read => anonymous_map.lock.readUnlock(current_task),
            .write => anonymous_map.lock.writeUnlock(current_task),
        }
    }

    fault_info.address_space.entries_lock.readUnlock(current_task);
}

const ObjectPage = union(enum) {
    need_io,
    zero_fill,
    page: *Page,
};

const AddressSpace = @import("AddressSpace.zig");
const AnonymousMap = @import("AnonymousMap.zig");
const AnonymousPage = @import("AnonymousPage.zig");
const Entry = @import("Entry.zig");
const Page = kernel.mem.Page; // called a `vm_page` in uvm
const Object = @import("Object.zig");

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.address_space);
