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

        const hdr: *const std.elf.Ehdr = @ptrCast(@alignCast(&kernel_file_slice[0]));
        if (!std.mem.eql(u8, hdr.e_ident[0..4], std.elf.MAGIC)) break :sdf_blk;
        if (hdr.e_ident[std.elf.EI_VERSION] != 1) break :sdf_blk;

        const shoff = hdr.e_shoff;
        const str_section_off = shoff + @as(u64, hdr.e_shentsize) * @as(u64, hdr.e_shstrndx);
        const str_shdr: *const std.elf.Shdr = @ptrCast(@alignCast(&kernel_file_slice[std.math.cast(usize, str_section_off) orelse break :sdf_blk]));
        const header_strings = kernel_file_slice[str_shdr.sh_offset..][0..str_shdr.sh_size];
        const shdrs = @as(
            [*]const std.elf.Shdr,
            @ptrCast(@alignCast(&kernel_file_slice[shoff])),
        )[0..hdr.e_shnum];

        const sdf_slice = sdf_slice: for (shdrs) |*shdr| {
            const name = std.mem.sliceTo(header_strings[shdr.sh_name..], 0);

            if (std.mem.eql(u8, name, ".sdf")) {
                break :sdf_slice kernel_file_slice[shdr.sh_offset..][0..shdr.sh_size];
            }
        } else break :sdf_blk;
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
