// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const ImageStep = @import("ImageStep.zig");
const Options = @import("Options.zig");

const QemuStep = @This();

pub const Collection = std.AutoHashMapUnmanaged(CascadeTarget, *QemuStep);

step: Step,
image: std.Build.FileSource,

target: CascadeTarget,
options: Options,

pub fn getQemuSteps(
    b: *std.Build,
    image_steps: ImageStep.Collection,
    options: Options,
    all_targets: []const CascadeTarget,
) !Collection {
    var qemu_steps: Collection = .{};
    try qemu_steps.ensureTotalCapacity(b.allocator, @intCast(u32, all_targets.len));

    for (all_targets) |target| {
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

        qemu_steps.putAssumeCapacityNoClobber(target, qemu_step);
    }

    return qemu_steps;
}

fn create(b: *std.Build, target: CascadeTarget, image: std.Build.FileSource, options: Options) !*QemuStep {
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
    };

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
    run_qemu.addArg("-no-reboot");

    // RAM
    run_qemu.addArgs(&.{
        "-m",
        try std.fmt.allocPrint(b.allocator, "{d}", .{self.options.memory}),
    });

    // boot disk
    run_qemu.addArgs(&.{
        "-drive",
        try std.fmt.allocPrint(
            b.allocator,
            "file={s},format=raw,if=virtio",
            .{self.image.getPath(b)},
        ),
    });

    // multicore
    run_qemu.addArgs(&.{
        "-smp",
        try std.fmt.allocPrint(
            b.allocator,
            "{d}",
            .{self.options.smp},
        ),
    });

    // interrupt details
    if (self.options.interrupt_details) {
        run_qemu.addArgs(&[_][]const u8{ "-d", "int" });
    }

    // qemu monitor
    if (self.options.qemu_monitor) {
        run_qemu.addArgs(&[_][]const u8{ "-serial", "mon:stdio" });
    } else {
        run_qemu.addArgs(&[_][]const u8{ "-serial", "stdio" });
    }

    // gdb debug
    if (self.options.qemu_debug) {
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

    // KVM
    const should_use_kvm = !self.options.no_kvm and helpers.fileExists("/dev/kvm") and self.target.isNative(b);
    if (should_use_kvm) {
        run_qemu.addArg("-enable-kvm");
    }

    // UEFI
    if (self.options.uefi or self.target.needsUefi()) {
        const uefi_firmware_path = self.target.uefiFirmwarePath() catch {
            return step.fail("unable to locate UEFI firmware for target {}", .{self.target});
        };
        run_qemu.addArgs(&[_][]const u8{ "-bios", uefi_firmware_path });
    }

    try run_qemu.step.make(prog_node);
}
