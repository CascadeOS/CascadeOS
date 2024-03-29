// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const helpers = @import("helpers.zig");

const EDK2Step = @This();

const step_version: []const u8 = "1";

step: Step,
target: CascadeTarget,

firmware: std.Build.GeneratedFile,
firmware_source: std.Build.LazyPath,

timestamp_path: []const u8,
edk2_dir: []const u8,
firmware_path: []const u8,

pub fn create(b: *std.Build, target: CascadeTarget) !*EDK2Step {
    const self = try b.allocator.create(EDK2Step);

    const name = try std.fmt.allocPrint(b.allocator, "fetch EDK2 firmware for {s}", .{@tagName(target)});

    self.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = name,
            .owner = b,
            .makeFn = make,
        }),
        .target = target,
        .firmware = undefined,
        .firmware_source = undefined,
        .timestamp_path = try b.cache_root.join(
            b.allocator,
            &.{
                try std.fmt.allocPrint(
                    b.allocator,
                    "edk2_timestamp_{s}",
                    .{@tagName(target)},
                ),
            },
        ),
        .edk2_dir = try b.cache_root.join(b.allocator, &.{"edk2"}),
        .firmware_path = try b.cache_root.join(b.allocator, &.{
            "edk2",
            try std.fmt.allocPrint(b.allocator, "OVMF-{s}.fd", .{@tagName(self.target)}),
        }),
    };
    self.firmware = .{ .step = &self.step };
    self.firmware_source = .{ .generated = &self.firmware };

    return self;
}

fn make(step: *Step, progress_node: *std.Progress.Node) !void {
    var node = progress_node.start(step.name, 0);
    defer node.end();

    progress_node.activate();

    const self = @fieldParentPtr(EDK2Step, "step", step);

    if (!try self.firmwareNeedsUpdate()) {
        self.firmware.path = self.firmware_path;
        step.result_cached = true;
        return;
    }

    var timer = try std.time.Timer.start();

    try std.fs.cwd().makePath(self.edk2_dir);

    try fetch(step.owner.allocator, uefiFirmwareUrl(self.target), self.firmware_path);

    self.firmware.path = self.firmware_path;

    try self.updateTimestampFile();

    step.result_duration_ns = timer.read();
}

/// Returns the URL to download the UEFI firmware for the given target.
fn uefiFirmwareUrl(self: CascadeTarget) []const u8 {
    return switch (self) {
        .x64 => "https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd",
    };
}

// 24 hours
const cache_validity_period = std.time.ns_per_hour * 24;

/// Checks if the EDK2 firmware needs to be updated.
fn firmwareNeedsUpdate(self: *EDK2Step) !bool {
    std.fs.accessAbsolute(self.firmware_path, .{}) catch return true;
    const timestamp_file = std.fs.cwd().openFile(self.timestamp_path, .{}) catch return true;
    defer timestamp_file.close();
    const stat = timestamp_file.stat() catch return true;
    if (std.time.nanoTimestamp() >= stat.mtime + cache_validity_period) return true;

    var buffer: [step_version.len]u8 = undefined;
    const len = try timestamp_file.readAll(&buffer);

    // if the versions don't match we need to download
    return !std.mem.eql(u8, buffer[0..len], step_version);
}

/// Update the timestamp file.
fn updateTimestampFile(self: *EDK2Step) !void {
    const timestamp_file = try std.fs.cwd().createFile(self.timestamp_path, .{});
    defer timestamp_file.close();

    try timestamp_file.writeAll(step_version);

    const stat = try timestamp_file.stat();
    try timestamp_file.updateTimes(stat.atime, std.time.nanoTimestamp());
}

/// Fetches a file from a URL.
fn fetch(allocator: std.mem.Allocator, url: []const u8, destination_path: []const u8) !void {
    const content = blk: {
        var http_client: std.http.Client = .{ .allocator = allocator };
        defer http_client.deinit();

        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        const fetch_result = try http_client.fetch(.{
            .location = .{ .url = url },
            .response_storage = .{ .dynamic = &result },
            .max_append_size = std.math.maxInt(usize),
        });

        if (fetch_result.status != .ok) return error.ResponseNotOk;

        break :blk try result.toOwnedSlice();
    };
    defer allocator.free(content);

    const file = try std.fs.cwd().createFile(destination_path, .{});
    defer file.close();

    try file.writeAll(content);
}
