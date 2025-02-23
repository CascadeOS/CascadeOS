// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

//! Defines the interface of the architecture specific code.

/// Architecture specific per-executor data.
pub const PerExecutor = current.PerExecutor;

/// Get the current `Executor`.
///
/// Assumes that `init.loadExecutor()` has been called on the currently running CPU.
pub fn rawGetCurrentExecutor() callconv(core.inline_in_non_debug) *kernel.Executor {
    checkSupport(current, "getCurrentExecutor", fn () *kernel.Executor);

    return current.getCurrentExecutor();
}

/// Issues an architecture specific hint to the CPU that we are spinning in a loop.
pub fn spinLoopHint() callconv(core.inline_in_non_debug) void {
    // `checkSupport` intentionally not called - mandatory function

    current.spinLoopHint();
}

/// Halts the current executor
pub fn halt() callconv(core.inline_in_non_debug) void {
    checkSupport(current, "halt", fn () void);

    current.halt();
}

pub const interrupts = struct {
    pub const Interrupt = current.interrupts.Interrupt;
    pub const InterruptFrame = current.interrupts.InterruptFrame;

    pub const InterruptHandler = *const fn (
        current_task: *kernel.Task,
        frame: *InterruptFrame,
        context1: ?*anyopaque,
        context2: ?*anyopaque,
    ) void;

    /// Disable interrupts and halt the CPU.
    ///
    /// This is a decl not a wrapper function like the other functions so that it can be inlined into a naked function.
    pub const disableInterruptsAndHalt = current.interrupts.disableInterruptsAndHalt;

    /// Returns true if interrupts are enabled.
    pub fn areEnabled() callconv(core.inline_in_non_debug) bool {
        // `checkSupport` intentionally not called - mandatory function

        return current.interrupts.areEnabled();
    }

    /// Enable interrupts.
    pub fn enableInterrupts() callconv(core.inline_in_non_debug) void {
        // `checkSupport` intentionally not called - mandatory function

        current.interrupts.enableInterrupts();
    }

    /// Disable interrupts.
    pub fn disableInterrupts() callconv(core.inline_in_non_debug) void {
        // `checkSupport` intentionally not called - mandatory function

        current.interrupts.disableInterrupts();
    }

    pub fn allocateInterrupt(
        current_task: *kernel.Task,
        handler: InterruptHandler,
        context1: ?*anyopaque,
        context2: ?*anyopaque,
    ) callconv(core.inline_in_non_debug) !Interrupt {
        checkSupport(
            current.interrupts,
            "allocateInterrupt",
            fn (*kernel.Task, InterruptHandler, ?*anyopaque, ?*anyopaque) anyerror!Interrupt,
        );

        return current.interrupts.allocateInterrupt(current_task, handler, context1, context2);
    }

    pub fn deallocateInterrupt(current_task: *kernel.Task, interrupt: Interrupt) callconv(core.inline_in_non_debug) void {
        checkSupport(current.interrupts, "deallocateInterrupt", fn (*kernel.Task, Interrupt) void);

        current.interrupts.deallocateInterrupt(current_task, interrupt);
    }

    pub fn routeInterrupt(external_interrupt: u32, interrupt: Interrupt) callconv(core.inline_in_non_debug) !void {
        checkSupport(
            current.interrupts,
            "routeInterrupt",
            fn (u32, Interrupt) anyerror!void,
        );

        return current.interrupts.routeInterrupt(external_interrupt, interrupt);
    }

    pub fn unrouteInterrupt(external_interrupt: u32) callconv(core.inline_in_non_debug) void {
        checkSupport(
            current.interrupts,
            "unrouteInterrupt",
            fn (u32) void,
        );

        current.interrupts.unrouteInterrupt(external_interrupt);
    }

    /// Signal end of interrupt.
    pub fn eoi() callconv(core.inline_in_non_debug) void {
        checkSupport(
            current.interrupts,
            "eoi",
            fn () void,
        );

        current.interrupts.eoi();
    }

    /// Send a panic IPI to all other executors.
    pub fn sendPanicIPI() callconv(core.inline_in_non_debug) void {
        checkSupport(
            current.interrupts,
            "sendPanicIPI",
            fn () void,
        );

        current.interrupts.sendPanicIPI();
    }

    pub const init = struct {
        /// Ensure that any exceptions/faults that occur during early initialization are handled.
        ///
        /// The handler is not expected to do anything other than panic.
        pub fn initializeEarlyInterrupts() callconv(core.inline_in_non_debug) void {
            checkSupport(current.interrupts.init, "initializeEarlyInterrupts", fn () void);

            current.interrupts.init.initializeEarlyInterrupts();
        }

        /// Prepare interrupt allocation and routing.
        pub fn initializeInterruptRouting(current_task: *kernel.Task) callconv(core.inline_in_non_debug) !void {
            checkSupport(current.interrupts.init, "initializeInterruptRouting", fn (*kernel.Task) anyerror!void);

            try current.interrupts.init.initializeInterruptRouting(current_task);
        }

        /// Switch away from the initial interrupt handlers installed by `initInterrupts` to the standard
        /// system interrupt handlers.
        pub fn loadStandardInterruptHandlers() callconv(core.inline_in_non_debug) void {
            checkSupport(current.interrupts.init, "loadStandardInterruptHandlers", fn () void);

            current.interrupts.init.loadStandardInterruptHandlers();
        }
    };
};

