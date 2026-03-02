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

fn next_internal(it: *StackIterator) ?usize {
    const fp = if (comptime native_arch.isSPARC())
        // On SPARC the offset is positive. (!)
        std.math.add(usize, it.fp, fp_offset) catch return null
    else
        std.math.sub(usize, it.fp, fp_offset) catch return null;

    // Sanity check.
    if (fp == 0 or !std.mem.isAligned(fp, @alignOf(usize))) return null;
    const new_fp = std.math.add(usize, fp, fp_bias) catch return null;

    // Sanity check: the stack grows down thus all the parent frames must be
    // be at addresses that are greater (or equal) than the previous one.
    // A zero frame pointer often signals this is the last frame, that case
    // is gracefully handled by the next call to next_internal.
    if (new_fp != 0 and new_fp < it.fp) return null;
    const new_pc = std.math.add(usize, fp, pc_offset) catch return null;

    it.fp = new_fp;

    return new_pc;
}

// Offset of the saved BP wrt the frame pointer.
const fp_offset = if (native_arch.isRISCV())
    // On RISC-V the frame pointer points to the top of the saved register
    // area, on pretty much every other architecture it points to the stack
    // slot where the previous frame pointer is saved.
    2 * @sizeOf(usize)
else if (native_arch.isSPARC())
    // On SPARC the previous frame pointer is stored at 14 slots past %fp+BIAS.
    14 * @sizeOf(usize)
else
    0;

const fp_bias = if (native_arch.isSPARC())
    // On SPARC frame pointers are biased by a constant.
    2047
else
    0;

// Positive offset of the saved PC wrt the frame pointer.
const pc_offset = if (native_arch == .powerpc64le)
    2 * @sizeOf(usize)
else
    @sizeOf(usize);
