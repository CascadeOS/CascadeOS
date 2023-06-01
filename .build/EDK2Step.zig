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

    const firmware_uris = try self.target.uefiFirmwareUris();

    const edk2_directory = try b.cache_root.join(b.allocator, &.{"edk2"});
    try std.fs.cwd().makePath(edk2_directory);

    var client: std.http.Client = .{ .allocator = b.allocator };
    defer client.deinit();

    const code_path = try b.cache_root.join(b.allocator, &.{
        "edk2",
        try std.fmt.allocPrint(b.allocator, "CODE-{s}.fd", .{@tagName(self.target)}),
    });
    try fetch(step, &client, firmware_uris.code, code_path);

    const vars_path = try b.cache_root.join(b.allocator, &.{
        "edk2",
        try std.fmt.allocPrint(b.allocator, "VARS-{s}.fd", .{@tagName(self.target)}),
    });
    try fetch(step, &client, firmware_uris.vars, vars_path);

    self.code_firmware.path = code_path;
    self.vars_firmware.path = vars_path;
}

fn fetch(step: *Step, client: *std.http.Client, uri: std.Uri, destination_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(destination_path, .{});
    defer file.close();

    var buffer_writer = std.io.bufferedWriter(file.writer());

    var h = std.http.Headers{ .allocator = client.allocator };
    defer h.deinit();

    var req = try client.request(.GET, uri, h, .{});
    defer req.deinit();

    try req.start();
    try req.wait();

    if (req.response.status != .ok) return step.fail("failed to fetch: {s}", .{uri});

    var buffer: [4096]u8 = undefined;

    while (true) {
        const number_read = try req.reader().read(&buffer);
        if (number_read == 0) break;
        try buffer_writer.writer().writeAll(buffer[0..number_read]);
    }

    try buffer_writer.flush();

    // QEMU requires the firmware to be at least 64 MiB in size (at least for aarch64)
    const minimum_size = 67108864; // 64 MiB
    if (try file.getEndPos() < minimum_size) {
        try file.setEndPos(minimum_size);
    }
}
