// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

// TODO: duplication of doc comments is annoying, but having them accessible to each arch as well to the rest of the
//       kernel is useful

//! Defines the interface of the architecture specific code.

pub const current_arch = @import("cascade_architecture").arch;

/// Architecture specific per-executor data.
pub const PerExecutor = current_decls.PerExecutor;

/// Get the current `Executor`.
///
/// Assumes that `init.loadExecutor` has been called on the currently running executor.
pub fn getCurrentExecutor() callconv(core.inline_in_non_debug) *kernel.Executor {
    return getFunction(
        current_functions,
        "getCurrentExecutor",
    )();
}

/// Issues an architecture specific hint to the executor that we are spinning in a loop.
pub fn spinLoopHint() callconv(core.inline_in_non_debug) void {
    getFunction(
        current_functions,
        "spinLoopHint",
    )();
}

/// Halts the current executor.
pub fn halt() callconv(core.inline_in_non_debug) void {
    getFunction(
        current_functions,
        "halt",
    )();
}

pub const interrupts = struct {
    // marked as `inline` unconditionally so that it can be called from a naked function.
    pub inline fn disableAndHalt() noreturn {
        getFunction(
            current_functions.interrupts,
            "disableAndHalt",
        )();
    }

    pub fn areEnabled() callconv(core.inline_in_non_debug) bool {
        return getFunction(
            current_functions.interrupts,
            "areEnabled",
        )();
    }

    pub fn enable() callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.interrupts,
            "enable",
        )();
    }

    pub fn disable() callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.interrupts,
            "disable",
        )();
    }

    /// Signal end of interrupt.
    pub fn eoi() callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.interrupts,
            "eoi",
        )();
    }

    /// Send a panic IPI to all other executors.
    pub fn sendPanicIPI() callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.interrupts,
            "sendPanicIPI",
        )();
    }

    /// Send a flush IPI to the given executor.
    pub fn sendFlushIPI(executor: *kernel.Executor) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.interrupts,
            "sendFlushIPI",
        )(executor);
    }

    pub const Interrupt = struct {
        arch_specific: current_decls.interrupts.Interrupt,

        pub const Handler = *const fn (
            current_task: *kernel.Task,
            frame: InterruptFrame,
            context1: ?*anyopaque,
            context2: ?*anyopaque,
        ) void;

        pub const AllocateError = error{InterruptAllocationFailed};

        pub fn allocate(
            current_task: *kernel.Task,
            handler: Handler,
            context1: ?*anyopaque,
            context2: ?*anyopaque,
        ) callconv(core.inline_in_non_debug) AllocateError!Interrupt {
            return .{
                .arch_specific = try getFunction(
                    current_functions.interrupts,
                    "allocateInterrupt",
                )(current_task, handler, context1, context2),
            };
        }

        pub fn deallocate(interrupt: Interrupt, current_task: *kernel.Task) callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.interrupts,
                "deallocateInterrupt",
            )(interrupt.arch_specific, current_task);
        }

        pub const RouteError = error{UnableToRouteExternalInterrupt};

        pub fn route(interrupt: Interrupt, external_interrupt: u32) callconv(core.inline_in_non_debug) RouteError!void {
            return getFunction(
                current_functions.interrupts,
                "routeInterrupt",
            )(interrupt.arch_specific, external_interrupt);
        }

        pub fn toUsize(interrupt: Interrupt) callconv(core.inline_in_non_debug) usize {
            return @intFromEnum(interrupt.arch_specific);
        }

        pub fn fromUsize(interrupt: usize) callconv(core.inline_in_non_debug) Interrupt {
            return .{ .arch_specific = @enumFromInt(interrupt) };
        }
    };

    pub const InterruptFrame = struct {
        arch_specific: *current_decls.interrupts.InterruptFrame,

        /// Creates a stack iterator for the context this interrupt was triggered from.
        pub fn createStackIterator(self: InterruptFrame) std.debug.StackIterator {
            // TODO: this is used during panics, so if it is not implemented we will panic during a panic
            return getFunction(
                current_functions.interrupts,
                "createStackIterator",
            )(self.arch_specific);
        }

        /// Returns the instruction pointer of the context this interrupt was triggered from.
        pub fn instructionPointer(self: InterruptFrame) usize {
            // TODO: this is used during panics, so if it is not implemented we will panic during a panic
            return getFunction(
                current_functions.interrupts,
                "instructionPointer",
            )(self.arch_specific);
        }

        pub inline fn format(
            interrupt_frame: InterruptFrame,
            writer: *std.Io.Writer,
        ) !void {
            return interrupt_frame.arch_specific.format(writer);
        }
    };

    pub const init = struct {
        /// Ensure that any exceptions/faults that occur during early initialization are handled.
        ///
        /// The handler is not expected to do anything other than panic.
        pub fn initializeEarlyInterrupts() callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.interrupts.init,
                "initializeEarlyInterrupts",
            )();
        }

        /// Prepare interrupt allocation and routing.
        pub fn initializeInterruptRouting(current_task: *kernel.Task) callconv(core.inline_in_non_debug) !void {
            return getFunction(
                current_functions.interrupts.init,
                "initializeInterruptRouting",
            )(current_task);
        }

        /// Switch away from the initial interrupt handlers installed by `initInterrupts` to the standard
        /// system interrupt handlers.
        pub fn loadStandardInterruptHandlers() callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.interrupts.init,
                "loadStandardInterruptHandlers",
            )();
        }
    };
};

