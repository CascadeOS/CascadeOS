// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const cascade = @import("cascade");
const core = @import("core");

const x64 = @import("x64.zig");

const Executor = @This();

apic_id: Id,

gdt: x64.Gdt = .{},
tss: x64.Tss = .{},

double_fault_stack: cascade.Task.Stack,
non_maskable_interrupt_stack: cascade.Task.Stack,

pub inline fn from(executor: *cascade.Executor) *Executor {
    return &executor.arch_specific.arch_specific;
}

pub inline fn fromConst(executor: *const cascade.Executor) *const Executor {
    return &executor.arch_specific.arch_specific;
}

pub const Id = enum(u32) {
    _,
};

/// Notify the given executor of a flush request.
pub fn flushRequestNotify(executor: *const cascade.Executor) void {
    x64.apic.sendFlushIPI(.fromConst(executor));
}

/// Send a panic to all other executors.
///
/// ***Caller Requirements***:
///   - Interrupts are disabled.
pub fn sendPanicAllButSelf() void {
    x64.apic.sendPanicAllButSelfIPI();
}

pub const current = struct {
    /// Issue an architecture specific hint to the current executor that we are spinning in a loop.
    pub inline fn spinLoopHint() void {
        asm volatile ("pause" ::: .{ .memory = true });
    }

    /// Halt the current executor.
    pub fn halt() void {
        asm volatile ("hlt");
    }

    /// Disable interrupts on the current executor and halt.
    pub inline fn disableInterruptsAndHalt() noreturn {
        while (true) {
            asm volatile ("cli; hlt");
        }
    }

    /// Are interrupts enabled on the current executor.
    pub fn interruptsEnabled() bool {
        return x64.registers.RFlags.read().enable_interrupts;
    }

    /// Enable interrupts on the current executor.
    pub fn enableInterrupts() void {
        asm volatile ("sti");
    }

    /// Disable interrupts on the current executor.
    pub fn disableInterrupts() void {
        asm volatile ("cli");
    }

    /// Flushes the cache for the given virtual range on the current executor.
    ///
    /// ***Caller Requirements***:
    ///  - `virtual_range` must be page aligned
    pub fn flushCache(virtual_range: cascade.VirtualRange) void {
        var current_virtual_address = virtual_range.address;
        const terminating_virtual_address = virtual_range.after();

        while (current_virtual_address.lessThan(terminating_virtual_address)) {
            asm volatile ("invlpg (%[address])"
                :
                : [address] "r" (current_virtual_address.value),
            );

            current_virtual_address.moveForwardPageInPlace();
        }
    }

    /// Enable the kernel on the current executor to access user memory.
    ///
    /// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
    /// memory.
    pub fn enableAccessToUserMemory() void {
        if (!x64.info.cpu_id.smap) {
            @branchHint(.unlikely); // modern CPUs support SMAP
            return;
        }
        asm volatile ("stac");
    }

    /// Disable the kernel on the current executor from accessing user memory.
    ///
    /// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
    /// memory.
    pub fn disableAccessToUserMemory() void {
        if (!x64.info.cpu_id.smap) {
            @branchHint(.unlikely); // modern CPUs support SMAP
            return;
        }
        asm volatile ("clac");
    }

    pub inline fn enableSSEUsage() void {
        if (core.is_debug) std.debug.assert(!interruptsEnabled());
        asm volatile ("clts");
    }

    pub fn disableSSEUsage() void {
        if (core.is_debug) std.debug.assert(!interruptsEnabled());
        var cr0: x64.registers.Cr0 = .read();
        cr0.task_switched = true;
        cr0.write();
    }
};

