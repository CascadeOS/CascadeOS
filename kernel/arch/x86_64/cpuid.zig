// SPDX-License-Identifier: MIT

// The specification used is "Intel® 64 and IA-32 Architectures Software Developer's Manual Volume 2A March 2023"

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

const arch_info = x86_64.arch_info;

const log = kernel.debug.log.scoped(.cpuid);

pub fn capture() linksection(kernel.info.init_code) void {
    if (!isCPUIDAvailable()) core.panic("cpuid is not supported");

    const cpuid_leaf_0 = raw_cpuid(0x0, 0);
    const cpuid_leaf_extended = raw_cpuid(0x80000000, 0);

    const max_standard_leaf = cpuid_leaf_0.eax;
    log.debug("maximum standard function: 0x{x}", .{max_standard_leaf});

    const max_extended_leaf = cpuid_leaf_extended.eax;
    log.debug("largest extended function: 0x{x}", .{max_extended_leaf});

    const vendor_string_array = [_]u32{ cpuid_leaf_0.ebx, cpuid_leaf_0.edx, cpuid_leaf_0.ecx };
    std.mem.copyForwards(u8, &arch_info.cpu_vendor_string, std.mem.sliceAsBytes(&vendor_string_array));
    log.debug("cpu vendor string: {s}", .{arch_info.cpu_vendor_string});

    handleSimpleLeafs(max_standard_leaf, max_extended_leaf);
}

const simple_leaf_handlers: []const SimpleLeafHandler linksection(kernel.info.init_data) = &.{
    .{
        .leaf = .{ .type = .standard, .value = 0x01 },
        .handlers = &.{
            .{
                .name = "apic",
                .register = .edx,
                .mask_bit = 9,
                .target = &x86_64.arch_info.has_apic,
                .required = true,
            },
        },
    },
    .{
        .leaf = .{ .type = .extended, .value = 0x80000001 },
        .handlers = &.{
            .{
                .name = "syscall",
                .register = .edx,
                .mask_bit = 11,
                .target = &x86_64.arch_info.has_syscall,
            },
            .{
                .name = "execute disable",
                .register = .edx,
                .mask_bit = 20,
                .target = &x86_64.arch_info.has_execute_disable,
            },
            .{
                .name = "1 GiB large pages",
                .register = .edx,
                .mask_bit = 26,
                .target = &x86_64.arch_info.has_gib_pages,
            },
            .{
                .name = "rdtscp",
                .register = .edx,
                .mask_bit = 27,
                .required = true,
            },
            .{
                .name = "64-bit",
                .register = .edx,
                .mask_bit = 29,
                .required = true,
            },
        },
    },
};

/// Handles simple CPUID leaves.
///
/// Loops through the `simple_leaf_handlers` performing the declared actions for each handler.
fn handleSimpleLeafs(max_standard_leaf: u32, max_extended_leaf: u32) linksection(kernel.info.init_code) void {
    inline for (simple_leaf_handlers) |leaf_handler| blk: {
        if (leaf_handler.leaf.type == .standard and leaf_handler.leaf.value > max_standard_leaf) {
            // leaf is out of range of available standard functions
            break :blk; // continue loop
        }

        if (leaf_handler.leaf.type == .extended and leaf_handler.leaf.value > max_extended_leaf) {
            // leaf is out of range of available extended functions
            break :blk; // continue loop
        }

        const cpuid_result = raw_cpuid(leaf_handler.leaf.value, 0);

        inline for (leaf_handler.handlers) |handler| {
            const register = switch (handler.register) {
                .eax => cpuid_result.eax,
                .ebx => cpuid_result.ebx,
                .ecx => cpuid_result.ecx,
                .edx => cpuid_result.edx,
            };

            const feature_present = register & (1 << handler.mask_bit) != 0;
            if (handler.required and !feature_present) core.panic("required feature " ++ comptime handler.name ++ " is not supported");
            if (handler.target) |target| target.* = feature_present;
            log.debug(comptime handler.name ++ ": {}", .{feature_present});
        }
    }
}

/// A handler for a simple CPUID leaf.
const SimpleLeafHandler = struct {
    leaf: LeafSelector,
    handlers: []const ValueHandler,

    /// Selects a CPUID leaf.
    pub const LeafSelector = struct {
        /// Specifies whether this is a standard or extended CPUID leaf.
        type: LeafType,
        value: u32,

        pub const LeafType = enum {
            standard,
            extended,
        };
    };

    /// A handler for a bit in a CPUID leaf register.
    pub const ValueHandler = struct {
        /// Name of the feature this handler represents.
        name: []const u8,

        /// The register this handler will read from.
        register: Register,

        /// The bit position in the register this handler will check.
        mask_bit: u5,

        /// Optional pointer to a bool that will be set based on the value of the bit.
        target: ?*bool = null,

        /// Is this feature required by Cascade
        required: bool = false,

        pub const Register = enum {
            eax,
            ebx,
            ecx,
            edx,
        };
    };
};

fn isCPUIDAvailable() linksection(kernel.info.init_code) bool {
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