pub const paging = struct {
    /// The standard page size for the architecture.
    pub const standard_page_size: core.Size = current_decls.paging.standard_page_size;

    /// The largest page size supported by the architecture.
    pub const largest_page_size: core.Size = current_decls.paging.largest_page_size;

    /// The total size of the lower half.
    ///
    /// This includes the zero page.
    pub const lower_half_size: core.Size = current_decls.paging.lower_half_size;

    /// The virtual address of the start of the higher half.
    pub const higher_half_start: core.VirtualAddress = current_decls.paging.higher_half_start;

    pub const PageTable = struct {
        physical_frame: kernel.mem.phys.Frame,
        arch_specific: *current_decls.paging.PageTable,

        /// Create a new page table in the given physical frame.
        pub fn create(physical_frame: kernel.mem.phys.Frame) callconv(core.inline_in_non_debug) PageTable {
            return .{
                .physical_frame = physical_frame,
                .arch_specific = getFunction(
                    current_functions.paging,
                    "createPageTable",
                )(physical_frame),
            };
        }

        pub fn load(page_table: PageTable) callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.paging,
                "loadPageTable",
            )(page_table.physical_frame);
        }

        /// Copies the top level of `page_table` into `target_page_table`.
        pub fn copyTopLevelInto(
            page_table: PageTable,
            target_page_table: PageTable,
        ) callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.paging,
                "copyTopLevelIntoPageTable",
            )(page_table.arch_specific, target_page_table.arch_specific);
        }
    };

    /// Maps `virtual_address` to `physical_frame` with mapping type `map_type`.
    ///
    /// Caller must ensure:
    ///  - the virtual address is aligned to the standard page size
    ///  - the virtual address is not already mapped
    ///
    /// This function:
    ///  - only supports the standard page size for the architecture
    ///  - does not flush the TLB
    pub fn mapSinglePage(
        page_table: PageTable,
        virtual_address: core.VirtualAddress,
        physical_frame: kernel.mem.phys.Frame,
        map_type: kernel.mem.MapType,
        physical_frame_allocator: kernel.mem.phys.FrameAllocator,
    ) callconv(core.inline_in_non_debug) kernel.mem.MapError!void {
        return getFunction(
            current_functions.paging,
            "mapSinglePage",
        )(page_table.arch_specific, virtual_address, physical_frame, map_type, physical_frame_allocator);
    }

    /// Unmaps `virtual_address`.
    ///
    /// Caller must ensure:
    ///  - the virtual address is aligned to the standard page size
    ///
    /// This function:
    ///  - only supports the standard page size for the architecture
    ///  - does not flush the TLB
    pub fn unmapSinglePage(
        page_table: PageTable,
        virtual_address: core.VirtualAddress,
        backing_page_decision: core.CleanupDecision,
        top_level_decision: core.CleanupDecision,
        deallocate_frame_list: *kernel.mem.phys.FrameList,
    ) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.paging,
            "unmapSinglePage",
        )(page_table.arch_specific, virtual_address, backing_page_decision, top_level_decision, deallocate_frame_list);
    }

    /// Flushes the cache for the given virtual range on the current executor.
    ///
    /// The `virtual_range` address and size must be aligned to the standard page size.
    pub fn flushCache(virtual_range: core.VirtualRange) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.paging,
            "flushCache",
        )(virtual_range);
    }

    pub const init = struct {
        /// The total size of the virtual address space that one entry in the top level of the page table covers.
        pub fn sizeOfTopLevelEntry() callconv(core.inline_in_non_debug) core.Size {
            return getFunction(
                current_functions.paging.init,
                "sizeOfTopLevelEntry",
            )();
        }

        /// This function fills in the top level of the page table for the given range.
        ///
        /// The range is expected to have both size and alignment of `sizeOfTopLevelEntry()`.
        ///
        /// This function:
        ///  - does not flush the TLB
        ///  - does not rollback on error
        pub fn fillTopLevel(
            page_table: PageTable,
            range: core.VirtualRange,
            physical_frame_allocator: kernel.mem.phys.FrameAllocator,
        ) callconv(core.inline_in_non_debug) anyerror!void {
            return getFunction(
                current_functions.paging.init,
                "fillTopLevel",
            )(page_table.arch_specific, range, physical_frame_allocator);
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
            page_table: PageTable,
            virtual_range: core.VirtualRange,
            physical_range: core.PhysicalRange,
            map_type: kernel.mem.MapType,
            physical_frame_allocator: kernel.mem.phys.FrameAllocator,
        ) callconv(core.inline_in_non_debug) anyerror!void {
            return getFunction(
                current_functions.paging.init,
                "mapToPhysicalRangeAllPageSizes",
            )(page_table.arch_specific, virtual_range, physical_range, map_type, physical_frame_allocator);
        }
    };
};

