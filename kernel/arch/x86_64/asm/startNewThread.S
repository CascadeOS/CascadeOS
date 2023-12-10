// SPDX-License-Identifier: MIT

/*
extern fn _startNewThread() callconv(.C) noreturn;
*/

/*
We need to prepare the arguments inorder to call:
export fn startNewThread(
    thread: *kernel.Thread, // rdi
    context: u64, // rsi
    target_function: *const fn (thread: *kernel.Thread, context: u64) noreturn, // rdx
) callconv(.C) noreturn {
*/

.section .text
.global _startNewThread
.type _startNewThread, @function
_startNewThread:
    pop %rdi // thread
    pop %rsi // context
    pop %rdx // target_function

    ret // the return address of `startNewThread` should be on the stack
