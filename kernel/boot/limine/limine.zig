// SPDX-License-Identifier: LicenseRef-NON-AI-MIT AND 0BSD
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: 2022-2025 Mintsuki and contributors (https://github.com/limine-bootloader/limine-protocol/blob/trunk/LICENSE)

//! This module contains the definitions of the Limine protocol as of 8a888d7ab3b274fad1a357a922e799fc2ff20729.
//!
//! [PROTOCOL DOC](https://github.com/limine-bootloader/limine-protocol/blob/8a888d7ab3b274fad1a357a922e799fc2ff20729/PROTOCOL.md)

const std = @import("std");

const boot = @import("boot");
const core = @import("core");
const UUID = @import("uuid").UUID;

/// Base protocol revisions change certain behaviours of the Limine boot protocol outside any specific feature.
/// The specifics are going to be described as needed throughout this specification.
pub const BaseRevison = extern struct {
    id: [2]u64 = [_]u64{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc },

    /// The Limine boot protocol comes in several base revisions; so far, 5 base revisions are specified: 0 through 4.
    ///
    /// Base revision 0 through 3 are considered deprecated.
    /// Base revision 0 is the default base revision an executable is assumed to be requesting and complying to if no base
    /// revision tag is provided by the executable, for backwards compatibility.
    ///
    /// A base revision tag is a set of 3 64-bit values placed somewhere in the loaded executable image on an 8-byte aligned boundary;
    /// the first 2 values are a magic number for the bootloader to be able to identify the tag, and the last value is the requested base
    /// revision number.
    ///
    /// If a bootloader drops support for an older base revision, the bootloader must fail to boot an executable requesting such base
    /// revision.
    /// If a bootloader does not yet support a requested base revision (i.e. if the requested base revision is higher than the
    /// maximum base revision supported), it must boot the executable using any arbitrary revision it supports, and communicate failure to
    /// comply to the executable by *leaving the 3rd component of the base revision tag unchanged*.
    /// On the other hand, if the executable's requested base revision is supported, *the 3rd component of the base revision tag must be
    /// set to 0 by the bootloader*.
    ///
    /// Note: this means that unlike when the bootloader drops support for an older base revision and *it* is responsible for failing to
    /// boot the executable, in case the bootloader does not yet support the executable's requested base revision, it is up to the
    /// executable itself to fail (or handle the condition otherwise).
    ///
    /// **WARNING**: if the requested revision is supported this is set to 0
    revison: Revison,

    pub const Revison = enum(u64) {
        @"0" = 0,
        @"1" = 1,
        @"2" = 2,
        @"3" = 3,
        @"4" = 4,

        _,

        pub fn equalToOrGreaterThan(revision: Revison, other: Revison) bool {
            return @intFromEnum(revision) >= @intFromEnum(other);
        }
    };

    /// Returns the revision that the bootloader is providing or `null` if the requested revision is unknown to the bootloader.
    pub fn loadedRevision(base_revision: *const BaseRevison) ?Revison {
        if (base_revision.id[1] == 0x6a7b384944536bdc) return null;
        return @enumFromInt(base_revision.id[1]);
    }

    comptime {
        core.testing.expectSize(BaseRevison, core.Size.of(u64).multiplyScalar(3));
    }
};

/// The bootloader can be told to start and/or stop searching for requests (including base revision tags) in an executable's loaded image
/// by placing start and/or end markers, on an 8-byte aligned boundary.
///
/// The bootloader will only accept requests placed between the last start marker found (if there happen to be more than 1, which there
/// should not, ideally) and the first end marker found.
///
/// For base revisions 0 and 1, the requests delimiters are *hints*. The bootloader can still search for requests and base revision tags
/// outside the delimited area if it doesn't support the hints.
///
/// Base revision 2's sole difference compared to base revision 1 is that support for request delimiters has to be provided and the
/// delimiters must be honoured, if present, rather than them just being a hint.
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

        pub fn name(response: *const Response) [:0]const u8 {
            return std.mem.sliceTo(response._name, 0);
        }

        pub fn version(response: *const Response) [:0]const u8 {
            return std.mem.sliceTo(response._version, 0);
        }

        pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
            try writer.print("Bootloader({s} {s})", .{
                response.name(),
                response.version(),
            });
        }
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
        /// This is a pointer to the same memory as the `string` member of the `executable_file` structure of the Executable File feature.
        pub fn cmdline(response: *const Response) ?[:0]const u8 {
            const str = std.mem.sliceTo(
                response._cmdline orelse return null,
                0,
            );
            return if (str.len == 0) null else str;
        }

        pub fn format(response: *const Response, writer: *std.Io.Writer) !void {
            if (response.cmdline()) |c| {
                try writer.print("ExecutableCommandLine(\"{s}\")", .{c});
            } else {
                try writer.writeAll("ExecutableCommandLine(null)");
            }
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

        pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
            try writer.print("Firmware({t})", .{response.firmware_type});
        }
    };

    pub const Type = enum(u64) {
        x86_bios = 0,
        efi_32 = 1,
        efi_64 = 2,
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

        pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
            try writer.print("HHDM({f})", .{response.offset});
        }
    };
};

