// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const DwarfSymbolMap = @import("DwarfSymbolMap.zig");

var symbol_map_spinlock: kernel.SpinLock = .{};
var symbol_maps_loaded = false;

var opt_dwarf_symbol_map: ?DwarfSymbolMap = null;

pub fn loadSymbols() void {
    if (symbol_maps_loaded) return;
    const held = symbol_map_spinlock.lock();
    defer held.unlock();
    if (symbol_maps_loaded) return;

    opt_dwarf_symbol_map = dwarf: {
        if (kernel.info.kernel_file) |kernel_file| {
            break :dwarf DwarfSymbolMap.init(kernel_file.ptr) catch null;
        }
        break :dwarf null;
    };

    symbol_maps_loaded = true;
}

pub fn getSymbol(address: usize) ?Symbol {
    // We subtract one from the address to better handle the case when the address is the last instruction of the
    // function (for example `@panic` as the very last statement of a function) as in that case the return
    // address will actually point at the first instruction _after_ intended function
    const safer_address = address - 1;

    if (opt_dwarf_symbol_map) |*dwarf_symbol_map| {
        if (dwarf_symbol_map.getSymbol(safer_address)) |symbol| {
            return symbol;
        }
    }

    return null;
}

pub const Symbol = struct {
    address: usize,
    name: []const u8,
    location: ?Location,

    pub const Location = struct {
        is_line_expected_to_be_precise: bool,
        file_name: []const u8,
        line: u64,
        column: ?u64,
    };
};