pub const paging = struct {
    // The standard page size for the architecture.
    pub const standard_page_size: core.Size = all_page_sizes[0];

    /// The largest page size supported by the architecture.
    pub const largest_page_size: core.Size = all_page_sizes[all_page_sizes.len - 1];

    /// All the page sizes supported by the architecture in order of smallest to largest.
    pub const all_page_sizes: []const core.Size = current.paging.all_page_sizes;

    /// The virtual address of the start of the higher half.
    pub const higher_half_start: core.VirtualAddress = current.paging.higher_half_start;

    /// The largest possible higher half virtual address.
    pub const largest_higher_half_virtual_address: core.VirtualAddress = current.paging.largest_higher_half_virtual_address;

    pub const PageTable = struct {
        physical_address: core.PhysicalAddress,
        arch: *ArchPageTable,

        /// Create a new page table at the given physical range.
        ///
        /// The range must have alignment of `page_table_alignment` and size greater than or equal to
        /// `page_table_size`.
        pub fn create(physical_range: core.PhysicalRange) callconv(core.inline_in_non_debug) PageTable {
            checkSupport(current.paging, "createPageTable", fn (core.PhysicalRange) *ArchPageTable);

            return .{
                .physical_address = physical_range.address,
                .arch = current.paging.createPageTable(physical_range),
            };
        }

        pub fn load(page_table: PageTable) callconv(core.inline_in_non_debug) void {
            checkSupport(current.paging, "loadPageTable", fn (core.PhysicalAddress) void);

            current.paging.loadPageTable(page_table.physical_address);
        }

        pub const page_table_alignment: core.Size = current.paging.page_table_alignment;
        pub const page_table_size: core.Size = current.paging.page_table_size;

        const ArchPageTable = current.paging.ArchPageTable;
    };

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
    pub fn mapToPhysicalRange(
        page_table: PageTable,
        virtual_range: core.VirtualRange,
        physical_range: core.PhysicalRange,
        map_type: kernel.vmm.MapType,
        keep_top_level: bool,
    ) callconv(core.inline_in_non_debug) kernel.vmm.MapError!void {
        checkSupport(current.paging, "mapToPhysicalRange", fn (
            *paging.PageTable.ArchPageTable,
            core.VirtualRange,
            core.PhysicalRange,
            kernel.vmm.MapType,
            bool,
        ) kernel.vmm.MapError!void);

        return current.paging.mapToPhysicalRange(
            page_table.arch,
            virtual_range,
            physical_range,
            map_type,
            keep_top_level,
        );
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
        page_table: PageTable,
        virtual_range: core.VirtualRange,
        free_backing_pages: bool,
        keep_top_level: bool,
    ) void {
        checkSupport(
            current.paging,
            "unmapRange",
            fn (*paging.PageTable.ArchPageTable, core.VirtualRange, bool, bool) void,
        );

        current.paging.unmapRange(
            page_table.arch,
            virtual_range,
            free_backing_pages,
            keep_top_level,
        );
    }

    /// Flushes the cache for the given virtual range.
    ///
    /// The `virtual_range` address and size must be aligned to the standard page size.
    pub fn flushCache(virtual_range: core.VirtualRange, flush_target: kernel.vmm.FlushTarget) callconv(core.inline_in_non_debug) void {
        checkSupport(current.paging, "flushCache", fn (core.VirtualRange, kernel.vmm.FlushTarget) void);

        current.paging.flushCache(virtual_range, flush_target);
    }

    pub const init = struct {
        /// The total size of the virtual address space that one entry in the top level of the page table covers.
        pub fn sizeOfTopLevelEntry() callconv(core.inline_in_non_debug) core.Size {
            checkSupport(current.paging.init, "sizeOfTopLevelEntry", fn () core.Size);

            return current.paging.init.sizeOfTopLevelEntry();
        }

        /// This function fills in the top level of the page table for the given range.
        ///
        /// The range is expected to have both size and alignment of `sizeOfTopLevelEntry()`.
        ///
        /// This function:
        ///  - does not flush the TLB
        ///  - does not rollback on error
        pub fn fillTopLevel(
            page_table: paging.PageTable,
            range: core.VirtualRange,
            map_type: kernel.vmm.MapType,
        ) callconv(core.inline_in_non_debug) !void {
            checkSupport(
                current.paging.init,
                "fillTopLevel",
                fn (
                    *paging.PageTable.ArchPageTable,
                    core.VirtualRange,
                    kernel.vmm.MapType,
                ) anyerror!void,
            );

            return current.paging.init.fillTopLevel(
                page_table.arch,
                range,
                map_type,
            );
        }

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
        ///  - does not rollback on error
        pub fn mapToPhysicalRangeAllPageSizes(
            page_table: paging.PageTable,
            virtual_range: core.VirtualRange,
            physical_range: core.PhysicalRange,
            map_type: kernel.vmm.MapType,
        ) callconv(core.inline_in_non_debug) !void {
            checkSupport(current.paging.init, "mapToPhysicalRangeAllPageSizes", fn (
                *paging.PageTable.ArchPageTable,
                core.VirtualRange,
                core.PhysicalRange,
                kernel.vmm.MapType,
            ) anyerror!void);

            return current.paging.init.mapToPhysicalRangeAllPageSizes(
                page_table.arch,
                virtual_range,
                physical_range,
                map_type,
            );
        }
    };
};

