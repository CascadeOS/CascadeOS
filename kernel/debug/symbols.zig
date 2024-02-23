// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const sdf = @import("sdf");

var symbols_loaded: bool = false;
var symbol_loading_failed: bool = false;

var symbol_loading_spinlock: kernel.SpinLock = .{};

/// Valid if `symbols_loaded` is true.
// var sdf_memory: []const u8 = undefined;

/// Valid if `symbols_loaded` is true.
var sdf_string_table: sdf.StringTable = undefined;

/// Valid if `symbols_loaded` is true.
var sdf_file_table: sdf.FileTable = undefined;

/// Valid if `symbols_loaded` is true.
var sdf_location_lookup: sdf.LocationLookup = undefined;

/// Valid if `symbols_loaded` is true.
var sdf_location_program: sdf.LocationProgram = undefined;

pub fn loadSymbols() void {
    if (@atomicLoad(bool, &symbols_loaded, .Acquire)) return;
    if (@atomicLoad(bool, &symbol_loading_failed, .Acquire)) return;

    // If the processor has not yet been initialized, we can't acquire the spinlock.
    if (kernel.arch.earlyGetProcessor() == null) return;

    const held = symbol_loading_spinlock.lock();
    defer held.unlock();

    if (@atomicLoad(bool, &symbols_loaded, .Acquire)) return;
    if (@atomicLoad(bool, &symbol_loading_failed, .Acquire)) return;

    // SDF
    sdf_blk: {
        const kernel_file = kernel.info.kernel_file orelse break :sdf_blk;
        const kernel_file_slice = kernel_file.toSlice(u8) catch break :sdf_blk;

        var kernel_file_fbs = std.io.fixedBufferStream(kernel_file_slice);
        const reader = kernel_file_fbs.reader();

        const section_headers_offset, const str_section_offset, const number_of_sections, const is_64 = blk: {
            // read the elf header into a buffer
            var elf_header_backing_buffer: [@sizeOf(std.elf.Elf64_Ehdr)]u8 align(@alignOf(std.elf.Elf64_Ehdr)) = undefined;
            reader.readNoEof(&elf_header_backing_buffer) catch break :sdf_blk;

            const elf_header_elf32: *std.elf.Elf32_Ehdr = std.mem.bytesAsValue(std.elf.Elf32_Ehdr, &elf_header_backing_buffer);

            if (!std.mem.eql(u8, elf_header_elf32.e_ident[0..4], std.elf.MAGIC)) break :sdf_blk;
            if (elf_header_elf32.e_ident[std.elf.EI_VERSION] != 1) break :sdf_blk;

            if (elf_header_elf32.e_ident[std.elf.EI_DATA] != std.elf.ELFDATA2LSB) break :sdf_blk; // TODO: Support big endian

            const is_64: bool = switch (elf_header_elf32.e_ident[std.elf.EI_CLASS]) {
                std.elf.ELFCLASS32 => false,
                std.elf.ELFCLASS64 => true,
                else => break :sdf_blk,
            };

            const elf_header_elf64: *std.elf.Elf64_Ehdr = std.mem.bytesAsValue(std.elf.Elf64_Ehdr, &elf_header_backing_buffer);

            break :blk if (is_64)
                .{
                    elf_header_elf64.e_shoff,
                    elf_header_elf64.e_shoff + @as(u64, elf_header_elf64.e_shentsize) * @as(u64, elf_header_elf64.e_shstrndx),
                    elf_header_elf64.e_shnum,
                    is_64,
                }
            else
                .{
                    elf_header_elf32.e_shoff,
                    elf_header_elf32.e_shoff + @as(u64, elf_header_elf64.e_shentsize) * @as(u64, elf_header_elf64.e_shstrndx),
                    elf_header_elf32.e_shnum,
                    is_64,
                };
        };

        const size_of_section_header = if (is_64) @as(usize, @sizeOf(std.elf.Elf64_Shdr)) else @sizeOf(std.elf.Elf32_Shdr);

        const header_strings = blk: {
            var str_section_header_buffer: [@sizeOf(std.elf.Elf64_Shdr)]u8 align(@alignOf(std.elf.Elf64_Shdr)) = undefined;
            kernel_file_fbs.pos = str_section_offset;
            reader.readNoEof(str_section_header_buffer[0..size_of_section_header]) catch break :sdf_blk;

            if (is_64) {
                const str_section_header: *std.elf.Elf64_Shdr = std.mem.bytesAsValue(std.elf.Elf64_Shdr, &str_section_header_buffer);
                break :blk kernel_file_slice[str_section_header.sh_offset..][0..str_section_header.sh_size];
            } else {
                const str_section_header: *std.elf.Elf32_Shdr = std.mem.bytesAsValue(std.elf.Elf32_Shdr, &str_section_header_buffer);
                break :blk kernel_file_slice[str_section_header.sh_offset..][0..str_section_header.sh_size];
            }
        };

        const sdf_slice = sdf_slice: {
            var section_header_buffer: [@sizeOf(std.elf.Elf64_Shdr)]u8 align(@alignOf(std.elf.Elf64_Shdr)) = undefined;
            kernel_file_fbs.pos = section_headers_offset;

            for (0..number_of_sections) |_| {
                reader.readNoEof(section_header_buffer[0..size_of_section_header]) catch break :sdf_blk;

                const name_offset, const section_offset, const section_size = if (is_64) blk: {
                    const section_header: *std.elf.Elf64_Shdr = std.mem.bytesAsValue(std.elf.Elf64_Shdr, &section_header_buffer);
                    break :blk .{ section_header.sh_name, section_header.sh_offset, section_header.sh_size };
                } else blk: {
                    const section_header: *std.elf.Elf32_Shdr = std.mem.bytesAsValue(std.elf.Elf32_Shdr, &section_header_buffer);
                    break :blk .{ section_header.sh_name, section_header.sh_offset, section_header.sh_size };
                };

                const name = std.mem.sliceTo(header_strings[name_offset..], 0);
                if (std.mem.eql(u8, name, ".sdf")) {
                    break :sdf_slice kernel_file_slice[section_offset..][0..section_size];
                }
            }

            break :sdf_blk;
        };

        var sdf_fbs = std.io.fixedBufferStream(sdf_slice);

        const header = sdf.Header.read(sdf_fbs.reader()) catch break :sdf_blk;

        sdf_string_table = header.stringTable(sdf_slice);
        sdf_file_table = header.fileTable(sdf_slice);
        sdf_location_lookup = header.locationLookup(sdf_slice);
        sdf_location_program = header.locationProgram(sdf_slice);

        @atomicStore(bool, &symbols_loaded, true, .Release);
        return;
    }

    @atomicStore(bool, &symbol_loading_failed, true, .Release);
}

pub fn getSymbol(address: usize) ?Symbol {
    if (!symbols_loaded) return null;

    const start_state = sdf_location_lookup.getStartState(address) catch return null;

    const location = sdf_location_program.getLocation(start_state, address) catch return null;

    const file = sdf_file_table.getFile(location.file_index) orelse return null;

    return .{
        .name = sdf_string_table.getString(location.symbol_offset),
        .directory = sdf_string_table.getString(file.directory_offset),
        .file = sdf_string_table.getString(file.file_offset),
        .line = location.line,
        .column = location.column,
    };
}

pub const Symbol = struct {
    name: []const u8,
    directory: []const u8,
    file: []const u8,
    line: u64,
    column: u64,
};
