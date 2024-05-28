// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;

const Options = @This();

/// The build directory root path
root_path: []const u8,

optimize: std.builtin.OptimizeMode,

/// CascadeOS version.
cascade_version_string: []const u8,

/// If true, library tests are built for the host and execution is attempted.
build_for_host: bool,

/// Enable QEMU monitor.
///
/// Defaults to false.
qemu_monitor: bool,

/// Enable QEMU remote debug.
///
/// If true, disables acceleration.
///
/// Defaults to false.
qemu_remote_debug: bool,

/// Disable QEMU graphical display.
///
/// Defaults to false.
no_display: bool,

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

/// Force the provided log scopes to be debug in the kernel (comma separated list of scope matchers).
///
/// If a scope ends with a `+` it will match any scope that starts with the prefix.
///
/// Example:
/// `virtual,init+,physical` will exact match `virtual` and `physcial` and match any scope that starts with `init`.
kernel_forced_debug_log_scopes: []const u8,

/// Force the log level of every scope to be debug in the kernel.
kernel_force_debug_log: bool,

/// Module containing kernel options.
kernel_option_module: *std.Build.Module,

/// Hash map of target to module containing target-specific kernel options.
target_specific_kernel_options_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module),

/// Module containing CascadeOS options.
cascade_os_options_module: *std.Build.Module,

/// Module containing non-CascadeOS options.
non_cascade_os_options_module: *std.Build.Module,

pub fn get(b: *std.Build, cascade_version: std.SemanticVersion, targets: []const CascadeTarget) !Options {
    const build_for_host = b.option(
        bool,
        "build_for_host",
        "Library tests are built for the host and execution is attempted (defaults to false)",
    ) orelse false;

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

    const no_display = b.option(
        bool,
        "no_display",
        "Disable QEMU graphical display (defaults to true)",
    ) orelse true;

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

    const kernel_force_debug_log = b.option(
        bool,
        "force_debug_log",
        "Force the log level of every scope to be debug in the kernel",
    ) orelse false;

    const kernel_forced_debug_log_scopes = b.option(
        []const u8,
        "debug_scope",
        "Force the provided log scopes to be debug in the kernel (comma separated list of scope matchers, scopes ending with `+` will match any scope that starts with the prefix).",
    ) orelse "";

    const root_path = std.fmt.allocPrint(
        b.allocator,
        comptime "{s}" ++ std.fs.path.sep_str,
        .{b.build_root.path.?},
    ) catch unreachable;

    const cascade_version_string = try getVersionString(b, cascade_version, root_path);

    return .{
        .root_path = root_path,
        .optimize = b.standardOptimizeOption(.{}),
        .cascade_version_string = cascade_version_string,
        .build_for_host = build_for_host,
        .qemu_monitor = qemu_monitor,
        .qemu_remote_debug = qemu_remote_debug,
        .no_display = no_display,
        .no_acceleration = no_acceleration,
        .interrupt_details = interrupt_details,
        .number_of_cpus = number_of_cpus,
        .uefi = uefi,
        .memory = memory,
        .kernel_force_debug_log = kernel_force_debug_log,
        .kernel_forced_debug_log_scopes = kernel_forced_debug_log_scopes,
        .kernel_option_module = try buildKernelOptionModule(
            b,
            kernel_force_debug_log,
            kernel_forced_debug_log_scopes,
            cascade_version_string,
        ),
        .target_specific_kernel_options_modules = try buildKernelTargetOptionModules(b, targets),
        .cascade_os_options_module = buildCascadeOptionModule(b, true),
        .non_cascade_os_options_module = buildCascadeOptionModule(b, false),
    };
}

/// Creates a option module containing a single `cascade` boolean.
///
/// This module can be used to detect if we are running on cascade or not.
fn buildCascadeOptionModule(b: *std.Build, is_cascade: bool) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "is_cascade", is_cascade);
    return options.createModule();
}

/// Creates a hash map of targets to modules containing target-specific options.
fn buildKernelTargetOptionModules(
    b: *std.Build,
    targets: []const CascadeTarget,
) !std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module) {
    var target_option_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module) = .{};
    errdefer target_option_modules.deinit(b.allocator);

    try target_option_modules.ensureTotalCapacity(b.allocator, @intCast(targets.len));

    for (targets) |target| {
        const target_options = b.addOptions();

        addTargetOptions(target_options, target);

        target_option_modules.putAssumeCapacityNoClobber(target, target_options.createModule());
    }

    return target_option_modules;
}

/// Create a module containing target independent kernel options.
fn buildKernelOptionModule(
    b: *std.Build,
    force_debug_log: bool,
    forced_debug_log_scopes: []const u8,
    cascade_version_string: []const u8,
) !*std.Build.Module {
    const kernel_options = b.addOptions();

    kernel_options.addOption([]const u8, "cascade_version", cascade_version_string);

    kernel_options.addOption(bool, "force_debug_log", force_debug_log);
    addStringLiteralSliceOption(kernel_options, "forced_debug_log_scopes", forced_debug_log_scopes);

    return kernel_options.createModule();
}

/// Adds a string literal slice option to the options.
fn addStringLiteralSliceOption(options: *Step.Options, name: []const u8, buffer: []const u8) void {
    const out = options.contents.writer();

    out.print("pub const {}: []const []const u8 = &.{{", .{std.zig.fmtId(name)}) catch unreachable;

    var iter = std.mem.split(u8, buffer, ",");
    while (iter.next()) |value| {
        if (value.len != 0) out.print("\"{s}\",", .{value}) catch unreachable;
    }

    out.writeAll("};\n") catch unreachable;
}

/// Adds an enum type option to the options.
fn addEnumType(options: *Step.Options, name: []const u8, comptime EnumT: type) void {
    const out = options.contents.writer();

    out.print("pub const {} = enum {{\n", .{std.zig.fmtId(name)}) catch unreachable;

    for (std.meta.tags(EnumT)) |tag| {
        out.print("    {},\n", .{std.zig.fmtId(@tagName(tag))}) catch unreachable;
    }

    out.writeAll("};\n") catch unreachable;
}

/// Adds target-specific options to the options.
fn addTargetOptions(options: *Step.Options, target: CascadeTarget) void {
    addEnumType(options, "Arch", CascadeTarget);

    const out = options.contents.writer();

    out.print("pub const arch: Arch = .{};\n", .{std.zig.fmtId(@tagName(target))}) catch unreachable;
}

/// Gets the version string.
fn getVersionString(b: *std.Build, base_semantic_version: std.SemanticVersion, root_path: []const u8) ![]const u8 {
    const version_string = b.fmt(
        "{d}.{d}.{d}",
        .{ base_semantic_version.major, base_semantic_version.minor, base_semantic_version.patch },
    );

    var exit_code: u8 = undefined;
    const raw_git_describe_output = b.runAllowFail(&[_][]const u8{
        "git", "-C", root_path, "describe", "--match", "*.*.*", "--tags", "--abbrev=9",
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
            var hash_iterator = std.mem.split(u8, git_describe_output, "-");
            const tagged_ancestor_version_string = hash_iterator.next() orelse unreachable;
            const commit_height = hash_iterator.next() orelse unreachable;
            const commit_id = hash_iterator.next() orelse unreachable;

            const ancestor_version = try std.SemanticVersion.parse(tagged_ancestor_version_string);
            if (base_semantic_version.order(ancestor_version) != .gt) {
                std.debug.print(
                    "version '{}' must be greater than tagged ancestor '{}'\n",
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
