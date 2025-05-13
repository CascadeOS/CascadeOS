// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Represents a duration.
pub const Duration = extern struct {
    /// The duration in nanoseconds.
    value: u64,

    pub const zero: Duration = .{ .value = 0 };
    pub const one: Duration = .{ .value = 1 };

    pub const Unit = enum(u64) {
        nanosecond = 1,
        microsecond = 1000,
        millisecond = 1000 * 1000,
        second = 1000 * 1000 * 1000,
        minute = 60 * 1000 * 1000 * 1000,
        hour = 60 * 60 * 1000 * 1000 * 1000,
        day = 24 * 60 * 60 * 1000 * 1000 * 1000,
    };

    pub fn from(amount: u64, unit: Unit) Duration {
        return .{
            .value = amount * @intFromEnum(unit),
        };
    }

    pub inline fn equal(self: Duration, other: Duration) bool {
        return self.value == other.value;
    }

    pub inline fn lessThan(self: Duration, other: Duration) bool {
        return self.value < other.value;
    }

    pub inline fn lessThanOrEqual(self: Duration, other: Duration) bool {
        return self.value <= other.value;
    }

    pub inline fn greaterThan(self: Duration, other: Duration) bool {
        return self.value > other.value;
    }

    pub inline fn greaterThanOrEqual(self: Duration, other: Duration) bool {
        return self.value >= other.value;
    }

    pub fn compare(self: Duration, other: Duration) std.math.Order {
        if (self.lessThan(other)) return .lt;
        if (self.greaterThan(other)) return .gt;
        return .eq;
    }

    pub fn add(self: Duration, other: Duration) Duration {
        return .{ .value = self.value + other.value };
    }

    pub fn addInPlace(self: *Duration, other: Duration) void {
        self.value += other.value;
    }

    pub fn subtract(self: Duration, other: Duration) Duration {
        return .{ .value = self.value - other.value };
    }

    pub fn subtractInPlace(self: *Duration, other: Duration) void {
        self.value -= other.value;
    }

    pub fn multiply(self: Duration, other: Duration) Duration {
        return .{ .value = self.value * other.value };
    }

    pub fn multiplyInPlace(self: *Duration, other: Duration) void {
        self.value *= other.value;
    }

    pub fn multiplyScalar(self: Duration, value: u64) Duration {
        return .{ .value = self.value * value };
    }

    pub fn multiplyScalarInPlace(self: *Duration, value: u64) void {
        self.value *= value;
    }

    pub fn divide(self: Duration, other: Duration) Duration {
        return .{ .value = self.value / other.value };
    }

    pub fn divideInPlace(self: *Duration, other: Duration) void {
        self.value /= other.value;
    }

    pub fn divideScalar(self: Duration, value: u64) Duration {
        return .{ .value = self.value / value };
    }

    pub fn divideScalarInPlace(self: *Duration, value: u64) void {
        self.value /= value;
    }

    // Must be kept in descending order due to the logic in `print`
    const unit_table = .{
        .{ .value = @intFromEnum(Unit.day), .name = "d" },
        .{ .value = @intFromEnum(Unit.hour), .name = "h" },
        .{ .value = @intFromEnum(Unit.minute), .name = "m" },
        .{ .value = @intFromEnum(Unit.second), .name = "s" },
        .{ .value = @intFromEnum(Unit.millisecond), .name = "ms" },
        .{ .value = @intFromEnum(Unit.microsecond), .name = "us" },
        .{ .value = @intFromEnum(Unit.nanosecond), .name = "ns" },
    };

    pub fn print(duration: Duration, writer: std.io.AnyWriter, indent: usize) !void {
        _ = indent;

        var any_output = false;
        var value = duration.value;

        if (value == 0) {
            try writer.writeAll("0.000000000");
            return;
        }

        const days = value / @intFromEnum(Unit.day);
        value -= days * @intFromEnum(Unit.day);

        if (days != 0) {
            try std.fmt.formatInt(days, 10, .lower, .{}, writer);
            try writer.writeByte('.');
            any_output = true;
        }

        const hours = value / @intFromEnum(Unit.hour);
        value -= hours * @intFromEnum(Unit.hour);

        if (hours != 0 or any_output) {
            try std.fmt.formatInt(hours, 10, .lower, .{ .fill = '0', .width = 2 }, writer);
            try writer.writeByte(':');
            any_output = true;
        }

        const minutes = value / @intFromEnum(Unit.minute);
        value -= minutes * @intFromEnum(Unit.minute);

        if (minutes != 0 or any_output) {
            try std.fmt.formatInt(minutes, 10, .lower, .{ .fill = '0', .width = 2 }, writer);
            try writer.writeByte(':');
            any_output = true;
        }

        const seconds = value / @intFromEnum(Unit.second);
        value -= seconds * @intFromEnum(Unit.second);

        try std.fmt.formatInt(seconds, 10, .lower, .{ .fill = '0', .width = 2 }, writer);
        try writer.writeByte('.');

        try std.fmt.formatInt(value, 10, .lower, .{ .fill = '0', .width = 9 }, writer);
    }

    pub inline fn format(
        duration: Duration,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(duration, writer, 0)
        else
            print(duration, writer.any(), 0);
    }

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u64));
    }
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
