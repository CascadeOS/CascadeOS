// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const LimineStep = @This();

step: Step,

limine_directory: std.Build.GeneratedFile,
limine_directory_source: std.Build.FileSource,

limine_deploy_source: std.Build.FileSource,

__limine_directory: []const u8,

pub fn create(b: *std.Build) !*LimineStep {
    const limine_directory = try b.cache_root.join(b.allocator, &.{"limine"});
    const limine_deploy_source = b.pathJoin(&.{ limine_directory, "limine-deploy.c" });

    const download_limine_step = try DownloadLimineStep.create(b, limine_directory);

    const build_limine = b.addExecutable(.{
        .name = "limine-deploy",
        .link_libc = true,
    });
    build_limine.addIncludePath(limine_directory);
    build_limine.addCSourceFile(limine_deploy_source, &.{
        "-std=c99",
        "-fno-sanitize=undefined",
    });

    build_limine.step.dependOn(&download_limine_step.step);

    const self = try b.allocator.create(LimineStep);

    self.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = "provide limine",
            .owner = b,
            .makeFn = make,
        }),
        .__limine_directory = limine_directory,
        .limine_deploy_source = build_limine.getOutputSource(),
        .limine_directory = undefined,
        .limine_directory_source = undefined,
    };
    self.limine_directory = .{ .step = &self.step };
    self.limine_directory_source = .{ .generated = &self.limine_directory };

    self.step.dependOn(&build_limine.step);

    return self;
}

fn make(step: *Step, prog_node: *std.Progress.Node) !void {
    _ = prog_node;
    const self = @fieldParentPtr(LimineStep, "step", step);
    self.limine_directory.path = self.__limine_directory;
}

const DownloadLimineStep = struct {
    step: Step,

    limine_directory: []const u8,

    pub fn create(b: *std.Build, limine_directory: []const u8) !*DownloadLimineStep {
        const self = try b.allocator.create(DownloadLimineStep);

        self.* = .{
            .step = Step.init(.{
                .id = .custom,
                .name = "download limine",
                .owner = b,
                .makeFn = downloadLimineMake,
            }),
            .limine_directory = limine_directory,
        };

        return self;
    }

    fn downloadLimineMake(step: *Step, prog_node: *std.Progress.Node) !void {
        var node = prog_node.start("downloading limine", 2);
        defer node.end();

        const b = step.owner;
        const self = @fieldParentPtr(DownloadLimineStep, "step", step);

        // attempt to git pull in a pre-existing limine directory
        run(b, &.{
            "git",
            "-C",
            self.limine_directory,
            "pull",
        }) catch {
            // pull failed, so attempt to clone

            node.completeOne();

            run(b, &.{
                "git",
                "clone",
                "-b",
                "v4.x-branch-binary",
                "--depth=1",
                "--single-branch",
                "https://github.com/limine-bootloader/limine.git",
                self.limine_directory,
            }) catch {
                return step.fail("failed to download limine", .{});
            };
        };
    }

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
