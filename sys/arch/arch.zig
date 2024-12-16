// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Defines the interface of the architecture specific code.

/// Architecture specific per-executor data.
pub const PerExecutor = current.PerExecutor;

/// Issues an architecture specific hint to the CPU that we are spinning in a loop.
pub fn spinLoopHint() callconv(core.inline_in_non_debug) void {
    // `checkSupport` intentionally not called - mandatory function

    current.spinLoopHint();
}

/// Get the current `Executor`.
///
/// Assumes that `init.loadExecutor()` has been called on the currently running CPU.
///
/// It is the callers responsibility to ensure that the current task is not re-scheduled onto another executor.
pub fn rawGetCurrentExecutor() callconv(core.inline_in_non_debug) *kernel.Executor {
    // `checkSupport` intentionally not called - mandatory function

    return current.getCurrentExecutor();
}

/// Halts the current executor
pub fn halt() callconv(core.inline_in_non_debug) void {
    // `checkSupport` intentionally not called - mandatory function

    current.halt();
}

pub const interrupts = struct {
    /// Returns true if interrupts are enabled.
    pub fn areEnabled() callconv(core.inline_in_non_debug) bool {
        // `checkSupport` intentionally not called - mandatory function

        return current.interrupts.areEnabled();
    }

    /// Disable interrupts and halt the CPU.
    ///
    /// This is a decl not a wrapper function like the other functions so that it can be inlined into a naked function.
    pub const disableInterruptsAndHalt = current.interrupts.disableInterruptsAndHalt;

    /// Disable interrupts.
    pub fn disableInterrupts() callconv(core.inline_in_non_debug) void {
        // `checkSupport` intentionally not called - mandatory function

        current.interrupts.disableInterrupts();
    }

    /// Enable interrupts.
    pub fn enableInterrupts() callconv(core.inline_in_non_debug) void {
        // `checkSupport` intentionally not called - mandatory function

        current.interrupts.enableInterrupts();
    }

    pub const InterruptHandler = *const fn (
        context: InterruptContext,
        interrupt_exclusion: *kernel.sync.InterruptExclusion,
    ) void;

    pub const InterruptContext = current.interrupts.InterruptContext;
};

