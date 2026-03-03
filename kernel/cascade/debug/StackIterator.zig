// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A copy of 0.15.2 `std.debug.StackIterator` with ucontext stuff removed.
//!
//! This is to simplify moving to 0.16.

const std = @import("std");
const builtin = @import("builtin");
const native_arch = builtin.cpu.arch;

const StackIterator = @This();

// Skip every frame before this address is found.
first_address: ?usize,
// Last known value of the frame pointer register.
fp: usize,

pub fn init(first_address: ?usize, fp: ?usize) StackIterator {
    return .{
        .first_address = first_address,
        // TODO: this is a workaround for #16876
        //.fp = fp orelse @frameAddress(),
        .fp = fp orelse blk: {
            const fa = @frameAddress();
            break :blk fa;
        },
    };
}

pub fn next(it: *StackIterator) ?usize {
    var address = it.next_internal() orelse return null;

    if (it.first_address) |first_address| {
        while (address != first_address) {
            address = it.next_internal() orelse return null;
        }
        it.first_address = null;
    }

    return address;
}

pub fn next_internal(it: *StackIterator) ?usize {
    const fp = std.math.sub(usize, it.fp, fp_offset) catch return null;
    if (fp == 0 or !std.mem.isAligned(fp, @alignOf(usize))) return null;

    const fp_ptr: *usize = @ptrFromInt(fp);
    const new_fp = fp_ptr.*;
    if (new_fp != 0 and new_fp < it.fp) return null;

    const new_pc_ptr: *usize = @ptrFromInt(std.math.add(usize, fp, pc_offset) catch return null);
    const new_pc = new_pc_ptr.*;

    it.fp = new_fp;

    return new_pc;
}

// Offset of the saved BP wrt the frame pointer.
const fp_offset = if (native_arch.isRISCV())
    // On RISC-V the frame pointer points to the top of the saved register
    // area, on pretty much every other architecture it points to the stack
    // slot where the previous frame pointer is saved.
    2 * @sizeOf(usize)
else
    0;

// Positive offset of the saved PC wrt the frame pointer.
const pc_offset = @sizeOf(usize);
