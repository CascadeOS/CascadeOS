// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const Firmware = union(enum) {
    default,
    uefi: *std.Build.Dependency, // EDK2 dependency
};

/// For each architecture, creates a step that runs the image for the architecture using QEMU.
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

        const qemu_step = try createQemuStep(
            b,
            architecture,
            kernel_log_wrapper_compile,
            image_step.image_file,
            options,
        );

        const qemu_step_name = try std.fmt.allocPrint(
            b.allocator,
            "run_{t}",
            .{architecture},
        );
        const qemu_step_description = try std.fmt.allocPrint(
            b.allocator,
            "Run the image for {t} in qemu",
            .{architecture},
        );

        const run_step = b.step(qemu_step_name, qemu_step_description);
        run_step.dependOn(&qemu_step.step);
    }
}

fn createQemuStep(
    b: *std.Build,
    architecture: CascadeTarget.Architecture,
    kernel_log_wrapper_compile: ?*std.Build.Step.Compile,
    image: std.Build.LazyPath,
    options: Options,
) !*std.Build.Step.Run {
    const firmware: Firmware = if (options.uefi or needsUefi(architecture))
        .{ .uefi = b.dependency("edk2", .{}) }
    else
        .default;

    const run_qemu = if (!options.display and kernel_log_wrapper_compile != null) run_qemu: {
        const kernel_log_wrapper = kernel_log_wrapper_compile.?;
        const run_qemu = b.addRunArtifact(kernel_log_wrapper);
        run_qemu.addArg(qemuExecutable(architecture));
        break :run_qemu run_qemu;
    } else b.addSystemCommand(&.{qemuExecutable(architecture)});

    run_qemu.has_side_effects = true;
    run_qemu.stdio = .inherit;

    run_qemu.addArg("-nodefaults");
    run_qemu.addArg("-no-user-config");

    run_qemu.addArgs(&.{ "-boot", "menu=off" });
    run_qemu.addArgs(&.{ "-d", "guest_errors" });

    // RAM
    run_qemu.addArgs(&.{
        "-m",
        try std.fmt.allocPrint(b.allocator, "{d}", .{options.memory}),
    });

    // boot disk
    run_qemu.addArgs(&.{
        "-device",
        "virtio-blk-pci,drive=drive0,bootindex=0",
        "-drive",
    });
    run_qemu.addDecoratedDirectoryArg( // TODO: raise an issue to support generic addArgs with prefix and suffix
        "file=",
        image,
        ",format=raw,if=none,id=drive0",
    );

    // multicore
    run_qemu.addArgs(&.{
        "-smp",
        try std.fmt.allocPrint(
            b.allocator,
            "{d}",
            .{options.number_of_cpus},
        ),
    });

    // interrupt details
    if (options.interrupt_details) {
        if (architecture == .x64) {
            // The "-M smm=off" below disables the SMM generated spam that happens before the kernel starts.
            run_qemu.addArgs(&.{ "-d", "int", "-M", "smm=off" });
        } else {
            run_qemu.addArgs(&.{ "-d", "int" });
        }
    }

    // gdb remote debug
    if (options.qemu_remote_debug) {
        run_qemu.addArgs(&.{ "-s", "-S" });
    }

    if (options.display) {
        run_qemu.addArgs(&.{ "-monitor", "vc" });

        switch (architecture) {
            .arm => {
                run_qemu.addArgs(&.{ "-serial", "vc" });

                // TODO: once we have virtio-gpu support, uncomment this:
                // run_qemu.addArgs(&.{ "-device", "virtio-gpu-gl-pci" });
                run_qemu.addArgs(&.{ "-device", "ramfb" });
            },
            .riscv => {
                run_qemu.addArgs(&.{ "-serial", "vc" });

                run_qemu.addArgs(&.{ "-device", "virtio-vga-gl" });
            },
            .x64 => {
                run_qemu.addArgs(&.{ "-debugcon", "vc" });

                run_qemu.addArgs(&.{ "-device", "virtio-vga-gl" });
            },
        }

        run_qemu.addArgs(&.{
            "-display",
            "gtk,gl=on,show-tabs=on,zoom-to-fit=off",
        });
    } else {
        if (architecture == .x64) {
            if (options.qemu_monitor) {
                run_qemu.addArgs(&.{ "-debugcon", "mon:stdio" });
            } else {
                run_qemu.addArgs(&.{ "-debugcon", "stdio" });
            }
        } else {
            if (options.qemu_monitor) {
                run_qemu.addArgs(&.{ "-serial", "mon:stdio" });
            } else {
                run_qemu.addArgs(&.{ "-serial", "stdio" });
            }
        }

        run_qemu.addArgs(&.{ "-display", "none" });
    }

    // set the cpu
    switch (architecture) {
        .arm => run_qemu.addArgs(&.{ "-cpu", "max" }),
        .riscv => run_qemu.addArgs(&.{ "-cpu", "max" }),
        .x64 => run_qemu.addArgs(&.{ "-cpu", "max,migratable=no" }),
    }

    // set the machine
    switch (architecture) {
        .arm => if (options.no_acpi) {
            run_qemu.addArgs(&.{ "-machine", "virt,acpi=off" });
        } else {
            run_qemu.addArgs(&.{ "-machine", "virt,acpi=on" });
        },
        .riscv => {
            if (firmware == .uefi) {
                if (options.no_acpi) {
                    run_qemu.addArgs(&.{ "-machine", "virt,pflash0=pflash0,pflash1=pflash1,acpi=off" });
                } else {
                    run_qemu.addArgs(&.{ "-machine", "virt,pflash0=pflash0,pflash1=pflash1,acpi=on" });
                }
            } else {
                if (options.no_acpi) {
                    run_qemu.addArgs(&.{ "-machine", "virt,acpi=off" });
                } else {
                    run_qemu.addArgs(&.{ "-machine", "virt,acpi=on" });
                }
            }
        },
        .x64 => {
            if (options.no_acpi) {
                std.debug.print("ACPI cannot be disabled on x64\n", .{});
                std.process.exit(1);
            }

            run_qemu.addArgs(&.{ "-machine", "q35" });
        },
    }

    // qemu acceleration
    const should_use_acceleration = !options.no_acceleration and architecture.isNative(b);
    if (should_use_acceleration) {
        switch (b.graph.host.result.os.tag) {
            .linux => run_qemu.addArgs(&.{ "-accel", "kvm" }),
            .macos => run_qemu.addArgs(&.{ "-accel", "hvf" }),
            .windows => run_qemu.addArgs(&.{ "-accel", "whpx" }),
            else => std.debug.panic(
                "unsupported host operating system: {t}",
                .{b.graph.host.result.os.tag},
            ),
        }
    }

    // always add tcg as the last accelerator
    run_qemu.addArgs(&.{ "-accel", "tcg" });

    switch (firmware) {
        .default => {},
        .uefi => |edk2| {
            const firmware_code = edk2.path(uefiFirmwareCodeFileName(architecture));
            const firmware_var = edk2.path(uefiFirmwareVarFileName(architecture));

            switch (architecture) {
                .riscv => {
                    run_qemu.addArg("-blockdev");
                    run_qemu.addPrefixedFileArg(
                        "node-name=pflash0,driver=file,read-only=on,filename=",
                        firmware_code,
                    );

                    // this being readonly is not correct but preventing modifcation of a file in the cache is good
                    run_qemu.addArg("-blockdev");
                    run_qemu.addPrefixedFileArg(
                        "node-name=pflash1,driver=file,read-only=on,filename=",
                        firmware_var,
                    );
                },
                else => {
                    run_qemu.addArg("-drive");
                    run_qemu.addPrefixedFileArg(
                        "if=pflash,format=raw,unit=0,readonly=on,file=",
                        firmware_code,
                    );
                    // this being readonly is not correct but preventing modification of a file in the cache is good
                    run_qemu.addArg("-drive");
                    run_qemu.addPrefixedFileArg(
                        "if=pflash,format=raw,unit=1,readonly=on,file=",
                        firmware_var,
                    );
                },
            }
        },
    }

    if (options.tpm_socket) |tpm_socket| {
        run_qemu.addArgs(&.{
            "-chardev", try std.fmt.allocPrint(b.allocator, "socket,id=chrtpm,path={s}", .{tpm_socket}),
            "-tpmdev",  "emulator,id=tpm0,chardev=chrtpm",
            "-device",  "tpm-tis,tpmdev=tpm0",
        });
    }

    return run_qemu;
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

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const ImageStep = @import("ImageStep.zig");
const Options = @import("Options.zig");
const StepCollection = @import("StepCollection.zig");
const Tool = @import("Tool.zig");
