// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;

const Options = @This();

optimize: std.builtin.OptimizeMode,

/// CascadeOS version.
cascade_version_string: []const u8,

/// If true, library tests are built for the host and execution is attempted.
build_for_host: bool,

/// Enable QEMU monitor.
qemu_monitor: bool,

/// Enable QEMU remote debug.
qemu_remote_debug: bool,

/// Disable QEMU graphical display.
/// TODO: Enable display by default when we have a graphical display https://github.com/CascadeOS/CascadeOS/issues/11
no_display: bool,

/// Disable usage of any virtualization accelerators.
///
/// Defaults to false, forced to true if interrupt_details is requested.
no_acceleration: bool,

/// Show detailed QEMU interrupt details.
interrupt_details: bool,

/// Number of cores.
number_of_cores: usize,

/// Force QEMU to run in UEFI mode.
///
/// Defaults to false, some architectures always run in UEFI mode.
uefi: bool,

/// How much memory (in MB) to request from QEMU.
///
/// Defaults to 256 for UEFI and 128 otherwise.
memory: usize,

/// Force the provided log scopes to be debug in the kernel (comma separated list of wildcard scope matchers).
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
        "Library tests are built for the host and execution is attempted",
    ) orelse false;

    const qemu_monitor = b.option(
        bool,
        "monitor",
        "Enable qemu monitor",
    ) orelse false;

    const qemu_remote_debug = b.option(
        bool,
        "debug",
        "Enable qemu remote debug",
    ) orelse false;

    const no_display = b.option(
        bool,
        "no_display",
        "Disable qemu graphical display (defaults to true)",
    ) orelse true;

    const interrupt_details = b.option(
        bool,
        "interrupts",
        "Show detailed qemu interrupt details (disables acceleration)",
    ) orelse false;

    const uefi = b.option(
        bool,
        "uefi",
        "Force qemu to run in UEFI mode",
    ) orelse false;

    const number_of_cores = b.option(
        usize,
        "cores",
        "Number of cores (default 1)",
    ) orelse 1;

    if (number_of_cores == 0) {
        std.debug.print("number of cores must be greater than zero", .{});
        return error.InvalidNumberOfCoreRequested;
    }

    const no_acceleration = blk: {
        if (b.option(bool, "no_acceleration", "Disable usage of QEMU accelerators")) |value| {
            if (value) break :blk true else {
                if (interrupt_details) std.debug.panic("cannot enable QEMU accelerators and show qemu interrupt details", .{});
            }
        }
        break :blk interrupt_details;
    };

    const memory: usize = b.option(
        usize,
        "memory",
        "How much memory (in MB) to request from qemu (defaults to 256 for UEFI and 128 otherwise)",
    ) orelse if (uefi) 256 else 128;

    const kernel_force_debug_log = b.option(
        bool,
        "force_debug_log",
        "Force the log level of every scope to be debug in the kernel",
    ) orelse false;

    const kernel_forced_debug_log_scopes = b.option(
        []const u8,
        "debug_scope",
        "Force the provided log scopes to be debug in the kernel (comma separated list of wildcard scope matchers)",
    ) orelse "";

    const cascade_version_string = try getVersionString(b, cascade_version);

    return .{
        .optimize = b.standardOptimizeOption(.{}),
        .cascade_version_string = cascade_version_string,
        .build_for_host = build_for_host,
        .qemu_monitor = qemu_monitor,
        .qemu_remote_debug = qemu_remote_debug,
        .no_display = no_display,
        .no_acceleration = no_acceleration,
        .interrupt_details = interrupt_details,
        .number_of_cores = number_of_cores,
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

fn buildKernelOptionModule(
    b: *std.Build,
    force_debug_log: bool,
    forced_debug_log_scopes: []const u8,
    cascade_version_string: []const u8,
) !*std.Build.Module {
    const root_path = std.fmt.allocPrint(
        b.allocator,
        comptime "{s}" ++ std.fs.path.sep_str,
        .{b.build_root.path.?},
    ) catch unreachable;

    const kernel_options = b.addOptions();

    kernel_options.addOption([]const u8, "cascade_version", cascade_version_string);

    kernel_options.addOption(bool, "force_debug_log", force_debug_log);
    addStringLiteralSliceOption(kernel_options, "forced_debug_log_scopes", forced_debug_log_scopes);

    kernel_options.addOption([]const u8, "root_path", root_path);

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
        out.print("    {s},\n", .{std.zig.fmtId(@tagName(tag))}) catch unreachable;
    }

    out.writeAll("};\n") catch unreachable;
}

fn addTargetOptions(options: *Step.Options, target: CascadeTarget) void {
    addEnumType(options, "Arch", CascadeTarget);

    const out = options.contents.writer();

    out.print("pub const arch: Arch = .{s};\n", .{std.zig.fmtId(@tagName(target))}) catch unreachable;
}

/// Gets the version string.
fn getVersionString(b: *std.Build, base_semantic_version: std.SemanticVersion) ![]const u8 {
    const version_string = b.fmt(
        "{d}.{d}.{d}",
        .{ base_semantic_version.major, base_semantic_version.minor, base_semantic_version.patch },
    );

    var exit_code: u8 = undefined;
    const raw_git_describe_output = b.runAllowFail(&[_][]const u8{
        "git", "-C", b.build_root.path.?, "describe", "--match", "*.*.*", "--tags",
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
