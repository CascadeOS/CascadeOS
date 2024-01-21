// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

// The specification used is "Intel® 64 and IA-32 Architectures Software Developer's Manual Volume 2A March 2023"

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

const arch_info = x86_64.arch_info;

const log = kernel.debug.log.scoped(.cpuid);

pub fn capture() linksection(kernel.info.init_code) void {
    if (!isCPUIDAvailable()) core.panic("cpuid is not supported");

    const cpuid_leaf_0 = rawCpuid(0x0, 0);

    const max_standard_leaf = cpuid_leaf_0.eax;
    log.debug("maximum standard function: 0x{x}", .{max_standard_leaf});

    const cpuid_leaf_extended = rawCpuid(0x80000000, 0);

    const max_extended_leaf = cpuid_leaf_extended.eax;
    log.debug("largest extended function: 0x{x}", .{max_extended_leaf});

    captureVendorString(cpuid_leaf_0);

    captureBrandString(max_extended_leaf);

    handleSimpleLeafs(max_standard_leaf, max_extended_leaf);

    var max_hypervisor_leaf: u32 = 0;

    if (arch_info.hypervisor_present) {
        const hypervisor_info = HypervisorInformation.read();
        max_hypervisor_leaf = hypervisor_info.max_hypervisor_leaf;
        log.debug("maximum hypervisor function: 0x{x}", .{max_hypervisor_leaf});

        kernel.info.hypervisor = determineHypervisor(hypervisor_info);
        log.debug("hypervisor: {s}", .{@tagName(kernel.info.hypervisor.?)});
    }

    determineTscTickDuration(max_standard_leaf, max_hypervisor_leaf);
}

fn isCPUIDAvailable() linksection(kernel.info.init_code) bool {
    const orig_rflags = x86_64.registers.RFlags.read();
    var modified_rflags = orig_rflags;

    modified_rflags.id = !modified_rflags.id;
    modified_rflags.write();

    const new_rflags = x86_64.registers.RFlags.read();

    return orig_rflags.id != new_rflags.id;
}

fn determineHypervisor(hypervisor_info: HypervisorInformation) linksection(kernel.info.init_code) kernel.info.Hypervisor {
    const hypervisor_vendor_id: [12]u8 = blk: {
        var hypervisor_vendor_id = [_]u8{0} ** 12;
        std.mem.copyForwards(u8, hypervisor_vendor_id[0..][0..4], std.mem.asBytes(&hypervisor_info.hypervisor_vendor_id_1));
        std.mem.copyForwards(u8, hypervisor_vendor_id[4..][0..4], std.mem.asBytes(&hypervisor_info.hypervisor_vendor_id_2));
        std.mem.copyForwards(u8, hypervisor_vendor_id[8..][0..4], std.mem.asBytes(&hypervisor_info.hypervisor_vendor_id_3));
        break :blk hypervisor_vendor_id;
    };
    log.debug("hypervisor vendor id: {s}", .{hypervisor_vendor_id});

    if (std.mem.startsWith(u8, &hypervisor_vendor_id, "KVMKVMKVM")) return .kvm;

    if (std.mem.startsWith(u8, &hypervisor_vendor_id, "TCGTCGTCGTCG")) return .tcg;

    if (std.mem.startsWith(u8, &hypervisor_vendor_id, "VMwareVMware")) return .vmware;

    if (std.mem.startsWith(u8, &hypervisor_vendor_id, "Microsoft Hv")) return .hyperv;

    log.warn("unable to determine hypervisor from vendor id: {s}", .{hypervisor_vendor_id});
    return .unknown;
}

/// Captures the vendor string from CPUID.00h
fn captureVendorString(cpuid_leaf_0: Leaf) linksection(kernel.info.init_code) void {
    const vendor_string_array = [_]u32{ cpuid_leaf_0.ebx, cpuid_leaf_0.edx, cpuid_leaf_0.ecx };
    std.mem.copyForwards(u8, &arch_info.cpu_vendor_string, std.mem.sliceAsBytes(&vendor_string_array));
    log.debug("cpu vendor string: {s}", .{arch_info.cpu_vendor_string});
}

