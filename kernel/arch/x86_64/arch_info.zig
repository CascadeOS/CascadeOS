// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

/// Vendor string from CPUID.00h
pub var cpu_vendor_string: [12]u8 = [_]u8{0} ** 12;

/// Brand string from CPUID.80000002h - CPUID.80000004h
pub var processor_brand_string: [48]u8 = [_]u8{0} ** 48;

/// Do we have a PIC?
pub var have_pic: bool = true;

// CPUID.01h:ECX

pub var monitor: bool = false;

pub var tsc_deadline: bool = false;

pub var xsave: bool = false;

pub var rdrand: bool = false;

// CPUID.07h.00h:EBX

/// supervisor mode execution prevention
pub var smep: bool = false;

pub var rdseed: bool = false;

/// supervisor mode access prevention
pub var smap: bool = false;

// CPUID.07h.00h:ECX

/// user mode instruction prevention
pub var umip: bool = false;

// CPUID.0Dh.01h:EAX

pub var xsaveopt: bool = false;

pub var xsavec: bool = false;

pub var xsaves: bool = false;

// CPUID.80000001h:EDX

pub var syscall: bool = false;

pub var execute_disable: bool = false;

pub var gib_pages: bool = false;

pub var rdtscp: bool = false;

// CPUID.80000007h:EDX

pub var invariant_tsc: bool = false;

// CPUID.80000008h:EBX

pub var invlpgb: bool = false;
