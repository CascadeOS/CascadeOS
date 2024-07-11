// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Defines the interface of the architecture specific code.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub const arch = @import("cascade_target").arch;

const current = switch (arch) {
    // x64 is first to help zls, atleast while x64 is the main target.
    .x64 => @import("x64/interface.zig"),
    .arm64 => @import("arm64/interface.zig"),
    .riscv => @import("riscv/interface.zig"),
};

/// Architecture specific per-cpu information.
pub const ArchCpu = current.ArchCpu;

/// Get the current CPU.
///
/// Assumes that `init.loadCpu()` has been called on the currently running CPU.
///
/// It is the callers responsibility to ensure that the current task is not re-scheduled on to another CPU.
pub inline fn rawGetCpu() *kernel.Cpu {
    // `checkSupport` intentionally not called - mandatory function

    return current.getCpu();
}

/// Issues an architecture specific hint to the CPU that we are spinning in a loop.
pub inline fn spinLoopHint() void {
    // `checkSupport` intentionally not called - mandatory function

    current.spinLoopHint();
}

/// Halts the current processor
pub inline fn halt() void {
    // `checkSupport` intentionally not called - mandatory function

    current.halt();
}

/// Functionality that is used during kernel init only.
pub const init = struct {
    /// Attempt to set up some form of early output.
    pub inline fn setupEarlyOutput() void {
        // `checkSupport` intentionally not called - mandatory function

        current.init.setupEarlyOutput();
    }

    pub const EarlyOutput = struct {
        writer: std.io.AnyWriter,
        held: kernel.sync.TicketSpinLock.Held,

        pub inline fn deinit(self: EarlyOutput) void {
            self.held.release();
        }

        pub var lock: kernel.sync.TicketSpinLock = .{};
    };

    /// Acquire a writer for the early output setup by `setupEarlyOutput`.
    pub inline fn getEarlyOutput() ?EarlyOutput {
        // `checkSupport` intentionally not called - mandatory function

        if (current.init.getEarlyOutput()) |early_output_writer| {
            const held = EarlyOutput.lock.acquire();

            return .{
                .writer = early_output_writer.any(),
                .held = held,
            };
        }

        return null;
    }

    pub inline fn getEarlyOutputNoLock() ?std.io.AnyWriter {
        // `checkSupport` intentionally not called - mandatory function

        return if (current.init.getEarlyOutput()) |early_output_writer| early_output_writer.any() else null;
    }

    /// Ensure that any exceptions/faults that occur are handled.
    pub inline fn initInterrupts() void {
        // `checkSupport` intentionally not called - mandatory function

        current.init.initInterrupts();
    }

    /// Prepares the provided `Cpu` for the bootstrap cpu.
    pub inline fn prepareBootstrapCpu(
        bootstrap_cpu: *kernel.Cpu,
    ) void {
        // `checkSupport` intentionally not called - mandatory function

        current.init.prepareBootstrapCpu(bootstrap_cpu);
    }

    /// Prepares the provided kernel.Cpu for use.
    ///
    /// **WARNING**: This function will panic if the cpu cannot be prepared.
    pub inline fn prepareCpu(
        cpu: *kernel.Cpu,
        cpu_descriptor: kernel.boot.CpuDescriptor,
        allocateCpuStackFn: fn () anyerror!kernel.Stack,
    ) void {
        checkSupport(
            current.init,
            "prepareCpu",
            fn (*kernel.Cpu, kernel.boot.CpuDescriptor, fn () anyerror!kernel.Stack) void,
        );

        current.init.prepareCpu(cpu, cpu_descriptor, allocateCpuStackFn);
    }

    /// Load the provided `Cpu` as the current CPU.
    pub inline fn loadCpu(cpu: *kernel.Cpu) void {
        // `checkSupport` intentionally not called - mandatory function

        current.init.loadCpu(cpu);
    }

    /// Capture any system information that is required for the architecture.
    ///
    /// For example, on x64 this should capture the CPUID information.
    pub inline fn captureSystemInformation() !void {
        checkSupport(current.init, "captureSystemInformation", fn () anyerror!void);

        return current.init.captureSystemInformation();
    }

    /// Configure any global system features.
    pub inline fn configureGlobalSystemFeatures() void {
        checkSupport(current.init, "configureGlobalSystemFeatures", fn () void);

        current.init.configureGlobalSystemFeatures();
    }

    /// Register any architectural time sources.
    ///
    /// For example, on x86_64 this should register the TSC, HPEC, PIT, etc.
    pub inline fn registerArchitecturalTimeSources() void {
        checkSupport(current.init, "registerArchitecturalTimeSources", fn () void);

        current.init.registerArchitecturalTimeSources();
    }

    /// Configure any cpu local system features.
    pub inline fn configureSystemFeaturesForCurrentCpu(cpu: *kernel.Cpu) void {
        checkSupport(current.init, "configureSystemFeaturesForCurrentCpu", fn (*kernel.Cpu) void);

        current.init.configureSystemFeaturesForCurrentCpu(cpu);
    }

    /// Initialize the local interrupt controller for the provided processor.
    ///
    /// For example, on x86_64 this should initialize the APIC.
    pub inline fn initLocalInterruptController(cpu: *kernel.Cpu) void {
        checkSupport(current.init, "initLocalInterruptController", fn (*kernel.Cpu) void);

        current.init.initLocalInterruptController(cpu);
    }
};