/// Captures the brand string from CPUID.80000002h - CPUID.80000004h
fn captureBrandString(max_extended_leaf: u32) linksection(kernel.info.init_code) void {
    if (max_extended_leaf < 0x80000004) {
        log.debug("processor brand string is not available", .{});
        return;
    }

    var brand_string_array: [12]u32 = [_]u32{0} ** 12;
    var i: usize = 0;

    for (0x80000002..0x80000004) |leaf| {
        const leaf_value = rawCpuid(@truncate(leaf), 0);

        brand_string_array[i] = leaf_value.eax;
        i += 1;
        brand_string_array[i] = leaf_value.ebx;
        i += 1;
        brand_string_array[i] = leaf_value.ecx;
        i += 1;
        brand_string_array[i] = leaf_value.edx;
        i += 1;
    }

    std.mem.copyForwards(u8, &arch_info.processor_brand_string, std.mem.sliceAsBytes(&brand_string_array));
    log.debug("processor brand string: {s}", .{arch_info.processor_brand_string});
}

/// Attempts to determine the TSC tick duration from CPUID information.
fn determineTscTickDuration(max_standard_leaf: u32, max_hypervisor_leaf: u32) void {
    const frequency: u64 = blk: {
        if (determineTscTickFrequencyLeaf15And16(max_standard_leaf)) |frequency| {
            log.debug("tsc frequency determined from leaf 0x15 and 0x16", .{});
            break :blk frequency;
        }

        if (determineTscTickFrequencyLeaf40000010(max_hypervisor_leaf)) |frequency| {
            log.debug("tsc frequency determined from leaf 0x40000010", .{});
            break :blk frequency;
        }

        // TODO: VMWare, Hyper-V, KVM, Xen, etc.

        log.debug("unable to determine tsc frequency from cpuid", .{});
        return;
    };

    arch_info.tsc_tick_duration_fs = kernel.time.fs_per_s / frequency;
    log.debug("tsc tick duration (fs): {}", .{arch_info.tsc_tick_duration_fs.?});
}

fn determineTscTickFrequencyLeaf15And16(max_standard_leaf: u32) ?u64 {
    // TODO: Is this Intel only?

    if (max_standard_leaf < 0x15) return null;

    const tsc_and_core_crystal_info = TscAndCrystalClockInformation.read();

    if (tsc_and_core_crystal_info.numerator == 0 or tsc_and_core_crystal_info.denominator == 0) {
        return null;
    }

    var crystal_hz = tsc_and_core_crystal_info.crystal_frequency;

    // TODO: if `crystal_hz` == 0 and model is Denverton SoCs (linux INTEL_FAM6_ATOM_GOLDMONT_D) then crystal is 25MHz

    if (crystal_hz == 0 and max_standard_leaf >= 0x16) {
        // use the crystal ratio and the CPU speed to determine the crystal frequency
        const processor_frequency_info = ProcessorFrequencyInformation.read();

        crystal_hz =
            (processor_frequency_info.processor_base_frequency * hz_per_mhz * tsc_and_core_crystal_info.denominator) /
            tsc_and_core_crystal_info.numerator;
    }

    if (crystal_hz == 0) return null;

    arch_info.lapic_tick_duration_fs = kernel.time.fs_per_s / crystal_hz;
    log.debug("lapic tick duration (fs): {}", .{arch_info.lapic_tick_duration_fs.?});

    return (crystal_hz * tsc_and_core_crystal_info.numerator) / tsc_and_core_crystal_info.denominator;
}

fn determineTscTickFrequencyLeaf40000010(max_hypervisor_leaf: u32) ?u64 {
    if (max_hypervisor_leaf < 0x40000010) return null;

    const hypervisor_timing_info = HypervisorTimingInformation.read();

    return hypervisor_timing_info.tsc_frequency * hz_per_khz;
}

const hz_per_mhz = 1000000;
const hz_per_khz = 1000;