pub const scheduling = struct {
    /// Prepares the executor for jumping from `old_task` to `new_task`.
    pub fn prepareForJumpToTaskFromTask(
        executor: *kernel.Executor,
        old_task: *kernel.Task,
        new_task: *kernel.Task,
    ) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.scheduling,
            "prepareForJumpToTaskFromTask",
        )(executor, old_task, new_task);
    }

    /// Jumps to the given task without saving the old task's state.
    ///
    /// If the old task is ever rescheduled undefined behaviour may occur.
    ///
    /// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromTask` before calling this function.
    pub fn jumpToTask(
        task: *kernel.Task,
    ) callconv(core.inline_in_non_debug) noreturn {
        getFunction(
            current_functions.scheduling,
            "jumpToTask",
        )(task);
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
        getFunction(
            current_functions.scheduling,
            "jumpToTaskFromTask",
        )(old_task, new_task);
    }

    pub const NewTaskFunction = *const fn (
        current_task: *kernel.Task,
        arg1: usize,
        arg2: usize,
    ) noreturn;

    /// Prepares the given task for being scheduled.
    ///
    /// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `target_function` with
    /// the given arguments.
    pub fn prepareNewTaskForScheduling(
        task: *kernel.Task,
        target_function: NewTaskFunction,
        arg1: usize,
        arg2: usize,
    ) callconv(core.inline_in_non_debug) error{StackOverflow}!void {
        return getFunction(
            current_functions.scheduling,
            "prepareNewTaskForScheduling",
        )(task, target_function, arg1, arg2);
    }

    pub const CallError = error{StackOverflow};

    /// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
    pub fn callTwoArgs(
        opt_old_task: ?*kernel.Task,
        new_stack: kernel.Task.Stack,
        arg1: usize,
        arg2: usize,
        target_function: *const fn (usize, usize) callconv(.c) noreturn,
    ) callconv(core.inline_in_non_debug) CallError!void {
        return getFunction(
            current_functions.scheduling,
            "callTwoArgs",
        )(opt_old_task, new_stack, arg1, arg2, target_function);
    }

    /// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
    pub fn callFourArgs(
        opt_old_task: ?*kernel.Task,
        new_stack: kernel.Task.Stack,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        target_function: *const fn (usize, usize, usize, usize) callconv(.c) noreturn,
    ) callconv(core.inline_in_non_debug) CallError!void {
        return getFunction(
            current_functions.scheduling,
            "callFourArgs",
        )(opt_old_task, new_stack, arg1, arg2, arg3, arg4, target_function);
    }
};

