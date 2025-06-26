// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const QemuStep = @This();

step: Step,
image: std.Build.LazyPath,

architecture: CascadeTarget.Architecture,
options: Options,

firmware: Firmware,

kernel_log_wrapper_compile: ?*Step.Compile,

const Firmware = union(enum) {
    default,
    uefi: *std.Build.Dependency, // EDK2 dependency
};

/// For each architecture, creates a `QemuStep` that runs the image for the architecture using QEMU.
pub fn registerQemuSteps(
    b: *std.Build,
    image_steps: ImageStep.Collection,
    tools: Tool.Collection,
    options: Options,
    all_architectures: []const CascadeTarget.Architecture,
) !void {
    const kernel_log_wrapper = tools.get("kernel_log_wrapper").?;

    // the kernel log wrapper interferes with the qemu monitor
    const kernel_log_wrapper_compile = if (!options.qemu_monitor and !options.no_kernel_log_wrapper)
        kernel_log_wrapper.release_safe_exe
    else
        null;

    for (all_architectures) |architecture| {
        const image_step = image_steps.get(architecture).?;

        const qemu_step = try QemuStep.create(
            b,
            architecture,
            kernel_log_wrapper_compile,
            image_step.image_file,
            options,
        );

        const qemu_step_name = try std.fmt.allocPrint(
            b.allocator,
            "run_{s}",
            .{@tagName(architecture)},
        );
        const qemu_step_description = try std.fmt.allocPrint(
            b.allocator,
            "Run the image for {s} in qemu",
            .{@tagName(architecture)},
        );

        const run_step = b.step(qemu_step_name, qemu_step_description);
        run_step.dependOn(&qemu_step.step);
    }
}

fn create(
    b: *std.Build,
    architecture: CascadeTarget.Architecture,
    kernel_log_wrapper_compile: ?*Step.Compile,
    image: std.Build.LazyPath,
    options: Options,
) !*QemuStep {
    const uefi = options.uefi or needsUefi(architecture);

    const step_name = try std.fmt.allocPrint(
        b.allocator,
        "run qemu with {s} image",
        .{@tagName(architecture)},
    );

    const qemu_step = try b.allocator.create(QemuStep);
    errdefer b.allocator.destroy(qemu_step);

    qemu_step.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = step_name,
            .owner = b,
            .makeFn = make,
        }),
        .image = image,
        .architecture = architecture,
        .options = options,
        .firmware = if (uefi) .{ .uefi = b.dependency("edk2", .{}) } else .default,
        .kernel_log_wrapper_compile = kernel_log_wrapper_compile,
    };

    if (kernel_log_wrapper_compile) |compile| {
        compile.getEmittedBin().addStepDependencies(&qemu_step.step);
    }
    image.addStepDependencies(&qemu_step.step);

    return qemu_step;
}

