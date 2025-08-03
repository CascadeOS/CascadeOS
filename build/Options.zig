// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const Options = @This();

/// The build directory root path
root_path: []const u8,

optimize: std.builtin.OptimizeMode,

/// CascadeOS version.
cascade_version_string: []const u8,

/// Enable QEMU monitor.
///
/// Defaults to false.
qemu_monitor: bool,

/// Enable QEMU remote debug.
///
/// If true, disables acceleration and KASLR.
///
/// Defaults to false.
qemu_remote_debug: bool,

/// Provide a graphical display in QEMU.
///
/// Defaults to false.
display: bool,

/// Disable ACPI in QEMU if the architecture supports it.
///
/// Defaults to false.
no_acpi: bool,

/// Disable usage of any virtualization acceleration.
///
/// Defaults to false.
///
/// Forced to true if `interrupt_details` is true.
no_acceleration: bool,

/// Show detailed QEMU interrupt details.
///
/// If true, disables acceleration.
///
/// Defaults to false.
interrupt_details: bool,

/// Number of cpus.
///
/// Defaults to 1.
number_of_cpus: usize,

/// Force QEMU to run in UEFI mode.
///
/// Defaults to false, some architectures always run in UEFI mode.
uefi: bool,

/// How much memory (in MB) to request from QEMU.
///
/// Defaults to 256 for UEFI and 128 otherwise.
memory: usize,

/// Disable KASLR.
///
/// Defaults to false.
no_kaslr: bool,

/// In the kernel, set the log level to be either debug or verbose.
kernel_log_level: ?ForceLogLevel,

/// In the kernel, force the provided log scopes to be logged.
///
/// If a scope ends with a `+` it will match any scope that starts with the prefix.
///
/// Example:
/// `virtual,init+,physical` will exact match `virtual` and `physical` and match any scope that starts with `init`.
kernel_log_scopes: []const []const u8,

/// Disable the kernel log wrapper.
///
/// Defaults to false.
no_kernel_log_wrapper: bool,

/// Module containing kernel options.
kernel_option_module: *std.Build.Module,

/// Hash map of `CascadeTarget.Architecture` to module containing architecture-specific kernel options.
architecture_specific_kernel_options_modules: Modules,

cascade_detect_option_module: *std.Build.Module,
non_cascade_detect_option_module: *std.Build.Module,

const ForceLogLevel = enum { debug, verbose };

pub fn get(b: *std.Build, cascade_version: std.SemanticVersion, all_architectures: []const CascadeTarget.Architecture) !Options {
    const qemu_monitor = b.option(
        bool,
        "monitor",
        "Enable QEMU monitor (defaults to false)",
    ) orelse false;

    const qemu_remote_debug = b.option(
        bool,
        "debug",
        "Enable QEMU remote debug (disables acceleration) (defaults to false)",
    ) orelse false;

    const no_acpi = b.option(
        bool,
        "no_acpi",
        "Disable ACPI in QEMU if the architecture supports it (defaults to false)",
    ) orelse false;

    const display = b.option(
        bool,
        "display",
        "Provide a graphical display in QEMU.",
    ) orelse false;

    const interrupt_details = b.option(
        bool,
        "interrupts",
        "Show detailed QEMU interrupt details (disables acceleration) (defaults to false)",
    ) orelse false;

    const uefi = b.option(
        bool,
        "uefi",
        "Force QEMU to run in UEFI mode (defaults to false)",
    ) orelse false;

    const number_of_cpus = b.option(
        usize,
        "cpus",
        "Number of cpus (defaults to 1)",
    ) orelse 1;

    if (number_of_cpus == 0) {
        std.debug.print("number of cpus must be greater than zero", .{});
        std.process.exit(1);
    }

    const no_acceleration = blk: {
        if (b.option(bool, "no_acceleration", "Disable usage of QEMU acceleration (defaults to false)")) |value| {
            if (value) {
                // user has explicitly requested acceleration to be **disabled**
                break :blk true;
            }

            // user has explicitly requested acceleration to be **enabled**

            if (interrupt_details) {
                std.debug.print("ERROR: cannot enable QEMU acceleration and show QEMU interrupt details\n", .{});
                std.process.exit(1);
            }

            if (qemu_remote_debug)
                std.debug.print("WARNING: QEMU remote debug is buggy when enabling QEMU acceleration\n", .{});

            break :blk false;
        }

        break :blk interrupt_details or qemu_remote_debug;
    };

    const memory: usize = b.option(
        usize,
        "memory",
        "How much memory (in MB) to request from QEMU (defaults to 256 for UEFI and 128 otherwise)",
    ) orelse if (uefi) 256 else 128;

    const no_kaslr = b.option(
        bool,
        "no_kaslr",
        "Disable KASLR (defaults to false)",
    ) orelse if (qemu_remote_debug) true else false;

    const kernel_log_level = b.option(
        ForceLogLevel,
        "kernel_log_level",
        "In the kernel, set the log level to be either debug or verbose.",
    );

    const kernel_log_scopes_raw = b.option(
        []const u8,
        "kernel_log_scopes",
        "In the kernel, force the provided log scopes to be logged (comma separated list of scope matchers, scopes ending with `+` will match any scope that starts with the prefix).",
    ) orelse "";

    const no_kernel_log_wrapper = b.option(
        bool,
        "no_log_wrapper",
        "Disable the kernel log wrapper (defaults to false)",
    ) orelse false;

    const root_path = std.fmt.allocPrint(
        b.allocator,
        comptime "{s}" ++ std.fs.path.sep_str,
        .{b.build_root.path.?},
    ) catch unreachable;

    const cascade_version_string = try getVersionString(b, cascade_version, root_path);

    const kernel_log_scopes = blk: {
        var kernel_log_scopes: std.ArrayList([]const u8) = .init(b.allocator);
        errdefer kernel_log_scopes.deinit();

        var iter = std.mem.splitScalar(u8, kernel_log_scopes_raw, ',');
        while (iter.next()) |scope| {
            if (scope.len != 0) try kernel_log_scopes.append(scope);
        }

        break :blk try kernel_log_scopes.toOwnedSlice();
    };

    return .{
        .root_path = root_path,
        .optimize = b.standardOptimizeOption(.{}),
        .cascade_version_string = cascade_version_string,
        .qemu_monitor = qemu_monitor,
        .qemu_remote_debug = qemu_remote_debug,
        .no_acpi = no_acpi,
        .display = display,
        .no_acceleration = no_acceleration,
        .interrupt_details = interrupt_details,
        .number_of_cpus = number_of_cpus,
        .uefi = uefi,
        .memory = memory,
        .no_kaslr = no_kaslr,
        .kernel_log_level = kernel_log_level,
        .kernel_log_scopes = kernel_log_scopes,
        .no_kernel_log_wrapper = no_kernel_log_wrapper,
        .kernel_option_module = try buildKernelOptionModule(
            b,
            kernel_log_level,
            kernel_log_scopes,
            cascade_version_string,
        ),
        .architecture_specific_kernel_options_modules = try buildKernelArchitectureOptionModules(b, all_architectures),
        .cascade_detect_option_module = buildCascadeDetectOptionModule(b, .cascade),
        .non_cascade_detect_option_module = buildCascadeDetectOptionModule(b, .non_cascade),
    };
}