pub const io = struct {
    pub const Port = struct {
        arch_specific: current_decls.io.Port,

        pub const FromError = error{InvalidPort};

        /// Creates a port.
        pub fn from(port: usize) FromError!Port {
            return .{
                .arch_specific = @enumFromInt(std.math.cast(
                    @typeInfo(current_decls.io.Port).@"enum".tag_type,
                    port,
                ) orelse return error.InvalidPort),
            };
        }

        pub fn read(port: Port, comptime T: type) callconv(core.inline_in_non_debug) T {
            return switch (T) {
                u8 => return getFunction(
                    current_functions.io,
                    "readPortU8",
                )(port.arch_specific),
                u16 => return getFunction(
                    current_functions.io,
                    "readPortU16",
                )(port.arch_specific),
                u32 => return getFunction(
                    current_functions.io,
                    "readPortU32",
                )(port.arch_specific),
                else => @compileError("unsupported port size"),
            };
        }

        pub fn write(port: Port, comptime T: type, value: T) callconv(core.inline_in_non_debug) void {
            switch (T) {
                u8 => getFunction(
                    current_functions.io,
                    "writePortU8",
                )(port.arch_specific, value),
                u16 => getFunction(
                    current_functions.io,
                    "writePortU16",
                )(port.arch_specific, value),
                u32 => getFunction(
                    current_functions.io,
                    "writePortU32",
                )(port.arch_specific, value),
                else => @compileError("unsupported port size"),
            }
        }
    };
};

/// Functionality that is used during kernel init only.
pub const init = struct {
    /// Read current wallclock time from the standard wallclock source of the current architecture.
    ///
    /// For example on x86_64 this is the TSC.
    pub fn getStandardWallclockStartTime() kernel.time.wallclock.Tick {
        return getFunction(
            current_functions.init,
            "getStandardWallclockStartTime",
        )();
    }

    pub const InitOutput = struct {
        output: Output,
        preference: Preference,

        pub const Output = kernel.exports.Output;

        pub const Preference = enum {
            /// Use this output.
            use,

            /// Only use this output if a generic output is not available.
            prefer_generic,
        };
    };

    /// Attempt to get some form of architecture specific init output if it is available.
    pub fn tryGetSerialOutput() callconv(core.inline_in_non_debug) ?InitOutput {
        return getFunction(
            current_functions.init,
            "tryGetSerialOutput",
        )();
    }

    /// Prepares the provided `Executor` for the bootstrap executor.
    pub fn prepareBootstrapExecutor(
        bootstrap_executor: *kernel.Executor,
        architecture_processor_id: u64,
    ) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.init,
            "prepareBootstrapExecutor",
        )(bootstrap_executor, architecture_processor_id);
    }

    /// Prepares the provided `Executor` for use.
    ///
    /// **WARNING**: This function will panic if the cpu cannot be prepared.
    pub fn prepareExecutor(
        executor: *kernel.Executor,
        architecture_processor_id: u64,
        current_task: *kernel.Task,
    ) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.init,
            "prepareExecutor",
        )(executor, architecture_processor_id, current_task);
    }

    /// Load the provided `Executor` as the current executor.
    pub fn loadExecutor(executor: *kernel.Executor) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.init,
            "loadExecutor",
        )(executor);
    }

    /// Capture any system information that can be without using mmio.
    ///
    /// For example, on x64 this should capture CPUID but not APIC or ACPI information.
    pub fn captureEarlySystemInformation() callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.init,
            "captureEarlySystemInformation",
        )();
    }

    pub const CaptureSystemInformationOptions = current_decls.init.CaptureSystemInformationOptions;

    /// Capture any system information that needs mmio.
    ///
    /// For example, on x64 this should capture APIC and ACPI information.
    pub fn captureSystemInformation(
        options: CaptureSystemInformationOptions,
    ) callconv(core.inline_in_non_debug) anyerror!void {
        return getFunction(
            current_functions.init,
            "captureSystemInformation",
        )(options);
    }

    /// Configure any global system features.
    pub fn configureGlobalSystemFeatures() callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.init,
            "configureGlobalSystemFeatures",
        )();
    }

    /// Configure any per-executor system features.
    ///
    /// **WARNING**: The `executor` provided must be the current executor.
    pub fn configurePerExecutorSystemFeatures(
        executor: *const kernel.Executor,
    ) callconv(core.inline_in_non_debug) void {
        std.debug.assert(executor == getCurrentExecutor());
        getFunction(
            current_functions.init,
            "configurePerExecutorSystemFeatures",
        )(executor);
    }

    /// Register any architectural time sources.
    ///
    /// For example, on x86_64 this should register the TSC, HPEC, PIT, etc.
    pub fn registerArchitecturalTimeSources(
        candidate_time_sources: *kernel.time.init.CandidateTimeSources,
    ) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.init,
            "registerArchitecturalTimeSources",
        )(candidate_time_sources);
    }

    /// Initialize the local interrupt controller for the current executor.
    ///
    /// For example, on x86_64 this should initialize the APIC.
    pub fn initLocalInterruptController() callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.init,
            "initLocalInterruptController",
        )();
    }
};

