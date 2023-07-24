// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const DwarfSymbolMap = @import("DwarfSymbolMap.zig");

var any_symbolmaps_loaded: bool = false;

var dwarf_symbol_map_spinlock: kernel.SpinLock = .{};
var dwarf_symbol_map_opt: ?DwarfSymbolMap = null;

pub fn loadSymbols() !void {
    if (dwarf_symbol_map_opt == null) {
        const held = dwarf_symbol_map_spinlock.lock();
        defer held.unlock();
        if (dwarf_symbol_map_opt == null) {
            dwarf_symbol_map_opt = DwarfSymbolMap.init(kernel.info.kernel_file.address.toPtr([*]const u8)) catch null;
            @atomicStore(bool, &any_symbolmaps_loaded, true, .Release);
        }
    }

    if (!@atomicLoad(bool, &any_symbolmaps_loaded, .Acquire)) {
        return error.FailedToLoadSymbols;
    }
}

/// Gets the symbol for the given address.
pub fn getSymbol(address: usize) ?Symbol {
    // We subtract one from the address to better handle the case when the address is the last instruction of the
    // function (for example `@panic` as the very last statement of a function) as in that case the return
    // address will actually point at the first instruction _after_ intended function
    const safer_address = address - 1;

    if (dwarf_symbol_map_opt) |*dwarf_symbol_map| {
        if (dwarf_symbol_map.getSymbol(safer_address)) |symbol| {
            return symbol;
        }
    }

    return null;
}

pub const Symbol = struct {
    /// The address of the symbol.
    address: usize,
    name: ?[]const u8,
    location: ?Location,

    pub const Location = struct {
        /// Whether the line number is expected to precisely correspond to the symbol.
        is_line_expected_to_be_precise: bool,
        file_name: []const u8,
        line: u64,
        column: ?u64,
    };
};