const TscAndCrystalClockInformation = struct {
    /// The denominator of the TSC/"core crystal clock" ratio.
    denominator: u64,

    /// The numerator of the TSC/"core crystal clock" ratio.
    numerator: u64,

    /// The nominal frequency of the core crystal clock in Hz.
    crystal_frequency: u64,

    pub fn read() TscAndCrystalClockInformation {
        const tsc_and_crystal_clock_info = rawCpuid(0x15, 0);
        return .{
            .denominator = tsc_and_crystal_clock_info.eax,
            .numerator = tsc_and_crystal_clock_info.ebx,
            .crystal_frequency = tsc_and_crystal_clock_info.ecx,
        };
    }
};

const ProcessorFrequencyInformation = struct {
    /// The processor base frequency in MHz.
    processor_base_frequency: u64,

    /// The processor maximum frequency in MHz.
    processor_max_frequency: u64,

    /// The bus (reference) frequency in MHz.
    bus_frequency: u64,

    pub fn read() ProcessorFrequencyInformation {
        const processor_frequency_info = rawCpuid(0x16, 0);
        return .{
            .processor_base_frequency = processor_frequency_info.eax,
            .processor_max_frequency = processor_frequency_info.ebx,
            .bus_frequency = processor_frequency_info.ecx,
        };
    }
};

const HypervisorInformation = struct {
    max_hypervisor_leaf: u32,

    hypervisor_vendor_id_1: u32,

    hypervisor_vendor_id_2: u32,

    hypervisor_vendor_id_3: u32,

    pub fn read() HypervisorInformation {
        const hypervisor_info = rawCpuid(0x40000000, 0);
        return .{
            .max_hypervisor_leaf = hypervisor_info.eax,
            .hypervisor_vendor_id_1 = hypervisor_info.ebx,
            .hypervisor_vendor_id_2 = hypervisor_info.ecx,
            .hypervisor_vendor_id_3 = hypervisor_info.edx,
        };
    }
};

const HypervisorTimingInformation = struct {
    /// TSC frequency in KHz.
    tsc_frequency: u64,

    /// Bus (local apic timer) frequency in KHz.
    bus_frequency: u64,

    pub fn read() HypervisorTimingInformation {
        const hypervisor_timing_info = rawCpuid(0x40000010, 0);
        return .{
            .tsc_frequency = hypervisor_timing_info.eax,
            .bus_frequency = hypervisor_timing_info.ebx,
        };
    }
};

