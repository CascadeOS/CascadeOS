// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const symbol_map = @import("symbol_map.zig");

const DwarfSymbolMap = @This();

debug_info: std.dwarf.DwarfInfo,
allocator: std.mem.Allocator,

// this buffer needs to be big enough to initalize the DWARF debug info for the kernel
const size_of_dwarf_debug_allocator = core.Size.from(16, .mib);

var dwarf_debug_allocator_bytes: [size_of_dwarf_debug_allocator.bytes]u8 = undefined;
var dwarf_debug_allocator = std.heap.FixedBufferAllocator.init(dwarf_debug_allocator_bytes[0..]);

pub fn init(kernel_elf_start: [*]const u8) !DwarfSymbolMap {
    const hdr = @ptrCast(*const std.elf.Ehdr, @alignCast(@alignOf(std.elf.Ehdr), &kernel_elf_start[0]));
    if (!std.mem.eql(u8, hdr.e_ident[0..4], std.elf.MAGIC)) return error.InvalidElfMagic;
    if (hdr.e_ident[std.elf.EI_VERSION] != 1) return error.InvalidElfVersion;

    const shoff = hdr.e_shoff;
    const str_section_off = shoff + @as(u64, hdr.e_shentsize) * @as(u64, hdr.e_shstrndx);
    const str_shdr = @ptrCast(
        *const std.elf.Shdr,
        @alignCast(@alignOf(std.elf.Shdr), &kernel_elf_start[std.math.cast(usize, str_section_off) orelse return error.Overflow]),
    );
    const header_strings = kernel_elf_start[str_shdr.sh_offset .. str_shdr.sh_offset + str_shdr.sh_size];
    const shdrs = @ptrCast(
        [*]const std.elf.Shdr,
        @alignCast(@alignOf(std.elf.Shdr), &kernel_elf_start[shoff]),
    )[0..hdr.e_shnum];

    var opt_debug_info: ?[]const u8 = null;
    var opt_debug_abbrev: ?[]const u8 = null;
    var opt_debug_str: ?[]const u8 = null;
    var opt_debug_str_offsets: ?[]const u8 = null;
    var opt_debug_line: ?[]const u8 = null;
    var opt_debug_line_str: ?[]const u8 = null;
    var opt_debug_ranges: ?[]const u8 = null;
    var opt_debug_loclists: ?[]const u8 = null;
    var opt_debug_rnglists: ?[]const u8 = null;
    var opt_debug_addr: ?[]const u8 = null;
    var opt_debug_names: ?[]const u8 = null;
    var opt_debug_frame: ?[]const u8 = null;

    for (shdrs) |*shdr| {
        if (shdr.sh_type == std.elf.SHT_NULL) continue;

        const name = std.mem.sliceTo(header_strings[shdr.sh_name..], 0);
        if (std.mem.eql(u8, name, ".debug_info")) {
            opt_debug_info = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_abbrev")) {
            opt_debug_abbrev = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_str")) {
            opt_debug_str = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_str_offsets")) {
            opt_debug_str_offsets = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_line")) {
            opt_debug_line = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_line_str")) {
            opt_debug_line_str = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_ranges")) {
            opt_debug_ranges = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_loclists")) {
            opt_debug_loclists = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_rnglists")) {
            opt_debug_rnglists = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_addr")) {
            opt_debug_addr = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_names")) {
            opt_debug_names = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_frame")) {
            opt_debug_frame = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        }
    }

    var map: DwarfSymbolMap = .{
        .debug_info = std.dwarf.DwarfInfo{
            .endian = .Little,
            .debug_info = opt_debug_info orelse return error.MissingDebugInfo,
            .debug_abbrev = opt_debug_abbrev orelse return error.MissingDebugInfo,
            .debug_str = opt_debug_str orelse return error.MissingDebugInfo,
            .debug_str_offsets = opt_debug_str_offsets,
            .debug_line = opt_debug_line orelse return error.MissingDebugInfo,
            .debug_line_str = opt_debug_line_str,
            .debug_ranges = opt_debug_ranges,
            .debug_loclists = opt_debug_loclists,
            .debug_rnglists = opt_debug_rnglists,
            .debug_addr = opt_debug_addr,
            .debug_names = opt_debug_names,
            .debug_frame = opt_debug_frame,
        },
        .allocator = dwarf_debug_allocator.allocator(),
    };

    std.dwarf.openDwarfDebugInfo(&map.debug_info, map.allocator) catch |err| switch (err) {
        error.OutOfMemory => core.panic("dwarf_debug_allocator does not have enough memory for chonky DWARF info"),
        else => |e| return e,
    };

    return map;
}

fn chopSlice(ptr: [*]const u8, offset: u64, size: u64) error{Overflow}![]const u8 {
    const start = std.math.cast(usize, offset) orelse return error.Overflow;
    const end = start + (std.math.cast(usize, size) orelse return error.Overflow);
    return ptr[start..end];
}

pub fn getSymbol(self: *DwarfSymbolMap, address: usize) ?symbol_map.Symbol {
    const compile_unit = self.debug_info.findCompileUnit(address) catch return null;

    const name = self.debug_info.getSymbolName(address) orelse return null;

    const opt_line_info: ?std.debug.LineInfo = self.debug_info.getLineNumberInfo(
        self.allocator,
        compile_unit.*,
        address,
    ) catch |err| switch (err) {
        error.MissingDebugInfo, error.InvalidDebugInfo => null,
        else => return null,
    };

    if (opt_line_info) |line_info| {
        return .{
            .address = address,
            .name = name,
            .location = .{
                .is_line_expected_to_be_precise = true,
                .file_name = removeRootPrefixFromPath(line_info.file_name),
                .line = line_info.line,
                .column = line_info.column,
            },
        };
    } else {
        return .{
            .address = address,
            .name = name,
            .location = null,
        };
    }
}

pub fn removeRootPrefixFromPath(path: []const u8) []const u8 {
    // things like `memset` and `memcopy` won't be under the ROOT_PATH
    if (std.mem.startsWith(u8, path, kernel.info.root_path)) {
        return path[(kernel.info.root_path.len)..];
    }

    return path;
}
