// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const DwarfSymbolMap = @import("DwarfSymbolMap.zig");

var symbols_loaded: bool = false;
var symbol_loading_failed: bool = false;

var symbol_loading_spinlock: kernel.SpinLock = .{};

var dwarf_symbol_map_opt: ?DwarfSymbolMap = null;

pub fn loadSymbols() void {
    if (@atomicLoad(bool, &symbols_loaded, .Acquire)) return;
    if (@atomicLoad(bool, &symbol_loading_failed, .Acquire)) return;

    // If the processor has not yet been initialized, we can't acquire the spinlock.
    if (kernel.arch.earlyGetProcessor() == null) return;

    const held = symbol_loading_spinlock.lock();
    defer held.unlock();

    if (@atomicLoad(bool, &symbols_loaded, .Acquire)) return;
    if (@atomicLoad(bool, &symbol_loading_failed, .Acquire)) return;

    // DWARF
    dwarf: {
        const kernel_file = kernel.info.kernel_file orelse break :dwarf;
        const kernel_file_slice = kernel_file.toSlice(u8) catch break :dwarf;

        if (DwarfSymbolMap.init(kernel_file_slice)) |dwarf_symbol_map| {
            dwarf_symbol_map_opt = dwarf_symbol_map;
            @atomicStore(bool, &symbols_loaded, true, .Release);
            return;
        } else |_| {}
    }

    @atomicStore(bool, &symbol_loading_failed, true, .Release);
}

pub fn getSymbol(address: usize) ?Symbol {
    if (!symbols_loaded) return null;

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
