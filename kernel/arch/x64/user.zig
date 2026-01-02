// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const cascade = @import("cascade");
const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const Process = kernel.user.Process;
const Thread = kernel.user.Thread;
const core = @import("core");

const log = kernel.debug.log.scoped(.user_x64);

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
pub fn createThread(current_task: Task.Current, thread: *Thread) kernel.mem.cache.ConstructorError!void {
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
pub fn enterUserspace(current_task: Task.Current, options: arch.user.EnterUserspaceOptions) noreturn {
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

export fn syscallDispatch(syscall_frame: *SyscallFrame) callconv(.c) void {
    x64.instructions.disableSSEUsage();

    const current_task: Task.Current = .onSyscallEntry();

    defer {
        const thread: *Thread = .fromTask(current_task.task);
        x64.instructions.enableSSEUsage();
        thread.arch_specific.xsave.load();
    }

    kernel.user.onSyscall(current_task, .{ .arch_specific = syscall_frame });

    x64.instructions.disableInterrupts();
}

pub fn getSyscallEntryPoint(executor: *kernel.Executor) *const anyopaque {
    return raw_syscall_entry_points[@intFromEnum(executor.id)];
}

pub const SyscallFrame = extern struct {
    fs: u64,
    gs: u64,
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rdx: u64,
    rbx: u64,
    rax: u64,
    rflags: x64.registers.RFlags,
    rip: u64,
    rsp: u64,

    pub fn syscall(syscall_frame: *const SyscallFrame) ?cascade.Syscall {
        return std.enums.fromInt(cascade.Syscall, syscall_frame.rdi);
    }

    pub fn print(
        value: *const SyscallFrame,
        writer: *std.Io.Writer,
        indent: usize,
    ) !void {
        const new_indent = indent + 2;

        try writer.writeAll("SyscallFrame{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rsp: 0x{x:0>16}, rip: 0x{x:0>16},\n", .{ value.rsp, value.rip });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rax: 0x{x:0>16}, rbx: 0x{x:0>16},\n", .{ value.rax, value.rbx });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rdx: 0x{x:0>16}, rbp: 0x{x:0>16},\n", .{ value.rdx, value.rbp });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rsi: 0x{x:0>16}, rdi: 0x{x:0>16},\n", .{ value.rsi, value.rdi });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("r8: 0x{x:0>16}, r9:  0x{x:0>16},\n", .{ value.r8, value.r9 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("r10:  0x{x:0>16}, r12: 0x{x:0>16},\n", .{ value.r10, value.r12 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("r13: 0x{x:0>16}, r14: 0x{x:0>16},\n", .{ value.r13, value.r14 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("r15: 0x{x:0>16},\n", .{value.r15});

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("rflags: ");
        try value.rflags.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(
        value: *const SyscallFrame,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return print(value, writer, 0);
    }
};

const globals = struct {
    /// Initialized during `init.initialize`.
    var xsave_area_cache: kernel.mem.cache.RawCache = undefined;
};

pub const init = struct {
    const init_log = kernel.debug.log.scoped(.thread_init);

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

comptime {
    // below asserts ensure the constants in `kernel/x64/asm/syscallEntry.S` are in sync
    std.debug.assert(kernel.config.executor.maximum_number_of_executors == 64);
    std.debug.assert(@offsetOf(kernel.Executor, "current_task") == 0);
    std.debug.assert(@offsetOf(Task, "stack") + @offsetOf(Task.Stack, "top_stack_pointer") == 136);
}

const RawSyscallEntry = *const fn () callconv(.naked) noreturn;

const raw_syscall_entry_points: [kernel.config.executor.maximum_number_of_executors]RawSyscallEntry = .{
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_0" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_1" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_2" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_3" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_4" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_5" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_6" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_7" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_8" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_9" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_10" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_11" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_12" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_13" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_14" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_15" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_16" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_17" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_18" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_19" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_20" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_21" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_22" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_23" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_24" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_25" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_26" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_27" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_28" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_29" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_30" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_31" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_32" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_33" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_34" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_35" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_36" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_37" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_38" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_39" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_40" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_41" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_42" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_43" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_44" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_45" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_46" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_47" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_48" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_49" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_50" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_51" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_52" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_53" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_54" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_55" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_56" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_57" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_58" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_59" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_60" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_61" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_62" }),
    @extern(RawSyscallEntry, .{ .name = "_syscall_entry_63" }),
};
