// SPDX-License-Identifier: MIT

//! This module contains the definitions of the Limine protocol version v5.20231103.0 as per
//! [PROTOCOL](https://github.com/limine-bootloader/limine/blob/v5.20231103.0/PROTOCOL.md)
//!
//! Unimplemented features:
//!   - Terminal Feature: deprecated and not used by Cascade
//!   - 5-Level Paging Feature: deprecated in favour of Paging Mode Feature
//!

const std = @import("std");
const core = @import("core");

const LIMINE_COMMON_MAGIC = [_]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

const Arch = enum {
    aarch64,
    riscv64,
    x86_64,
};

const arch: Arch = switch (@import("builtin").cpu.arch) {
    .aarch64 => .aarch64,
    .riscv64 => .riscv64,
    .x86_64 => .x86_64,
    else => |e| @compileError("unsupported architecture " ++ @tagName(e)),
};

/// Base protocol revisions change certain behaviours of the Limine boot protocol
/// outside any specific feature. The specifics are going to be described as
/// needed throughout this specification.
pub const BaseRevison = extern struct {
    id: [2]u64 = [_]u64{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc },

    /// The Limine boot protocol comes in several base revisions; so far only 2
    /// base revisions are specified: 0 and 1.
    ///
    /// Base protocol revisions change certain behaviours of the Limine boot protocol
    /// outside any specific feature. The specifics are going to be described as
    /// needed throughout this specification.
    ///
    /// Base revision 0 is considered deprecated, and it is the default base revision
    /// a kernel is assumed to be requesting and complying to if no base revision tag
    /// is provided by the kernel, for backwards compatibility.
    ///
    /// A base revision tag is a set of 3 64-bit values placed somewhere in the kernel
    /// binary on an 8-byte aligned boundary; the first 2 values are a magic number
    /// for the bootloader to be able to identify the tag, and the last value is the
    /// requested base revision number. Lack of base revision tag implies revision 0.
    ///
    /// If a bootloader drops support for an older base revision, the bootloader must
    /// fail to boot a kernel requesting such base revision. If a bootloader does not yet
    /// support a requested base revision (i.e. if the requested base revision is higher
    /// than the maximum base revision supported), it must boot the kernel using any
    /// arbitrary revision it supports, and communicate failure to comply to the kernel by
    /// *leaving the 3rd component of the base revision tag unchanged*.
    /// On the other hand, if the kernel's requested base revision is supported,
    /// *the 3rd component of the base revision tag must be set to 0 by the bootloader*.
    ///
    /// Note: this means that unlike when the bootloader drops support for an older base
    /// revision and *it* is responsible for failing to boot the kernel, in case the
    /// bootloader does not yet support the kernel's requested base revision,
    /// it is up to the kernel itself to fail (or handle the condition otherwise).
    revison: u64,
};

/// Bootloader Info Feature
pub const BootloaderInfo = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0xf55038d8e2a1202f, 0x279426fcf5f59740 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        _name: [*:0]const u8,
        _version: [*:0]const u8,

        pub fn name(self: *const Response) [:0]const u8 {
            return std.mem.sliceTo(self._name, 0);
        }

        pub fn version(self: *const Response) [:0]const u8 {
            return std.mem.sliceTo(self._version, 0);
        }
    };
};

/// Stack Size Feature
pub const StackSize = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x224ef0460a8e8926, 0xe1cb0fc25f46ea3d },
    revision: u64 = 0,

    response: ?*const Response = null,

    /// The requested stack size (also used for SMP processors).
    stack_size: u64,

    pub const Response = extern struct {
        revision: u64,
    };
};

/// HHDM (Higher Half Direct Map) Feature
pub const HHDM = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// the virtual address offset of the beginning of the higher half direct map
        offset: u64,
    };
};

/// Framebuffer Feature
pub const Framebuffer = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        _framebuffer_count: u64,

        _framebuffers: [*]const *const LimineFramebuffer,

        pub fn framebuffers(self: *const Response) []const *const LimineFramebuffer {
            return self._framebuffers[0..self._framebuffer_count];
        }
    };

    pub const LimineFramebuffer = extern struct {
        address: [*]u8,
        /// Width and height of the framebuffer in pixels
        width: u64,
        height: u64,
        /// Pitch in bytes
        pitch: u64,
        /// Bits per pixel
        bpp: u16,
        memory_model: MemoryModel,
        red_mask_size: u8,
        red_mask_shift: u8,
        green_mask_size: u8,
        green_mask_shift: u8,
        blue_mask_size: u8,
        blue_mask_shift: u8,
        unused: [7]u8,

        _edid_size: u64,
        _edid: [*]const u8,

        /// Response revision 1 required
        _video_mode_count: u64,

        /// Response revision 1 required
        _video_modes: [*]const *const VideoMode,

        pub fn edid(self: *const LimineFramebuffer) []const u8 {
            return self._edid[0..self._edid_size];
        }

        /// Response revision 1 required
        pub fn videoModes(self: *const LimineFramebuffer) []const *const VideoMode {
            return self._video_modes[0..self._video_mode_count];
        }
    };

    pub const VideoMode = extern struct {
        /// Pitch in bytes
        pitch: u64,
        /// Width and height of the framebuffer in pixels
        width: u64,
        height: u64,
        /// Bits per pixel
        bpp: u16,
        memory_model: MemoryModel,
        red_mask_size: u8,
        red_mask_shift: u8,
        green_mask_size: u8,
        green_mask_shift: u8,
        blue_mask_size: u8,
        blue_mask_shift: u8,
    };

    pub const MemoryModel = enum(u8) {
        rgb = 1,
        _,
    };
};

