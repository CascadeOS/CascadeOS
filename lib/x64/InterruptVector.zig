// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const InterruptVector = enum(u8) {
    divide = 0,
    debug = 1,
    non_maskable_interrupt = 2,
    breakpoint = 3,
    overflow = 4,
    bound_range = 5,
    invalid_opcode = 6,
    device_not_available = 7,
    double_fault = 8,
    coprocessor_segment_overrun = 9,
    invalid_tss = 10,
    segment_not_present = 11,
    stack_fault = 12,
    general_protection = 13,
    page_fault = 14,
    _reserved1 = 15,
    x87_floating_point = 16,
    alignment_check = 17,
    machine_check = 18,
    simd_floating_point = 19,
    virtualization = 20,
    control_protection = 21,
    _reserved2 = 22,
    _reserved3 = 23,
    _reserved4 = 24,
    _reserved5 = 25,
    _reserved6 = 26,
    _reserved7 = 27,
    hypervisor_injection = 28,
    vmm_communication = 29,
    security = 30,
    _reserved8 = 31,

    _,

    /// Checks if the given interrupt vector pushes an error code.
    pub fn hasErrorCode(vector: InterruptVector) bool {
        return switch (@intFromEnum(vector)) {
            // Exceptions
            0x00...0x07 => false,
            0x08 => true,
            0x09 => false,
            0x0A...0x0E => true,
            0x0F...0x10 => false,
            0x11 => true,
            0x12...0x14 => false,
            //0x15 ... 0x1D => unreachable,
            0x1E => true,
            //0x1F          => unreachable,

            // Other interrupts
            else => false,
        };
    }

    /// Checks if the given interrupt vector is an exception.
    pub fn isException(vector: InterruptVector) bool {
        if (@intFromEnum(vector) <= @intFromEnum(InterruptVector._reserved8)) {
            return vector != InterruptVector.non_maskable_interrupt;
        }
        return false;
    }
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
