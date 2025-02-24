// SPDX-License-Identifier: MIT AND BSD-2-Clause
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: 2019-2024 mintsuki and contributors (https://github.com/limine-bootloader/limine/blob/v9.0.0/COPYING)

//! This module contains the definitions of the Limine protocol as of v9.0.0.
//!
//! [PROTOCOL DOC](https://github.com/limine-bootloader/limine/blob/v9.0.0/PROTOCOL.md)
//! 99738edd072a14fdedba822359daee754c8fe193 2025-02-17

/// Base protocol revisions change certain behaviours of the Limine boot protocol
/// outside any specific feature. The specifics are going to be described as
/// needed throughout this specification.
pub const BaseRevison = extern struct {
    id: [2]u64 = [_]u64{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc },

    /// The Limine boot protocol comes in several base revisions; so far, 4
    /// base revisions are specified: 0 through 3.
    ///
    /// Base protocol revisions change certain behaviours of the Limine boot protocol
    /// outside any specific feature. The specifics are going to be described as
    /// needed throughout this specification.
    ///
    /// Base revision 0 through 2 are considered deprecated. Base revision 0 is the default
    /// base revision an executable is assumed to be requesting and complying to if no base
    /// revision tag is provided by the executable, for backwards compatibility.
    ///
    /// A base revision tag is a set of 3 64-bit values placed somewhere in the loaded executable
    /// image on an 8-byte aligned boundary; the first 2 values are a magic number
    /// for the bootloader to be able to identify the tag, and the last value is the
    /// requested base revision number. Lack of base revision tag implies revision 0.
    ///
    /// If a bootloader drops support for an older base revision, the bootloader must
    /// fail to boot an executable requesting such base revision. If a bootloader does not yet
    /// support a requested base revision (i.e. if the requested base revision is higher
    /// than the maximum base revision supported), it must boot the executable using any
    /// arbitrary revision it supports, and communicate failure to comply to the executable by
    /// *leaving the 3rd component of the base revision tag unchanged*.
    /// On the other hand, if the executable's requested base revision is supported,
    /// *the 3rd component of the base revision tag must be set to 0 by the bootloader*.
    ///
    /// Note: this means that unlike when the bootloader drops support for an older base
    /// revision and *it* is responsible for failing to boot the executable, in case the
    /// bootloader does not yet support the executable's requested base revision,
    /// it is up to the executable itself to fail (or handle the condition otherwise).
    ///
    /// **WARNING**: if the requested revision is supported this is set to 0
    revison: Revison,

    pub const Revison = enum(u64) {
        @"0" = 0,
        @"1" = 1,
        @"2" = 2,
        @"3" = 3,

        _,

        pub fn equalToOrGreaterThan(self: Revison, other: Revison) bool {
            return @intFromEnum(self) >= @intFromEnum(other);
        }
    };

    comptime {
        core.testing.expectSize(@This(), 3 * @sizeOf(u64));
    }
};

/// The bootloader can be told to start and/or stop searching for requests (including base revision tags) in an
/// executable's loaded image by placing start and/or end markers, on an 8-byte aligned boundary.
///
/// The bootloader will only accept requests placed between the last start marker found (if there happen to be more
/// than 1, which there should not, ideally) and the first end marker found.
///
/// For base revisions 0 and 1, the requests delimiters are *hints*. The bootloader can still search for requests
/// and base revision tags outside the delimited area if it doesn't support the hints.
///
/// Base revision 2's sole difference compared to base revision 1 is that support for request delimiters has to be
/// provided and the delimiters must be honoured, if present, rather than them just being a hint.
pub const RequestDelimiters = struct {
    pub const start_marker = extern struct {
        id: [4]u64 = [_]u64{
            0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf,
            0x785c6ed015d3e316, 0x181e920a7852b9d9,
        },
    };

    pub const end_marker = extern struct {
        id: [2]u64 = [_]u64{
            0xadc0e0531bb10d03, 0x9572709f31764c62,
        },
    };
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

/// Firmware Type Feature
pub const FirmwareType = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x8c2f75d90bef28a8, 0x7045a4688eac00c3 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        firmware_type: Type,
    };

    pub const Type = enum(u64) {
        x86_bios = 0,
        uefi_32 = 1,
        uefi_64 = 2,
        sbi = 3,

        _,
    };
};

