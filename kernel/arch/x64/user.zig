// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const Process = cascade.user.Process;
const Thread = cascade.user.Thread;
const core = @import("core");

const x64 = @import("x64.zig");

pub const PerThread = struct {
    xsave: XSave,

    pub const XSave = struct {
        area: []align(64) u8,

        /// Where is the xsave data currently stored.
        state: State = .area,

        pub const State = enum {
            registers,
            area,
        };

        pub fn zero(xsave: *XSave) void {
            @memset(xsave.area, 0);
            xsave.state = .area;
        }

        /// Save the xsave state into the xsave area if it is currently stored in the registers.
        ///
        /// Caller must ensure SSE is enabled before calling; see `x64.instructions.enableSSEUsage`
        pub fn save(xsave: *XSave) void {
            switch (xsave.state) {
                .area => {},
                .registers => {
                    switch (x64.info.xsave.method) {
                        .xsaveopt => {
                            @branchHint(.likely); // modern machines support xsaveopt
                            x64.instructions.xsaveopt(
                                xsave.area,
                                x64.info.xsave.xcr0_value,
                            );
                        },
                        .xsave => x64.instructions.xsave(
                            xsave.area,
                            x64.info.xsave.xcr0_value,
                        ),
                    }
                    xsave.state = .area;
                },
            }
        }

        /// Load the xsave state into registers if it is currently stored in the xsave area.
        ///
        /// Caller must ensure SSE is enabled before calling; see `x64.instructions.enableSSEUsage`
        pub fn load(xsave: *XSave) void {
            switch (xsave.state) {
                .area => {
                    x64.instructions.xrstor(
                        xsave.area,
                        x64.info.xsave.xcr0_value,
                    );
                    xsave.state = .registers;
                },
                .registers => {},
            }
        }
    };
};

/// Create the `PerThread` data of a thread.
///
/// Non-architecture specific creation has already been performed but no initialization.
///
/// This function is called in the `Thread` cache constructor.
pub fn createThread(
    current_task: Task.Current,
    thread: *Thread,
) cascade.mem.cache.ConstructorError!void {
    thread.arch_specific = .{
        .xsave = .{
            .area = @alignCast(
                globals.xsave_area_cache.allocate(current_task) catch return error.ItemConstructionFailed,
            ),
        },
    };
}

/// Destroy the `PerThread` data of a thread.
///
/// Non-architecture specific destruction has not already been performed.
///
/// This function is called in the `Thread` cache destructor.
pub fn destroyThread(current_task: Task.Current, thread: *Thread) void {
    globals.xsave_area_cache.deallocate(current_task, thread.arch_specific.xsave.area);
}

/// Initialize the `PerThread` data of a thread.
///
/// All non-architecture specific initialization has already been performed.
///
/// This function is called in `Thread.internal.create`.
pub fn initializeThread(current_task: Task.Current, thread: *Thread) void {
    _ = current_task;
    thread.arch_specific.xsave.zero();
}

/// Enter userspace for the first time in the current task.
pub fn enterUserspace(
    current_task: Task.Current,
    options: arch.user.EnterUserspaceOptions,
) noreturn {
    const thread: *Thread = .fromTask(current_task.task);

    x64.instructions.disableInterrupts();

    x64.instructions.enableSSEUsage();
    thread.arch_specific.xsave.load();

    const frame: EnterUserspaceFrame = .{
        .rip = options.entry_point,
        .rsp = options.stack_pointer,
    };

    asm volatile (
        \\mov %[frame], %rsp
        \\xor %eax, %eax
        \\xor %ebx, %ebx
        \\xor %ecx, %ecx
        \\xor %edx, %edx
        \\xor %esi, %esi
        \\xor %edi, %edi
        \\xor %ebp, %ebp
        \\xor %r8, %r8
        \\xor %r9, %r9
        \\xor %r10, %r10
        \\xor %r11, %r11
        \\xor %r12, %r12
        \\xor %r13, %r13
        \\xor %r14, %r14
        \\xor %r15, %r15
        \\mov %ax, %fs
        \\mov %ax, %gs
        \\iretq
        \\ud2
        :
        : [frame] "r" (&frame),
    );

    unreachable;
}

const EnterUserspaceFrame = extern struct {
    rip: core.VirtualAddress,
    cs: extern union {
        full: u64,
        selector: x64.Gdt.Selector,
    } = .{ .selector = .user_code },
    rflags: x64.registers.RFlags = user_rflags,
    rsp: core.VirtualAddress,
    ss: extern union {
        full: u64,
        selector: x64.Gdt.Selector,
    } = .{ .selector = .user_data },

    const user_rflags: x64.registers.RFlags = .{
        .carry = false,
        ._reserved1 = 0,
        .parity = false,
        ._reserved2 = 0,
        .auxiliary_carry = false,
        ._reserved3 = 0,
        .zero = false,
        .sign = false,
        .trap = false,
        .enable_interrupts = true,
        .direction = .up,
        .overflow = false,
        .iopl = .ring0,
        .nested = false,
        ._reserved4 = 0,
        .@"resume" = false,
        .virtual_8086 = false,
        .alignment_check = false,
        .virtual_interrupt = false,
        .virtual_interrupt_pending = false,
        .id = false,
        ._reserved5 = 0,
    };
};

const globals = struct {
    /// Initialized during `init.initialize`.
    var xsave_area_cache: cascade.mem.cache.RawCache = undefined;
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.thread_init);

    /// Perform any per-achitecture initialization needed for userspace processes/threads.
    pub fn initialize(current_task: Task.Current) !void {
        init_log.debug(current_task, "initializing xsave area cache", .{});
        globals.xsave_area_cache.init(current_task, .{
            .name = try .fromSlice("xsave"),
            .size = x64.info.xsave.xsave_area_size.value,
            .alignment = .fromByteUnits(64),
        });
    }
};
