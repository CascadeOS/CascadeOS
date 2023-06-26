// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const LimineStep = @This();

const step_version: []const u8 = "2";

step: Step,

/// The generated file providing the path to the Limine directory.
limine_generated_directory: std.Build.GeneratedFile,

/// The file source for the Limine directory.
limine_directory_source: std.Build.FileSource,

/// The file source for the Limine executable.
limine_executable_source: std.Build.FileSource,

/// The path to the Limine directory.
__limine_directory: []const u8,

/// The `DownloadLimineStep` which downloads Limine.
__download_limine_step: *DownloadLimineStep,

/// The Step which builds the Limine executable.
__build_limine_executable: *Step.Compile,

pub fn create(b: *std.Build) !*LimineStep {
    const limine_dir = try b.cache_root.join(b.allocator, &.{"limine"});
    const limine_c_source = b.pathJoin(&.{ limine_dir, "limine.c" });

    const download_limine = try DownloadLimineStep.create(b, limine_dir);

    const build_limine_exe = b.addExecutable(.{
        .name = "limine",
        .link_libc = true,
    });
    build_limine_exe.addIncludePath(limine_dir);
    build_limine_exe.addCSourceFile(limine_c_source, &.{
        "-std=c99",
        "-fno-sanitize=undefined",
    });

    build_limine_exe.step.dependOn(&download_limine.step);

    const self = try b.allocator.create(LimineStep);

    self.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = "provide limine",
            .owner = b,
            .makeFn = make,
        }),
        .__limine_directory = limine_dir,
        .__download_limine_step = download_limine,
        .__build_limine_executable = build_limine_exe,
        .limine_executable_source = build_limine_exe.getOutputSource(),
        .limine_generated_directory = undefined,
        .limine_directory_source = undefined,
    };
    self.limine_generated_directory = .{ .step = &self.step };
    self.limine_directory_source = .{ .generated = &self.limine_generated_directory };

    self.step.dependOn(&build_limine_exe.step);

    return self;
}

fn make(step: *Step, prog_node: *std.Progress.Node) !void {
    _ = prog_node;
    const self = @fieldParentPtr(LimineStep, "step", step);
    self.limine_generated_directory.path = self.__limine_directory;

    // if both of our child steps are cached, then we are cached
    if (self.__download_limine_step.step.result_cached and self.__build_limine_executable.step.result_cached) {
        step.result_cached = true;
    }
}

const DownloadLimineStep = struct {
    step: Step,

    /// The path to the Limine directory.
    limine_dir: []const u8,

    /// The path to the timestamp file used to check if Limine needs to be downloaded.
    timestamp_file_path: []const u8,

    pub fn create(b: *std.Build, limine_dir: []const u8) !*DownloadLimineStep {
        const self = try b.allocator.create(DownloadLimineStep);

        self.* = .{
            .step = Step.init(.{
                .id = .custom,
                .name = "download limine",
                .owner = b,
                .makeFn = downloadLimineMake,
            }),
            .limine_dir = limine_dir,
            .timestamp_file_path = try b.cache_root.join(b.allocator, &.{
                "limine_timestamp",
            }),
        };

        return self;
    }

    fn downloadLimineMake(step: *Step, prog_node: *std.Progress.Node) !void {
        var node = prog_node.start(step.name, 0);
        defer node.end();

        const b = step.owner;
        const self = @fieldParentPtr(DownloadLimineStep, "step", step);

        if (!try self.limineNeedsUpdate()) {
            step.result_cached = true;
            return;
        }

        // attempt to git pull in a pre-existing limine directory
        run(b, &.{
            "git",
            "-C",
            self.limine_dir,
            "pull",
        }) catch {
            // pull failed, so attempt to clone
            try std.fs.cwd().deleteTree(self.limine_dir);

            run(b, &.{
                "git",
                "clone",
                "-b",
                "v5.x-branch-binary",
                "--depth=1",
                "--single-branch",
                "https://github.com/limine-bootloader/limine.git",
                self.limine_dir,
            }) catch {
                return step.fail("failed to download limine", .{});
            };
        };

        try self.updateTimestampFile();
    }

    // 24 hours
    const cache_validity_period = std.time.ns_per_hour * 24;

    /// Checks if Limine needs to be updated.
    fn limineNeedsUpdate(self: *DownloadLimineStep) !bool {
        std.fs.accessAbsolute(self.limine_dir, .{}) catch return true;
        const timestamp_file = std.fs.cwd().openFile(self.timestamp_file_path, .{}) catch return true;
        defer timestamp_file.close();
        const stat = timestamp_file.stat() catch return true;
        if (std.time.nanoTimestamp() >= stat.mtime + cache_validity_period) return true;

        var buffer: [step_version.len]u8 = undefined;
        const len = try timestamp_file.readAll(&buffer);

        // if the versions don't match we need to download
        return !std.mem.eql(u8, buffer[0..len], step_version);
    }

    /// Update the timestamp file.
    fn updateTimestampFile(self: *DownloadLimineStep) !void {
        const timestamp_file = try std.fs.cwd().createFile(self.timestamp_file_path, .{});
        defer timestamp_file.close();

        try timestamp_file.writeAll(step_version);

        const stat = try timestamp_file.stat();
        try timestamp_file.updateTimes(stat.atime, std.time.nanoTimestamp());
    }

    /// Runs an external process.
    /// Ignores stdin, stdout and stderr.
    fn run(b: *std.Build, args: []const []const u8) !void {
        var child = std.ChildProcess.init(args, b.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        const result = try child.wait();

        if (result == .Exited and result.Exited == 0) {
            // success
            return;
        }

        return error.Failed;
    }
};
