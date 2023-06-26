// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const helpers = @import("helpers.zig");

const EDK2Step = @This();

const step_version: []const u8 = "1";

step: Step,
target: CascadeTarget,

firmware: std.Build.GeneratedFile,
firmware_source: std.Build.FileSource,

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

    try std.fs.cwd().makePath(self.edk2_dir);

    try fetch(step, self.target.uefiFirmwareUrl(), self.firmware_path);

    self.firmware.path = self.firmware_path;

    try self.updateTimestampFile();
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
fn fetch(step: *Step, url: []const u8, destination_path: []const u8) !void {
    var failed = false;

    // try curl
    helpers.runExternalBinary(
        step.owner.allocator,
        &.{
            "curl",
            "-s", // silent
            "-f", // fail fast
            "-o",
            destination_path,
            url,
        },
        null,
    ) catch {
        failed = true;
    };

    if (!failed) return;
    failed = false;

    // try wget
    helpers.runExternalBinary(
        step.owner.allocator,
        &.{
            "wget",
            "-q", // quiet
            "-O",
            destination_path,
            url,
        },
        null,
    ) catch {};

    if (!failed) return;
    failed = false;

    return step.fail("failed to fetch '{s}' using either curl or wget", .{url});

    // TODO: use the std http client once it stops crashing randomly https://github.com/CascadeOS/CascadeOS/issues/53
    // const file = try std.fs.cwd().createFile(destination_path, .{});
    // defer file.close();
    //
    // var buffered_writer = std.io.bufferedWriter(file.writer());
    //
    // downloadWithHttpClient(step.owner.allocator, url, buffered_writer.writer()) catch |err| {
    //     return step.fail("failed to fetch '{s}': {s}", .{ url, @errorName(err) });
    // };
    //
    // try buffered_writer.flush();
}

/// Downloads a file using the std http client.
fn downloadWithHttpClient(allocator: std.mem.Allocator, url: []const u8, writer: anytype) !void {
    const uri = try std.Uri.parse(url);

    var http_client: std.http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    var request_headers = std.http.Headers{ .allocator = allocator };
    defer request_headers.deinit();

    var request = try http_client.request(.GET, uri, request_headers, .{});
    defer request.deinit();

    try request.start();
    try request.wait();

    if (request.response.status != .ok) return error.ResponseNotOk;

    var buffer: [4096]u8 = undefined;

    while (true) {
        const bytes_read = try request.reader().read(&buffer);
        if (bytes_read == 0) break;
        try writer.writeAll(buffer[0..bytes_read]);
    }
}