pub const scheduling = struct {
    /// Prepares the executor for jumping to the idle state.
    pub fn prepareForJumpToIdleFromTask(
        executor: *kernel.Executor,
        old_task: *kernel.Task,
    ) callconv(core.inline_in_non_debug) void {
        checkSupport(current.scheduling, "prepareForJumpToIdleFromTask", fn (
            *kernel.Executor,
            *kernel.Task,
        ) void);

        current.scheduling.prepareForJumpToIdleFromTask(executor, old_task);
    }

    /// Prepares the executor for jumping to the given task from the idle state.
    pub fn prepareForJumpToTaskFromIdle(
        executor: *kernel.Executor,
        new_task: *kernel.Task,
    ) callconv(core.inline_in_non_debug) void {
        checkSupport(current.scheduling, "prepareForJumpToTaskFromIdle", fn (
            *kernel.Executor,
            *kernel.Task,
        ) void);

        current.scheduling.prepareForJumpToTaskFromIdle(executor, new_task);
    }

    /// Jumps to the given task from the idle state.
    ///
    /// Saves the old task's state to allow it to be resumed later.
    ///
    /// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromIdle` before calling this function.
    pub fn jumpToTaskFromIdle(
        task: *kernel.Task,
    ) callconv(core.inline_in_non_debug) noreturn {
        checkSupport(current.scheduling, "jumpToTaskFromIdle", fn (*kernel.Task) noreturn);

        current.scheduling.jumpToTaskFromIdle(task);
    }

    /// Prepares the executor for jumping from `old_task` to `new_task`.
    pub fn prepareForJumpToTaskFromTask(
        executor: *kernel.Executor,
        old_task: *kernel.Task,
        new_task: *kernel.Task,
    ) callconv(core.inline_in_non_debug) void {
        checkSupport(current.scheduling, "prepareForJumpToTaskFromTask", fn (
            *kernel.Executor,
            *kernel.Task,
            *kernel.Task,
        ) void);

        current.scheduling.prepareForJumpToTaskFromTask(executor, old_task, new_task);
    }

    /// Jumps from `old_task` to `new_task`.
    ///
    /// Saves the old task's state to allow it to be resumed later.
    ///
    /// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromTask` before calling this function.
    pub fn jumpToTaskFromTask(
        old_task: *kernel.Task,
        new_task: *kernel.Task,
    ) callconv(core.inline_in_non_debug) void {
        checkSupport(current.scheduling, "jumpToTaskFromTask", fn (*kernel.Task, *kernel.Task) void);

        current.scheduling.jumpToTaskFromTask(old_task, new_task);
    }

    pub const NewTaskFunction = *const fn (
        current_task: *kernel.Task,
        arg: u64,
    ) noreturn;

    /// Prepares the given task for being scheduled.
    ///
    /// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `target_function` with
    /// the given `arg`.
    pub fn prepareNewTaskForScheduling(
        task: *kernel.Task,
        arg: u64,
        target_function: NewTaskFunction,
    ) callconv(core.inline_in_non_debug) error{StackOverflow}!void {
        checkSupport(current.scheduling, "prepareNewTaskForScheduling", fn (
            *kernel.Task,
            u64,
            NewTaskFunction,
        ) error{StackOverflow}!void);

        return current.scheduling.prepareNewTaskForScheduling(task, arg, target_function);
    }

    pub const CallError = error{StackOverflow};

    /// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
    pub fn callOneArgs(
        opt_old_task: ?*kernel.Task,
        new_stack: kernel.Stack,
        arg1: anytype,
        target_function: *const fn (@TypeOf(arg1)) callconv(.C) noreturn,
    ) callconv(core.inline_in_non_debug) CallError!void {
        checkSupport(current.scheduling, "callOneArgs", fn (
            ?*kernel.Task,
            kernel.Stack,
            *const fn (@TypeOf(arg1)) callconv(.C) noreturn,
            @TypeOf(arg1),
        ) CallError!void);

        try current.scheduling.callOneArgs(opt_old_task, new_stack, arg1, target_function);
    }

    /// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
    pub fn callTwoArgs(
        opt_old_task: ?*kernel.Task,
        new_stack: kernel.Stack,
        arg1: anytype,
        arg2: anytype,
        target_function: *const fn (@TypeOf(arg1), @TypeOf(arg2)) callconv(.C) noreturn,
    ) callconv(core.inline_in_non_debug) CallError!void {
        checkSupport(current.scheduling, "callTwoArgs", fn (
            ?*kernel.Task,
            kernel.Stack,
            *const fn (@TypeOf(arg1), @TypeOf(arg2)) callconv(.C) noreturn,
            @TypeOf(arg1),
            @TypeOf(arg2),
        ) CallError!void);

        try current.scheduling.callTwoArgs(opt_old_task, new_stack, arg1, arg2, target_function);
    }
};