fn make(step: *Step, options: Step.MakeOptions) !void {
    const b = step.owner;
    const qemu_step: *QemuStep = @fieldParentPtr("step", step);

    const run_qemu = if (!qemu_step.options.display and qemu_step.kernel_log_wrapper_compile != null) run_qemu: {
        const kernel_log_wrapper = qemu_step.kernel_log_wrapper_compile.?;
        const run_qemu = b.addRunArtifact(kernel_log_wrapper);
        run_qemu.addArg(qemuExecutable(qemu_step.architecture));
        break :run_qemu run_qemu;
    } else b.addSystemCommand(&.{qemuExecutable(qemu_step.architecture)});

    run_qemu.has_side_effects = true;
    run_qemu.stdio = .inherit;

    run_qemu.addArg("-nodefaults");
    run_qemu.addArg("-no-user-config");

    run_qemu.addArgs(&.{ "-boot", "menu=off" });
    run_qemu.addArgs(&.{ "-d", "guest_errors" });

    // RAM
    run_qemu.addArgs(&.{
        "-m",
        try std.fmt.allocPrint(b.allocator, "{d}", .{qemu_step.options.memory}),
    });

    // boot disk
    run_qemu.addArgs(&.{
        "-device",
        "virtio-blk-pci,drive=drive0,bootindex=0",
        "-drive",
        try std.fmt.allocPrint(
            b.allocator,
            "file={s},format=raw,if=none,id=drive0",
            .{qemu_step.image.getPath(b)},
        ),
    });

    // multicore
    run_qemu.addArgs(&.{
        "-smp",
        try std.fmt.allocPrint(
            b.allocator,
            "{d}",
            .{qemu_step.options.number_of_cpus},
        ),
    });

    // interrupt details
    if (qemu_step.options.interrupt_details) {
        if (qemu_step.architecture == .x64) {
            // The "-M smm=off" below disables the SMM generated spam that happens before the kernel starts.
            run_qemu.addArgs(&[_][]const u8{ "-d", "int", "-M", "smm=off" });
        } else {
            run_qemu.addArgs(&[_][]const u8{ "-d", "int" });
        }
    }

    // gdb remote debug
    if (qemu_step.options.qemu_remote_debug) {
        run_qemu.addArgs(&[_][]const u8{ "-s", "-S" });
    }

    if (qemu_step.options.display) {
        run_qemu.addArgs(&[_][]const u8{ "-monitor", "vc" });

        switch (qemu_step.architecture) {
            .arm => {
                run_qemu.addArgs(&[_][]const u8{ "-serial", "vc" });

                // TODO: once we have virtio-gpu support, uncomment this:
                // run_qemu.addArgs(&[_][]const u8{ "-device", "virtio-gpu-gl-pci" });
                run_qemu.addArgs(&[_][]const u8{ "-device", "ramfb" });
            },
            .riscv => {
                run_qemu.addArgs(&[_][]const u8{ "-serial", "vc" });

                run_qemu.addArgs(&[_][]const u8{ "-device", "virtio-vga-gl" });
            },
            .x64 => {
                run_qemu.addArgs(&[_][]const u8{ "-debugcon", "vc" });

                run_qemu.addArgs(&[_][]const u8{ "-device", "virtio-vga-gl" });
            },
        }

        run_qemu.addArgs(&[_][]const u8{
            "-display",
            "gtk,gl=on,show-tabs=on,zoom-to-fit=off",
        });
    } else {
        if (qemu_step.architecture == .x64) {
            if (qemu_step.options.qemu_monitor) {
                run_qemu.addArgs(&[_][]const u8{ "-debugcon", "mon:stdio" });
            } else {
                run_qemu.addArgs(&[_][]const u8{ "-debugcon", "stdio" });
            }
        } else {
            if (qemu_step.options.qemu_monitor) {
                run_qemu.addArgs(&[_][]const u8{ "-serial", "mon:stdio" });
            } else {
                run_qemu.addArgs(&[_][]const u8{ "-serial", "stdio" });
            }
        }

        run_qemu.addArgs(&[_][]const u8{ "-display", "none" });
    }

    // set the cpu
    switch (qemu_step.architecture) {
        .arm => run_qemu.addArgs(&.{ "-cpu", "max" }),
        .riscv => run_qemu.addArgs(&.{ "-cpu", "max" }),
        .x64 => run_qemu.addArgs(&.{ "-cpu", "max,migratable=no" }),
    }

    // set the machine
    switch (qemu_step.architecture) {
        .arm => if (qemu_step.options.no_acpi) {
            run_qemu.addArgs(&[_][]const u8{ "-machine", "virt,acpi=off" });
        } else {
            run_qemu.addArgs(&[_][]const u8{ "-machine", "virt,acpi=on" });
        },
        .riscv => {
            if (qemu_step.firmware == .uefi) {
                if (qemu_step.options.no_acpi) {
                    run_qemu.addArgs(&[_][]const u8{ "-machine", "virt,pflash0=pflash0,pflash1=pflash1,acpi=off" });
                } else {
                    run_qemu.addArgs(&[_][]const u8{ "-machine", "virt,pflash0=pflash0,pflash1=pflash1,acpi=on" });
                }
            } else {
                if (qemu_step.options.no_acpi) {
                    run_qemu.addArgs(&[_][]const u8{ "-machine", "virt,acpi=off" });
                } else {
                    run_qemu.addArgs(&[_][]const u8{ "-machine", "virt,acpi=on" });
                }
            }
        },
        .x64 => {
            if (qemu_step.options.no_acpi) {
                std.debug.print("ACPI cannot be disabled on x64\n", .{});
                std.process.exit(1);
            }

            run_qemu.addArgs(&[_][]const u8{ "-machine", "q35" });
        },
    }

    // qemu acceleration
    const should_use_acceleration = !qemu_step.options.no_acceleration and qemu_step.architecture.isNative(b);
    if (should_use_acceleration) {
        switch (b.graph.host.result.os.tag) {
            .linux => run_qemu.addArgs(&[_][]const u8{ "-accel", "kvm" }),
            .macos => run_qemu.addArgs(&[_][]const u8{ "-accel", "hvf" }),
            .windows => run_qemu.addArgs(&[_][]const u8{ "-accel", "whpx" }),
            else => std.debug.panic("unsupported host operating system: {s}", .{@tagName(b.graph.host.result.os.tag)}),
        }
    }

    // always add tcg as the last accelerator
    run_qemu.addArgs(&[_][]const u8{ "-accel", "tcg" });

    switch (qemu_step.firmware) {
        .default => {},
        .uefi => |edk2| {
            const firmware_code = edk2.path(uefiFirmwareCodeFileName(qemu_step.architecture));
            const firmware_var = edk2.path(uefiFirmwareVarFileName(qemu_step.architecture));

            switch (qemu_step.architecture) {
                .riscv => {
                    run_qemu.addArgs(&[_][]const u8{
                        "-blockdev",
                        try std.fmt.allocPrint(
                            b.allocator,
                            "node-name=pflash0,driver=file,read-only=on,filename={s}",
                            .{firmware_code.getPath2(b, step)},
                        ),
                    });

                    // this being readonly is not correct but preventing modifcation of a file in the cache is good
                    run_qemu.addArgs(&[_][]const u8{
                        "-blockdev",
                        try std.fmt.allocPrint(
                            b.allocator,
                            "node-name=pflash1,driver=file,read-only=on,filename={s}",
                            .{firmware_var.getPath2(b, step)},
                        ),
                    });
                },
                else => {
                    run_qemu.addArgs(&[_][]const u8{
                        "-drive",
                        try std.fmt.allocPrint(
                            b.allocator,
                            "if=pflash,format=raw,unit=0,readonly=on,file={s}",
                            .{firmware_code.getPath2(b, step)},
                        ),
                    });

                    // this being readonly is not correct but preventing modification of a file in the cache is good
                    run_qemu.addArgs(&[_][]const u8{
                        "-drive",
                        try std.fmt.allocPrint(
                            b.allocator,
                            "if=pflash,format=raw,unit=1,readonly=on,file={s}",
                            .{firmware_var.getPath2(b, step)},
                        ),
                    });
                },
            }
        },
    }

    var timer = try std.time.Timer.start();

    try run_qemu.step.make(options);

    step.result_duration_ns = timer.read();
}