/// This contains the functions that the architecture specific code must implement.
///
/// Any optional functions that are not implemented will result in runtime panics when called.
pub const Functions = struct {
    /// Get the current `Executor`.
    ///
    /// Assumes that `init.loadExecutor` has been called on the currently running executor.
    getCurrentExecutor: ?fn () callconv(.@"inline") *kernel.Executor = null,

    /// Issues an architecture specific hint to the executor that we are spinning in a loop.
    spinLoopHint: ?fn () callconv(.@"inline") void = null,

    /// Halts the current executor.
    halt: ?fn () callconv(.@"inline") void = null,

    interrupts: struct {
        /// Disables interrupts and halts the current executor.
        ///
        /// Non-optional because it is used during early initialization.
        disableAndHalt: fn () callconv(.@"inline") noreturn,

        /// Returns whether interrupts are enabled.
        areEnabled: ?fn () callconv(.@"inline") bool = null,

        /// Enables interrupts.
        enable: ?fn () callconv(.@"inline") void = null,

        /// Disables interrupts.
        ///
        /// Non-optional because it is used during early initialization.
        disable: fn () callconv(.@"inline") void,

        /// Signal end of interrupt.
        eoi: ?fn () void = null,

        /// Send a panic IPI to all other executors.
        sendPanicIPI: ?fn () void = null,

        /// Send a flush IPI to the given executor.
        sendFlushIPI: ?fn (*kernel.Executor) void = null,

        allocateInterrupt: ?fn (
            current_task: *kernel.Task,
            handler: interrupts.Interrupt.Handler,
            context1: ?*anyopaque,
            context2: ?*anyopaque,
        ) interrupts.Interrupt.AllocateError!current_decls.interrupts.Interrupt = null,

        deallocateInterrupt: ?fn (
            interrupt: current_decls.interrupts.Interrupt,
            current_task: *kernel.Task,
        ) void = null,

        routeInterrupt: ?fn (
            interrupt: current_decls.interrupts.Interrupt,
            external_interrupt: u32,
        ) interrupts.Interrupt.RouteError!void = null,

        /// Creates a stack iterator for the context this interrupt was triggered from.
        createStackIterator: ?fn (
            interrupt_frame: *const current_decls.interrupts.InterruptFrame,
        ) std.debug.StackIterator = null,

        /// Returns the instruction pointer of the context this interrupt was triggered from.
        instructionPointer: ?fn (interrupt_frame: *const current_decls.interrupts.InterruptFrame) usize = null,

        init: struct {
            /// Ensure that any exceptions/faults that occur during early initialization are handled.
            ///
            /// The handler is not expected to do anything other than panic.
            initializeEarlyInterrupts: ?fn () void = null,

            /// Prepare interrupt allocation and routing.
            initializeInterruptRouting: ?fn (*kernel.Task) void = null,

            /// Switch away from the initial interrupt handlers installed by `initInterrupts` to the standard
            /// system interrupt handlers.
            loadStandardInterruptHandlers: ?fn () void = null,
        },
    },

    paging: struct {
        /// Create a new page table in the given physical frame.
        createPageTable: ?fn (physical_frame: kernel.mem.phys.Frame) *current_decls.paging.PageTable = null,

        loadPageTable: ?fn (physical_frame: kernel.mem.phys.Frame) void = null,

        /// Copies the top level of `page_table` into `target_page_table`.
        copyTopLevelIntoPageTable: ?fn (
            page_table: *current_decls.paging.PageTable,
            target_page_table: *current_decls.paging.PageTable,
        ) void = null,

        /// Maps `virtual_address` to `physical_frame` with mapping type `map_type`.
        ///
        /// Caller must ensure:
        ///  - the virtual address is aligned to the standard page size
        ///  - the virtual address is not already mapped
        ///
        /// This function:
        ///  - only supports the standard page size for the architecture
        ///  - does not flush the TLB
        mapSinglePage: ?fn (
            page_table: *current_decls.paging.PageTable,
            virtual_address: core.VirtualAddress,
            physical_frame: kernel.mem.phys.Frame,
            map_type: kernel.mem.MapType,
            physical_frame_allocator: kernel.mem.phys.FrameAllocator,
        ) kernel.mem.MapError!void = null,

        /// Unmaps `virtual_address`.
        ///
        /// Caller must ensure:
        ///  - the virtual address is aligned to the standard page size
        ///
        /// This function:
        ///  - only supports the standard page size for the architecture
        ///  - does not flush the TLB
        unmapSinglePage: ?fn (
            page_table: *current_decls.paging.PageTable,
            virtual_address: core.VirtualAddress,
            backing_page_decision: core.CleanupDecision,
            top_level_decision: core.CleanupDecision,
            deallocate_frame_list: *kernel.mem.phys.FrameList,
        ) void = null,

        /// Flushes the cache for the given virtual range on the current executor.
        ///
        /// The `virtual_range` address and size must be aligned to the standard page size.
        flushCache: ?fn (virtual_range: core.VirtualRange) void = null,

        init: struct {
            /// The total size of the virtual address space that one entry in the top level of the page table covers.
            sizeOfTopLevelEntry: ?fn () core.Size = null,

            /// This function fills in the top level of the page table for the given range.
            ///
            /// The range is expected to have both size and alignment of `sizeOfTopLevelEntry()`.
            ///
            /// This function:
            ///  - does not flush the TLB
            ///  - does not rollback on error
            fillTopLevel: ?fn (
                page_table: *current_decls.paging.PageTable,
                range: core.VirtualRange,
                physical_frame_allocator: kernel.mem.phys.FrameAllocator,
            ) anyerror!void = null,

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
            mapToPhysicalRangeAllPageSizes: ?fn (
                page_table: *current_decls.paging.PageTable,
                virtual_range: core.VirtualRange,
                physical_range: core.PhysicalRange,
                map_type: kernel.mem.MapType,
                physical_frame_allocator: kernel.mem.phys.FrameAllocator,
            ) anyerror!void = null,
        },
    },

    scheduling: struct {
        /// Prepares the executor for jumping from `old_task` to `new_task`.
        prepareForJumpToTaskFromTask: ?fn (
            executor: *kernel.Executor,
            old_task: *kernel.Task,
            new_task: *kernel.Task,
        ) void = null,

        /// Jumps to the given task without saving the old task's state.
        ///
        /// If the old task is ever rescheduled undefined behaviour may occur.
        ///
        /// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromTask` before calling this function.
        jumpToTask: ?fn (task: *kernel.Task) noreturn = null,

        /// Jumps from `old_task` to `new_task`.
        ///
        /// Saves the old task's state to allow it to be resumed later.
        ///
        /// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromTask` before calling this function.
        jumpToTaskFromTask: ?fn (old_task: *kernel.Task, new_task: *kernel.Task) void = null,

        /// Prepares the given task for being scheduled.
        ///
        /// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `target_function` with
        /// the given arguments.
        prepareNewTaskForScheduling: ?fn (
            task: *kernel.Task,
            target_function: scheduling.NewTaskFunction,
            arg1: usize,
            arg2: usize,
        ) error{StackOverflow}!void = null,

        /// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
        callTwoArgs: ?fn (
            opt_old_task: ?*kernel.Task,
            new_stack: kernel.Task.Stack,
            arg1: usize,
            arg2: usize,
            target_function: *const fn (usize, usize) callconv(.c) noreturn,
        ) scheduling.CallError!void = null,

        /// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
        callFourArgs: ?fn (
            opt_old_task: ?*kernel.Task,
            new_stack: kernel.Task.Stack,
            arg1: usize,
            arg2: usize,
            arg3: usize,
            arg4: usize,
            target_function: *const fn (usize, usize, usize, usize) callconv(.c) noreturn,
        ) scheduling.CallError!void = null,
    },

    io: struct {
        readPortU8: ?fn (port: current_decls.io.Port) u8 = null,
        readPortU16: ?fn (port: current_decls.io.Port) u16 = null,
        readPortU32: ?fn (port: current_decls.io.Port) u32 = null,

        writePortU8: ?fn (port: current_decls.io.Port, value: u8) void = null,
        writePortU16: ?fn (port: current_decls.io.Port, value: u16) void = null,
        writePortU32: ?fn (port: current_decls.io.Port, value: u32) void = null,
    },

    init: struct {
        /// Read current wallclock time from the standard wallclock source of the current architecture.
        ///
        /// For example on x86_64 this is the TSC.
        ///
        /// Non-optional because it is used during early initialization.
        getStandardWallclockStartTime: fn () kernel.time.wallclock.Tick,

        /// Attempt to get some form of architecture specific init output if it is available.
        ///
        /// Non-optional because it is used during early initialization.
        tryGetSerialOutput: fn () ?init.InitOutput,

        /// Prepares the provided `Executor` for the bootstrap executor.
        prepareBootstrapExecutor: ?fn (*kernel.Executor, u64) void = null,

        /// Prepares the provided `Executor` for use.
        ///
        /// **WARNING**: This function will panic if the cpu cannot be prepared.
        prepareExecutor: ?fn (*kernel.Executor, u64, *kernel.Task) void = null,

        /// Load the provided `Executor` as the current executor.
        loadExecutor: ?fn (*kernel.Executor) void = null,

        /// Capture any system information that can be without using mmio.
        ///
        /// For example, on x64 this should capture CPUID but not APIC or ACPI information.
        captureEarlySystemInformation: ?fn () void = null,

        /// Capture any system information that needs mmio.
        ///
        /// For example, on x64 this should capture APIC and ACPI information.
        captureSystemInformation: ?fn (options: current_decls.init.CaptureSystemInformationOptions) anyerror!void = null,

        /// Configure any global system features.
        configureGlobalSystemFeatures: ?fn () void = null,

        /// Configure any per-executor system features.
        ///
        /// **WARNING**: The `executor` provided must be the current executor.
        configurePerExecutorSystemFeatures: ?fn (*const kernel.Executor) void = null,

        /// Register any architectural time sources.
        ///
        /// For example, on x86_64 this should register the TSC, HPEC, PIT, etc.
        registerArchitecturalTimeSources: ?fn (*kernel.time.init.CandidateTimeSources) void = null,

        /// Initialize the local interrupt controller for the current executor.
        ///
        /// For example, on x86_64 this should initialize the APIC.
        initLocalInterruptController: ?fn () void = null,
    },
};

