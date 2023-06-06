// SPDX-License-Identifier: MIT

//! This module contains the definitions of the Limine protocol.
//! https://github.com/limine-bootloader/limine/blob/v4.x-branch/PROTOCOL.md
//! 0c66863d3e041cd6da63cb2474333aa655966fe5

const std = @import("std");

const LIMINE_COMMON_MAGIC = [_]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

pub const BootloaderInfo = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0xf55038d8e2a1202f, 0x279426fcf5f59740 },
    revision: u64 = 0,
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        name: [*:0]const u8,
        version: [*:0]const u8,

        pub fn getName(self: *const Response) [:0]const u8 {
            return std.mem.sliceTo(self.name, 0);
        }

        pub fn getVersion(self: *const Response) [:0]const u8 {
            return std.mem.sliceTo(self.version, 0);
        }
    };
};

pub const StackSize = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x224ef0460a8e8926, 0xe1cb0fc25f46ea3d },
    revision: u64 = 0,
    response: ?*const Response = null,

    /// The requested stack size (also used for SMP processors).
    stack_size: u64,

    pub const Response = extern struct {
        revision: u64,
    };
};

pub const HHDM = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    revision: u64 = 0,
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        offset: u64,
    };
};

// TODO: Limine's Terminal Feature is not implemented as it is not used by Cascade.

pub const Framebuffer = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    revision: u64 = 0,
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,

        framebuffer_count: u64,

        framebuffers: [*]const *const LimineFramebuffer,

        pub fn getFramebuffers(self: *const Response) []const *const LimineFramebuffer {
            return self.framebuffers[0..self.framebuffer_count];
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
        edid_size: u64,
        edid: [*]const u8,

        /// Only present in revision 1
        mode_count: u64,
        /// Only present in revision 1
        video_modes: [*]const *const VideoMode,

        pub fn getEdid(self: *const LimineFramebuffer) []const u8 {
            return self.edid[0..self.edid_size];
        }

        pub fn getVideoModes(self: *const LimineFramebuffer) []const *const VideoMode {
            return self.video_modes[0..self.mode_count];
        }

        comptime {
            std.debug.assert(10 * @sizeOf(u64) == @sizeOf(LimineFramebuffer));
            std.debug.assert(10 * @bitSizeOf(u64) == @bitSizeOf(LimineFramebuffer));
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
    };
};

/// The presence of this request will prompt the bootloader to turn on x86_64 5-level paging.
/// It will not be turned on if this request is not present.
/// If the response pointer is changed to a valid pointer, 5-level paging is engaged.
pub const Level5Paging = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x94469551da9b3192, 0xebe5e86db7382888 },
    revision: u64 = 0,
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
    };
};