const simple_leaf_handlers: []const SimpleLeafHandler linksection(kernel.info.init_data) = &.{
    .{
        .leaf = .{ .type = .standard, .leaf = 0x01 },
        .handlers = &.{
            .{
                .name = "monitor/mwait",
                .register = .ecx,
                .mask_bit = 3,
                .target = &x86_64.arch_info.monitor,
            },
            .{
                .name = "tsc deadline",
                .register = .ecx,
                .mask_bit = 24,
                .target = &x86_64.arch_info.tsc_deadline,
            },
            .{
                .name = "xsave",
                .register = .ecx,
                .mask_bit = 26,
                .target = &x86_64.arch_info.xsave,
            },
            .{
                .name = "rdrand",
                .register = .ecx,
                .mask_bit = 30,
                .target = &x86_64.arch_info.rdrand,
            },
            .{
                .name = "hypervisor present",
                .register = .ecx,
                .mask_bit = 31,
                .target = &x86_64.arch_info.hypervisor_present,
            },
            .{
                .name = "tsc",
                .register = .edx,
                .mask_bit = 4,
                .required = true,
            },
            .{
                .name = "msr",
                .register = .edx,
                .mask_bit = 5,
                .required = true,
            },
            .{
                .name = "physical address extension",
                .register = .edx,
                .mask_bit = 6,
                .required = true,
            },
            .{
                .name = "apic",
                .register = .edx,
                .mask_bit = 9,
                .required = true,
            },
            .{
                .name = "page global bit",
                .register = .edx,
                .mask_bit = 13,
                .required = true,
            },
        },
    },
    .{
        .leaf = .{ .type = .standard, .leaf = 0x06 },
        .handlers = &.{
            .{
                .name = "arat",
                .register = .eax,
                .mask_bit = 2,
                .required = true,
            },
        },
    },
    .{
        .leaf = .{ .type = .standard, .leaf = 0x07, .subleaf = 0 },
        .handlers = &.{
            .{
                .name = "supervisor mode execution prevention",
                .register = .ebx,
                .mask_bit = 7,
                .target = &x86_64.arch_info.smep,
            },
            .{
                .name = "rdseed",
                .register = .ebx,
                .mask_bit = 18,
                .target = &x86_64.arch_info.rdseed,
            },
            .{
                .name = "supervisor mode access prevention",
                .register = .ebx,
                .mask_bit = 20,
                .target = &x86_64.arch_info.smap,
            },
            .{
                .name = "user mode instruction prevention",
                .register = .ecx,
                .mask_bit = 2,
                .target = &x86_64.arch_info.umip,
            },
        },
    },
    .{
        .leaf = .{ .type = .standard, .leaf = 0x0D, .subleaf = 1 },
        .handlers = &.{
            .{
                .name = "xsaveopt",
                .register = .eax,
                .mask_bit = 0,
                .target = &x86_64.arch_info.xsaveopt,
            },
            .{
                .name = "xsavec",
                .register = .eax,
                .mask_bit = 1,
                .target = &x86_64.arch_info.xsavec,
            },
            .{
                .name = "xsaves/xrstors",
                .register = .eax,
                .mask_bit = 3,
                .target = &x86_64.arch_info.xsaves,
            },
        },
    },
    .{
        .leaf = .{ .type = .extended, .leaf = 0x80000001 },
        .handlers = &.{
            .{
                .name = "syscall",
                .register = .edx,
                .mask_bit = 11,
                .target = &x86_64.arch_info.syscall,
            },
            .{
                .name = "execute disable",
                .register = .edx,
                .mask_bit = 20,
                .target = &x86_64.arch_info.execute_disable,
            },
            .{
                .name = "1 GiB large pages",
                .register = .edx,
                .mask_bit = 26,
                .target = &x86_64.arch_info.gib_pages,
            },
            .{
                .name = "rdtscp",
                .register = .edx,
                .mask_bit = 27,
                .target = &x86_64.arch_info.rdtscp,
            },
            .{
                .name = "64-bit",
                .register = .edx,
                .mask_bit = 29,
                .required = true,
            },
        },
    },
    .{
        .leaf = .{ .type = .extended, .leaf = 0x80000007 },
        .handlers = &.{
            .{
                .name = "invariant tsc",
                .register = .edx,
                .mask_bit = 8,
                .target = &x86_64.arch_info.invariant_tsc,
            },
        },
    },
    .{
        .leaf = .{ .type = .extended, .leaf = 0x80000008 },
        .handlers = &.{
            .{
                .name = "invlpgb",
                .register = .ebx,
                .mask_bit = 3,
                .target = &x86_64.arch_info.invlpgb,
            },
        },
    },
};

/// Handles simple CPUID leaves.
///
/// Loops through the `simple_leaf_handlers` performing the declared actions for each handler.
fn handleSimpleLeafs(max_standard_leaf: u32, max_extended_leaf: u32) linksection(kernel.info.init_code) void {
    inline for (simple_leaf_handlers) |leaf_handler| blk: {
        if (leaf_handler.leaf.type == .standard and leaf_handler.leaf.leaf > max_standard_leaf) {
            // leaf is out of range of available standard functions
            break :blk; // continue loop
        }

        if (leaf_handler.leaf.type == .extended and leaf_handler.leaf.leaf > max_extended_leaf) {
            // leaf is out of range of available extended functions
            break :blk; // continue loop
        }

        const cpuid_result = rawCpuid(leaf_handler.leaf.leaf, leaf_handler.leaf.subleaf);

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
        leaf: u32,
        subleaf: u32 = 0,

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

const Leaf = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

fn rawCpuid(leaf_id: u32, subid: u32) Leaf {
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