pub const io = struct {
    pub const Port = current.io.Port;

    pub const PortError = error{UnsupportedPortSize};

    pub fn readPort(comptime T: type, port: Port) callconv(core.inline_in_non_debug) PortError!T {
        checkSupport(current.io, "readPort", fn (type, Port) PortError!T);

        return current.io.readPort(T, port);
    }

    pub fn writePort(comptime T: type, port: Port, value: T) callconv(core.inline_in_non_debug) PortError!void {
        checkSupport(current.io, "writePort", fn (type, Port, T) PortError!void);

        return current.io.writePort(T, port, value);
    }
};

/// Functionality that is used during kernel init only.
pub const init = struct {
    /// Attempt to get some form of init output.
    pub fn tryGetOutput() callconv(core.inline_in_non_debug) ?kernel.init.Output {
        // `checkSupport` intentionally not called - mandatory function

        return current.init.tryGetOutput();
    }

    /// Prepares the provided `Executor` for the bootstrap executor.
    pub fn prepareBootstrapExecutor(
        bootstrap_executor: *kernel.Executor,
        architecture_processor_id: u64,
    ) callconv(core.inline_in_non_debug) void {
        checkSupport(current.init, "prepareBootstrapExecutor", fn (*kernel.Executor, u64) void);

        current.init.prepareBootstrapExecutor(bootstrap_executor, architecture_processor_id);
    }

    /// Prepares the provided `Executor` for use.
    ///
    /// **WARNING**: This function will panic if the cpu cannot be prepared.
    pub fn prepareExecutor(
        executor: *kernel.Executor,
        architecture_processor_id: u64,
        current_task: *kernel.Task,
    ) callconv(core.inline_in_non_debug) void {
        checkSupport(
            current.init,
            "prepareExecutor",
            fn (*kernel.Executor, u64, *kernel.Task) void,
        );

        current.init.prepareExecutor(executor, architecture_processor_id, current_task);
    }

    /// Load the provided `Executor` as the current executor.
    pub fn loadExecutor(executor: *kernel.Executor) callconv(core.inline_in_non_debug) void {
        checkSupport(current.init, "loadExecutor", fn (*kernel.Executor) void);

        current.init.loadExecutor(executor);
    }

    /// Capture any system information that can be without using mmio.
    ///
    /// For example, on x64 this should capture CPUID but not APIC or ACPI information.
    pub fn captureEarlySystemInformation() callconv(core.inline_in_non_debug) !void {
        checkSupport(
            current.init,
            "captureEarlySystemInformation",
            fn () anyerror!void,
        );

        return current.init.captureEarlySystemInformation();
    }

    pub const CaptureSystemInformationOptions: type =
        if (@hasDecl(current.init, "CaptureSystemInformationOptions"))
        current.init.CaptureSystemInformationOptions
    else
        struct {};

    /// Capture any system information that needs mmio.
    ///
    /// For example, on x64 this should capture APIC and ACPI information.
    pub fn captureSystemInformation(
        options: CaptureSystemInformationOptions,
    ) callconv(core.inline_in_non_debug) !void {
        checkSupport(
            current.init,
            "captureSystemInformation",
            fn (CaptureSystemInformationOptions) anyerror!void,
        );

        return current.init.captureSystemInformation(options);
    }

    /// Configure any global system features.
    pub fn configureGlobalSystemFeatures() callconv(core.inline_in_non_debug) !void {
        checkSupport(current.init, "configureGlobalSystemFeatures", fn () anyerror!void);

        return current.init.configureGlobalSystemFeatures();
    }

    /// Configure any per-executor system features.
    ///
    /// **WARNING**: The `executor` provided must be the current executor.
    pub fn configurePerExecutorSystemFeatures(executor: *const kernel.Executor) callconv(core.inline_in_non_debug) void {
        checkSupport(current.init, "configurePerExecutorSystemFeatures", fn (*const kernel.Executor) void);

        std.debug.assert(executor == rawGetCurrentExecutor());

        current.init.configurePerExecutorSystemFeatures(executor);
    }

    /// Register any architectural time sources.
    ///
    /// For example, on x86_64 this should register the TSC, HPEC, PIT, etc.
    pub fn registerArchitecturalTimeSources(candidate_time_sources: *kernel.time.init.CandidateTimeSources) callconv(core.inline_in_non_debug) void {
        checkSupport(
            current.init,
            "registerArchitecturalTimeSources",
            fn (*kernel.time.init.CandidateTimeSources) void,
        );

        current.init.registerArchitecturalTimeSources(candidate_time_sources);
    }

    /// Initialize the local interrupt controller for the current executor.
    ///
    /// For example, on x86_64 this should initialize the APIC.
    pub fn initLocalInterruptController() callconv(core.inline_in_non_debug) void {
        checkSupport(current.init, "initLocalInterruptController", fn () void);

        current.init.initLocalInterruptController();
    }
};