/// Returns true if the architecture needs UEFI to boot.
fn needsUefi(architecture: CascadeTarget.Architecture) bool {
    return switch (architecture) {
        .arm => true,
        .riscv => true,
        .x64 => false,
    };
}

fn uefiFirmwareCodeFileName(architecture: CascadeTarget.Architecture) []const u8 {
    return switch (architecture) {
        .arm => "aarch64/code.fd",
        .riscv => "riscv64/code.fd",
        .x64 => "x64/code.fd",
    };
}

fn uefiFirmwareVarFileName(architecture: CascadeTarget.Architecture) []const u8 {
    return switch (architecture) {
        .arm => "aarch64/vars.fd",
        .riscv => "riscv64/vars.fd",
        .x64 => "x64/vars.fd",
    };
}

/// Returns the name of the QEMU system executable for the given architecture.
fn qemuExecutable(architecture: CascadeTarget.Architecture) []const u8 {
    return switch (architecture) {
        .arm => "qemu-system-aarch64",
        .riscv => "qemu-system-riscv64",
        .x64 => "qemu-system-x86_64",
    };
}

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const ImageStep = @import("ImageStep.zig");
const Options = @import("Options.zig");
const StepCollection = @import("StepCollection.zig");
const Tool = @import("Tool.zig");