/// Stack Size Feature
pub const StackSize = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x224ef0460a8e8926, 0xe1cb0fc25f46ea3d },
    revision: u64 = 0,

    response: ?*const Response = null,

    /// The requested stack size (also used for MP processors).
    stack_size: core.Size,

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
        offset: core.VirtualAddress,
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
        address: core.VirtualAddress,
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

        _edid_size: core.Size,

        /// Points to the screen's EDID blob, if available, else zero.
        _edid: core.VirtualAddress,

        /// Response revision 1 required
        _video_mode_count: u64,

        /// Response revision 1 required
        _video_modes: [*]const *const VideoMode,

        pub fn edid(self: *const LimineFramebuffer) ?[]const u8 {
            if (self._edid.value == 0) return null;

            return core.VirtualRange.fromAddr(self._edid, self._edid_size).toByteSlice();
        }

        pub fn videoModes(self: *const LimineFramebuffer, revision: BaseRevison.Revison) []const *const VideoMode {
            if (revision.equalToOrGreaterThan(.@"1")) return self._video_modes[0..self._video_mode_count];

            return &.{};
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
/// The Paging Mode feature allows the executable to control which paging mode is enabled before control is passed to it.
///
/// The response indicates which paging mode was actually enabled by the bootloader.
///
/// Executables must be prepared to handle the case where the requested paging mode is not supported by the hardware.
///
/// If no Paging Mode Request is provided, the values of `mode`, `max_mode`, and `min_mode` that the bootloader assumes
/// are `PagingMode.default_mode`, `PagingMode.max_mode`, and `PagingMode.min_mode`, respectively.
///
/// If request revision 0 is used, the values of `max_mode` and `min_mode` that the bootloader assumes are the value of
/// `mode` and `PagingMode.min_mode`, respectively.
pub const PagingMode = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x95c1a0edab0944cb, 0xa4e5cb3842f7488a },
    revision: u64 = 0,

    response: ?*const Response = null,

    /// The preferred paging mode by the OS.
    ///
    /// The bootloader should always aim to pick this mode unless unavailable or overridden by the user in the
    /// bootloader's configuration file.
    mode: Mode = default_mode,

    // Request revision 1 and above

    /// The highest paging mode that the OS supports.
    ///
    /// The bootloader will refuse to boot the OS if no paging modes of this type or lower (but equal or greater than
    /// `min_mode`) are available.
    max_mode: Mode,

    /// The lowest paging mode that the OS supports.
    ///
    /// The bootloader will refuse to boot the OS if no paging modes of this type or greater (but equal or lower than
    /// `max_mode`) are available.
    min_mode: Mode = default_min_mode,

    pub const Response = extern struct {
        revision: u64,

        /// Which paging mode was actually enabled by the bootloader.
        ///
        /// Executables must be prepared to handle the case where the requested paging mode is not supported by the hardware.
        mode: Mode,
    };

    pub const default_mode: Mode = switch (arch) {
        .aarch64 => .four_level,
        .loongarch64 => .four_level,
        .riscv64 => .sv48,
        .x86_64 => .four_level,
    };

    pub const default_min_mode: Mode = switch (arch) {
        .aarch64 => .four_level,
        .loongarch64 => .four_level,
        .riscv64 => .sv39,
        .x86_64 => .four_level,
    };

    pub const Mode = switch (arch) {
        .aarch64 => enum(u64) {
            four_level,
            five_level,
            _,
        },
        .loongarch64 => enum(u64) {
            four_level,
            _,
        },
        .riscv64 => enum(u64) {
            /// Three level paging
            sv39,

            /// Four level paging
            sv48,

            /// Five level paging
            sv57,

            _,
        },
        .x86_64 => enum(u64) {
            four_level,
            five_level,
            _,
        },
    };
};