pub const interrupts = struct {
    /// Disable interrupts and put the CPU to sleep.
    pub inline fn disableInterruptsAndHalt() noreturn {
        // `checkSupport` intentionally not called - mandatory function

        current.interrupts.disableInterruptsAndHalt();
    }

    /// Are interrupts enabled?
    pub inline fn interruptsEnabled() bool {
        // `checkSupport` intentionally not called - mandatory function

        return current.interrupts.interruptsEnabled();
    }

    /// Disable interrupts.
    pub inline fn disableInterrupts() void {
        // `checkSupport` intentionally not called - mandatory function

        current.interrupts.disableInterrupts();
    }

    /// Enable interrupts.
    pub inline fn enableInterrupts() void {
        // `checkSupport` intentionally not called - mandatory function

        current.interrupts.enableInterrupts();
    }

    pub inline fn setTaskPriority(priority: kernel.scheduler.Priority) void {
        checkSupport(current.interrupts, "setTaskPriority", fn (kernel.scheduler.Priority) void);

        current.interrupts.setTaskPriority(priority);
    }
};

pub const paging = struct {
    /// The standard page size for the architecture.
    pub const standard_page_size: core.Size = current.paging.standard_page_size;

    /// The virtual address of the higher half.
    pub const higher_half: core.VirtualAddress = current.paging.higher_half;

    /// All the page sizes supported by the architecture in order of smallest to largest.
    pub const all_page_sizes: []const core.Size = current.paging.all_page_sizes;

    /// The largest possible higher half virtual address.
    pub const largest_higher_half_virtual_address: core.VirtualAddress = current.paging.largest_higher_half_virtual_address;

    /// The page table type for the architecture.
    pub const PageTable: type = current.paging.PageTable;

    /// Allocates a new page table and returns a pointer to it in the direct map.
    pub inline fn allocatePageTable() kernel.pmm.AllocateError!*PageTable {
        checkSupport(current.paging, "allocatePageTable", fn () kernel.pmm.AllocateError!*PageTable);

        return current.paging.allocatePageTable();
    }

    /// Switches to the given page table.
    pub inline fn switchToPageTable(page_table_address: core.PhysicalAddress) void {
        checkSupport(current.paging, "switchToPageTable", fn (core.PhysicalAddress) void);

        current.paging.switchToPageTable(page_table_address);
    }

    pub const MapError = error{
        AlreadyMapped,

        /// This is used to surface errors from the underlying paging implementation that are architecture specific.
        MappingNotValid,
    } || kernel.pmm.AllocateError;

    /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
    ///
    /// Caller must ensure:
    ///  - the virtual range address and size are aligned to the standard page size
    ///  - the physical range address and size are aligned to the standard page size
    ///  - the virtual range size is equal to the physical range size
    ///  - the virtual range is not already mapped
    ///
    /// This function:
    ///  - uses only the standard page size for the architecture
    ///  - does not flush the TLB
    ///  - on error is not required roll back any modifications to the page tables
    pub inline fn mapToPhysicalRange(
        page_table: *PageTable,
        virtual_range: core.VirtualRange,
        physical_range: core.PhysicalRange,
        map_type: kernel.vmm.MapType,
    ) MapError!void {
        checkSupport(current.paging, "mapToPhysicalRange", fn (
            *PageTable,
            core.VirtualRange,
            core.PhysicalRange,
            kernel.vmm.MapType,
        ) MapError!void);

        return current.paging.mapToPhysicalRange(page_table, virtual_range, physical_range, map_type);
    }

    /// Unmaps the `virtual_range`.
    ///
    /// Caller must ensure:
    ///  - the virtual range address and size are aligned to the standard page size
    ///  - the virtual range is mapped
    ///  - the virtual range is mapped using only the standard page size for the architecture
    ///
    /// This function:
    ///  - does not flush the TLB
    pub inline fn unmapRange(
        page_table: *PageTable,
        virtual_range: core.VirtualRange,
    ) void {
        checkSupport(current.paging, "unmapRange", fn (*PageTable, core.VirtualRange) void);

        current.paging.unmapRange(page_table, virtual_range);
    }

    pub const init = struct {
        /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
        ///
        /// Caller must ensure:
        ///  - the virtual range address and size are aligned to the standard page size
        ///  - the physical range address and size are aligned to the standard page size
        ///  - the virtual range size is equal to the physical range size
        ///  - the virtual range is not already mapped
        ///
        /// This function:
        ///  - uses all page sizes available to the architecture
        ///  - does not flush the TLB
        ///  - on error is not required to roll back any modifications to the page tables
        pub inline fn mapToPhysicalRangeAllPageSizes(
            page_table: *PageTable,
            virtual_range: core.VirtualRange,
            physical_range: core.PhysicalRange,
            map_type: kernel.vmm.MapType,
        ) MapError!void {
            checkSupport(current.paging.init, "mapToPhysicalRangeAllPageSizes", fn (
                *PageTable,
                core.VirtualRange,
                core.PhysicalRange,
                kernel.vmm.MapType,
            ) MapError!void);

            return current.paging.init.mapToPhysicalRangeAllPageSizes(page_table, virtual_range, physical_range, map_type);
        }

        /// The total size of the virtual address space that one entry in the top level of the page table covers.
        pub inline fn sizeOfTopLevelEntry() core.Size {
            checkSupport(current.paging.init, "sizeOfTopLevelEntry", fn () core.Size);

            return current.paging.init.sizeOfTopLevelEntry();
        }

        pub const FillTopLevelError = error{
            TopLevelPresent,
        } || MapError;

        /// This function fills in the top level of the page table for the given range.
        ///
        /// The range is expected to have both size and alignment of `sizeOfTopLevelEntry()`.
        pub inline fn fillTopLevel(
            page_table: *PageTable,
            range: core.VirtualRange,
            map_type: kernel.vmm.MapType,
        ) FillTopLevelError!void {
            checkSupport(
                current.paging.init,
                "fillTopLevel",
                fn (*PageTable, core.VirtualRange, kernel.vmm.MapType) FillTopLevelError!void,
            );

            return current.paging.init.fillTopLevel(page_table, range, map_type);
        }
    };
};