/// Framebuffer Feature
pub const Framebuffer = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    revision: u64 = 0,

    /// If no framebuffer is available no response will be provided.
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        _framebuffer_count: u64,

        _framebuffers: [*]const *const LimineFramebuffer,

        pub fn framebuffers(response: *const Response) []const *const LimineFramebuffer {
            return response._framebuffers[0..response._framebuffer_count];
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

        pub fn edid(limine_framebuffer: *const LimineFramebuffer) ?[]const u8 {
            if (limine_framebuffer._edid.equal(.zero)) return null;

            return core.VirtualRange.fromAddr(
                limine_framebuffer._edid,
                limine_framebuffer._edid_size,
            ).toByteSlice();
        }

        pub fn videoModes(
            limine_framebuffer: *const LimineFramebuffer,
            response_revision: u64,
        ) []const *const VideoMode {
            if (response_revision < 1) return &.{};
            return limine_framebuffer._video_modes[0..limine_framebuffer._video_mode_count];
        }

        pub fn print(limine_framebuffer: *const LimineFramebuffer, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("Framebuffer{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("address: {f}\n", .{limine_framebuffer.address});

            try writer.splatByteAll(' ', new_indent);
            try writer.print(
                "resolution: {}x{}@{}\n",
                .{ limine_framebuffer.width, limine_framebuffer.height, limine_framebuffer.bpp },
            );

            try writer.splatByteAll(' ', new_indent);
            try writer.print("pitch: {}\n", .{limine_framebuffer.pitch});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("memory_model: {t}\n", .{limine_framebuffer.memory_model});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(
            limine_framebuffer: *const LimineFramebuffer,
            writer: *std.Io.Writer,
        ) !void {
            return limine_framebuffer.print(limine_framebuffer, writer, 0);
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

        pub fn print(video_mode: *const VideoMode, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("VideoMode{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print(
                "resolution: {}x{}@{}\n",
                .{ video_mode.width, video_mode.height, video_mode.bpp },
            );

            try writer.splatByteAll(' ', new_indent);
            try writer.print("pitch: {}\n", .{video_mode.pitch});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("memory_model: {t}\n", .{video_mode.memory_model});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(video_mode: *const VideoMode, writer: *std.Io.Writer) !void {
            return video_mode.print(writer, 0);
        }
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
/// If no Paging Mode Request is provided, the values of `mode`, `max_mode`, and `min_mode` that the bootloader assumes are
/// `PagingMode.default_mode`, `PagingMode.max_mode`, and `PagingMode.min_mode`, respectively.
///
/// If request revision 0 is used, the values of `max_mode` and `min_mode` that the bootloader assumes are the value of `mode` and
/// `PagingMode.min_mode`, respectively.
pub const PagingMode = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x95c1a0edab0944cb, 0xa4e5cb3842f7488a },
    revision: u64 = 0,

    response: ?*const Response = null,

    /// The preferred paging mode by the OS.
    ///
    /// The bootloader should always aim to pick this mode unless unavailable or overridden by the user in the bootloader's configuration
    /// file.
    mode: Mode = .default,

    // Request revision 1 and above

    /// The highest paging mode that the OS supports.
    ///
    /// The bootloader will refuse to boot the OS if no paging modes of this type or lower (but equal or greater than `min_mode`) are
    /// available.
    max_mode: Mode,

    /// The lowest paging mode that the OS supports.
    ///
    /// The bootloader will refuse to boot the OS if no paging modes of this type or greater (but equal or lower than `max_mode`) are
    /// available.
    min_mode: Mode = .default_min,

    pub const Response = extern struct {
        revision: u64,

        /// Which paging mode was actually enabled by the bootloader.
        ///
        /// Executables must be prepared to handle the case where the requested paging mode is not supported by the hardware.
        mode: Mode,

        pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
            try writer.print("PagingMode({t})", .{response.mode});
        }
    };

    pub const Mode = switch (arch) {
        .aarch64 => enum(u64) {
            four_level,
            five_level,
            _,

            pub const default: @This() = .four_level;
            pub const default_min: @This() = .four_level;
        },
        .loongarch64 => enum(u64) {
            four_level,
            _,

            pub const default: @This() = .four_level;
            pub const default_min: @This() = .four_level;
        },
        .riscv64 => enum(u64) {
            /// Three level paging
            sv39,

            /// Four level paging
            sv48,

            /// Five level paging
            sv57,

            _,

            pub const default: @This() = .sv48;
            pub const default_min: @This() = .sv39;
        },
        .x86_64 => enum(u64) {
            four_level,
            five_level,
            _,

            pub const default: @This() = .four_level;
            pub const default_min: @This() = .four_level;
        },
    };
};

/// MP (Multiprocessor) Feature
///
/// Notes: The presence of this request will prompt the bootloader to bootstrap the secondary processors.
/// This will not be done if this request is not present.
pub const MP = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x95a67b819a1b857e, 0xa0b61b723b6a73e0 },
    revision: u64 = 0,

    response: ?*const Response = null,

    flags: Flags = .{},

    pub const Flags = packed struct(u64) {
        /// Enable x2APIC, if possible. (x86-64 only)
        x2apic: bool = false,

        _: u63 = 0,
    };

    pub const Response = switch (arch) {
        .aarch64 => aarch64,
        .loongarch64 => @compileError("MP feature not available for loongarch64"),
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

        pub fn cpus(response: *const aarch64) []*MPInfo {
            return response._cpus[0..response._cpu_count];
        }

        pub fn print(response: *const aarch64, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("MP{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("bsp_mpidr: {}\n", .{response.bsp_mpidr});

            try writer.splatByteAll(' ', new_indent);
            try writer.writeAll("cpus:\n");

            for (response.cpus()) |cpu| {
                try writer.splatByteAll(' ', new_indent + 2);
                try cpu.print(writer, new_indent + 2);
                try writer.writeByte('\n');
            }

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(response: *const aarch64, writer: *std.Io.Writer) !void {
            return response.print(writer.any(), 0);
        }

        pub const MPInfo = extern struct {
            /// ACPI Processor UID as specified by the MADT (always 0 on non-ACPI systems)
            processor_id: u32,

            _reserved1: u32,

            /// MPIDR of the processor as specified by the MADT or device tree
            mpidr: u64,

            _reserved2: u64,

            /// An atomic write to this field causes the parked CPU to jump to the written address, on a 64KiB (or Stack Size Request size)
            /// stack.
            ///
            /// A pointer to the `MPInfo` structure of the CPU is passed in X0.
            ///
            /// Other than that, the CPU state will be the same as described for the bootstrap processor.
            ///
            /// This field is unused for the structure describing the bootstrap processor.
            goto_address: ?*const fn (smp_info: *const MPInfo) callconv(.c) noreturn,

            /// A free for use field
            extra_argument: u64,

            pub fn print(mp_info: *const MPInfo, writer: *std.Io.Writer, indent: usize) !void {
                const new_indent = indent + 2;

                try writer.writeAll("CPU{\n");

                try writer.splatByteAll(' ', new_indent);
                try writer.print("processor_id: {}\n", .{mp_info.processor_id});

                try writer.splatByteAll(' ', new_indent);
                try writer.print("mpidr: {}\n", .{mp_info.mpidr});

                try writer.splatByteAll(' ', indent);
                try writer.writeByte('}');
            }

            pub inline fn format(mp_info: *const MPInfo, writer: *std.Io.Writer) !void {
                return mp_info.print(writer, 0);
            }
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

        pub fn print(response: *const riscv64, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("MP{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("bsp_hartid: {}\n", .{response.bsp_hartid});

            try writer.splatByteAll(' ', new_indent);
            try writer.writeAll("cpus:\n");

            for (response.cpus()) |cpu| {
                try writer.splatByteAll(' ', new_indent + 2);
                try cpu.print(writer, new_indent + 2);
                try writer.writeByte('\n');
            }

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(response: *const riscv64, writer: *std.Io.Writer) !void {
            return response.print(writer, 0);
        }

        pub fn cpus(response: *const riscv64) []*MPInfo {
            return response._cpus[0..response._cpu_count];
        }

        pub const MPInfo = extern struct {
            /// ACPI Processor UID as specified by the MADT (always 0 on non-ACPI systems).
            processor_id: u32,

            /// Hart ID of the processor as specified by the MADT or Device Tree.
            hartid: u32,

            _reserved: u64,

            /// An atomic write to this field causes the parked CPU to jump to the written address, on a 64KiB (or Stack Size Request size)
            /// stack.
            ///
            /// A pointer to the `MPInfo` structure of the CPU is passed in x10(a0).
            ///
            /// Other than that, the CPU state will be the same as described for the bootstrap processor.
            ///
            /// This field is unused for the structure describing the bootstrap processor.
            goto_address: ?*const fn (smp_info: *const MPInfo) callconv(.c) noreturn,

            /// A free for use field
            extra_argument: u64,

            pub fn print(mp_info: *const MPInfo, writer: *std.Io.Writer, indent: usize) !void {
                const new_indent = indent + 2;

                try writer.writeAll("CPU{\n");

                try writer.splatByteAll(' ', new_indent);
                try writer.print("processor_id: {}\n", .{mp_info.processor_id});

                try writer.splatByteAll(' ', new_indent);
                try writer.print("hartid: {}\n", .{mp_info.hartid});

                try writer.splatByteAll(' ', indent);
                try writer.writeByte('}');
            }

            pub inline fn format(mp_info: *const MPInfo, writer: *std.Io.Writer) !void {
                return mp_info.print(mp_info, writer, 0);
            }
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
            /// x2APIC has been enabled
            x2apic_enabled: bool = false,
            _: u31 = 0,
        };

        pub fn cpus(response: *const x86_64) []*MPInfo {
            return response._cpus[0..response._cpu_count];
        }

        pub fn print(response: *const x86_64, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("MP{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("bsp_lapic_id: {}\n", .{response.bsp_lapic_id});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("x2apic_enabled: {}\n", .{response.flags.x2apic_enabled});

            try writer.splatByteAll(' ', new_indent);
            try writer.writeAll("cpus:\n");

            for (response.cpus()) |cpu| {
                try writer.splatByteAll(' ', new_indent + 2);
                try cpu.print(writer, new_indent + 2);
                try writer.writeByte('\n');
            }

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(response: *const x86_64, writer: *std.Io.Writer) !void {
            return response.print(writer, 0);
        }

        pub const MPInfo = extern struct {
            /// ACPI Processor UID as specified by the MADT
            processor_id: u32,

            /// Local APIC ID of the processor as specified by the MADT
            lapic_id: u32,

            _reserved: u64,

            /// An atomic write to this field causes the parked CPU to jump to the written address, on a 64KiB (or Stack Size Request size)
            /// stack.
            ///
            /// A pointer to the `MPInfo` structure of the CPU is passed in RDI.
            ///
            /// Other than that, the CPU state will be the same as described for the bootstrap processor.
            ///
            /// This field is unused for the structure describing the bootstrap processor.
            ///
            /// For all CPUs, this field is guaranteed to be `null` when control is first passed to the bootstrap
            /// processor.
            goto_address: ?*const fn (smp_info: *const MPInfo) callconv(.c) noreturn,

            /// A free for use field
            extra_argument: u64,

            pub fn print(mp_info: *const MPInfo, writer: *std.Io.Writer, indent: usize) !void {
                const new_indent = indent + 2;

                try writer.writeAll("CPU{\n");

                try writer.splatByteAll(' ', new_indent);
                try writer.print("processor_id: {}\n", .{mp_info.processor_id});

                try writer.splatByteAll(' ', new_indent);
                try writer.print("lapic_id: {}\n", .{mp_info.lapic_id});

                try writer.splatByteAll(' ', indent);
                try writer.writeByte('}');
            }

            pub inline fn format(mp_info: *const MPInfo, writer: *std.Io.Writer) !void {
                return mp_info.print(writer, 0);
            }
        };
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

        pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
            try writer.print("BSPHartID({})", .{response.bsp_hartid});
        }
    };
};

/// Memory Map Feature
///
/// For base revisions <= 2, memory between 0 and 0x1000 is never marked as usable memory.
///
/// The entries are guaranteed to be sorted by base address, lowest to highest.
///
/// Usable and bootloader reclaimable entries are guaranteed to be 4096 byte aligned for both base and length.
///
/// Usable and bootloader reclaimable entries are guaranteed not to overlap with any other entry.
///
/// To the contrary, all non-usable entries (including executable/modules) are not guaranteed any alignment, nor is it guaranteed that they
/// do not overlap other entries.
pub const Memmap = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        _entry_count: u64,
        _entries: [*]const *const Entry,

        pub fn entries(response: *const Response) []const *const Entry {
            return response._entries[0..response._entry_count];
        }

        pub fn print(response: *const Response, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("Memmap{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.writeAll("entries:\n");

            for (response.entries()) |entry| {
                try writer.splatByteAll(' ', new_indent + 2);
                try writer.print("{f}\n", .{entry});
            }

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
            return response.print(writer, 0);
        }
    };

    pub const Entry = extern struct {
        /// Physical address of the base of the memory section
        base: core.PhysicalAddress,

        /// Length of the memory section
        length: core.Size,

        type: Type,

        pub const Type = enum(u64) {
            /// A region of the address space that is usable RAM, and does not contain other data, the executable, bootloader information,
            /// or anything valuable, and is therefore free for use.
            usable = 0,

            /// A region of the address space that are reserved for unspecified purposes by the firmware, hardware, or otherwise, and
            /// should not be touched by the executable.
            reserved = 1,

            /// A region of the address space containing ACPI related data, such as ACPI tables and AML code.
            ///
            /// The executable should make absolutely sure that no data contained in these regions is still needed before deciding to
            /// reclaim these memory regions for itself.
            ///
            /// Refer to the ACPI specification for further information.
            acpi_reclaimable = 2,

            /// A region of the address space used for ACPI non-volatile data storage.
            ///
            /// Refer to the ACPI specification for further information.
            acpi_nvs = 3,

            /// A region of the address space that contains bad RAM, which may be unreliable, and therefore these regions should be treated
            /// the same as reserved regions.
            bad_memory = 4,

            /// A region of the address space containing RAM used to store bootloader or firmware information that should be available to
            /// the executable (or, in some cases, hardware, such as for MP trampolines).
            ///
            /// The executable should make absolutely sure that no data contained in these regions is still needed before deciding to
            /// reclaim these memory regions for itself.
            bootloader_reclaimable = 5,

            /// An entry that is meant to have an illustrative purpose only, and are not authoritative sources to be used as a means to find
            /// the addresses of the executable or modules.
            ///
            /// One must use the specific Limine features (executable address and module features) to do that.
            executable_and_modules = 6,

            /// A region of the address space containing memory-mapped framebuffers.
            ///
            /// These entries exist for illustrative purposes only, and are not to be used to acquire the address of any framebuffer.
            /// One must use the framebuffer feature for that.
            framebuffer = 7,

            /// A region of the address space containing ACPI tables, if the firmware did not already map them within either the ACPI
            /// reclaimable or an ACPI NVS region.
            ///
            /// Base revision 4 or greater.
            acpi_tables = 8,

            _,
        };

        pub inline fn format(entry: *const Entry, writer: *std.Io.Writer) !void {
            try writer.print("Entry({f} - {f} - {t})", .{ entry.base, entry.length, entry.type });
        }
    };
};

/// Entry Point Feature
pub const EntryPoint = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x13d86c035a1cd3e1, 0x2b0caa89d8f3026a },
    revision: u64 = 0,

    response: ?*const Response = null,

    /// The requested entry point.
    entry: *const fn () callconv(.c) noreturn,

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

        pub fn print(response: *const Response, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("ExecutableFile{\n");

            try writer.splatByteAll(' ', new_indent + 2);
            try response.executable_file.print(writer, new_indent + 2);
            try writer.writeByte('\n');

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
            return response.print(writer, 0);
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

        pub fn modules(response: *const Response) []const *const File {
            return response._modules[0..response._module_count];
        }

        pub fn print(response: *const Response, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            if (response._module_count == 0) {
                try writer.writeAll("Modules{}");
                return;
            }

            try writer.writeAll("Modules{\n");

            for (response.modules()) |module| {
                try writer.splatByteAll(' ', new_indent + 2);
                try module.print(writer, new_indent + 2);
                try writer.writeByte('\n');
            }

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
            return response.print(writer, 0);
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
        pub fn string(internal_module: *const InternalModule) ?[:0]const u8 {
            return if (internal_module._string) |s|
                std.mem.sliceTo(s, 0)
            else
                null;
        }

        pub const Flags = packed struct(u64) {
            /// If `true` then fail if the requested module is not found.
            required: bool = false,

            /// Deprecated. Bootloader may not support it and panic instead (from Limine 8.x onwards).
            ///
            /// Alternatively, the module is GZ-compressed and should be decompressed by the bootloader.
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
        _address: boot.Address.Raw,

        /// Address of the RSDP table. Physical for base revision 3.
        pub fn address(response: *const Response, revision: BaseRevison.Revison) boot.Address {
            return switch (revision) {
                .@"3" => .{ .physical = response._address.physical },
                else => .{ .virtual = response._address.virtual },
            };
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

        /// Address of the 32-bit SMBIOS entry point, `null` if not present. Physical for base revision >= 3.
        pub fn entry32(response: *const Response, revision: BaseRevison.Revison) core.Address {
            return if (revision.equalToOrGreaterThan(.@"3"))
                .{ .physical = response._entry_32.physical }
            else
                .{ .virtual = response._entry_32.virtual };
        }

        /// Address of the 64-bit SMBIOS entry point, `null` if not present. Physical for base revision >= 3.
        pub fn entry64(response: *const Response, revision: BaseRevison.Revison) core.Address {
            return if (revision.equalToOrGreaterThan(.@"3"))
                .{ .physical = response._entry_64.physical }
            else
                .{ .virtual = response._entry_64.virtual };
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

        /// Address of EFI system table. Physical for base revision >= 3.
        pub fn address(response: *const Response, revision: BaseRevison.Revison) core.Address {
            return if (revision.equalToOrGreaterThan(.@"3"))
                .{ .physical = response._address.physical }
            else
                .{ .virtual = response._address.virtual };
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

        pub fn print(response: *const Response, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("EFIMemoryMap{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("address: {f}\n", .{response.memmap});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("size: {f}\n", .{response.memmap_size});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("desc_size: {f}\n", .{response.desc_size});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("desc_version: {}\n", .{response.desc_version});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
            return response.print(response, writer, 0);
        }
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

        pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
            try writer.print("DateAtBoot({})", .{response.timestamp});
        }
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

        pub fn print(response: *const Response, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("ExecutableAddress{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("physical_base: {f}\n", .{response.physical_base});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("virtual_base: {f}\n", .{response.virtual_base});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
            return response.print(writer, 0);
        }
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

        pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
            try writer.print("DeviceTreeBlob({f})", .{response.address});
        }
    };
};

pub const BootloaderPerformance = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x6b50ad9bf36d13ad, 0xdc4c7e88fc759e17 },
    revision: u64 = 0,

    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        /// Time of system reset in microseconds relative to an arbitrary point in the past.
        reset_usec: u64,

        /// Time of bootloader initialisation in microseconds relative to an arbitrary point in the past.
        init_usec: u64,

        /// Time of executable handoff in microseconds relative to an arbitrary point in the past.
        exec_usec: u64,

        pub fn print(response: *const Response, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("BootloaderPerformance{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("reset_usec: {}\n", .{response.reset_usec});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("init_usec: {}\n", .{response.init_usec});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("exec_usec: {}\n", .{response.exec_usec});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
            return response.print(writer, 0);
        }
    };
};

pub const File = extern struct {
    revision: u64,

    /// The address of the file. This is always at least 4KiB aligned.
    address: core.VirtualAddress,

    /// The size of the file.
    ///
    /// Regardless of the file size, all loaded modules are guaranteed to have all 4KiB chunks of memory they cover for
    /// themselves exclusively.
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
    pub fn path(file: *const File) [:0]const u8 {
        return std.mem.sliceTo(file._path, 0);
    }

    /// A string associated with the file
    pub fn string(file: *const File) ?[:0]const u8 {
        const str = std.mem.sliceTo(
            file._string orelse return null,
            0,
        );
        return if (str.len == 0) null else str;
    }

    pub fn getContents(file: *const File) []const u8 {
        return core.VirtualRange.fromAddr(file.address, file.size).toByteSlice();
    }

    pub fn print(file: *const File, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("File{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("path: \"{s}\"\n", .{file.path()});

        if (file.string()) |s| {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("string: \"{s}\"\n", .{s});
        }

        try writer.splatByteAll(' ', new_indent);
        try writer.print("address: {f}\n", .{file.address});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("size: {f}\n", .{file.size});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("media_type: {t}\n", .{file.media_type});

        if (file.tftp_ip != 0) {
            try writer.splatByteAll(' ', new_indent);
            try writer.writeAll("tftp: ");
            try formatIP(file.tftp_ip, file.tftp_port, writer);
            try writer.writeByte('\n');
        }

        if (file.partition_index != 0) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("partition_index: {}\n", .{file.partition_index});
        }

        if (file.mbr_disk_id != 0) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("mbr_disk_id: {}\n", .{file.mbr_disk_id});
        }

        if (!file.gpt_disk_uuid.eql(.nil)) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("gpt_disk_uuid: {f}\n", .{file.gpt_disk_uuid});
        }

        if (!file.gpt_part_uuid.eql(.nil)) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("gpt_part_uuid: {f}\n", .{file.gpt_part_uuid});
        }

        if (!file.part_uuid.eql(.nil)) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("part_uuid: {f}\n", .{file.part_uuid});
        }

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    fn formatIP(ip: u32, port: u32, writer: *std.Io.Writer) !void {
        const bytes: *const [4]u8 = @ptrCast(&ip);
        try writer.print("{}.{}.{}.{}:{}", .{
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            port,
        });
    }

    pub inline fn format(file: *const File, writer: *std.Io.Writer) !void {
        return File.print(file, writer, 0);
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
