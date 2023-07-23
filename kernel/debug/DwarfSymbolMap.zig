// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const elf = std.elf;
const DW = std.dwarf;

const symbol_map = @import("symbol_map.zig");

const DwarfSymbolMap = @This();

debug_info: std.dwarf.DwarfInfo,
allocator: std.mem.Allocator,

// TODO: Needing such a big buffer for DWARF is annoying https://github.com/CascadeOS/CascadeOS/issues/47
// this buffer needs to be big enough to initalize the DWARF debug info for the kernel
const size_of_dwarf_debug_allocator = core.Size.from(16, .mib);

var dwarf_debug_allocator_bytes: [size_of_dwarf_debug_allocator.bytes]u8 = undefined;
var dwarf_debug_allocator = std.heap.FixedBufferAllocator.init(dwarf_debug_allocator_bytes[0..]);

// This function is a re-implementation of `std.debug.readElfDebugInfo`
pub fn init(kernel_elf_start: [*]const u8) !DwarfSymbolMap {
    const allocator = dwarf_debug_allocator.allocator();

    const hdr: *const elf.Ehdr = @ptrCast(@alignCast(kernel_elf_start));
    if (!std.mem.eql(u8, hdr.e_ident[0..4], elf.MAGIC)) return error.InvalidElfMagic;
    if (hdr.e_ident[elf.EI_VERSION] != 1) return error.InvalidElfVersion;

    const shoff = hdr.e_shoff;
    const str_section_off = shoff + @as(u64, hdr.e_shentsize) * @as(u64, hdr.e_shstrndx);
    const str_shdr: *const elf.Shdr = @ptrCast(@alignCast(&kernel_elf_start[std.math.cast(usize, str_section_off) orelse return error.Overflow]));
    const header_strings = kernel_elf_start[str_shdr.sh_offset..][0..str_shdr.sh_size];
    const shdrs = @as(
        [*]const elf.Shdr,
        @ptrCast(@alignCast(&kernel_elf_start[shoff])),
    )[0..hdr.e_shnum];

    var sections: DW.DwarfInfo.SectionArray = DW.DwarfInfo.null_section_array;

    for (shdrs) |*shdr| {
        if (shdr.sh_type == elf.SHT_NULL or shdr.sh_type == elf.SHT_NOBITS) continue;
        const name = std.mem.sliceTo(header_strings[shdr.sh_name..], 0);

        var section_index: ?usize = null;
        inline for (@typeInfo(DW.DwarfSection).Enum.fields, 0..) |section, i| {
            if (std.mem.eql(u8, "." ++ section.name, name)) section_index = i;
        }
        if (section_index == null) continue;
        if (sections[section_index.?] != null) continue;

        const section_bytes = try chopSlice(kernel_elf_start, shdr.sh_offset, shdr.sh_size);
        sections[section_index.?] = if ((shdr.sh_flags & elf.SHF_COMPRESSED) > 0) blk: {
            var section_stream = std.io.fixedBufferStream(section_bytes);
            var section_reader = section_stream.reader();
            const chdr = section_reader.readStruct(elf.Chdr) catch continue;
            if (chdr.ch_type != .ZLIB) continue;

            var zlib_stream = std.compress.zlib.decompressStream(allocator, section_stream.reader()) catch continue;
            defer zlib_stream.deinit();

            var decompressed_section = try allocator.alloc(u8, chdr.ch_size);
            errdefer allocator.free(decompressed_section);

            const read = zlib_stream.reader().readAll(decompressed_section) catch continue;
            if (read != decompressed_section.len) return error.DecompressionFailed;

            break :blk .{
                .data = decompressed_section,
                .virtual_address = shdr.sh_addr,
                .owned = true,
            };
        } else .{
            .data = section_bytes,
            .virtual_address = shdr.sh_addr,
            .owned = false,
        };
    }

    var map: DwarfSymbolMap = .{
        .debug_info = DW.DwarfInfo{
            .endian = .Little,
            .sections = sections,
            .is_macho = false,
        },
        .allocator = dwarf_debug_allocator.allocator(),
    };

    try DW.openDwarfDebugInfo(&map.debug_info, allocator);

    return map;
}

/// Chops a slice from the given pointer at the given offset and size.
///
/// Returns Overflow if the offset or size cannot be represented as a usize.
fn chopSlice(ptr: [*]const u8, offset: u64, size: u64) error{Overflow}![]const u8 {
    const start = std.math.cast(usize, offset) orelse return error.Overflow;
    const end = start + (std.math.cast(usize, size) orelse return error.Overflow);
    return ptr[start..end];
}

/// Gets the symbol for the given address. Returns null if no symbol was found.
pub fn getSymbol(self: *DwarfSymbolMap, address: usize) ?symbol_map.Symbol {
    const compile_unit = self.debug_info.findCompileUnit(address) catch return null;

    const name = self.debug_info.getSymbolName(address) orelse null;

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
///
/// Returns the original path if it does not start with the root path.
pub fn removeRootPrefixFromPath(path: []const u8) []const u8 {
    // things like `memset` and `memcopy` won't be under the ROOT_PATH
    if (std.mem.startsWith(u8, path, kernel.info.root_path)) {
        return path[(kernel.info.root_path.len)..];
    }

    return path;
}
