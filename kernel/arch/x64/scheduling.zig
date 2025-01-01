// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

/// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
pub fn callOneArgs(
    opt_old_task: ?*kernel.Task,
    new_stack: kernel.Stack,
    arg1: anytype,
    target_function: *const fn (@TypeOf(arg1)) callconv(.C) noreturn,
) kernel.arch.scheduling.CallError!void {
    const impls = struct {
        const callOneArgs: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
            previous_kernel_stack_pointer: *core.VirtualAddress, // rsi
        ) callconv(.C) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\push %rbx
                        \\push %rbp
                        \\push %r12
                        \\push %r13
                        \\push %r14
                        \\push %r15
                        \\mov %rsp, %rax
                        \\mov %rax, (%rsi)
                        \\mov %rdi, %rsp
                        \\pop %rdi
                        \\ret
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };

        const callOneArgsNoPrevious: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
        ) callconv(.C) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\mov %rdi, %rsp
                        \\pop %rdi
                        \\ret
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    var stack = new_stack;

    try stack.push(core.VirtualAddress, .fromPtr(@ptrCast(target_function)));
    try stack.push(@TypeOf(arg1), arg1);

    if (opt_old_task) |old_task| {
        impls.callOneArgs(
            stack.stack_pointer,
            &old_task.stack.stack_pointer,
        );
    } else {
        impls.callOneArgsNoPrevious(stack.stack_pointer);
    }
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("x64");
