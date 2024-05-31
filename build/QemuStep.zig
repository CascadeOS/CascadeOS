// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const ImageStep = @import("ImageStep.zig");
const Options = @import("Options.zig");
const StepCollection = @import("StepCollection.zig");

const QemuStep = @This();

step: Step,
image: std.Build.LazyPath,

target: CascadeTarget,
options: Options,

/// Only non-null if `options.uefi` is true
edk2: ?*std.Build.Dependency,

/// Registers QEMU steps for all targets.
///
/// For each target, creates a `QemuStep` that runs the image for the target using QEMU.
pub fn registerQemuSteps(
    b: *std.Build,
    image_steps: ImageStep.Collection,
    options: Options,
    targets: []const CascadeTarget,
) !void {
    for (targets) |target| {
        const image_step = image_steps.get(target).?;

        const qemu_step = try QemuStep.create(b, target, image_step.image_file, options);

        const qemu_step_name = try std.fmt.allocPrint(
            b.allocator,
            "run_{s}",
            .{@tagName(target)},
        );
        const qemu_step_description = try std.fmt.allocPrint(
            b.allocator,
            "Run the image for {s} in qemu",
            .{@tagName(target)},
        );

        const run_step = b.step(qemu_step_name, qemu_step_description);
        run_step.dependOn(&qemu_step.step);
    }
}

fn create(b: *std.Build, target: CascadeTarget, image: std.Build.LazyPath, options: Options) !*QemuStep {
    const uefi = options.uefi or needsUefi(target);

    const edk2: ?*std.Build.Dependency = if (uefi) b.dependency("edk2", .{}) else null;

    const step_name = try std.fmt.allocPrint(
        b.allocator,
        "run qemu with {s} image",
        .{@tagName(target)},
    );

    const self = try b.allocator.create(QemuStep);
    errdefer b.allocator.destroy(self);

    self.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = step_name,
            .owner = b,
            .makeFn = make,
        }),
        .image = image,
        .target = target,
        .options = options,
        .edk2 = edk2,
    };

    image.addStepDependencies(&self.step);

    return self;
}

/// Returns true if the target needs UEFI to boot.
fn needsUefi(self: CascadeTarget) bool {
    return switch (self) {
        .x64 => false,
    };
}

fn make(step: *Step, prog_node: std.Progress.Node) !void {
    _ = prog_node;

    const b = step.owner;
    const self: *QemuStep = @fieldParentPtr("step", step);

    const run_qemu = b.addSystemCommand(&.{qemuExecutable(self.target)});

    run_qemu.has_side_effects = true;
    run_qemu.stdio = .inherit;

    // no reboot
    run_qemu.addArg("-no-reboot");

    // no shutdown
    run_qemu.addArg("-no-shutdown");

    run_qemu.addArgs(&.{ "-boot", "menu=off" });

    // RAM
    run_qemu.addArgs(&.{
        "-m",
        try std.fmt.allocPrint(b.allocator, "{d}", .{self.options.memory}),
    });

    // boot disk
    run_qemu.addArgs(&.{
        "-device",
        "virtio-blk-pci,drive=drive0,bootindex=0",
        "-drive",
        try std.fmt.allocPrint(
            b.allocator,
            "file={s},format=raw,if=none,id=drive0",
            .{self.image.getPath(b)},
        ),
    });

    // multicore
    run_qemu.addArgs(&.{
        "-smp",
        try std.fmt.allocPrint(
            b.allocator,
            "{d}",
            .{self.options.number_of_cpus},
        ),
    });

    // interrupt details
    if (self.options.interrupt_details) {
        if (self.target == .x64) {
            // The "-M smm=off" below disables the SMM generated spam that happens before the kernel starts.
            run_qemu.addArgs(&[_][]const u8{ "-d", "int", "-M", "smm=off" });
        } else {
            run_qemu.addArgs(&[_][]const u8{ "-d", "int" });
        }
    }

    // gdb remote debug
    if (self.options.qemu_remote_debug) {
        run_qemu.addArgs(&[_][]const u8{ "-s", "-S" });
    }

    switch (self.options.display_mode) {
        .none => {
            if (self.options.qemu_monitor) {
                run_qemu.addArgs(&[_][]const u8{ "-serial", "mon:stdio" });
            } else {
                run_qemu.addArgs(&[_][]const u8{ "-serial", "stdio" });
            }

            run_qemu.addArgs(&[_][]const u8{ "-display", "none" });
        },
        .gtk => run_qemu.addArgs(&[_][]const u8{
            "-display",
            "gtk,grab-on-hover=off,show-tabs=on,window-close=on,show-menubar=on",
        }),
        .qemu_default => {},
    }

    // set target cpu
    switch (self.target) {
        .x64 => run_qemu.addArgs(&.{ "-cpu", "max,migratable=no,+invtsc" }),
    }

    // set target machine
    switch (self.target) {
        .x64 => run_qemu.addArgs(&[_][]const u8{ "-machine", "q35" }),
    }

    // qemu acceleration
    const should_use_acceleration = !self.options.no_acceleration and self.target.isNative(b);
    if (should_use_acceleration) {
        switch (b.host.result.os.tag) {
            .linux => if (helpers.fileExists("/dev/kvm")) run_qemu.addArgs(&[_][]const u8{ "-accel", "kvm" }),
            .macos => run_qemu.addArgs(&[_][]const u8{ "-accel", "hvf" }),
            .windows => run_qemu.addArgs(&[_][]const u8{ "-accel", "whpx" }),
            else => std.debug.panic("unsupported host operating system: {s}", .{@tagName(b.host.result.os.tag)}),
        }
    }

    // always add tcg as the last accelerator
    run_qemu.addArgs(&[_][]const u8{ "-accel", "tcg" });

    // UEFI
    if (self.edk2) |edk2| {
        std.debug.assert(self.options.uefi);

        const firmware_code = edk2.path(uefiFirmwareCodeFileName(self.target));

        run_qemu.addArgs(&[_][]const u8{
            "-drive",
            try std.fmt.allocPrint(
                b.allocator,
                "if=pflash,format=raw,unit=0,file={s},readonly=on",
                .{firmware_code.getPath2(b, step)},
            ),
        });

        const firmware_var = edk2.path(uefiFirmwareVarFileName(self.target));

        // this being readonly is not correct but preventing modifcation of a file in the cache is good
        run_qemu.addArgs(&[_][]const u8{
            "-drive",
            try std.fmt.allocPrint(
                b.allocator,
                "if=pflash,format=raw,unit=1,file={s},readonly=on",
                .{firmware_var.getPath2(b, step)},
            ),
        });
    }

    var timer = try std.time.Timer.start();

    try run_qemu.step.make(.{ .index = .none });

    step.result_duration_ns = timer.read();
}

fn uefiFirmwareCodeFileName(self: CascadeTarget) []const u8 {
    return switch (self) {
        .x64 => "x64/code.fd",
    };
}

fn uefiFirmwareVarFileName(self: CascadeTarget) []const u8 {
    return switch (self) {
        .x64 => "x64/vars.fd",
    };
}

/// Returns the name of the QEMU system executable for the given target.
fn qemuExecutable(self: CascadeTarget) []const u8 {
    return switch (self) {
        .x64 => "qemu-system-x86_64",
    };
}