pub const scheduling = struct {
    pub const CallError = error{StackOverflow};

    /// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
    pub inline fn callZeroArgs(
        opt_old_task: ?*kernel.Task,
        new_stack: kernel.Stack,
        target_function: *const fn () callconv(.C) noreturn,
    ) CallError!void {
        checkSupport(current.scheduling, "callZeroArgs", fn (
            ?*kernel.Task,
            kernel.Stack,
            *const fn () callconv(.C) noreturn,
        ) CallError!void);

        try current.scheduling.callZeroArgs(opt_old_task, new_stack, target_function);
    }

    /// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
    pub inline fn callOneArgs(
        opt_old_task: ?*kernel.Task,
        new_stack: kernel.Stack,
        target_function: *const fn (usize) callconv(.C) noreturn,
        arg1: usize,
    ) CallError!void {
        checkSupport(current.scheduling, "callOneArgs", fn (
            ?*kernel.Task,
            kernel.Stack,
            *const fn (usize) callconv(.C) noreturn,
            usize,
        ) CallError!void);

        try current.scheduling.callOneArgs(opt_old_task, new_stack, target_function, arg1);
    }

    /// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
    pub inline fn callTwoArgs(
        opt_old_task: ?*kernel.Task,
        new_stack: kernel.Stack,
        target_function: *const fn (usize, usize) callconv(.C) noreturn,
        arg1: usize,
        arg2: usize,
    ) CallError!void {
        checkSupport(current.scheduling, "callTwoArgs", fn (
            ?*kernel.Task,
            kernel.Stack,
            *const fn (usize, usize) callconv(.C) noreturn,
            usize,
            usize,
        ) CallError!void);

        try current.scheduling.callTwoArgs(opt_old_task, new_stack, target_function, arg1, arg2);
    }

    /// Prepares the CPU for jumping to the idle state.
    pub inline fn prepareForJumpToIdleFromTask(cpu: *kernel.Cpu, old_task: *kernel.Task) void {
        checkSupport(current.scheduling, "prepareForJumpToIdleFromTask", fn (
            *kernel.Cpu,
            *kernel.Task,
        ) void);

        current.scheduling.prepareForJumpToIdleFromTask(cpu, old_task);
    }

    /// Jumps to the idle state.
    ///
    /// Saves the old task's state to allow it to be resumed later.
    ///
    /// **Note**: It is the caller's responsibility to call `prepareForJumpToIdleFromTask` before calling this function.
    pub inline fn jumpToIdleFromTask(
        cpu: *kernel.Cpu,
        old_task: *kernel.Task,
    ) void {
        checkSupport(current.scheduling, "switchToIdleFromTask", fn (*kernel.Cpu, *kernel.Task) void);

        current.scheduling.jumpToIdleFromTask(cpu, old_task);
    }

    /// Prepares the CPU for jumping to the given task from the idle state.
    pub inline fn prepareForJumpToTaskFromIdle(cpu: *kernel.Cpu, new_task: *kernel.Task) void {
        checkSupport(current.scheduling, "prepareForJumpToTaskFromIdle", fn (
            *kernel.Cpu,
            *kernel.Task,
        ) void);

        current.scheduling.prepareForJumpToTaskFromIdle(cpu, new_task);
    }

    /// Jumps to the given task from the idle state.
    ///
    /// Saves the old task's state to allow it to be resumed later.
    ///
    /// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromIdle` before calling this function.
    pub inline fn jumpToTaskFromIdle(
        task: *kernel.Task,
    ) noreturn {
        checkSupport(current.scheduling, "jumpToTaskFromIdle", fn (*kernel.Task) noreturn);

        current.scheduling.jumpToTaskFromIdle(task);
    }

    /// Prepares the CPU for jumping from `old_task` to `new_task`.
    pub inline fn prepareForJumpToTaskFromTask(cpu: *kernel.Cpu, old_task: *kernel.Task, new_task: *kernel.Task) void {
        checkSupport(current.scheduling, "prepareForJumpToTaskFromTask", fn (
            *kernel.Cpu,
            *kernel.Task,
            *kernel.Task,
        ) void);

        current.scheduling.prepareForJumpToTaskFromTask(cpu, old_task, new_task);
    }

    /// Jumps from `old_task` to `new_task`.
    ///
    /// Saves the old task's state to allow it to be resumed later.
    ///
    /// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromTask` before calling this function.
    pub inline fn jumpToTaskFromTask(
        old_task: *kernel.Task,
        new_task: *kernel.Task,
    ) void {
        checkSupport(current.scheduling, "jumpToTaskFromTask", fn (*kernel.Task, *kernel.Task) void);

        current.scheduling.jumpToTaskFromTask(old_task, new_task);
    }

    pub const NewTaskFunction = *const fn (
        interrupt_exclusion: kernel.sync.InterruptExclusion,
        task: *kernel.Task,
        context: u64,
    ) noreturn;

    /// Prepares the given task for being scheduled.
    ///
    /// Ensures that when the task is scheduled it will release the scheduler then
    /// call the `target_function` with the given `context`.
    pub inline fn prepareNewTaskForScheduling(
        task: *kernel.Task,
        context: u64,
        target_function: NewTaskFunction,
    ) error{StackOverflow}!void {
        checkSupport(current.scheduling, "prepareNewTaskForScheduling", fn (
            *kernel.Task,
            u64,
            NewTaskFunction,
        ) error{StackOverflow}!void);

        return current.scheduling.prepareNewTaskForScheduling(task, context, target_function);
    }
};