const current = switch (cascade_target) {
    // x64 is first to help zls, atleast while x64 is the main target.
    .x64 => @import("x64/x64.zig"),
    .arm => @import("arm/arm.zig"),
    .riscv => @import("riscv/riscv.zig"),
};

/// Checks if the current architecture implements the given function.
///
/// If it is unimplemented, this function will panic at runtime.
///
/// If it is implemented, this function will validate it's signature at compile time and do nothing at runtime.
inline fn checkSupport(comptime Container: type, comptime name: []const u8, comptime TargetT: type) void {
    if (comptime name.len == 0) @compileError("zero-length name");

    if (comptime !@hasDecl(Container, name)) {
        @panic(comptime "`" ++ @tagName(cascade_target) ++ "` does not implement `" ++ name ++ "`");
    }

    const DeclT = @TypeOf(@field(Container, name));

    const mismatch_type_msg =
        comptime "Expected `" ++ name ++ "` to be compatible with `" ++ @typeName(TargetT) ++
        "`, but it is `" ++ @typeName(DeclT) ++ "`";

    const decl_type_info = @typeInfo(DeclT).@"fn";
    const target_type_info = @typeInfo(TargetT).@"fn";

    if (decl_type_info.return_type != target_type_info.return_type) blk: {
        const DeclReturnT = decl_type_info.return_type orelse break :blk;
        const TargetReturnT = target_type_info.return_type orelse @compileError(mismatch_type_msg);

        const target_return_type_info = @typeInfo(TargetReturnT);
        if (target_return_type_info != .error_union) @compileError(mismatch_type_msg);

        const target_return_error_union = target_return_type_info.error_union;
        if (target_return_error_union.error_set != anyerror) @compileError(mismatch_type_msg);

        // the target return type is an error union with anyerror, so the decl return type just needs to be an
        // error union with the right child type.

        const decl_return_type_info = @typeInfo(DeclReturnT);
        if (decl_return_type_info != .error_union) @compileError(mismatch_type_msg);

        const decl_return_error_union = decl_return_type_info.error_union;
        if (decl_return_error_union.payload != target_return_error_union.payload) @compileError(mismatch_type_msg);
    }

    if (decl_type_info.params.len != target_type_info.params.len) @compileError(mismatch_type_msg);

    inline for (decl_type_info.params, target_type_info.params) |decl_param, target_param| {
        // `null` means generics/anytype, so we just assume the types match and let zig catch mismatches.
        if (decl_param.type == null) continue;
        if (target_param.type == null) continue;

        if (decl_param.type != target_param.type) @compileError(mismatch_type_msg);
    }
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const cascade_target = kernel.config.cascade_target;
