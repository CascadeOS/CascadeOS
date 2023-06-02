// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;

const EDK2Step = @This();

step: Step,
target: CascadeTarget,

code_firmware: std.Build.GeneratedFile,
code_firmware_source: std.Build.FileSource,

vars_firmware: std.Build.GeneratedFile,
vars_firmware_source: std.Build.FileSource,

timestamp_file_path: []const u8,
edk2_path: []const u8,
code_path: []const u8,
var_path: []const u8,

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
        .code_firmware = undefined,
        .code_firmware_source = undefined,
        .vars_firmware = undefined,
        .vars_firmware_source = undefined,
        .timestamp_file_path = try b.cache_root.join(
            b.allocator,
            &.{
                try std.fmt.allocPrint(
                    b.allocator,
                    "edk2_timestamp_{s}",
                    .{@tagName(target)},
                ),
            },
        ),
        .edk2_path = try b.cache_root.join(b.allocator, &.{"edk2"}),
        .code_path = try b.cache_root.join(b.allocator, &.{
            "edk2",
            try std.fmt.allocPrint(b.allocator, "CODE-{s}.fd", .{@tagName(self.target)}),
        }),
        .var_path = try b.cache_root.join(b.allocator, &.{
            "edk2",
            try std.fmt.allocPrint(b.allocator, "VAR-{s}.fd", .{@tagName(self.target)}),
        }),
    };
    self.code_firmware = .{ .step = &self.step };
    self.code_firmware_source = .{ .generated = &self.code_firmware };
    self.vars_firmware = .{ .step = &self.step };
    self.vars_firmware_source = .{ .generated = &self.vars_firmware };

    return self;
}

fn make(step: *Step, prog_node: *std.Progress.Node) !void {
    _ = prog_node;

    const b = step.owner;
    const self = @fieldParentPtr(EDK2Step, "step", step);

    if (!self.needToDownloadFirmware()) {
        self.code_firmware.path = self.code_path;
        self.vars_firmware.path = self.var_path;
        step.result_cached = true;
        return;
    }

    const firmware_uris = try self.target.uefiFirmwareUris();

    try std.fs.cwd().makePath(self.edk2_path);

    var client: std.http.Client = .{ .allocator = b.allocator };
    defer client.deinit();

    try self.fetch(&client, firmware_uris.code, self.code_path);

    try self.fetch(&client, firmware_uris.vars, self.var_path);

    self.code_firmware.path = self.code_path;
    self.vars_firmware.path = self.var_path;

    try self.updateTimestampFile();
}

// 6 hours
const timeout_ns = std.time.ns_per_hour * 6;

fn needToDownloadFirmware(self: *EDK2Step) bool {
    std.fs.accessAbsolute(self.code_path, .{}) catch return true;
    std.fs.accessAbsolute(self.var_path, .{}) catch return true;
    const timestamp_file = std.fs.cwd().openFile(self.timestamp_file_path, .{}) catch return true;
    defer timestamp_file.close();
    const stat = timestamp_file.stat() catch return true;
    return std.time.nanoTimestamp() >= stat.mtime + timeout_ns;
}

fn updateTimestampFile(self: *EDK2Step) !void {
    const timestamp_file = try std.fs.cwd().createFile(self.timestamp_file_path, .{});
    defer timestamp_file.close();
    const stat = try timestamp_file.stat();
    try timestamp_file.updateTimes(stat.atime, std.time.nanoTimestamp());
}

fn fetch(self: *EDK2Step, client: *std.http.Client, uri: std.Uri, destination_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(destination_path, .{});
    defer file.close();

    var buffer_writer = std.io.bufferedWriter(file.writer());

    var h = std.http.Headers{ .allocator = client.allocator };
    defer h.deinit();

    var req = try client.request(.GET, uri, h, .{});
    defer req.deinit();

    try req.start();
    try req.wait();

    if (req.response.status != .ok) return self.step.fail("failed to fetch: {s}", .{uri});

    var buffer: [4096]u8 = undefined;

    while (true) {
        const number_read = try req.reader().read(&buffer);
        if (number_read == 0) break;
        try buffer_writer.writer().writeAll(buffer[0..number_read]);
    }

    try buffer_writer.flush();

    if (self.target == .aarch64) {
        // QEMU requires the firmware to be at least 64 MiB in size for aarch64
        const minimum_size = 67108864; // 64 MiB
        if (try file.getEndPos() < minimum_size) {
            try file.setEndPos(minimum_size);
        }
    }
}
