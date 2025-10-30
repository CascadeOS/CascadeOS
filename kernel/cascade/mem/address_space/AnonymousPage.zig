// SPDX-License-Identifier: MIT and BSD-2-Clause
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
const cascade = @import("cascade");
const Task = cascade.Task;
const Cache = cascade.mem.cache.Cache;
const Page = cascade.mem.Page;
const core = @import("core");

const log = cascade.debug.log.scoped(.address_space);

const AnonymousPage = @This();

lock: cascade.sync.RwLock = .{},

reference_count: u32 = 1,

page: *Page,

pub fn create(current_task: *Task, page: *Page) !*AnonymousPage {
    const anonymous_page = try globals.anonymous_page_cache.allocate(current_task);
    anonymous_page.* = .{
        .page = page,
    };
    return anonymous_page;
}

/// Increment the reference count.
///
/// When called the lock must be held.
pub fn incrementReferenceCount(anonymous_page: *AnonymousPage, current_task: *Task) void {
    if (core.is_debug) {
        std.debug.assert(anonymous_page.reference_count != 0);
        std.debug.assert(anonymous_page.lock.isLockedByCurrent(current_task));
    }

    anonymous_page.reference_count += 1;
}

/// Decrement the reference count.
///
/// When called the lock must be held, upon return the lock is unlocked.
pub fn decrementReferenceCount(anonymous_page: *AnonymousPage, current_task: *Task) void {
    if (core.is_debug) {
        std.debug.assert(anonymous_page.reference_count != 0);
        std.debug.assert(anonymous_page.lock.isLockedByCurrent(current_task));
    }

    const reference_count = anonymous_page.reference_count;
    anonymous_page.reference_count = reference_count - 1;

    if (reference_count == 1) {
        // reference count is now zero, destroy the anonymous page

        if (true) @panic("NOT IMPLEMENTED"); // TODO

        anonymous_page.lock.unlock(current_task);

        globals.anonymous_page_cache.deallocate(current_task, anonymous_page);
    } else {
        anonymous_page.lock.unlock(current_task);
    }
}

const globals = struct {
    /// Initialized during `init.initializeCaches`.
    var anonymous_page_cache: Cache(AnonymousPage, null, null) = undefined;
};

pub const init = struct {
    pub fn initializeCaches(current_task: *Task) !void {
        globals.anonymous_page_cache.init(current_task, .{
            .name = try .fromSlice("anonymous page"),
        });
    }
};