/// This contains the declarations that the architecture specific code must export.
pub const Decls = struct {
    /// Architecture specific per-executor data.
    PerExecutor: type,

    interrupts: struct {
        /// Handle to an interrupt.
        ///
        /// Expected to be an enum.
        Interrupt: type,

        InterruptFrame: type,
    },

    paging: struct {
        /// The standard page size for the architecture.
        standard_page_size: core.Size,

        /// The largest page size supported by the architecture.
        largest_page_size: core.Size,

        /// The total size of the lower half.
        ///
        /// This includes the zero page.
        lower_half_size: core.Size,

        /// The virtual address of the start of the higher half.
        higher_half_start: core.VirtualAddress,

        PageTable: type,
    },

    io: struct {
        /// Handle to a port.
        ///
        /// Expected to be an enum.
        Port: type,
    },

    init: struct {
        CaptureSystemInformationOptions: type,
    },
};

const current_interface = switch (current_arch) {
    .arm => @import("arm/interface.zig"),
    .riscv => @import("riscv/interface.zig"),
    .x64 => @import("x64/interface.zig"),
};

// `Functions` and `Decls` must be seperate types to avoid dependency loops.
const current_functions: Functions = current_interface.functions;
const current_decls: Decls = current_interface.decls;

inline fn getFunction(comptime container: anytype, comptime name: []const u8) GetFunctionReturnType(container, name) {
    const T: type = @FieldType(@TypeOf(container), name);
    switch (@typeInfo(T)) {
        .@"fn" => return @field(container, name),
        .optional => {
            if (@field(container, name)) |func| return func;
            @panic(comptime "`" ++ @tagName(current_arch) ++ "` does not implement `" ++ name ++ "`");
        },
        // TODO: the error here is not perfect as it does not gives the full path to the function
        else => @compileError("field `" ++ name ++ "` has unsupported type " ++ @typeName(T)),
    }
}

fn GetFunctionReturnType(comptime container: anytype, comptime name: []const u8) type {
    const T: type = @FieldType(@TypeOf(container), name);
    switch (@typeInfo(T)) {
        .@"fn" => return T,
        .optional => |opt| return opt.child,
        // TODO: the error here is not perfect as it does not gives the full path to the function
        else => @compileError("field `" ++ name ++ "` has unsupported type " ++ @typeName(T)),
    }
}

const kernel = @import("kernel");

const core = @import("core");
const std = @import("std");