/// Paging Mode Feature
///
/// The Paging Mode feature allows the kernel to control which paging mode is enabled before control is passed to it.
///
/// The response indicates which paging mode was actually enabled by the bootloader.
///
/// Kernels must be prepared to handle the case where the requested paging mode is not supported by the hardware.
pub const PagingMode = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x95c1a0edab0944cb, 0xa4e5cb3842f7488a },
    revision: u64 = 0,

    response: ?*const Response = null,

    mode: Mode = default_mode,
    flags: Flags = .{},

    pub const Response = extern struct {
        revision: u64,

        /// Which paging mode was actually enabled by the bootloader.
        ///
        /// Kernels must be prepared to handle the case where the requested paging mode is not supported by the hardware.
        mode: Mode,

        flags: Flags,
    };

    pub const default_mode: Mode = switch (arch) {
        .aarch64 => .four_level,
        .riscv64 => .sv48,
        .x86_64 => .four_level,
    };

    pub const Mode = switch (arch) {
        .aarch64 => enum(u64) {
            four_level,
            five_level,
            _,
        },
        .riscv64 => enum(u64) {
            /// Three level paging
            sv39,

            /// Four level paging
            sv48,

            /// Five level paging
            sv57,
        },
        .x86_64 => enum(u64) {
            four_level,
            five_level,
            _,
        },
    };

    /// No flags are currently defined
    pub const Flags = packed struct(u64) {
        _reserved: u64 = 0,
    };
};

/// SMP (multiprocessor) Feature
///
/// Notes: The presence of this request will prompt the bootloader to bootstrap the secondary processors.
/// This will not be done if this request is not present.
pub const SMP = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x95a67b819a1b857e, 0xa0b61b723b6a73e0 },
    revision: u64 = 0,

    response: ?*const Response = null,

    flags: Flags = .{},

    pub const Flags = packed struct(u64) {
        /// Enable X2APIC, if possible. (x86-64 only)
        x2apic: bool = false,

        _: u63 = 0,
    };

    pub const Response = switch (arch) {
        .aarch64 => aarch64,
        .riscv64 => riscv64,
        .x86_64 => x86_64,
    };

    pub const aarch64 = extern struct {
        revision: u64,

        /// Always zero.
        flags: u32,

        /// MPIDR of the bootstrap processor (as read from MPIDR_EL1, with Res1 masked off).
        bsp_mpidr: u64,

        _cpu_count: u64,
        _cpus: [*]*SMPInfo,

        pub fn cpus(self: *const aarch64) []*SMPInfo {
            return self._cpus[0..self._cpu_count];
        }

        pub const SMPInfo = extern struct {
            /// ACPI Processor UID as specified by the MADT
            processor_id: u32,

            /// GIC CPU Interface number of the processor as specified by the MADT (possibly always 0)
            gic_iface_no: u32,

            /// MPIDR of the processor as specified by the MADT or device tree
            mpidr: u64,

            _reserved: u64,

            /// An atomic write to this field causes the parked CPU to jump to the written address,
            /// on a 64KiB (or Stack Size Request size) stack
            ///
            /// A pointer to the `SMPInfo` structure of the CPU is passed in X0.
            ///
            /// Other than that, the CPU state will be the same as described for the bootstrap processor.
            ///
            /// This field is unused for the structure describing the bootstrap processor.
            goto_address: ?*const fn (smp_info: *const SMPInfo) callconv(.C) noreturn,

            /// A free for use field
            extra_argument: u64,
        };
    };

    pub const riscv64 = extern struct {
        revision: u64,

        /// Always zero.
        flags: u32,

        /// Hart ID of the bootstrap processor as reported by the UEFI RISC-V Boot Protocol or the SBI.
        bsp_hartid: u64,

        _cpu_count: u64,
        _cpus: [*]*SMPInfo,

        pub fn cpus(self: *const riscv64) []*SMPInfo {
            return self._cpus[0..self._cpu_count];
        }

        pub const SMPInfo = extern struct {
            /// ACPI Processor UID as specified by the MADT (always 0 on non-ACPI systems).
            processor_id: u32,

            /// Hart ID of the processor as specified by the MADT or Device Tree.
            hartid: u32,

            _reserved: u64,

            /// An atomic write to this field causes the parked CPU to jump to the written address, on a 64KiB
            /// (or Stack Size Request size) stack.
            ///
            /// A pointer to the `SMPInfo` structure of the CPU is passed in x10(a0).
            ///
            /// Other than that, the CPU state will be the same as described for the bootstrap processor.
            ///
            /// This field is unused for the structure describing the bootstrap processor.
            goto_address: ?*const fn (smp_info: *const SMPInfo) callconv(.C) noreturn,

            /// A free for use field
            extra_argument: u64,
        };
    };

    pub const x86_64 = extern struct {
        revision: u64,

        flags: ResponseFlags,

        /// The Local APIC ID of the bootstrap processor.
        bsp_lapic_id: u32,

        _cpu_count: u64,
        _cpus: [*]*SMPInfo,

        pub const ResponseFlags = packed struct(u32) {
            /// X2APIC has been enabled
            x2apic_enabled: u1 = 0,
            _: u31 = 0,
        };

        pub fn cpus(self: *const x86_64) []*SMPInfo {
            return self._cpus[0..self._cpu_count];
        }

        pub const SMPInfo = extern struct {
            /// ACPI Processor UID as specified by the MADT
            processor_id: u32,

            /// Local APIC ID of the processor as specified by the MADT
            lapic_id: u32,

            _reserved: u64,

            /// An atomic write to this field causes the parked CPU to jump to the written address,
            /// on a 64KiB (or Stack Size Request size) stack.
            ///
            /// A pointer to the `SMPInfo` structure of the CPU is passed in RDI.
            ///
            /// Other than that, the CPU state will be the same as described for the bootstrap processor.
            ///
            /// This field is unused for the structure describing the bootstrap processor.
            ///
            /// For all CPUs, this field is guaranteed to be `null` when control is first passed to the bootstrap
            /// processor.
            goto_address: ?*const fn (smp_info: *const SMPInfo) callconv(.C) noreturn,

            /// A free for use field
            extra_argument: u64,
        };
    };
};