pub const paging = struct {
    /// The standard page size for the architecture.
    pub const standard_page_size: core.Size = all_page_sizes[0];

    /// The largest page size supproted by the architecture.
    pub const largest_page_size: core.Size = all_page_sizes[current.paging.all_page_sizes.len - 1];

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
    pub inline fn mapToPhysicalRange(
        page_table: *PageTable,
        virtual_range: core.VirtualRange,
        physical_range: core.PhysicalRange,
        map_type: kernel.mem.MapType,
    ) kernel.mem.MapError!void {
        checkSupport(current.paging, "mapToPhysicalRange", fn (
            *paging.PageTable.ArchPageTable,
            core.VirtualRange,
            core.PhysicalRange,
            kernel.mem.MapType,
        ) kernel.mem.MapError!void);

        return current.paging.mapToPhysicalRange(
            page_table.arch,
            virtual_range,
            physical_range,
            map_type,
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
        page_table: *PageTable,
        virtual_range: core.VirtualRange,
        free_backing_pages: bool,
    ) void {
        checkSupport(
            current.paging,
            "unmapRange",
            fn (*paging.PageTable.ArchPageTable, core.VirtualRange, bool) void,
        );

        current.paging.unmapRange(
            page_table.arch,
            virtual_range,
            free_backing_pages,
        );
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
        /// This function panics on error.
        pub fn fillTopLevel(
            page_table: paging.PageTable,
            range: core.VirtualRange,
            map_type: kernel.mem.MapType,
        ) callconv(core.inline_in_non_debug) void {
            checkSupport(
                current.paging.init,
                "fillTopLevel",
                fn (
                    *paging.PageTable.ArchPageTable,
                    core.VirtualRange,
                    kernel.mem.MapType,
                ) void,
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
        ///  - panics on error
        pub fn mapToPhysicalRangeAllPageSizes(
            page_table: paging.PageTable,
            virtual_range: core.VirtualRange,
            physical_range: core.PhysicalRange,
            map_type: kernel.mem.MapType,
        ) callconv(core.inline_in_non_debug) void {
            checkSupport(current.paging.init, "mapToPhysicalRangeAllPageSizes", fn (
                *paging.PageTable.ArchPageTable,
                core.VirtualRange,
                core.PhysicalRange,
                kernel.mem.MapType,
            ) void);

            return current.paging.init.mapToPhysicalRangeAllPageSizes(
                page_table.arch,
                virtual_range,
                physical_range,
                map_type,
            );
        }
    };
};

/// Functionality that is used during kernel init only.
pub const init = struct {
    /// The entry point that is exported as `_start` and acts as fallback entry point for unknown bootloaders.
    ///
    /// No bootloader is ever expected to call `_start` and instead should use bootloader specific entry points;
    /// meaning this function is not expected to ever be called.
    ///
    /// This function is required to disable interrupts and halt execution at a minimum but may perform any additional
    /// debugging and error output if possible.
    pub const unknownBootloaderEntryPoint: *const fn () callconv(.Naked) noreturn = current.init.unknownBootloaderEntryPoint;

    /// Attempt to set up some form of early output.
    pub fn setupEarlyOutput() callconv(core.inline_in_non_debug) void {
        // `checkSupport` intentionally not called - mandatory function

        current.init.setupEarlyOutput();
    }

    /// Write to early output.
    ///
    /// Cannot fail, any errors are ignored.
    pub fn writeToEarlyOutput(bytes: []const u8) callconv(core.inline_in_non_debug) void {
        // `checkSupport` intentionally not called - mandatory function

        current.init.writeToEarlyOutput(bytes);
    }

    pub const early_output_writer = std.io.Writer(
        void,
        error{},
        struct {
            fn writeFn(_: void, bytes: []const u8) error{}!usize {
                writeToEarlyOutput(bytes);
                return bytes.len;
            }
        }.writeFn,
    ){ .context = {} };

    /// Prepares the provided `Executor` for the bootstrap executor.
    pub fn prepareBootstrapExecutor(
        bootstrap_executor: *kernel.Executor,
    ) callconv(core.inline_in_non_debug) void {
        checkSupport(current.init, "prepareBootstrapExecutor", fn (*kernel.Executor) void);

        current.init.prepareBootstrapExecutor(bootstrap_executor);
    }

    /// Prepares the provided `Executor` for use.
    ///
    /// **WARNING**: This function will panic if the cpu cannot be prepared.
    pub fn prepareExecutor(executor: *kernel.Executor) callconv(core.inline_in_non_debug) void {
        checkSupport(
            current.init,
            "prepareExecutor",
            fn (*kernel.Executor) void,
        );

        current.init.prepareExecutor(executor);
    }

    /// Load the provided `Executor` as the current executor.
    pub fn loadExecutor(executor: *kernel.Executor) callconv(core.inline_in_non_debug) void {
        checkSupport(current.init, "loadExecutor", fn (*kernel.Executor) void);

        current.init.loadExecutor(executor);
    }

    /// Ensure that any exceptions/faults that occur are handled.
    pub fn initInterrupts() callconv(core.inline_in_non_debug) void {
        checkSupport(current.init, "initInterrupts", fn () void);

        current.init.initInterrupts();
    }

    /// Switch away from the initial interrupt handlers installed by `initInterrupts` to the standard
    /// system interrupt handlers.
    pub fn loadStandardInterruptHandlers() callconv(core.inline_in_non_debug) void {
        checkSupport(current.init, "loadStandardInterruptHandlers", fn () void);

        current.init.loadStandardInterruptHandlers();
    }

    pub const CaptureSystemInformationOptions: type =
        if (@hasDecl(current.init, "CaptureSystemInformationOptions"))
        current.init.CaptureSystemInformationOptions
    else
        struct {};

    /// Capture any system information that is required for the architecture.
    ///
    /// For example, on x64 this should capture the CPUID information.
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
    pub fn configurePerExecutorSystemFeatures(executor: *kernel.Executor) callconv(core.inline_in_non_debug) void {
        checkSupport(current.init, "configurePerExecutorSystemFeatures", fn (*kernel.Executor) void);

        std.debug.assert(executor == rawGetCurrentExecutor());

        current.init.configurePerExecutorSystemFeatures(executor);
    }

    /// Register any architectural time sources.
    ///
    /// For example, on x86_64 this should register the TSC, HPEC, PIT, etc.
    pub fn registerArchitecturalTimeSources(candidate_time_sources: *init_time.CandidateTimeSources) callconv(core.inline_in_non_debug) void {
        checkSupport(
            current.init,
            "registerArchitecturalTimeSources",
            fn (*init_time.CandidateTimeSources) void,
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

pub const scheduling = struct {
    pub const CallError = error{StackOverflow};

    /// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
    pub fn callZeroArgs(
        opt_old_task: ?*kernel.Task,
        new_stack: kernel.Stack,
        target_function: *const fn () callconv(.C) noreturn,
    ) callconv(core.inline_in_non_debug) CallError!void {
        checkSupport(current.scheduling, "callZeroArgs", fn (
            ?*kernel.Task,
            kernel.Stack,
            *const fn () callconv(.C) noreturn,
        ) CallError!void);

        try current.scheduling.callZeroArgs(opt_old_task, new_stack, target_function);
    }

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
        task: *kernel.Task,
        context: u64,
        interrupt_exclusion: *kernel.sync.InterruptExclusion,
    ) noreturn;

    /// Prepares the given task for being scheduled.
    ///
    /// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `target_function` with
    /// the given `context`.
    pub fn prepareNewTaskForScheduling(
        task: *kernel.Task,
        context: u64,
        target_function: NewTaskFunction,
    ) callconv(core.inline_in_non_debug) error{StackOverflow}!void {
        checkSupport(current.scheduling, "prepareNewTaskForScheduling", fn (
            *kernel.Task,
            u64,
            NewTaskFunction,
        ) error{StackOverflow}!void);

        return current.scheduling.prepareNewTaskForScheduling(task, context, target_function);
    }
};

const current = switch (cascade_target) {
    // x64 is first to help zls, atleast while x64 is the main target.
    .x64 => @import("x64/x64.zig"),
    .arm64 => @import("arm64/arm64.zig"),
};

/// Checks if the current architecture implements the given function.
///
/// If it is unimplemented, this function will panic at runtime.
///
/// If it is implemented, this function will validate it's signature at compile time and do nothing at runtime.
inline fn checkSupport(comptime Container: type, comptime name: []const u8, comptime TargetT: type) void {
    if (comptime name.len == 0) @compileError("zero-length name");

    if (comptime !@hasDecl(Container, name)) {
        core.panic(comptime "`" ++ @tagName(cascade_target) ++ "` does not implement `" ++ name ++ "`", null);
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
const init_time = @import("init").time;
const cascade_target = @import("cascade_target").arch;