/// The presence of this request will prompt the bootloader to bootstrap the secondary processors.
/// This will not be done if this request is not present.
pub const SMP = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x95a67b819a1b857e, 0xa0b61b723b6a73e0 },
    revision: u64 = 0,
    response: Response = .{ .x86_64 = null }, // it doesn't matter what tag we use here for the default value

    flags: Flags = .{},

    pub const Flags = packed struct {
        /// Use x2APIC if possible (x86_64-only)
        x2apic: u1 = 0,
        _: u63 = 0,

        comptime {
            std.debug.assert(@sizeOf(u64) == @sizeOf(Flags));
            std.debug.assert(@bitSizeOf(u64) == @bitSizeOf(Flags));
        }
    };

    pub const Response = extern union {
        x86_64: ?*const Response_x86_64,
    };

    pub const Response_x86_64 = extern struct {
        revision: u64,
        flags: ResponseFlags,
        /// The Local APIC ID of the bootstrap processor.
        bsp_lapic_id: u32,
        /// How many CPUs are present. It includes the bootstrap processor.
        cpu_count: u64,
        cpus: [*]const *SMPInfo_x86_64,

        pub const ResponseFlags = packed struct {
            /// X2APIC has been enabled
            x2apic_enabled: u1 = 0,
            _: u31 = 0,

            comptime {
                std.debug.assert(@sizeOf(u32) == @sizeOf(ResponseFlags));
                std.debug.assert(@bitSizeOf(u32) == @bitSizeOf(ResponseFlags));
            }
        };

        pub fn getCpus(self: *const Response) []const *SMPInfo_x86_64 {
            return self.cpus[0..self.cpu_count];
        }
    };

    pub const SMPInfo_x86_64 = extern struct {
        /// ACPI Processor UID as specified by the MADT
        processor_id: u32,
        /// Local APIC ID of the processor as specified by the MADT
        lapic_id: u32,
        reserved: u64,
        /// An atomic write to this field causes the parked CPU to jump to the written address,
        /// on a 64KiB (or Stack Size Request size) stack.
        ///
        /// A pointer to the `SMPInfo` structure of the CPU is passed in RDI.
        /// Other than that, the CPU state will be the same as described for the bootstrap processor.
        /// This field is unused for the structure describing the bootstrap processor.
        /// For all CPUs, this field is guaranteed to be `null` when control is first passed to the bootstrap
        /// processor.
        goto_address: ?*const fn (smp_info: *const SMPInfo_x86_64) callconv(.C) noreturn,
        /// A free for use field
        extra_argument: u64,
    };

    pub const Response_aarch64 = extern struct {
        revision: u64,
        /// Always zero.
        flags: u32,
        /// MPIDR of the bootstrap processor (as read from MPIDR_EL1, with Res1 masked off).
        bsp_mpidr: u64,
        /// How many CPUs are present. It includes the bootstrap processor.
        cpu_count: u64,
        cpus: [*]const *SMPInfo_aarch64,

        pub fn getCpus(self: *const Response) []const *SMPInfo_aarch64 {
            return self.cpus[0..self.cpu_count];
        }
    };

    pub const SMPInfo_aarch64 = extern struct {
        /// ACPI Processor UID as specified by the MADT
        processor_id: u32,
        /// GIC CPU Interface number of the processor as specified by the MADT (possibly always 0)
        gic_iface_no: u32,
        /// MPIDR of the processor as specified by the MADT or device tree
        mpidr: u64,
        /// An atomic write to this field causes the parked CPU to jump to the written address,
        /// on a 64KiB (or Stack Size Request size) stack
        ///
        /// A pointer to the `SMPInfo` structure of the CPU is passed in X0.
        /// Other than that, the CPU state will be the same as described for the bootstrap processor.
        /// This field is unused for the structure describing the bootstrap processor.
        goto_address: ?*const fn (smp_info: *const SMPInfo_aarch64) callconv(.C) noreturn,
        /// A free for use field
        extra_argument: u64,
    };
};

/// Memory between 0 and 0x1000 is never marked as usable memory.
/// The kernel and modules loaded are not marked as usable memory. They are marked as Kernel/Modules.
/// The entries are guaranteed to be sorted by base address, lowest to highest.
/// Usable and bootloader reclaimable entries are guaranteed to be 4096 byte aligned for both base and length.
/// Usable and bootloader reclaimable entries are guaranteed not to overlap with any other entry.
/// To the contrary, all non-usable entries (including kernel/modules) are not guaranteed any alignment,
/// nor is it guaranteed that they do not overlap other entries.
pub const Memmap = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    revision: u64 = 0,
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        entry_count: u64,
        entries: [*]const *const Entry,

        pub fn getEntries(self: *const Response) []const *const Entry {
            return self.entries[0..self.entry_count];
        }

        pub fn getEntry(self: *const Response, index: usize) ?*const Entry {
            if (index >= self.entry_count) return null;
            return self.entries[index];
        }
    };

    pub const Entry = extern struct {
        /// Physical address of the base of the memory section
        base: u64,
        /// Length of the memory section
        length: u64,
        memmap_type: Type,

        pub const Type = enum(u64) {
            usable = 0,
            reserved = 1,
            acpi_reclaimable = 2,
            acpi_nvs = 3,
            bad_memory = 4,
            bootloader_reclaimable = 5,
            kernel_and_modules = 6,
            framebuffer = 7,
        };
    };
};

