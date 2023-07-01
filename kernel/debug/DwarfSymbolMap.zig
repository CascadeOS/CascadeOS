// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const symbol_map = @import("symbol_map.zig");

const DwarfSymbolMap = @This();

debug_info: std.dwarf.DwarfInfo,
allocator: std.mem.Allocator,

// TODO: Needing such a big buffer for DWARF is annoying https://github.com/CascadeOS/CascadeOS/issues/47
// this buffer needs to be big enough to initalize the DWARF debug info for the kernel
const size_of_dwarf_debug_allocator = core.Size.from(16, .mib);

var dwarf_debug_allocator_bytes: [size_of_dwarf_debug_allocator.bytes]u8 = undefined;
var dwarf_debug_allocator = std.heap.FixedBufferAllocator.init(dwarf_debug_allocator_bytes[0..]);

pub fn init(kernel_elf_start: [*]const u8) !DwarfSymbolMap {
    const elf_header: *const std.elf.Ehdr = @ptrCast(@alignCast(&kernel_elf_start[0]));
    if (!std.mem.eql(u8, elf_header.e_ident[0..4], std.elf.MAGIC)) return error.InvalidElfMagic;
    if (elf_header.e_ident[std.elf.EI_VERSION] != 1) return error.InvalidElfVersion;

    const section_header_offset = elf_header.e_shoff;
    const string_section_offset =
        section_header_offset +
        @as(u64, elf_header.e_shentsize) * @as(u64, elf_header.e_shstrndx);
    const string_section_header: *const std.elf.Shdr = @ptrCast(@alignCast(&kernel_elf_start[string_section_offset]));
    const header_strings = kernel_elf_start[string_section_header.sh_offset .. string_section_header.sh_offset + string_section_header.sh_size];
    const section_headers = @as(
        [*]const std.elf.Shdr,
        @ptrCast(@alignCast(&kernel_elf_start[section_header_offset])),
    )[0..elf_header.e_shnum];

    var debug_info_opt: ?[]const u8 = null;
    var debug_abbrev_opt: ?[]const u8 = null;
    var debug_str_opt: ?[]const u8 = null;
    var debug_str_offsets_opt: ?[]const u8 = null;
    var debug_line_opt: ?[]const u8 = null;
    var debug_line_str_opt: ?[]const u8 = null;
    var debug_ranges_opt: ?[]const u8 = null;
    var debug_loclists_opt: ?[]const u8 = null;
    var debug_rnglists_opt: ?[]const u8 = null;
    var debug_addr_opt: ?[]const u8 = null;
    var debug_names_opt: ?[]const u8 = null;
    var debug_frame_opt: ?[]const u8 = null;

    for (section_headers) |*shdr| {
        if (shdr.sh_type == std.elf.SHT_NULL) continue;

        const name = std.mem.sliceTo(header_strings[shdr.sh_name..], 0);
        if (std.mem.eql(u8, name, ".debug_info")) {
            debug_info_opt = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_abbrev")) {
            debug_abbrev_opt = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_str")) {
            debug_str_opt = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_str_offsets")) {
            debug_str_offsets_opt = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_line")) {
            debug_line_opt = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_line_str")) {
            debug_line_str_opt = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_ranges")) {
            debug_ranges_opt = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_loclists")) {
            debug_loclists_opt = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_rnglists")) {
            debug_rnglists_opt = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_addr")) {
            debug_addr_opt = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_names")) {
            debug_names_opt = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        } else if (std.mem.eql(u8, name, ".debug_frame")) {
            debug_frame_opt = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        }
    }

    var map: DwarfSymbolMap = .{
        .debug_info = std.dwarf.DwarfInfo{
            .endian = .Little,
            .debug_info = debug_info_opt orelse return error.MissingDebugInfo,
            .debug_abbrev = debug_abbrev_opt orelse return error.MissingDebugInfo,
            .debug_str = debug_str_opt orelse return error.MissingDebugInfo,
            .debug_str_offsets = debug_str_offsets_opt,
            .debug_line = debug_line_opt orelse return error.MissingDebugInfo,
            .debug_line_str = debug_line_str_opt,
            .debug_ranges = debug_ranges_opt,
            .debug_loclists = debug_loclists_opt,
            .debug_rnglists = debug_rnglists_opt,
            .debug_addr = debug_addr_opt,
            .debug_names = debug_names_opt,
            .debug_frame = debug_frame_opt,
        },
        .allocator = dwarf_debug_allocator.allocator(),
    };

    std.dwarf.openDwarfDebugInfo(&map.debug_info, map.allocator) catch |err| switch (err) {
        error.OutOfMemory => core.panic("dwarf_debug_allocator does not have enough memory for chonky DWARF info"),
        else => |e| return e,
    };

    return map;
}

/// Chops a slice from the given pointer at the given offset and size.
/// Returns Overflow if the offset or size cannot be represented as a usize.
fn chopSlice(ptr: [*]const u8, offset: u64, size: u64) error{Overflow}![]const u8 {
    const start = std.math.cast(usize, offset) orelse return error.Overflow;
    const end = start + (std.math.cast(usize, size) orelse return error.Overflow);
    return ptr[start..end];
}

/// Gets the symbol for the given address. Returns null if no symbol was found.
pub fn getSymbol(self: *DwarfSymbolMap, address: usize) ?symbol_map.Symbol {
    const compile_unit = self.debug_info.findCompileUnit(address) catch return null;

    const name = self.debug_info.getSymbolName(address) orelse return null;

    const line_info_opt: ?std.debug.LineInfo = self.debug_info.getLineNumberInfo(
        self.allocator,
        compile_unit.*,
        address,
    ) catch |err| switch (err) {
        error.MissingDebugInfo, error.InvalidDebugInfo => null,
        else => return null,
    };

    const line_info = line_info_opt orelse {
        return .{
            .address = address,
            .name = name,
            .location = null,
        };
    };

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
}

/// Removes the kernel root path prefix from the given path.
/// Returns the original path if it does not start with the root path.
pub fn removeRootPrefixFromPath(path: []const u8) []const u8 {
    // things like `memset` and `memcopy` won't be under the ROOT_PATH
    if (std.mem.startsWith(u8, path, kernel.info.root_path)) {
        return path[(kernel.info.root_path.len)..];
    }

    return path;
}