/// MP (multiprocessor) Feature
///
/// Notes: The presence of this request will prompt the bootloader to bootstrap the secondary processors.
/// This will not be done if this request is not present.
pub const MP = extern struct {
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
        .loongarch64 => unreachable,
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
        _cpus: [*]*MPInfo,

        pub fn cpus(self: *const aarch64) []*MPInfo {
            return self._cpus[0..self._cpu_count];
        }

        pub const MPInfo = extern struct {
            /// ACPI Processor UID as specified by the MADT (always 0 on non-ACPI systems)
            processor_id: u32,

            _reserved1: u32,

            /// MPIDR of the processor as specified by the MADT or device tree
            mpidr: u64,

            _reserved2: u64,

            /// An atomic write to this field causes the parked CPU to jump to the written address,
            /// on a 64KiB (or Stack Size Request size) stack
            ///
            /// A pointer to the `MPInfo` structure of the CPU is passed in X0.
            ///
            /// Other than that, the CPU state will be the same as described for the bootstrap processor.
            ///
            /// This field is unused for the structure describing the bootstrap processor.
            goto_address: ?*const fn (smp_info: *const MPInfo) callconv(.C) noreturn,

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
        _cpus: [*]*MPInfo,

        pub fn cpus(self: *const riscv64) []*MPInfo {
            return self._cpus[0..self._cpu_count];
        }

        pub const MPInfo = extern struct {
            /// ACPI Processor UID as specified by the MADT (always 0 on non-ACPI systems).
            processor_id: u32,

            /// Hart ID of the processor as specified by the MADT or Device Tree.
            hartid: u32,

            _reserved: u64,

            /// An atomic write to this field causes the parked CPU to jump to the written address, on a 64KiB
            /// (or Stack Size Request size) stack.
            ///
            /// A pointer to the `MPInfo` structure of the CPU is passed in x10(a0).
            ///
            /// Other than that, the CPU state will be the same as described for the bootstrap processor.
            ///
            /// This field is unused for the structure describing the bootstrap processor.
            goto_address: ?*const fn (smp_info: *const MPInfo) callconv(.C) noreturn,

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
        _cpus: [*]*MPInfo,

        pub const ResponseFlags = packed struct(u32) {
            /// X2APIC has been enabled
            x2apic_enabled: bool = false,
            _: u31 = 0,
        };

        pub fn cpus(self: *const x86_64) []*MPInfo {
            return self._cpus[0..self._cpu_count];
        }

        pub const MPInfo = extern struct {
            /// ACPI Processor UID as specified by the MADT
            processor_id: u32,

            /// Local APIC ID of the processor as specified by the MADT
            lapic_id: u32,

            _reserved: u64,

            /// An atomic write to this field causes the parked CPU to jump to the written address,
            /// on a 64KiB (or Stack Size Request size) stack.
            ///
            /// A pointer to the `MPInfo` structure of the CPU is passed in RDI.
            ///
            /// Other than that, the CPU state will be the same as described for the bootstrap processor.
            ///
            /// This field is unused for the structure describing the bootstrap processor.
            ///
            /// For all CPUs, this field is guaranteed to be `null` when control is first passed to the bootstrap
            /// processor.
            goto_address: ?*const fn (smp_info: *const MPInfo) callconv(.C) noreturn,

            /// A free for use field
            extra_argument: u64,
        };
    };
};

/// Memory Map Feature
///
/// All these memory entry types, besides usable and bootloader reclaimable,
/// are meant to have an illustrative purpose only, and are not authoritative sources
/// to be used as a means to find the addresses of the executable, modules, framebuffer, ACPI,
/// or otherwise. Use the specific Limine features to do that, if available, or other
/// discovery means.
///
/// For base revisions <= 2, memory between 0 and 0x1000 is never marked as usable memory.
///
/// The executable and modules loaded are not marked as usable memory, but as Executable/Modules.
///
/// The entries are guaranteed to be sorted by base address, lowest to highest.
///
/// Usable and bootloader reclaimable entries are guaranteed to be 4096 byte aligned for both base and length.
///
/// Usable and bootloader reclaimable entries are guaranteed not to overlap with any other entry.
/// To the contrary, all non-usable entries (including executable/modules) are not guaranteed any alignment,
/// nor is it guaranteed that they do not overlap other entries.
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
        base: core.PhysicalAddress,

        /// Length of the memory section
        length: core.Size,

        type: Type,

        pub const Type = enum(u64) {
            usable = 0,
            reserved = 1,
            acpi_reclaimable = 2,
            acpi_nvs = 3,
            bad_memory = 4,
            bootloader_reclaimable = 5,
            executable_and_modules = 6,
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

/// Executable File Feature
pub const ExecutableFile = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0xad97e90e83f1ed67, 0x31eb5d1c5ff23b69 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        executable_file: *const File,
    };
};