pub const EntryPoint = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x13d86c035a1cd3e1, 0x2b0caa89d8f3026a },
    revision: u64 = 0,
    response: ?*const Response = null,
    entry: ?*const fn () callconv(.Naked) noreturn,

    pub const Response = extern struct {
        revision: u64,
    };
};

pub const KernelFile = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0xad97e90e83f1ed67, 0x31eb5d1c5ff23b69 },
    revision: u64 = 0,
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        kernel_file: *File,
    };
};

pub const Module = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x3e7e279702be32af, 0xca1c4f3bd1280cee },
    revision: u64 = 0,
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        module_count: u64,
        modules: [*]const *const File,

        pub fn getModules(self: *const Response) []const *const File {
            return self.modules[0..self.module_count];
        }
    };
};

pub const File = extern struct {
    /// Revision of the `File` structure
    revision: u64,

    address: *anyopaque,
    size: u64,

    /// The path of the file within the volume, with a leading slash
    path: [*:0]const u8,
    /// A command line associated with the file
    cmdline: [*:0]const u8,

    media_type: MediaType,

    unused: u32,

    /// If non-0, this is the IP of the TFTP server the file was loaded from.
    tftp_ip: u32,
    /// Likewise, but port.
    tftp_port: u32,

    /// 1-based partition index of the volume from which the file was loaded. If 0, it means invalid or unpartitioned.
    partition_index: u32,

    /// If non-0, this is the ID of the disk the file was loaded from as reported in its MBR.
    mbr_disk_id: u32,

    /// If non-0, this is the UUID of the disk the file was loaded from as reported in its GPT.
    gpt_disk_uuid: LimineUUID,

    /// If non-0, this is the UUID of the partition the file was loaded from as reported in the GPT.
    gpt_part_uuid: LimineUUID,

    /// If non-0, this is the UUID of the filesystem of the partition the file was loaded from.
    part_uuid: LimineUUID,

    pub fn getPath(self: *const File) [:0]const u8 {
        return std.mem.sliceTo(self.path, 0);
    }

    pub fn getCmdline(self: *const File) [:0]const u8 {
        return std.mem.sliceTo(self.cmdline, 0);
    }

    pub fn getContents(self: *const File) []const u8 {
        return @ptrCast([*]const u8, self.address)[0..self.size];
    }

    pub const MediaType = enum(u32) {
        generic = 0,
        optical = 1,
        tftp = 2,
    };

    pub const LimineUUID = extern struct {
        a: u32,
        b: u16,
        c: u16,
        d: [8]u8,
    };
};

pub const RSDP = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0xc5e77b6b397e7b43, 0x27637845accdcf3c },
    revision: u64 = 0,
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        address: *anyopaque,
    };
};

pub const SMBIOS = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x9e9046f11e095391, 0xaa4a520fefbde5ee },
    revision: u64 = 0,
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        /// Address of the 32-bit SMBIOS entry point. NULL if not present.
        entry_32: ?*anyopaque,
        /// Address of the 64-bit SMBIOS entry point. NULL if not present.
        entry_64: ?*anyopaque,
    };
};

pub const EFISystemTable = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x5ceba5163eaaf6d6, 0x0a6981610cf65fcc },
    revision: u64 = 0,
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        address: *anyopaque,
    };
};

pub const BootTime = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x502746e184c088aa, 0xfbc5ec83e6327893 },
    revision: u64 = 0,
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        /// The UNIX time on boot, in seconds, taken from the system RTC.
        boot_time: i64,
    };
};

pub const KernelAddress = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    revision: u64 = 0,
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        physical_base: u64,
        virtual_base: u64,
    };
};

pub const DeviceTreeBlob = extern struct {
    id: [4]u64 align(8) = LIMINE_COMMON_MAGIC ++ [_]u64{ 0xb40ddb48fb54bac7, 0x545081493f81ffb7 },
    revision: u64 = 0,
    /// Note: If the DTB cannot be found, the response will not be generated.
    response: ?*const Response = null,

    pub const Response = extern struct {
        revision: u64,
        /// Virtual pointer to the device tree blob.
        address: *anyopaque,
    };
};