/// Creates a option module containing a single `cascade` boolean.
///
/// This module can be used to detect if we are running on cascade or not.
fn buildCascadeDetectOptionModule(b: *std.Build, context: CascadeTarget.Context) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "is_cascade", switch (context) {
        .cascade => true,
        .non_cascade => false,
    });
    return options.createModule();
}

/// Creates a hash map of `CascadeTarget.Architecture` to modules containing architecture-specific options.
fn buildKernelArchitectureOptionModules(
    b: *std.Build,
    all_architectures: []const CascadeTarget.Architecture,
) !Modules {
    var architecture_option_modules: Modules = .{};
    errdefer architecture_option_modules.deinit(b.allocator);

    try architecture_option_modules.ensureTotalCapacity(b.allocator, @intCast(all_architectures.len));

    for (all_architectures) |architecture| {
        const architecture_options = b.addOptions();

        architecture_options.addOption(CascadeTarget.Architecture, "arch", architecture);

        architecture_option_modules.putAssumeCapacityNoClobber(architecture, architecture_options.createModule());
    }

    return architecture_option_modules;
}

/// Create a module containing target independent kernel options.
fn buildKernelOptionModule(
    b: *std.Build,
    kernel_log_level: ?ForceLogLevel,
    kernel_log_scopes: []const []const u8,
    cascade_version_string: []const u8,
) !*std.Build.Module {
    const kernel_options = b.addOptions();

    kernel_options.addOption([]const u8, "cascade_version", cascade_version_string);

    if (kernel_log_level) |force_log_level| {
        kernel_options.addOption(ForceLogLevel, "force_log_level", force_log_level);
    }

    kernel_options.addOption([]const []const u8, "kernel_log_scopes", kernel_log_scopes);

    return kernel_options.createModule();
}

/// Gets the version string.
fn getVersionString(b: *std.Build, base_semantic_version: std.SemanticVersion, root_path: []const u8) ![]const u8 {
    const version_string = b.fmt(
        "{d}.{d}.{d}",
        .{ base_semantic_version.major, base_semantic_version.minor, base_semantic_version.patch },
    );

    var exit_code: u8 = undefined;
    const raw_git_describe_output = b.runAllowFail(&[_][]const u8{
        "git", "-C", root_path, "--git-dir", ".git", "describe", "--match", "*.*.*", "--tags", "--abbrev=9",
    }, &exit_code, .Ignore) catch {
        return b.fmt("{s}-unknown", .{version_string});
    };
    const git_describe_output = std.mem.trim(u8, raw_git_describe_output, " \n\r");

    switch (std.mem.count(u8, git_describe_output, "-")) {
        0 => {
            // Tagged release version (e.g. 0.8.0).
            if (!std.mem.eql(u8, git_describe_output, version_string)) {
                std.debug.print(
                    "version '{s}' does not match Git tag '{s}'\n",
                    .{ version_string, git_describe_output },
                );
                std.process.exit(1);
            }
            return version_string;
        },
        2 => {
            // Untagged development build (e.g. 0.8.0-684-gbbe2cca1a).
            var hash_iterator = std.mem.splitScalar(u8, git_describe_output, '-');
            const tagged_ancestor_version_string = hash_iterator.next() orelse unreachable;
            const commit_height = hash_iterator.next() orelse unreachable;
            const commit_id = hash_iterator.next() orelse unreachable;

            const ancestor_version = try std.SemanticVersion.parse(tagged_ancestor_version_string);
            if (base_semantic_version.order(ancestor_version) != .gt) {
                std.debug.print(
                    "version '{f}' must be greater than tagged ancestor '{f}'\n",
                    .{ base_semantic_version, ancestor_version },
                );
                std.process.exit(1);
            }

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                std.debug.print("unexpected `git describe` output: {s}\n", .{git_describe_output});
                return version_string;
            }

            // The version is reformatted in accordance with the https://semver.org specification.
            return b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
        },
        else => {
            std.debug.print("unexpected `git describe` output: {s}\n", .{git_describe_output});
            return version_string;
        },
    }
}

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Modules = std.AutoHashMapUnmanaged(CascadeTarget.Architecture, *std.Build.Module);
