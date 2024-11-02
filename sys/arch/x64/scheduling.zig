// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
pub fn callZeroArgs(
    opt_old_task: ?*kernel.Task,
    new_stack: kernel.Stack,
    target_function: *const fn () callconv(.C) noreturn,
) arch.scheduling.CallError!void {
    const impls = struct {
        const callZeroArgs: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
            previous_kernel_stack_pointer: *core.VirtualAddress, // rsi
        ) callconv(.C) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) noreturn {
                    asm volatile (
                        \\// all other registers are saved by the caller due to the calling convention
                        \\push %rbx
                        \\push %rbp
                        \\push %r12
                        \\push %r13
                        \\push %r14
                        \\push %r15
                        \\
                        \\// save current stack to `previous_kernel_stack_pointer`
                        \\mov %rsp, %rax
                        \\mov %rax, (%rsi)
                        \\
                        \\// switch to `new_kernel_stack_pointer`
                        \\mov %rdi, %rsp
                        \\
                        \\// the address of `targetFunction` should be on the stack as the return address
                        \\ret
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };

        const callZeroArgsNoPrevious: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
        ) callconv(.C) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) noreturn {
                    asm volatile (
                        \\// switch to `new_kernel_stack_pointer`
                        \\mov %rdi, %rsp
                        \\
                        \\// the address of `targetFunction` should be on the stack as the return address
                        \\ret
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    var stack = new_stack;

    try stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(target_function)));

    if (opt_old_task) |old_task| {
        impls.callZeroArgs(
            stack.stack_pointer,
            &old_task.stack.stack_pointer,
        );
    } else {
        impls.callZeroArgsNoPrevious(stack.stack_pointer);
    }
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const log = kernel.log.scoped(.scheduling_x64);
