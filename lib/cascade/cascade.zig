// SPDX-License-Identifier: 0BSD
// SPDX-FileCopyrightText: CascadeOS Contributors

pub const exportEntry = @import("entry.zig").exportEntry;
pub const Syscall = @import("Syscall.zig").Syscall;
pub const Thread = @import("Thread.zig").Thread;

/// Output a debug message.
///
/// This is not intended to be used by normal userspace programs and instead is intended for logs from system libraries like libc.
///
/// The message is assumed to be UTF-8 encoded.
///
/// If the message does not end with a newline, one will be appended.
///
/// No guarantees are made about the destination of the message, the implementation may choose to discard it or send it to any number of
/// destinations.
///
/// Any errors encountered while writing the message are ignored and may cause the message to be truncated.
pub fn debugPrint(str: []const u8) void {
    _ = Syscall.call2(.debug_print, str.len, @intFromPtr(str.ptr));
}
