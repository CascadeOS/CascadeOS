// SPDX-License-Identifier: MIT

// The specification used is "Intel® 64 and IA-32 Architectures Software Developer's Manual Volume 2A April 2022"

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("x86_64.zig");

const log = kernel.log.scoped(.cpuid);

pub fn capture() void {
    if (!isCPUIDAvailable()) core.panic("cpuid is not supported");

    const leaf_0 = raw_cpuid(0x0, 0);
    const leaf_extended = raw_cpuid(0x80000000, 0);

    const largest_standard_function = leaf_0.eax;
    log.debug("largest standard function: 0x{x}", .{largest_standard_function});

    const largest_extended_function = leaf_extended.eax;
    log.debug("largest extended function: 0x{x}", .{largest_extended_function});

    if (largest_extended_function >= 0x80000001) {
        handle0x80000001(raw_cpuid(0x80000001, 0));
    }
}

fn handle0x80000001(leaf: Leaf) void {
    const edx = leaf.edx;

    x86_64.info.syscall = (edx & (1 << 11)) != 0;
    log.debug("syscall: {}", .{x86_64.info.syscall});

    x86_64.info.execute_disable = (edx & (1 << 20)) != 0;
    log.debug("execute disable: {}", .{x86_64.info.execute_disable});

    x86_64.info.gib_pages = (edx & (1 << 26)) != 0;
    log.debug("gib pages: {}", .{x86_64.info.gib_pages});
}

fn isCPUIDAvailable() bool {
    const orig_rflags = x86_64.registers.RFlags.read();
    var modified_rflags = orig_rflags;

    modified_rflags.id = !modified_rflags.id;
    modified_rflags.write();

    const new_rflags = x86_64.registers.RFlags.read();

    return orig_rflags.id != new_rflags.id;
}

const Leaf = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

fn raw_cpuid(leaf_id: u32, subid: u32) Leaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf_id),
          [_] "{ecx}" (subid),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}
