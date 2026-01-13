// SPDX-License-Identifier: LicenseRef-NON-AI-MIT and BSD-2-Clause
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: Copyright (c) 1997 Charles D. Cranor and Washington University.

//! A page of anonymous memory.
//!
//! Called a `vm_anon` in uvm.
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
const kernel = @import("kernel");
const Task = kernel.Task;
const Cache = kernel.mem.cache.Cache;
const PhysicalPage = kernel.mem.PhysicalPage;
const core = @import("core");

const log = kernel.debug.log.scoped(.address_space);

const AnonymousPage = @This();

lock: kernel.sync.RwLock = .{},

reference_count: u32 = 1,

physical_page: PhysicalPage.Index,

pub fn create(physical_page: PhysicalPage.Index) !*AnonymousPage {
    const anonymous_page = try globals.anonymous_page_cache.allocate();
    anonymous_page.* = .{
        .physical_page = physical_page,
    };
    return anonymous_page;
}

/// Increment the reference count.
///
/// When called the lock must be held.
pub fn incrementReferenceCount(anonymous_page: *AnonymousPage) void {
    if (core.is_debug) {
        std.debug.assert(anonymous_page.reference_count != 0);
        std.debug.assert(anonymous_page.lock.isLockedByCurrent());
    }

    anonymous_page.reference_count += 1;
}

/// Decrement the reference count.
///
/// When called the a write lock must be held, upon return the lock is unlocked.
pub fn decrementReferenceCount(
    anonymous_page: *AnonymousPage,
    deallocate_page_list: *kernel.mem.PhysicalPage.List,
) void {
    if (core.is_debug) {
        std.debug.assert(anonymous_page.reference_count != 0);
        std.debug.assert(anonymous_page.lock.isWriteLocked());
    }

    const reference_count = anonymous_page.reference_count;
    anonymous_page.reference_count = reference_count - 1;

    if (reference_count == 1) {
        // reference count is now zero, destroy the anonymous page
        anonymous_page.destroy(deallocate_page_list);
        return;
    }

    anonymous_page.lock.writeUnlock();
}

/// Destroy the anonymous page.
///
/// Only called by `decrementReferenceCount` when the reference count is zero.
///
/// Called `uvm_anfree` in OpenBSD uvm.
fn destroy(
    anonymous_page: *AnonymousPage,
    deallocate_page_list: *kernel.mem.PhysicalPage.List,
) void {
    if (core.is_debug) {
        std.debug.assert(anonymous_page.lock.isWriteLocked());
        std.debug.assert(anonymous_page.reference_count == 0);
    }

    deallocate_page_list.prepend(anonymous_page.physical_page);

    anonymous_page.lock.writeUnlock();
    globals.anonymous_page_cache.deallocate(anonymous_page);
}

const globals = struct {
    /// Initialized during `init.initializeCaches`.
    var anonymous_page_cache: Cache(AnonymousPage, null, null) = undefined;
};

pub const init = struct {
    const init_log = kernel.debug.log.scoped(.anonymous_page_init);

    pub fn initializeCaches() !void {
        log.debug("initializing anonymous page cache", .{});

        globals.anonymous_page_cache.init(.{
            .name = try .fromSlice("anonymous page"),
        });
    }
};