/// Executable Command Line Feature
pub const ExecutableCommandLine = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x4b161536e598651e, 0xb390ad4a2f1f303a },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// String containing the command line associated with the booted executable.
        ///
        /// This is equivalent to the `string` member of the `executable_file` structure of the Executable File feature.
        _cmdline: ?[*:0]const u8,

        /// String containing the command line associated with the booted executable.
        ///
        /// This is equivalent to the `string` member of the `executable_file` structure of the Executable File feature.
        pub fn cmdline(self: *const Response) ?[:0]const u8 {
            return if (self._cmdline) |c|
                std.mem.sliceTo(c, 0)
            else
                null;
        }
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
    _internal_modules: ?[*]const *const InternalModule = null,

    /// Request revision 1 required
    pub fn withInternalModules(internal_modules: []const *const InternalModule) Module {
        return .{
            .revision = 1,
            ._internal_module_count = internal_modules.len,
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
        /// This path is relative to the location of the executable.
        path: [*:0]const u8,

        /// String associated with the given module.
        _string: ?[*:0]const u8,

        /// Flags changing module loading behaviour
        flags: Flags,

        /// String associated with the given module.
        pub fn string(self: *const InternalModule) ?[:0]const u8 {
            return if (self._string) |s|
                std.mem.sliceTo(s, 0)
            else
                null;
        }

        pub const Flags = packed struct(u64) {
            /// If `true` then fail if the requested module is not found.
            required: bool = false,

            /// Deprecated. Bootloader may not support it and panic instead (from Limine 8.x onwards). Alternatively:
            ///
            /// The module is GZ-compressed and should be decompressed by the bootloader.
            ///
            /// This is honoured if the response is revision 2 or greater.
            compressed: bool = false,

            _reserved: u62 = 0,
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
        _address: core.Address.Raw,

        /// Address of the RSDP table. Physical for base @intFromEnum(revision) >= 3.
        pub fn address(self: *const Response, revision: BaseRevison.Revison) core.Address {
            return if (revision.equalToOrGreaterThan(.@"3"))
                .{ .physical = self._address.physical }
            else
                .{ .virtual = self._address.virtual };
        }
    };
};

/// SMBIOS Feature
pub const SMBIOS = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x9e9046f11e095391, 0xaa4a520fefbde5ee },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        _entry_32: core.Address.Raw,
        _entry_64: core.Address.Raw,

        /// Address of the 32-bit SMBIOS entry point, `null` if not present. Physical for base @intFromEnum(revision) >= 3.
        pub fn entry32(self: *const Response, revision: BaseRevison.Revison) core.Address {
            return if (revision.equalToOrGreaterThan(.@"3"))
                .{ .physical = self._entry_32.physical }
            else
                .{ .virtual = self._entry_32.virtual };
        }

        /// Address of the 64-bit SMBIOS entry point, `null` if not present. Physical for base @intFromEnum(revision) >= 3.
        pub fn entry64(self: *const Response, revision: BaseRevison.Revison) core.Address {
            return if (revision.equalToOrGreaterThan(.@"3"))
                .{ .physical = self._entry_64.physical }
            else
                .{ .virtual = self._entry_64.virtual };
        }
    };
};

/// EFI System Table Feature
pub const EFISystemTable = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x5ceba5163eaaf6d6, 0x0a6981610cf65fcc },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        _address: core.Address.Raw,

        /// Address of EFI system table. Physical for base @intFromEnum(revision) >= 3.
        pub fn address(self: *const Response, revision: BaseRevison.Revison) core.Address {
            return if (revision.equalToOrGreaterThan(.@"3"))
                .{ .physical = self._address.physical }
            else
                .{ .virtual = self._address.virtual };
        }
    };
};

