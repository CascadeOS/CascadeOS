// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;

const Options = @This();

optimize: std.builtin.OptimizeMode,

version: []const u8,

// build options

/// if this is true then library tests are built for the host and execution is attempted
build_for_host: bool,

// qemu options

/// enable qemu monitor
qemu_monitor: bool,

/// enable qemu remote debug
qemu_debug: bool,

/// disable qemu graphical display
/// TODO: Enable display by default when we have a graphical display https://github.com/CascadeOS/CascadeOS/issues/11
no_display: bool,

/// disable usage of any virtualisation accelerators
/// defaults to false, if qemu interrupt details is requested then this is *forced* to true
no_acceleration: bool,

/// show detailed qemu interrupt details
interrupt_details: bool,

/// number of cores
smp: usize,

/// force qemu to run in UEFI mode
/// defaults to false, some architectures always run in UEFI mode
uefi: bool,

/// how much memory to request from qemu
/// defaults to 256mb in UEFI mode and 128mb otherwise
memory: usize,

// kernel options

/// force the provided log scopes to be debug (comma seperated list of wildcard scope matchers)
scopes_to_force_debug: []const u8,

/// force the log level of every scope to be debug in the kernel
force_debug_log: bool,

kernel_option_module: *std.Build.Module,
kernel_target_option_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module),

cascade_option_module: *std.Build.Module,
non_cascade_option_module: *std.Build.Module,

pub fn get(b: *std.Build, cascade_version: std.builtin.Version, all_targets: []const CascadeTarget) !Options {
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

    const qemu_debug = b.option(
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

    const smp = b.option(
        usize,
        "smp",
        "Number of cores (default 1)",
    ) orelse 1;

    if (smp == 0) {
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

    const force_debug_log = b.option(
        bool,
        "force_debug_log",
        "Force the log level of every scope to be debug in the kernel",
    ) orelse false;

    const scopes_to_force_debug = b.option(
        []const u8,
        "debug_scope",
        "Forces the provided log scopes to be debug (comma seperated list of wildcard scope matchers)",
    ) orelse "";

    const version = try getVersionString(b, cascade_version);

    return .{
        .optimize = b.standardOptimizeOption(.{}),
        .version = version,
        .build_for_host = build_for_host,
        .qemu_monitor = qemu_monitor,
        .qemu_debug = qemu_debug,
        .no_display = no_display,
        .no_acceleration = no_acceleration,
        .interrupt_details = interrupt_details,
        .smp = smp,
        .uefi = uefi,
        .memory = memory,
        .force_debug_log = force_debug_log,
        .scopes_to_force_debug = scopes_to_force_debug,
        .kernel_option_module = try buildKernelOptionModule(
            b,
            force_debug_log,
            scopes_to_force_debug,
            version,
        ),
        .kernel_target_option_modules = try buildKernelTargetOptionModules(b, all_targets),
        .cascade_option_module = buildCascadeOptionModule(b, true),
        .non_cascade_option_module = buildCascadeOptionModule(b, false),
    };
}

fn buildCascadeOptionModule(b: *std.Build, value: bool) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "cascade", value);
    return options.createModule();
}

fn buildKernelTargetOptionModules(
    b: *std.Build,
    all_targets: []const CascadeTarget,
) !std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module) {
    var target_option_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module) = .{};
    errdefer target_option_modules.deinit(b.allocator);

    try target_option_modules.ensureTotalCapacity(b.allocator, @intCast(u32, all_targets.len));

    for (all_targets) |target| {
        const target_options = b.addOptions();

        addTargetOptions(target_options, target);

        target_option_modules.putAssumeCapacityNoClobber(target, target_options.createModule());
    }

    return target_option_modules;
}

fn buildKernelOptionModule(
    b: *std.Build,
    force_debug_log: bool,
    scopes_to_force_debug: []const u8,
    version: []const u8,
) !*std.Build.Module {
    const root_path = std.fmt.allocPrint(
        b.allocator,
        comptime "{s}" ++ std.fs.path.sep_str,
        .{b.build_root.path.?},
    ) catch unreachable;

    const kernel_options = b.addOptions();

    kernel_options.addOption([]const u8, "version", version);

    kernel_options.addOption(bool, "force_debug_log", force_debug_log);
    addStringLiteralSliceOption(kernel_options, "scopes_to_force_debug", scopes_to_force_debug);

    kernel_options.addOption([]const u8, "root_path", root_path);

    return kernel_options.createModule();
}

fn addStringLiteralSliceOption(options: *Step.Options, name: []const u8, buffer: []const u8) void {
    const out = options.contents.writer();

    out.print("pub const {}: []const []const u8 = &.{{", .{std.zig.fmtId(name)}) catch unreachable;

    var iter = std.mem.split(u8, buffer, ",");
    while (iter.next()) |value| {
        if (value.len != 0) out.print("\"{s}\",", .{value}) catch unreachable;
    }

    out.writeAll("};\n") catch unreachable;
}

fn addEnumType(options: *Step.Options, name: []const u8, comptime EnumT: type) void {
    const out = options.contents.writer();

    out.print("pub const {} = enum {{\n", .{std.zig.fmtId(name)}) catch unreachable;

    inline for (std.meta.tags(EnumT)) |tag| {
        out.print("    {s},\n", .{std.zig.fmtId(@tagName(tag))}) catch unreachable;
    }

    out.writeAll("};\n") catch unreachable;
}

fn addTargetOptions(options: *Step.Options, target: CascadeTarget) void {
    addEnumType(options, "Arch", CascadeTarget);

    const out = options.contents.writer();

    out.print("pub const arch: Arch = .{s};\n", .{std.zig.fmtId(@tagName(target))}) catch unreachable;
}

fn getVersionString(b: *std.Build, version: std.builtin.Version) ![]const u8 {
    const version_string = b.fmt(
        "{d}.{d}.{d}",
        .{ version.major, version.minor, version.patch },
    );

    var code: u8 = undefined;
    const git_describe_untrimmed = b.execAllowFail(&[_][]const u8{
        "git", "-C", b.build_root.path.?, "describe", "--match", "*.*.*", "--tags",
    }, &code, .Ignore) catch {
        return version_string;
    };
    const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");

    switch (std.mem.count(u8, git_describe, "-")) {
        0 => {
            // Tagged release version (e.g. 0.8.0).
            if (!std.mem.eql(u8, git_describe, version_string)) {
                std.debug.print(
                    "version '{s}' does not match Git tag '{s}'\n",
                    .{ version_string, git_describe },
                );
                std.process.exit(1);
            }
            return version_string;
        },
        2 => {
            // Untagged development build (e.g. 0.8.0-684-gbbe2cca1a).
            var it = std.mem.split(u8, git_describe, "-");
            const tagged_ancestor = it.next() orelse unreachable;
            const commit_height = it.next() orelse unreachable;
            const commit_id = it.next() orelse unreachable;

            const ancestor_ver = try std.builtin.Version.parse(tagged_ancestor);
            if (version.order(ancestor_ver) != .gt) {
                std.debug.print(
                    "version '{}' must be greater than tagged ancestor '{}'\n",
                    .{ version, ancestor_ver },
                );
                std.process.exit(1);
            }

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                std.debug.print("unexpected `git describe` output: {s}\n", .{git_describe});
                return version_string;
            }

            // The version is reformatted in accordance with the https://semver.org specification.
            return b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
        },
        else => {
            std.debug.print("unexpected `git describe` output: {s}\n", .{git_describe});
            return version_string;
        },
    }
}