/// Checks if the current architecture implements the given function.
///
/// If it is unimplemented, this function will panic at runtime.
///
/// If it is implemented, this function will validate it's signature at compile time and do nothing at runtime.
inline fn checkSupport(comptime Container: type, comptime name: []const u8, comptime TargetT: type) void {
    if (comptime name.len == 0) @compileError("zero-length name");

    if (comptime !@hasDecl(Container, name)) {
        core.panic("`" ++ @tagName(@import("cascade_target").arch) ++ "` does not implement `" ++ name ++ "`");
    }

    const DeclT = @TypeOf(@field(Container, name));

    const mismatch_type_msg =
        comptime "Expected `" ++ name ++ "` to be compatible with `" ++ @typeName(TargetT) ++
        "`, but it is `" ++ @typeName(DeclT) ++ "`";

    const decl_type_info = @typeInfo(DeclT).Fn;
    const target_type_info = @typeInfo(TargetT).Fn;

    if (decl_type_info.return_type != target_type_info.return_type) {
        const DeclReturnT = decl_type_info.return_type.?;
        const TargetReturnT = target_type_info.return_type.?;

        const target_return_type_info = @typeInfo(TargetReturnT);
        if (target_return_type_info != .ErrorUnion) @compileError(mismatch_type_msg);

        const target_return_error_union = target_return_type_info.ErrorUnion;
        if (target_return_error_union.error_set != anyerror) @compileError(mismatch_type_msg);

        // the target return type is an error union with anyerror, so the decl return type just needs to be an
        // error union with the right child type.

        const decl_return_type_info = @typeInfo(DeclReturnT);
        if (decl_return_type_info != .ErrorUnion) @compileError(mismatch_type_msg);

        const decl_return_error_union = decl_return_type_info.ErrorUnion;
        if (decl_return_error_union.payload != target_return_error_union.payload) @compileError(mismatch_type_msg);
    }

    if (decl_type_info.params.len != target_type_info.params.len) @compileError(mismatch_type_msg);

    inline for (decl_type_info.params, target_type_info.params) |decl_param, target_param| {
        if (decl_param.type != target_param.type) @compileError(mismatch_type_msg);
    }
}
