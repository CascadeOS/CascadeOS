// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A library for reading ELF files.
//!
//! The design of this library is constrained by its usage in the kernel, meaning it does not support file readers nor
//! being given the full ELF file as a slice and instead requires the caller to perfrom all read operations then pass the data
//! in to be parsed.
//!
//! [ELF Object File Format Version 4.3 DRAFT](https://gabi.xinuos.com/)

const std = @import("std");
const builtin = @import("builtin");

pub const Header = struct {
    is_64: bool,
    endian: std.builtin.Endian,

    /// Object file type.
    type: ObjectType,

    /// The required architecture.
    machine: Machine,

    /// The virtual address to which the system first transfers control, thus starting the process.
    ///
    /// Zero if the file has no associated entry point.
    entry: u64,

    /// The program header tables file offset in bytes.
    ///
    /// Zero if the file has no program header table.
    program_header_offset: u64,

    /// Size in bytes of one entry in the program header table.
    program_header_entry_size: u16,

    /// The number of entries in the program header table.
    program_header_entry_count: u16,

    /// The section header tables file offset in bytes.
    ///
    /// Zero if the file has no section header table.
    section_header_offset: u64,

    /// Size in bytes of one entry in the section header table.
    section_header_entry_size: u16,

    /// The number of entries in the section header table.
    section_header_entry_count: u16,

    /// Section header table index of the entry associated with the section name string table.
    section_name_string_table_index: u16,

    pub const ParseError = error{
        InvalidMagic,
        InvalidVersion,
        InvalidEndian,
        InvalidClass,
    };

    /// Parse the given slice into an ELF header.
    ///
    /// The slice must be atleast 64 bytes long.
    pub fn parse(elf_header_slice: []const u8) ParseError!Header {
        if (builtin.mode == .Debug) std.debug.assert(elf_header_slice.len >= 64);

        const ident: HeaderIdent = .from(elf_header_slice);
        if (!std.mem.eql(u8, ident.magic(), HeaderIdent.MAGIC)) return error.InvalidMagic;
        if (ident.version() != .current) return error.InvalidVersion;

        const endian: std.builtin.Endian = switch (ident.endian()) {
            .little => .little,
            .big => .big,
            else => return error.InvalidEndian,
        };

        const is_64: bool = switch (ident.class()) {
            .@"32" => false,
            .@"64" => true,
            else => return error.InvalidClass,
        };

        return if (is_64)
            innerParse(elf_header_slice, true, endian)
        else
            innerParse(elf_header_slice, false, endian);
    }

    fn innerParse(elf_header_slice: []const u8, comptime is_64: bool, endian: std.builtin.Endian) ParseError!Header {
        const HeaderT = if (is_64) RawElf64Header else RawElf32Header;
        const FileOffset = if (is_64) u64 else u32;
        const raw_elf_header: *align(1) const HeaderT = std.mem.bytesAsValue(HeaderT, elf_header_slice);

        return .{
            .is_64 = is_64,
            .endian = endian,
            .type = @enumFromInt(std.mem.toNative(u16, raw_elf_header.e_type, endian)),
            .machine = @enumFromInt(std.mem.toNative(u16, raw_elf_header.e_machine, endian)),
            .entry = std.mem.toNative(FileOffset, raw_elf_header.e_entry, endian),
            .program_header_offset = std.mem.toNative(FileOffset, raw_elf_header.e_phoff, endian),
            .program_header_entry_size = std.mem.toNative(u16, raw_elf_header.e_phentsize, endian),
            .program_header_entry_count = std.mem.toNative(u16, raw_elf_header.e_phnum, endian),
            .section_header_offset = std.mem.toNative(FileOffset, raw_elf_header.e_shoff, endian),
            .section_header_entry_size = std.mem.toNative(u16, raw_elf_header.e_shentsize, endian),
            .section_header_entry_count = std.mem.toNative(u16, raw_elf_header.e_shnum, endian),
            .section_name_string_table_index = std.mem.toNative(u16, raw_elf_header.e_shstrndx, endian),
        };
    }

    pub const TableLocation = struct {
        base: u64,
        length: u32, // as number and size of entries are both u16 the length cannot be larger than u32
    };

    pub fn programHeaderTableLocation(header: *const Header) TableLocation {
        return .{
            .base = header.program_header_offset,
            .length = header.program_header_entry_count * header.program_header_entry_size,
        };
    }

    /// Iterates over the program header table.
    ///
    /// The provided slice must match the location and size given by `programHeaderTableLocation`.
    pub fn iterateProgramHeaders(header: *const Header, program_header_table_slice: []const u8) ProgramHeader.Iterator {
        if (builtin.mode == .Debug) std.debug.assert(
            program_header_table_slice.len >= header.program_header_entry_count * header.program_header_entry_size,
        );

        return .{
            .header = header,
            .program_header_table_slice = program_header_table_slice,
        };
    }

    pub fn print(header: *const Header, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("Header{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("is_64: {},\n", .{header.is_64});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("endian: {t},\n", .{header.endian});

        try writer.splatByteAll(' ', new_indent);
        switch (header.type) {
            _ => |value| try writer.print("type: 0x{x},\n", .{value}),
            else => |tag| try writer.print("type: {t},\n", .{tag}),
        }

        try writer.splatByteAll(' ', new_indent);
        switch (header.machine) {
            _ => |value| try writer.print("machine: 0x{x},\n", .{value}),
            else => |tag| try writer.print("machine: {t},\n", .{tag}),
        }

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry: 0x{x},\n", .{header.entry});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("program_header_offset: 0x{x},\n", .{header.program_header_offset});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("program_header_entry_size: 0x{x},\n", .{header.program_header_entry_size});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("program_header_entry_count: {},\n", .{header.program_header_entry_count});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("section_header_offset: 0x{x},\n", .{header.section_header_offset});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("section_header_entry_size: 0x{x},\n", .{header.section_header_entry_size});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("section_header_entry_count: {},\n", .{header.section_header_entry_count});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("section_name_string_table_index: {},\n", .{header.section_name_string_table_index});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub fn format(header: *const Header, writer: *std.Io.Writer) !void {
        return header.print(writer, 0);
    }

    const RawElf64Header = extern struct {
        e_ident: HeaderIdent,
        e_type: u16,
        e_machine: u16,
        e_version: u32,
        e_entry: u64,
        e_phoff: u64,
        e_shoff: u64,
        e_flags: u32,
        e_ehsize: u16,
        e_phentsize: u16,
        e_phnum: u16,
        e_shentsize: u16,
        e_shnum: u16,
        e_shstrndx: u16,
    };

    const RawElf32Header = extern struct {
        e_ident: HeaderIdent,
        e_type: u16,
        e_machine: u16,
        e_version: u32,
        e_entry: u32,
        e_phoff: u32,
        e_shoff: u32,
        e_flags: u32,
        e_ehsize: u16,
        e_phentsize: u16,
        e_phnum: u16,
        e_shentsize: u16,
        e_shnum: u16,
        e_shstrndx: u16,
    };
};

pub const ProgramHeader = struct {
    /// What kind of segment this describes or how to interpret the information.
    type: Type,

    flags: Flags,

    /// The offset from the beginning of the file at which the first byte of the segment resides.
    offset: u64,

    /// The number of bytes in the file image of the segment; it may be zero.
    file_size: u64,

    /// The virtual address at which the first byte of the segment resides in memory.
    virtual_address: u64,

    /// On systems for which physical addressing is relevant, this member is reserved for the segment’s physical address.
    ///
    /// Because System V ignores physical addressing for application programs, this member has unspecified contents for
    /// executable files and shared objects.
    physical_address: u64,

    /// The number of bytes in the memory image of the segment; it may be zero.
    memory_size: u64,

    /// Loadable process segments must have congruent values for `virtual_address` and `offset`, modulo the page size.
    ///
    /// This member gives the value to which the segments are aligned in memory and in the file.
    ///
    /// Values 0 and 1 mean no alignment is required.
    ///
    /// Otherwise, `alignment` should be a positive, integral power of 2, and `virtual_address` should equal `offset`
    /// modulo `alignment`.
    alignment: u64,

    pub const Iterator = struct {
        header: *const Header,
        index: usize = 0,
        program_header_table_slice: []const u8,

        pub fn reset(it: *Iterator) void {
            it.index = 0;
        }

        pub fn next(it: *Iterator) ?ProgramHeader {
            const index = it.index;
            const header = it.header;
            if (index >= header.program_header_entry_count) return null;
            defer it.index += 1;

            var reader: std.Io.Reader = .fixed(it.program_header_table_slice[header.program_header_entry_size * index ..]);

            if (header.is_64) {
                const raw_header = reader.takeStruct(
                    RawElf64ProgramHeader,
                    header.endian,
                ) catch unreachable; // `iterateProgramHeaders` ensures the slice is long enough

                return .{
                    .type = @enumFromInt(raw_header.p_type),
                    .flags = @bitCast(raw_header.p_flags),
                    .offset = raw_header.p_offset,
                    .virtual_address = raw_header.p_vaddr,
                    .physical_address = raw_header.p_paddr,
                    .file_size = raw_header.p_filesz,
                    .memory_size = raw_header.p_memsz,
                    .alignment = raw_header.p_align,
                };
            } else {
                const raw_header = reader.takeStruct(
                    RawElf32ProgramHeader,
                    header.endian,
                ) catch unreachable; // `iterateProgramHeaders` ensures the slice is long enough

                return .{
                    .type = @enumFromInt(raw_header.p_type),
                    .flags = @bitCast(raw_header.p_flags),
                    .offset = raw_header.p_offset,
                    .virtual_address = raw_header.p_vaddr,
                    .physical_address = raw_header.p_paddr,
                    .file_size = raw_header.p_filesz,
                    .memory_size = raw_header.p_memsz,
                    .alignment = raw_header.p_align,
                };
            }
        }
    };

    pub const Type = enum(u32) {
        /// The array element is unused; other members values are undefined.
        ///
        /// This type lets the program header table have ignored entries.
        null = 0,

        /// The array element specifies a loadable segment, described by `file_size` and `mem_size`.
        ///
        /// The bytes from the file are mapped to the beginning of the memory segment.
        ///
        /// If the segment’s memory size (`mem_size`) is larger than the file size (`file_size`), the "extra" bytes are
        /// defined to hold the value 0 and to follow the segment's initialized area.
        ///
        /// The file size may not be larger than the memory size.
        ///
        /// Loadable segment entries in the program header table appear in ascending order, sorted on the
        /// `virtual_address` member.
        load = 1,

        /// The array element specifies dynamic linking information.
        dynamic = 2,

        /// The array element specifies the location and size of a null-terminated path name to invoke as an interpreter.
        ///
        /// This segment type is meaningful only for executable files (though it may occur for shared objects); it may
        /// not occur more than once in a file.
        ///
        /// If it is present, it must precede any loadable segment entry.
        interpreter = 3,

        /// The array element specifies the location and size of auxiliary information.
        note = 4,

        /// This segment type is reserved but has unspecified semantics.
        ///
        /// Programs that contain an array element of this type do not conform to the ABI.
        shlib = 5,

        /// The array element, if present, specifies the location and size of the program header table itself, both in
        /// the file and in the memory image of the program.
        ///
        /// This segment type may not occur more than once in a file. Moreover, it may occur only if the program header
        /// table is part of the memory image of the program.
        ///
        /// If it is present, it must precede any loadable segment entry.
        phdr = 6,

        /// The array element specifies the Thread-Local Storage template.
        ///
        /// Implementations need not support this program table entry.
        tls = 7,

        _,

        /// Beginning of OS-specific types
        pub const LOOS = 0x60000000;

        /// End of OS-specific types
        pub const HIOS = 0x6fffffff;

        /// Beginning of processor-specific types
        pub const LOPROC = 0x70000000;

        /// End of processor-specific types
        pub const HIPROC = 0x7fffffff;
    };

    pub const Flags = packed struct(u32) {
        execute: bool,
        write: bool,
        read: bool,

        _reserved: u29,

        /// All bits included in the `MASKOS` mask are reserved for operating system-specific semantics.
        pub const MASKOS: u32 = 0x0ff00000;

        /// All bits included in the `MASKPROC` mask are reserved for processor-specific semantics.
        ///
        /// If meanings are specified, the psABI supplement explains them.
        pub const MASKPROC: u32 = 0xf0000000;

        pub fn print(flags: *const Flags, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("Flags{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("execute: {},\n", .{flags.execute});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("write: {},\n", .{flags.write});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("read: {},\n", .{flags.read});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub fn format(flags: *const Flags, writer: *std.Io.Writer) !void {
            return flags.print(writer, 0);
        }
    };

    pub fn print(program_header: *const ProgramHeader, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("ProgramHeader{\n");

        try writer.splatByteAll(' ', new_indent);
        switch (program_header.type) {
            _ => |value| try writer.print("type: 0x{x},\n", .{value}),
            else => |tag| try writer.print("type: {t},\n", .{tag}),
        }

        try writer.splatByteAll(' ', new_indent);
        try writer.print("flags: ", .{});
        try program_header.flags.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("offset: 0x{x},\n", .{program_header.offset});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("file_size: 0x{x},\n", .{program_header.file_size});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("virtual_address: 0x{x},\n", .{program_header.virtual_address});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("physical_address: 0x{x},\n", .{program_header.physical_address});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("memory_size: 0x{x},\n", .{program_header.memory_size});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("alignment: 0x{x},\n", .{program_header.alignment});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub fn format(program_header: *const ProgramHeader, writer: *std.Io.Writer) !void {
        return program_header.print(writer, 0);
    }

    const RawElf32ProgramHeader = extern struct {
        p_type: u32,
        p_offset: u32,
        p_vaddr: u32,
        p_paddr: u32,
        p_filesz: u32,
        p_memsz: u32,
        p_flags: u32,
        p_align: u32,
    };

    const RawElf64ProgramHeader = extern struct {
        p_type: u32,
        p_flags: u32,
        p_offset: u64,
        p_vaddr: u64,
        p_paddr: u64,
        p_filesz: u64,
        p_memsz: u64,
        p_align: u64,
    };
};

pub const ObjectType = enum(u16) {
    none = 0,
    relocatable = 1,
    executable = 2,
    shared = 3,
    core = 4,

    _,

    /// Beginning of OS-specific codes
    pub const LOOS = 0xfe00;

    /// End of OS-specific codes
    pub const HIOS = 0xfeff;

    /// Beginning of processor-specific codes
    pub const LOPROC = 0xff00;

    /// End of processor-specific codes
    pub const HIPROC = 0xffff;
};

pub const Machine = enum(u16) {
    /// No machine
    NONE = 0,
    /// AT&T WE 32100
    M32 = 1,
    /// SPARC
    SPARC = 2,
    /// Intel 80386
    @"386" = 3,
    /// Motorola 68000
    @"68K" = 4,
    /// Motorola 88000
    @"88K" = 5,
    /// Intel MCU
    IAMCU = 6,
    /// Intel 80860
    @"860" = 7,
    /// MIPS I Architecture
    MIPS = 8,
    /// IBM System/370 Processor
    S370 = 9,
    /// MIPS RS3000 Little-endian
    MIPS_RS3_LE = 10,
    /// Hewlett-Packard PA-RISC
    PARISC = 15,
    /// Fujitsu VPP500
    VPP500 = 17,
    /// Enhanced instruction set SPARC
    SPARC32PLUS = 18,
    /// Intel 80960
    @"960" = 19,
    /// PowerPC
    PPC = 20,
    /// 64-bit PowerPC
    PPC64 = 21,
    /// IBM System/390 Processor
    S390 = 22,
    /// IBM SPU/SPC
    SPU = 23,
    /// NEC V800
    V800 = 36,
    /// Fujitsu FR20
    FR20 = 37,
    /// TRW RH-32
    RH32 = 38,
    /// Motorola RCE
    RCE = 39,
    /// ARM 32-bit architecture (AARCH32)
    ARM = 40,
    /// Digital Alpha
    OLD_ALPHA = 41,
    /// Hitachi SH
    SH = 42,
    /// SPARC Version 9
    SPARCV9 = 43,
    /// Siemens TriCore embedded processor
    TRICORE = 44,
    /// Argonaut RISC Core, Argonaut Technologies Inc.
    ARC = 45,
    /// Hitachi H8/300
    H8_300 = 46,
    /// Hitachi H8/300H
    H8_300H = 47,
    /// Hitachi H8S
    H8S = 48,
    /// Hitachi H8/500
    H8_500 = 49,
    /// Intel IA-64 processor architecture
    IA_64 = 50,
    /// Stanford MIPS-X
    MIPS_X = 51,
    /// Motorola ColdFire
    COLDFIRE = 52,
    /// Motorola M68HC12
    @"68HC12" = 53,
    /// Fujitsu MMA Multimedia Accelerator
    MMA = 54,
    /// Siemens PCP
    PCP = 55,
    /// Sony nCPU embedded RISC processor
    NCPU = 56,
    /// Denso NDR1 microprocessor
    NDR1 = 57,
    /// Motorola Star*Core processor
    STARCORE = 58,
    /// Toyota ME16 processor
    ME16 = 59,
    /// STMicroelectronics ST100 processor
    ST100 = 60,
    /// Advanced Logic Corp. TinyJ embedded processor family
    TINYJ = 61,
    /// AMD x86-64 architecture
    X86_64 = 62,
    /// Sony DSP Processor
    PDSP = 63,
    /// Digital Equipment Corp. PDP-10
    PDP10 = 64,
    /// Digital Equipment Corp. PDP-11
    PDP11 = 65,
    /// Siemens FX66 microcontroller
    FX66 = 66,
    /// STMicroelectronics ST9+ 8/16 bit microcontroller
    ST9PLUS = 67,
    /// STMicroelectronics ST7 8-bit microcontroller
    ST7 = 68,
    /// Motorola MC68HC16 Microcontroller
    @"68HC16" = 69,
    /// Motorola MC68HC11 Microcontroller
    @"68HC11" = 70,
    /// Motorola MC68HC08 Microcontroller
    @"68HC08" = 71,
    /// Motorola MC68HC05 Microcontroller
    @"68HC05" = 72,
    /// Silicon Graphics SVx
    SVX = 73,
    /// STMicroelectronics ST19 8-bit microcontroller
    ST19 = 74,
    /// Digital VAX
    VAX = 75,
    /// Axis Communications 32-bit embedded processor
    CRIS = 76,
    /// Infineon Technologies 32-bit embedded processor
    JAVELIN = 77,
    /// Element 14 64-bit DSP Processor
    FIREPATH = 78,
    /// LSI Logic 16-bit DSP Processor
    ZSP = 79,
    /// Donald Knuth’s educational 64-bit processor
    MMIX = 80,
    /// Harvard University machine-independent object files
    HUANY = 81,
    /// SiTera Prism
    PRISM = 82,
    /// Atmel AVR 8-bit microcontroller
    AVR = 83,
    /// Fujitsu FR30
    FR30 = 84,
    /// Mitsubishi D10V
    D10V = 85,
    /// Mitsubishi D30V
    D30V = 86,
    /// NEC v850
    V850 = 87,
    /// Mitsubishi M32R
    M32R = 88,
    /// Matsushita MN10300
    MN10300 = 89,
    /// Matsushita MN10200
    MN10200 = 90,
    /// picoJava
    PJ = 91,
    /// OpenRISC 32-bit embedded processor
    OPENRISC = 92,
    /// ARC International ARCompact processor (old spelling/synonym: EM_ARC_A5)
    ARC_COMPACT = 93,
    /// Tensilica Xtensa Architecture
    XTENSA = 94,
    /// Alphamosaic VideoCore processor
    VIDEOCORE = 95,
    /// Thompson Multimedia General Purpose Processor
    TMM_GPP = 96,
    /// National Semiconductor 32000 series
    NS32K = 97,
    /// Tenor Network TPC processor
    TPC = 98,
    /// Trebia SNP 1000 processor
    SNP1K = 99,
    /// STMicroelectronics (www.st.com) ST200 microcontroller
    ST200 = 100,
    /// Ubicom IP2xxx microcontroller family
    IP2K = 101,
    /// MAX Processor
    MAX = 102,
    /// National Semiconductor CompactRISC microprocessor
    CR = 103,
    /// Fujitsu F2MC16
    F2MC16 = 104,
    /// Texas Instruments embedded microcontroller msp430
    MSP430 = 105,
    /// Analog Devices Blackfin (DSP) processor
    BLACKFIN = 106,
    /// S1C33 Family of Seiko Epson processors
    SE_C33 = 107,
    /// Sharp embedded microprocessor
    SEP = 108,
    /// Arca RISC Microprocessor
    ARCA = 109,
    /// Microprocessor series from PKU-Unity Ltd. and MPRC of Peking University
    UNICORE = 110,
    /// eXcess: 16/32/64-bit configurable embedded CPU
    EXCESS = 111,
    /// Icera Semiconductor Inc. Deep Execution Processor
    DXP = 112,
    /// Altera Nios II soft-core processor
    ALTERA_NIOS2 = 113,
    /// National Semiconductor CompactRISC CRX microprocessor
    CRX = 114,
    /// Motorola XGATE embedded processor
    XGATE = 115,
    /// Infineon C16x/XC16x processor
    C166 = 116,
    /// Renesas M16C series microprocessors
    M16C = 117,
    /// Microchip Technology dsPIC30F Digital Signal Controller
    DSPIC30F = 118,
    /// Freescale Communication Engine RISC core
    CE = 119,
    /// Renesas M32C series microprocessors
    M32C = 120,
    /// Altium TSK3000 core
    TSK3000 = 131,
    /// Freescale RS08 embedded processor
    RS08 = 132,
    /// Analog Devices SHARC family of 32-bit DSP processors
    SHARC = 133,
    /// Cyan Technology eCOG2 microprocessor
    ECOG2 = 134,
    /// Sunplus S+core7 RISC processor
    SCORE7 = 135,
    /// New Japan Radio (NJR) 24-bit DSP Processor
    DSP24 = 136,
    /// Broadcom VideoCore III processor
    VIDEOCORE3 = 137,
    /// RISC processor for Lattice FPGA architecture
    LATTICEMICO32 = 138,
    /// Seiko Epson C17 family
    SE_C17 = 139,
    /// The Texas Instruments TMS320C6000 DSP family
    TI_C6000 = 140,
    /// The Texas Instruments TMS320C2000 DSP family
    TI_C2000 = 141,
    /// The Texas Instruments TMS320C55x DSP family
    TI_C5500 = 142,
    /// Texas Instruments Application Specific RISC Processor, 32bit fetch
    TI_ARP32 = 143,
    /// Texas Instruments Programmable Realtime Unit
    TI_PRU = 144,
    /// STMicroelectronics 64bit VLIW Data Signal Processor
    MMDSP_PLUS = 160,
    /// Cypress M8C microprocessor
    CYPRESS_M8C = 161,
    /// Renesas R32C series microprocessors
    R32C = 162,
    /// NXP Semiconductors TriMedia architecture family
    TRIMEDIA = 163,
    /// QUALCOMM DSP6 Processor
    QDSP6 = 164,
    /// Intel 8051 and variants
    @"8051" = 165,
    /// STMicroelectronics STxP7x family of configurable and extensible RISC processors
    STXP7X = 166,
    /// Andes Technology compact code size embedded RISC processor family
    NDS32 = 167,
    /// Cyan Technology eCOG1X family
    ECOG1 = 168,
    /// Dallas Semiconductor MAXQ30 Core Micro-controllers
    MAXQ30 = 169,
    /// New Japan Radio (NJR) 16-bit DSP Processor
    XIMO16 = 170,
    /// M2000 Reconfigurable RISC Microprocessor
    MANIK = 171,
    /// Cray Inc. NV2 vector architecture
    CRAYNV2 = 172,
    /// Renesas RX family
    RX = 173,
    /// Imagination Technologies META processor architecture
    METAG = 174,
    /// MCST Elbrus general purpose hardware architecture
    MCST_ELBRUS = 175,
    /// Cyan Technology eCOG16 family
    ECOG16 = 176,
    /// National Semiconductor CompactRISC CR16 16-bit microprocessor
    CR16 = 177,
    /// Freescale Extended Time Processing Unit
    ETPU = 178,
    /// Infineon Technologies SLE9X core
    SLE9X = 179,
    /// Intel L10M
    L10M = 180,
    /// Intel K10M
    K10M = 181,
    /// ARM 64-bit architecture (AARCH64)
    AARCH64 = 183,
    /// Atmel Corporation 32-bit microprocessor family
    AVR32 = 185,
    /// STMicroeletronics STM8 8-bit microcontroller
    STM8 = 186,
    /// Tilera TILE64 multicore architecture family
    TILE64 = 187,
    /// Tilera TILEPro multicore architecture family
    TILEPRO = 188,
    /// Xilinx MicroBlaze 32-bit RISC soft processor core
    MICROBLAZE = 189,
    /// NVIDIA CUDA architecture
    CUDA = 190,
    /// Tilera TILE-Gx multicore architecture family
    TILEGX = 191,
    /// CloudShield architecture family
    CLOUDSHIELD = 192,
    /// KIPO-KAIST Core-A 1st generation processor family
    COREA_1ST = 193,
    /// KIPO-KAIST Core-A 2nd generation processor family
    COREA_2ND = 194,
    /// Synopsys ARCompact V2
    ARC_COMPACT2 = 195,
    /// Open8 8-bit RISC soft processor core
    OPEN8 = 196,
    /// Renesas RL78 family
    RL78 = 197,
    /// Broadcom VideoCore V processor
    VIDEOCORE5 = 198,
    /// Renesas 78KOR family
    @"78KOR" = 199,
    /// Freescale 56800EX Digital Signal Controller (DSC)
    @"56800EX" = 200,
    /// Beyond BA1 CPU architecture
    BA1 = 201,
    /// Beyond BA2 CPU architecture
    BA2 = 202,
    /// XMOS xCORE processor family
    XCORE = 203,
    /// Microchip 8-bit PIC(r) family
    MCHP_PIC = 204,
    /// Reserved by Intel
    INTEL205 = 205,
    /// Reserved by Intel
    INTEL206 = 206,
    /// Reserved by Intel
    INTEL207 = 207,
    /// Reserved by Intel
    INTEL208 = 208,
    /// Reserved by Intel
    INTEL209 = 209,
    /// KM211 KM32 32-bit processor
    KM32 = 210,
    /// KM211 KMX32 32-bit processor
    KMX32 = 211,
    /// KM211 KMX16 16-bit processor
    KMX16 = 212,
    /// KM211 KMX8 8-bit processor
    KMX8 = 213,
    /// KM211 KVARC processor
    KVARC = 214,
    /// Paneve CDP architecture family
    CDP = 215,
    /// Cognitive Smart Memory Processor
    COGE = 216,
    /// Bluechip Systems CoolEngine
    COOL = 217,
    /// Nanoradio Optimized RISC
    NORC = 218,
    /// CSR Kalimba architecture family
    CSR_KALIMBA = 219,
    /// Zilog Z80
    Z80 = 220,
    /// Controls and Data Services VISIUMcore processor
    VISIUM = 221,
    /// FTDI Chip FT32 high performance 32-bit RISC architecture
    FT32 = 222,
    /// Moxie processor family
    MOXIE = 223,
    /// AMD GPU architecture
    AMDGPU = 224,
    /// RISC-V
    RISCV = 243,
    /// Lanai processor
    LANAI = 244,
    /// CEVA Processor Architecture Family
    CEVA = 245,
    /// CEVA X2 Processor Family
    CEVA_X2 = 246,
    /// Linux BPF – in-kernel virtual machine
    BPF = 247,
    /// Graphcore Intelligent Processing Unit
    GRAPHCORE_IPU = 248,
    /// Imagination Technologies
    IMG1 = 249,
    /// Netronome Flow Processor (NFP)
    NFP = 250,
    /// NEC Vector Engine
    VE = 251,
    /// C-SKY processor family
    CSKY = 252,
    /// Synopsys ARCv2.3 64-bit
    ARC_COMPACT3_64 = 253,
    /// MOS Technology MCS 6502 processor
    MCS6502 = 254,
    /// Synopsys ARCv2.3 32-bit
    ARC_COMPACT3 = 255,
    /// Kalray VLIW core of the MPPA processor family
    KVX = 256,
    /// WDC 65816/65C816
    @"65816" = 257,
    /// Loongson Loongarch
    LOONGARCH = 258,
    /// ChipON KungFu32
    KF32 = 259,
    /// LAPIS nX-U16/U8
    U16_U8CORE = 260,
    /// Reserved for Tachyum processor
    TACHYUM = 261,
    /// NXP 56800EF Digital Signal Controller (DSC)
    @"56800EF" = 262,
    /// Solana Bytecode Format
    SBF = 263,
    /// AMD/Xilinx AIEngine architecture
    AIENGINE = 264,
    /// SiMa MLA
    SIMA_MLA = 265,
    /// Cambricon BANG
    BANG = 266,
    /// Loongson LoongGPU
    LOONGGPU = 267,
    /// Wuxi Institute of Advanced Technology SW64
    SW64 = 268,
    /// AMD/Xilinx AIEngine ctrlcode
    AIECTRLCODE = 269,

    // Above here was taken from https://gabi.xinuos.com/elf/a-emachine.html
    //
    // Below here are additional values present in `std.elf.EM`

    /// AVR
    AVR_OLD = 0x1057,
    /// MSP430
    MSP430_OLD = 0x1059,
    /// Morpho MT
    MT = 0x2530,
    /// FR30
    CYGNUS_FR30 = 0x3330,
    /// WebAssembly (as used by LLVM)
    WEBASSEMBLY = 0x4157,
    /// Infineon Technologies 16-bit microcontroller with C166-V2 core
    XC16X = 0x4688,
    /// Freescale S12Z
    S12Z = 0x4def,
    /// DLX
    DLX = 0x5aa5,
    /// FRV
    CYGNUS_FRV = 0x5441,
    /// D10V
    CYGNUS_D10V = 0x7650,
    /// D30V
    CYGNUS_D30V = 0x7676,
    /// Ubicom IP2xxx
    IP2K_OLD = 0x8217,
    /// Cygnus PowerPC ELF
    CYGNUS_POWERPC = 0x9025,
    /// Alpha
    ALPHA = 0x9026,
    /// Cygnus M32R ELF
    CYGNUS_M32R = 0x9041,
    /// V850
    CYGNUS_V850 = 0x9080,
    /// Old S/390
    S390_OLD = 0xa390,
    /// Old unofficial value for Xtensa
    XTENSA_OLD = 0xabc7,
    /// Xstormy16
    XSTORMY16 = 0xad45,
    /// MN10300
    CYGNUS_MN10300 = 0xbeef,
    /// MN10200
    CYGNUS_MN10200 = 0xdead,
    /// Renesas M32C and M16C
    M32C_OLD = 0xfeb0,
    /// Vitesse IQ2000
    IQ2000 = 0xfeba,
    /// NIOS
    NIOS32 = 0xfebb,
    /// Toshiba MeP
    CYGNUS_MEP = 0xf00d,
    /// Old unofficial value for Moxie
    MOXIE_OLD = 0xfeed,
    /// Old MicroBlaze
    MICROBLAZE_OLD = 0xbaab,
    /// Adapteva's Epiphany architecture
    ADAPTEVA_EPIPHANY = 0x1223,

    /// Parallax Propeller (P1)
    /// This value is an unofficial ELF value used in: https://github.com/parallaxinc/propgcc
    PROPELLER = 0x5072,

    /// Parallax Propeller 2 (P2)
    /// This value is an unofficial ELF value used in: https://github.com/ne75/llvm-project
    PROPELLER2 = 300,

    _,
};

pub const Version = enum(u32) {
    /// Invalid version
    none = 0,

    /// Current version
    current = 1,

    _,
};

pub const OSABI = enum(u8) {
    /// UNIX System V ABI
    NONE = 0,
    /// HP-UX operating system
    HPUX = 1,
    /// NetBSD
    NETBSD = 2,
    /// GNU (Hurd/Linux)
    GNU = 3,
    /// Solaris
    SOLARIS = 6,
    /// AIX
    AIX = 7,
    /// IRIX
    IRIX = 8,
    /// FreeBSD
    FREEBSD = 9,
    /// TRU64 UNIX
    TRU64 = 10,
    /// Novell Modesto
    MODESTO = 11,
    /// OpenBSD
    OPENBSD = 12,
    /// OpenVMS
    OPENVMS = 13,
    /// Hewlett-Packard Non-Stop Kernel
    NSK = 14,
    /// AROS
    AROS = 15,
    /// FenixOS
    FENIXOS = 16,
    /// Nuxi CloudABI
    CLOUDABI = 17,
    /// Stratus Technologies OpenVOS
    OPENVOS = 18,

    // Above here was taken from https://gabi.xinuos.com/elf/b-osabi.html
    //
    // Below here are additional values present in `std.elf.OSABI`

    /// NVIDIA CUDA architecture (not gABI assigned)
    CUDA = 51,
    /// AMD HSA Runtime (not gABI assigned)
    AMDGPU_HSA = 64,
    /// AMD PAL Runtime (not gABI assigned)
    AMDGPU_PAL = 65,
    /// AMD Mesa3D Runtime (not gABI assigned)
    AMDGPU_MESA3D = 66,
    /// ARM (not gABI assigned)
    ARM = 97,
    /// Standalone (embedded) application (not gABI assigned)
    STANDALONE = 255,

    _,
};

const HeaderIdent = extern struct {
    value: [header_ident_size]u8,

    inline fn from(slice: []const u8) HeaderIdent {
        return .{ .value = slice[0..header_ident_size].* };
    }

    const MAGIC = "\x7fELF";

    fn magic(self: *const HeaderIdent) []const u8 {
        return self.value[0..4];
    }

    fn class(self: *const HeaderIdent) Class {
        return @enumFromInt(self.value[4]);
    }

    fn endian(self: *const HeaderIdent) Endian {
        return @enumFromInt(self.value[5]);
    }

    fn version(self: *const HeaderIdent) Version {
        return @enumFromInt(self.value[6]);
    }

    fn osABI(self: *const HeaderIdent) OSABI {
        return @enumFromInt(self.value[7]);
    }

    fn abiVersion(self: *const HeaderIdent) u8 {
        return self.value[8];
    }

    const Class = enum(u8) {
        none = 0,
        @"32" = 1,
        @"64" = 2,
    };

    const Endian = enum(u8) {
        none = 0,
        little = 1,
        big = 2,
    };

    const header_ident_size = 16;
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
