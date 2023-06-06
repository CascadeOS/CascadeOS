// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

var symbol_map_spinlock: kernel.SpinLock = .{};
var symbol_maps_loaded = false;

pub fn loadSymbols() void {
    if (symbol_maps_loaded) return;
    const held = symbol_map_spinlock.lock();
    defer held.unlock();
    if (symbol_maps_loaded) return;

    symbol_maps_loaded = true;
}

pub fn getSymbol(address: usize) ?Symbol {
    // `- 1` is needed in the case where the call to the next function in the stack trace is the very last instruction
    // of the function (for example `@panic` as the very last statement of a function) in this case using the return
    // address directly will actually point at the first instruction of the function immediately following the intended
    // function
    const safer_address = address - 1;

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