/// Memory Map Feature
///
/// Note: Memory between 0 and 0x1000 is never marked as usable memory.
/// The kernel and modules loaded are not marked as usable memory.
/// They are marked as Kernel/Modules. The entries are guaranteed to be sorted by
/// base address, lowest to highest. Usable and bootloader reclaimable entries
/// are guaranteed to be 4096 byte aligned for both base and length. Usable and
/// bootloader reclaimable entries are guaranteed not to overlap with any other
/// entry. To the contrary, all non-usable entries (including kernel/modules) are
/// not guaranteed any alignment, nor is it guaranteed that they do not overlap
/// other entries.
pub const Memmap = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        _entry_count: u64,
        _entries: [*]const *const Entry,

        pub fn entries(self: *const Response) []const *const Entry {
            return self._entries[0..self._entry_count];
        }
    };

    pub const Entry = extern struct {
        /// Physical address of the base of the memory section
        base: u64,

        /// Length of the memory section
        length: u64,

        type: Type,

        pub const Type = enum(u64) {
            usable = 0,
            reserved = 1,
            acpi_reclaimable = 2,
            acpi_nvs = 3,
            bad_memory = 4,
            bootloader_reclaimable = 5,
            kernel_and_modules = 6,
            framebuffer = 7,
            _,
        };
    };
};

/// Entry Point Feature
pub const EntryPoint = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x13d86c035a1cd3e1, 0x2b0caa89d8f3026a },
    revision: u64 = 0,

    response: ?*const Response = null,

    /// The requested entry point.
    entry: *const fn () callconv(.C) noreturn,

    pub const Response = extern struct {
        revision: u64,
    };
};

/// Kernel File Feature
pub const KernelFile = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0xad97e90e83f1ed67, 0x31eb5d1c5ff23b69 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        kernel_file: *const File,
    };
};

