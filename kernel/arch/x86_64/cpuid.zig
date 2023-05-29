// SPDX-License-Identifier: MIT

// The specification used is "Intel® 64 and IA-32 Architectures Software Developer's Manual Volume 2A March 2023"
// TODO: implement any stuff in the AMD manual that is not in the Intel manual as well

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

    handleSimpleLeafs(largest_standard_function, largest_extended_function);
}

const simple_leaf_handlers: []const SimpleLeafHandler = &.{
    .{
        .leaf = .{ .type = .extended, .value = 0x80000001 },
        .handlers = &.{
            .{ .name = "syscall", .register = .edx, .mask_bit = 11, .target = &x86_64.info.syscall },
            .{ .name = "execute disable", .register = .edx, .mask_bit = 20, .target = &x86_64.info.execute_disable },
            .{ .name = "1 gib pages", .register = .edx, .mask_bit = 26, .target = &x86_64.info.gib_pages },
            .{ .name = "rdtscp", .register = .edx, .mask_bit = 27 },
            .{ .name = "64-bit", .register = .edx, .mask_bit = 29 },
        },
    },
};

fn handleSimpleLeafs(largest_standard_function: u32, largest_extended_function: u32) void {
    inline for (simple_leaf_handlers) |leaf_handler| {
        if ((leaf_handler.leaf.type == .standard and leaf_handler.leaf.value <= largest_standard_function) or
            (leaf_handler.leaf.type == .extended and leaf_handler.leaf.value <= largest_extended_function))
        {
            const leaf = raw_cpuid(leaf_handler.leaf.value, 0);

            inline for (leaf_handler.handlers) |handler| {
                const register = switch (handler.register) {
                    .eax => leaf.eax,
                    .ebx => leaf.ebx,
                    .ecx => leaf.ecx,
                    .edx => leaf.edx,
                };

                const result = register & (1 << handler.mask_bit) != 0;
                if (handler.target) |target| target.* = result;
                log.debug(comptime handler.name ++ ": {}", .{result});
            }
        }
    }
}

const SimpleLeafHandler = struct {
    leaf: LeafSelector,
    handlers: []const ValueHandler,

    pub const LeafSelector = struct {
        type: LeafType,
        value: u32,

        pub const LeafType = enum {
            standard,
            extended,
        };
    };

    pub const ValueHandler = struct {
        name: []const u8,
        register: Register,
        mask_bit: u5,
        target: ?*bool = null,

        pub const Register = enum {
            eax,
            ebx,
            ecx,
            edx,
        };
    };
};

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
