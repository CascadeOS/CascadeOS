// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/*
extern fn _startNewTask() callconv(.C) noreturn;
*/

/*
We need to prepare the arguments inorder to call:
export fn startNewTask(
    task: *kernel.Task, // rdi
    context: u64, // rsi
    target_function: *const fn (task: *kernel.Task, context: u64) noreturn, // rdx
) callconv(.C) noreturn {
*/

.section .text
.global _startNewTask
.type _startNewTask, @function
_startNewTask:
    pop %rdi // task
    pop %rsi // context
    pop %rdx // target_function

    ret // the return address of `startNewTask` should be on the stack