/// Module Feature
pub const Module = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x3e7e279702be32af, 0xca1c4f3bd1280cee },
    revision: u64 = 0,

    response: ?*const Response = null,

    /// Request revision 1 required
    _internal_module_count: u64 = 0,

    /// Request revision 1 required
    _internal_modules: ?[*]*const InternalModule = null,

    /// Request revision 1 required
    pub fn withInternalModules(internal_modules: []const *const InternalModule) Module {
        return .{
            ._internal_module_count = internal_modules,
            ._internal_modules = internal_modules.ptr,
        };
    }

    pub const Response = extern struct {
        revision: u64,
        _module_count: u64,
        _modules: [*]const *const File,

        pub fn modules(self: *const Response) []const *const File {
            return self._modules[0..self._module_count];
        }
    };

    /// Internal Limine modules are guaranteed to be loaded before user-specified (configuration) modules,
    /// and thus they are guaranteed to appear before user-specified modules in the modules array in the response.
    pub const InternalModule = extern struct {
        /// Path to the module to load.
        ///
        /// This path is relative to the location of the kernel.
        path: [*:0]const u8,

        /// Command line for the given module.
        cmdline: [*:0]const u8,

        /// Flags changing module loading behaviour
        flags: Flags,

        pub const Flags = packed struct(u64) {
            /// If `true` then fail if the requested module is not found.
            required: bool = false,

            _reserved: u63 = 0,
        };
    };
};

/// RSDP Feature
pub const RSDP = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0xc5e77b6b397e7b43, 0x27637845accdcf3c },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// Address of the RSDP table.
        address: *anyopaque,
    };
};

/// SMBIOS Feature
pub const SMBIOS = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x9e9046f11e095391, 0xaa4a520fefbde5ee },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// Address of the 32-bit SMBIOS entry point, `null` if not present.
        entry_32: ?*anyopaque,

        /// Address of the 64-bit SMBIOS entry point, `null` if not present.
        entry_64: ?*anyopaque,
    };
};

/// EFI System Table Feature
pub const EFISystemTable = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x5ceba5163eaaf6d6, 0x0a6981610cf65fcc },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// Address of EFI system table.
        address: *anyopaque,
    };
};

/// Boot Time Feature
pub const BootTime = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x502746e184c088aa, 0xfbc5ec83e6327893 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// The UNIX time on boot, in seconds, taken from the system RTC.
        boot_time: i64,
    };
};

/// Kernel Address Feature
pub const KernelAddress = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// The physical base address of the kernel.
        physical_base: u64,

        /// The virtual base address of the kernel.
        virtual_base: u64,
    };
};

/// Device Tree Blob Feature
///
/// Note: Information contained in the /chosen node may not reflect the information given by bootloader tags,
/// and as such the /chosen node properties should be ignored.
pub const DeviceTreeBlob = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0xb40ddb48fb54bac7, 0x545081493f81ffb7 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// Virtual pointer to the device tree blob.
        address: *anyopaque,
    };
};

pub const File = extern struct {
    revision: u64,

    /// The address of the file. This is always at least 4KiB aligned.
    address: *anyopaque,

    /// The size of the file, in bytes.
    size: u64,

    /// The path of the file within the volume, with a leading slash
    _path: [*:0]const u8,

    /// A command line associated with the file
    _cmdline: ?[*:0]const u8,

    media_type: MediaType,

    unused: u32,

    /// If non-0, this is the IP of the TFTP server the file was loaded from.
    tftp_ip: u32,
    /// Likewise, but port.
    tftp_port: u32,

    /// 1-based partition index of the volume from which the file was loaded.
    ///
    /// If 0, it means invalid or unpartitioned.
    partition_index: u32,

    /// If non-0, this is the ID of the disk the file was loaded from as reported in its MBR.
    mbr_disk_id: u32,

    /// If non-0, this is the UUID of the disk the file was loaded from as reported in its GPT.
    gpt_disk_uuid: LimineUUID,

    /// If non-0, this is the UUID of the partition the file was loaded from as reported in the GPT.
    gpt_part_uuid: LimineUUID,

    /// If non-0, this is the UUID of the filesystem of the partition the file was loaded from.
    part_uuid: LimineUUID,

    /// The path of the file within the volume, with a leading slash
    pub fn path(self: *const File) [:0]const u8 {
        return std.mem.sliceTo(self._path, 0);
    }

    /// A command line associated with the file
    pub fn cmdline(self: *const File) [:0]const u8 {
        return std.mem.sliceTo(self._cmdline, 0);
    }

    pub fn getContents(self: *const File) []const u8 {
        return @as([*]const u8, @ptrCast(self.address))[0..self.size];
    }

    pub const MediaType = enum(u32) {
        generic = 0,
        optical = 1,
        tftp = 2,
        _,
    };

    pub const LimineUUID = extern struct {
        a: u32,
        b: u16,
        c: u16,
        d: [8]u8,
    };
};

comptime {
    refAllDeclsRecursive(@This());
}

fn refAllDeclsRecursive(comptime T: type) void {
    comptime {
        if (!@import("builtin").is_test) return;

        inline for (std.meta.declarations(T)) |decl| {
            if (std.mem.eql(u8, decl.name, "std")) continue;

            if (!@hasDecl(T, decl.name)) continue;

            defer _ = @field(T, decl.name);

            if (@TypeOf(@field(T, decl.name)) != type) continue;

            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        return;
    }
}
