// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const EDK2Step = @import("EDK2Step.zig");
const ImageStep = @import("ImageStep.zig");
const Options = @import("Options.zig");
const StepCollection = @import("StepCollection.zig");

const QemuStep = @This();

step: Step,
image: std.Build.FileSource,

target: CascadeTarget,
options: Options,

uefi: bool,

/// Only non-null if uefi is true
edk2_step: ?*EDK2Step,

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

        const qemu_step = try QemuStep.create(b, target, image_step.image_file_source, options);

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

fn create(b: *std.Build, target: CascadeTarget, image: std.Build.FileSource, options: Options) !*QemuStep {
    const uefi = options.uefi or target.needsUefi();

    const edk2_step: ?*EDK2Step = if (uefi) try EDK2Step.create(b, target) else null;

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
        .uefi = uefi,
        .edk2_step = edk2_step,
    };

    if (uefi) {
        self.step.dependOn(&edk2_step.?.step);
    }

    image.addStepDependencies(&self.step);

    return self;
}

fn make(step: *Step, prog_node: *std.Progress.Node) !void {
    const b = step.owner;
    const self = @fieldParentPtr(QemuStep, "step", step);

    const run_qemu = b.addSystemCommand(&.{self.target.qemuExecutable()});

    run_qemu.has_side_effects = true;
    run_qemu.stdio = .inherit;

    // no reboot
    if (self.options.qemu_remote_debug) run_qemu.addArg("-no-reboot");

    // no shutdown
    if (self.options.qemu_remote_debug) run_qemu.addArg("-no-shutdown");

    // no default devices
    run_qemu.addArg("-nodefaults");

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
            .{self.options.number_of_cores},
        ),
    });

    // interrupt details
    if (self.options.interrupt_details) {
        if (self.target == .x86_64) {
            // The "-M smm=off" below disables the SMM generated spam that happens before the kernel starts.
            run_qemu.addArgs(&[_][]const u8{ "-d", "int", "-M", "smm=off" });
        } else {
            run_qemu.addArgs(&[_][]const u8{ "-d", "int" });
        }
    }

    // qemu monitor
    if (self.options.qemu_monitor) {
        run_qemu.addArgs(&[_][]const u8{ "-serial", "mon:stdio" });
    } else {
        run_qemu.addArgs(&[_][]const u8{ "-serial", "stdio" });
    }

    // gdb remote debug
    if (self.options.qemu_remote_debug) {
        run_qemu.addArgs(&[_][]const u8{ "-s", "-S" });
    }

    // no display
    if (self.options.no_display) {
        run_qemu.addArgs(&[_][]const u8{ "-display", "none" });
    }

    // set target cpu
    self.target.setQemuCpu(run_qemu);

    // set target machine
    self.target.setQemuMachine(run_qemu);

    // qemu acceleration
    const should_use_acceleration = !self.options.no_acceleration and self.target.isNative(b);
    if (should_use_acceleration) {
        switch (b.host.target.os.tag) {
            .linux => if (helpers.fileExists("/dev/kvm")) run_qemu.addArgs(&[_][]const u8{ "-accel", "kvm" }),
            .macos => run_qemu.addArgs(&[_][]const u8{ "-accel", "hvf" }),
            .windows => run_qemu.addArgs(&[_][]const u8{ "-accel", "whpx" }),
            else => std.debug.panic("unsupported host operating system: {s}", .{@tagName(b.host.target.os.tag)}),
        }
    }

    // always add tcg as the last accelerator
    run_qemu.addArgs(&[_][]const u8{ "-accel", "tcg" });

    // UEFI
    if (self.uefi) {
        run_qemu.addArgs(&[_][]const u8{ "-bios", self.edk2_step.?.firmware.getPath() });
    }

    // This is a hack to stop zig's progress output interfering with qemu's output
    try ensureCurrentStdoutLineIsEmpty();

    var timer = try std.time.Timer.start();

    try run_qemu.step.make(prog_node);

    step.result_duration_ns = timer.read();
}

fn ensureCurrentStdoutLineIsEmpty() !void {
    const stdout = std.io.getStdOut();
    const tty_config = std.io.tty.detectConfig(stdout);
    switch (tty_config) {
        .no_color, .windows_api => {
            try stdout.writeAll("\r\n");
        },
        .escape_codes => {
            // clear the current line and return the cursor to the beginning of the line
            try stdout.writeAll("\x1b[2K\r");
        },
    }
}