pub const init = struct {
    /// Prepares this executor as the bootstrap executor.
    pub fn prepareBootstrap(executor: *cascade.Executor, id: Id) void {
        const static = struct {
            var bootstrap_double_fault_stack: [cascade.config.task.kernel_stack_size.value]u8 align(16) = undefined;
            var bootstrap_non_maskable_interrupt_stack: [cascade.config.task.kernel_stack_size.value]u8 align(16) = undefined;
        };

        prepareShared(
            executor,
            id,
            .fromRange(
                .fromSlice(u8, &static.bootstrap_double_fault_stack),
                .fromSlice(u8, &static.bootstrap_double_fault_stack),
            ),
            .fromRange(
                .fromSlice(u8, &static.bootstrap_non_maskable_interrupt_stack),
                .fromSlice(u8, &static.bootstrap_non_maskable_interrupt_stack),
            ),
        );
    }

    /// Prepares the provided `Executor` for use.
    pub fn prepare(executor: *cascade.Executor, id: Id) void {
        prepareShared(
            executor,
            id,
            cascade.Task.init.earlyCreateStack() catch @panic("failed to allocate double fault stack"),
            cascade.Task.init.earlyCreateStack() catch @panic("failed to allocate NMI stack"),
        );
    }

    fn prepareShared(
        executor: *cascade.Executor,
        id: Id,
        double_fault_stack: cascade.Task.Stack,
        non_maskable_interrupt_stack: cascade.Task.Stack,
    ) void {
        const x64_executor = from(executor);

        x64_executor.* = .{
            .apic_id = id,
            .double_fault_stack = double_fault_stack,
            .non_maskable_interrupt_stack = non_maskable_interrupt_stack,
        };

        x64_executor.tss.setInterruptStack(
            .double_fault,
            x64_executor.double_fault_stack.stack_pointer,
        );
        x64_executor.tss.setInterruptStack(
            .non_maskable_interrupt,
            x64_executor.non_maskable_interrupt_stack.stack_pointer,
        );
    }

    /// Initialize the current executor.
    pub fn initialize(executor: *cascade.Executor) void {
        const x64_executor = from(executor);

        x64_executor.gdt.load();
        x64_executor.gdt.setTss(&x64_executor.tss);

        x64.Interrupt.init.loadIdt();
    }

    /// Configure any per-executor system features on the current executor.
    ///
    /// This function is called in a few different contexts and must leave the system in a reasonable state for each of them:
    ///  - By the bootstrap executor after calling `init.captureSystemInformation(.early)`
    ///  - By the bootstrap executor after calling `init.captureSystemInformation(.full)`
    ///  - By every executor after `init.captureSystemInformation(.full)` has been called
    pub fn configurePerExecutorSystemFeatures() void {
        if (x64.info.cpu_id.rdtscp) {
            x64.registers.IA32_TSC_AUX.write(@intFromEnum(cascade.Task.Current.get().knownExecutor().id));
        }

        // TODO: be more thorough with setting up these registers

        // CR0
        {
            var cr0 = x64.registers.Cr0.read();

            if (!cr0.protected_mode_enable) @panic("protected mode not enabled");
            if (!cr0.paging) @panic("paging not enabled");

            cr0.monitor_coprocessor = true;
            cr0.emulate_coprocessor = false;
            cr0.task_switched = true; // disable SSE instructions in the kernel
            cr0.write_protect = true;

            cr0.write();
        }

        // CR4
        {
            var cr4 = x64.registers.Cr4.read();

            if (!cr4.physical_address_extension) @panic("physical address extension not enabled");

            cr4.time_stamp_disable = false;
            cr4.debugging_extensions = true;
            cr4.machine_check_exception = x64.info.cpu_id.mce;
            cr4.page_global = true;
            cr4.performance_monitoring_counter = true;
            cr4.os_fxsave = true;
            cr4.unmasked_exception_support = true;
            cr4.usermode_instruction_prevention = x64.info.cpu_id.umip;
            cr4.level_5_paging = false;
            cr4.fsgsbase = x64.info.cpu_id.fsgsbase;
            cr4.pcid = false; // TODO

            if (!x64.info.cpu_id.xsave.supported) @panic("XSAVE not supported");
            cr4.osxsave = true;

            cr4.supervisor_mode_execution_prevention = x64.info.cpu_id.smep;
            cr4.supervisor_mode_access_prevention = x64.info.cpu_id.smap;

            cr4.write();
        }

        // EFER
        {
            var efer = x64.registers.EFER.read();

            if (!efer.long_mode_active or !efer.long_mode_enable) @panic("not in long mode");

            if (!x64.info.cpu_id.syscall_sysret) @panic("syscall/sysret not supported");
            efer.syscall_enable = true;

            efer.no_execute_enable = x64.info.cpu_id.execute_disable;

            efer.write();
        }

        // SYSCALL/SYSRET
        {
            x64.registers.IA32_SFMASK.write(.{
                .clear_enable_interrupts = true,
                .clear_direction = true,
            });

            x64.registers.IA32_STAR.write(.{
                .syscall_target_eip_32bit = 0, // 32-bit mode not supported
                .syscall_cs_ss = .kernel_code,
                .sysret_cs_ss = .user_code_32bit,
            });

            x64.registers.IA32_LSTAR.write(@intFromPtr(&x64.syscall.entry));
        }

        // PAT
        {
            var pat = x64.registers.PAT.read();

            pat.entry0 = .write_back;
            pat.entry1 = .write_through;
            pat.entry2 = .uncached;
            pat.entry3 = .unchacheable;
            pat.entry4 = .write_protected;
            pat.entry5 = .write_combining;
            pat.entry6 = .uncached;
            pat.entry7 = .unchacheable;
            x64.registers.PAT.write(pat);

            // flip the page global bit to ensure the PAT is applied
            var cr4 = x64.registers.Cr4.read();
            cr4.page_global = false;
            cr4.write();
            cr4.page_global = true;
            cr4.write();
        }

        // XCr0
        {
            current.enableSSEUsage();
            x64.info.xsave.xcr0_value.write();
            current.disableSSEUsage();
        }
    }

    /// Initialize the local interrupt controller for the current executor.
    ///
    /// For example, on x86_64 this should initialize the APIC.
    pub fn initLocalInterruptController() void {
        x64.apic.init.initApicOnCurrentExecutor();
    }
};
