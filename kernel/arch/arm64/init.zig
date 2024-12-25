// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz

/// Attempt to set up some form of early output.
pub fn setupEarlyOutput() void {
    // IMPLEMENT - we need to get the HHDM setup before we can access the UART
}

/// Write to early output.
///
/// Cannot fail, any errors are ignored.
pub fn writeToEarlyOutput(bytes: []const u8) void {
    _ = bytes;
    // IMPLEMENT - we need to get the HHDM setup before we can access the UART
}