/// EFI Memory Map Feature
///
/// This feature provides data suitable for use with RT->SetVirtualAddressMap(), provided HHDM offset is subtracted from memmap.
pub const EFIMemoryMap = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x7df62a431d6872d5, 0xa4fcdfb3e57306c8 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// Address (HHDM, in bootloader reclaimable memory) of the EFI memory map.
        memmap: core.VirtualAddress,

        /// Size in bytes of the EFI memory map.
        memmap_size: core.Size,

        /// EFI memory map descriptor size in bytes.
        desc_size: core.Size,

        /// Version of EFI memory map descriptors.
        desc_version: u64,
    };
};

/// Date at Boot Feature
pub const DateAtBoot = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x502746e184c088aa, 0xfbc5ec83e6327893 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// The UNIX timestamp, in seconds, taken from the system RTC, representing the date and time of boot.
        timestamp: i64,
    };
};

/// Executable Address Feature
pub const ExecutableAddress = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// The physical base address of the executable.
        physical_base: core.PhysicalAddress,

        /// The virtual base address of the executable.
        virtual_base: core.VirtualAddress,
    };
};

/// Device Tree Blob Feature
///
/// Note: Information contained in the /chosen node may not reflect the information given by bootloader tags,
/// and as such the /chosen node properties should be ignored.
///
/// Note: If the DTB contained `memory@...` nodes, they will get removed.
/// Executable may not rely on these nodes and should use the Memory Map feature instead.
pub const DeviceTreeBlob = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0xb40ddb48fb54bac7, 0x545081493f81ffb7 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// Virtual (HHDM) pointer to the device tree blob, in bootloader reclaimable memory.
        address: core.VirtualAddress,
    };
};

/// RISC-V BSP Hart ID Feature
///
/// This request contains the same information as `MP.riscv64.bsp_hartid`, but doesn't boot up other APs.
pub const BSPHartID = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x1369359f025525f9, 0x2ff2a56178391bb6 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// The Hart ID of the boot processor.
        bsp_hartid: u64,
    };
};

pub const File = extern struct {
    revision: u64,

    /// The address of the file. This is always at least 4KiB aligned.
    address: core.VirtualAddress,

    /// The size of the file, in bytes.
    size: core.Size,

    /// The path of the file within the volume, with a leading slash
    _path: [*:0]const u8,

    /// A string associated with the file
    _string: ?[*:0]const u8,

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
    gpt_disk_uuid: UUID,

    /// If non-0, this is the UUID of the partition the file was loaded from as reported in the GPT.
    gpt_part_uuid: UUID,

    /// If non-0, this is the UUID of the filesystem of the partition the file was loaded from.
    part_uuid: UUID,

    /// The path of the file within the volume, with a leading slash
    pub fn path(self: *const File) [:0]const u8 {
        return std.mem.sliceTo(self._path, 0);
    }

    /// A string associated with the file
    pub fn string(self: *const File) ?[:0]const u8 {
        const str = std.mem.sliceTo(
            self._string orelse return null,
            0,
        );
        return if (str.len == 0) null else str;
    }

    pub fn getContents(self: *const File) []const u8 {
        return core.VirtualRange.fromAddr(self.address, self.size).toByteSlice();
    }

    pub const MediaType = enum(u32) {
        generic = 0,
        optical = 1,
        tftp = 2,
        _,
    };
};

const LIMINE_COMMON_MAGIC = [_]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

const Arch = enum {
    aarch64,
    loongarch64,
    riscv64,
    x86_64,
};

const arch: Arch = switch (@import("builtin").cpu.arch) {
    .aarch64 => .aarch64,
    .loongarch64 => .loongarch64,
    .riscv64 => .riscv64,
    .x86_64 => .x86_64,
    else => |e| @compileError("unsupported architecture " ++ @tagName(e)),
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const core = @import("core");
const std = @import("std");
const UUID = @import("uuid").UUID;
