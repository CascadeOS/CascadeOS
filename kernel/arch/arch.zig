// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Defines the interface of the architecture specific code.

// TODO: duplication of doc comments is annoying, but having them accessible to each arch as well to the rest of the
//       kernel is useful

const std = @import("std");

const arch = @import("arch");
const core = @import("core");
const cascade = @import("cascade");
const Task = cascade.Task;
const Thread = cascade.user.Thread;
const user_cascade = @import("user_cascade");

pub const current_arch = @import("cascade_architecture").arch;

/// Architecture specific per-executor data.
pub const PerExecutor = current_decls.PerExecutor;

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
    ///
    /// Asserts interrupts are disabled.
    pub fn sendPanicIPI() callconv(core.inline_in_non_debug) void {
        if (core.is_debug) std.debug.assert(!interrupts.areEnabled());
        getFunction(
            current_functions.interrupts,
            "sendPanicIPI",
        )();
    }

    /// Send a flush IPI to the given executor.
    pub fn sendFlushIPI(executor: *cascade.Executor) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.interrupts,
            "sendFlushIPI",
        )(executor);
    }

    pub const Interrupt = struct {
        arch_specific: current_decls.interrupts.Interrupt,

        pub const Handler = core.TypeErasedCall.Templated(&.{
            InterruptFrame,
            Task.Current.StateBeforeInterrupt,
        });

        pub const AllocateError = error{InterruptAllocationFailed};

        pub fn allocate(
            handler: Handler,
        ) callconv(core.inline_in_non_debug) AllocateError!Interrupt {
            return .{
                .arch_specific = try getFunction(
                    current_functions.interrupts,
                    "allocateInterrupt",
                )(handler),
            };
        }

        pub fn deallocate(interrupt: Interrupt) callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.interrupts,
                "deallocateInterrupt",
            )(interrupt.arch_specific);
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
        pub fn instructionPointer(self: InterruptFrame) cascade.VirtualAddress {
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
        pub fn initializeInterruptRouting() callconv(core.inline_in_non_debug) !void {
            return getFunction(
                current_functions.interrupts.init,
                "initializeInterruptRouting",
            )();
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
    pub const standard_page_size_alignment: std.mem.Alignment = standard_page_size.toAlignment();

    /// The largest page size supported by the architecture.
    pub const largest_page_size: core.Size = current_decls.paging.largest_page_size;
    pub const largest_page_size_alignment: std.mem.Alignment = largest_page_size.toAlignment();

    /// The range of the address space that is considered kernel memory.
    ///
    /// Usually the higher half of the address space.
    ///
    /// This must not include either the zero, undefined nor max addresses.
    pub const kernel_memory_range: cascade.VirtualRange = current_decls.paging.kernel_memory_range;

    comptime {
        std.debug.assert(!kernel_memory_range.containsAddress(.zero));
        std.debug.assert(!kernel_memory_range.containsAddress(.undefined_address));
        std.debug.assert(!kernel_memory_range.containsAddress(.max));
    }

    pub const PageTable = struct {
        physical_page: cascade.mem.PhysicalPage.Index,
        arch_specific: *current_decls.paging.PageTable,

        /// Create a page table in the given physical page.
        ///
        /// **REQUIREMENTS**:
        /// - The provided physical page must be accessible in the direct map.
        pub fn create(physical_page: cascade.mem.PhysicalPage.Index) callconv(core.inline_in_non_debug) PageTable {
            return .{
                .physical_page = physical_page,
                .arch_specific = getFunction(
                    current_functions.paging,
                    "createPageTable",
                )(physical_page),
            };
        }

        pub fn load(page_table: PageTable) callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.paging,
                "loadPageTable",
            )(page_table.physical_page);
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

        /// Maps `virtual_address` to `physical_page` with mapping type `map_type`.
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
            virtual_address: cascade.VirtualAddress,
            physical_page: cascade.mem.PhysicalPage.Index,
            map_type: cascade.mem.MapType,
            physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
        ) callconv(core.inline_in_non_debug) cascade.mem.MapError!void {
            return getFunction(
                current_functions.paging,
                "mapSinglePage",
            )(
                page_table.arch_specific,
                virtual_address,
                physical_page,
                map_type,
                physical_page_allocator,
            );
        }

        /// Unmaps the given virtual range.
        ///
        /// Caller must ensure:
        ///  - the virtual range address and size are aligned to the standard page size
        ///
        /// This function:
        ///  - does not flush the TLB
        pub fn unmap(
            page_table: PageTable,
            virtual_range: cascade.VirtualRange,
            backing_page_decision: core.CleanupDecision,
            top_level_decision: core.CleanupDecision,
            flush_batch: *cascade.mem.VirtualRangeBatch,
            deallocate_page_list: *cascade.mem.PhysicalPage.List,
        ) callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.paging,
                "unmap",
            )(
                page_table.arch_specific,
                virtual_range,
                backing_page_decision,
                top_level_decision,
                flush_batch,
                deallocate_page_list,
            );
        }

        /// Changes the protection of the given virtual range.
        ///
        /// Caller must ensure:
        ///  - the virtual range address and size are aligned to the standard page size
        ///
        /// This function:
        ///  - does not flush the TLB
        pub fn changeProtection(
            page_table: PageTable,
            virtual_range: cascade.VirtualRange,
            previous_map_type: cascade.mem.MapType,
            new_map_type: cascade.mem.MapType,
            flush_batch: *cascade.mem.VirtualRangeBatch,
        ) callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.paging,
                "changeProtection",
            )(page_table.arch_specific, virtual_range, previous_map_type, new_map_type, flush_batch);
        }
    };

    /// Flushes the cache for the given virtual range on the current executor.
    ///
    /// Caller must ensure:
    ///   - the `virtual_range` address and size must be aligned to the standard page size
    pub fn flushCache(virtual_range: cascade.VirtualRange) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.paging,
            "flushCache",
        )(virtual_range);
    }

    /// Enable the kernel to access user memory.
    ///
    /// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
    /// memory.
    pub fn enableAccessToUserMemory() callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.paging,
            "enableAccessToUserMemory",
        )();
    }

    /// Disable the kernel from accessing user memory.
    ///
    /// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
    /// memory.
    pub fn disableAccessToUserMemory() callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.paging,
            "disableAccessToUserMemory",
        )();
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
            range: cascade.VirtualRange,
            physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
        ) callconv(core.inline_in_non_debug) anyerror!void {
            return getFunction(
                current_functions.paging.init,
                "fillTopLevel",
            )(page_table.arch_specific, range, physical_page_allocator);
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
            virtual_range: cascade.VirtualRange,
            physical_range: cascade.PhysicalRange,
            map_type: cascade.mem.MapType,
            physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
        ) callconv(core.inline_in_non_debug) anyerror!void {
            return getFunction(
                current_functions.paging.init,
                "mapToPhysicalRangeAllPageSizes",
            )(page_table.arch_specific, virtual_range, physical_range, map_type, physical_page_allocator);
        }
    };
};

pub const scheduling = struct {
    /// Architecture specific per-task data.
    pub const PerTask = current_decls.scheduling.PerTask;

    /// Perform architecture specific task initialization.
    ///
    /// This function is called very early during init so cannot use any kernel subsystems.
    pub fn initializeTaskArchSpecific(task: *cascade.Task) callconv(core.inline_in_non_debug) void {
        current_functions.scheduling.initializeTaskArchSpecific(task);
    }

    /// Get the current task.
    ///
    /// Supports being called with interrupts and preemption enabled.
    pub fn getCurrentTask() callconv(core.inline_in_non_debug) *cascade.Task {
        return getFunction(
            current_functions.scheduling,
            "getCurrentTask",
        )();
    }

    /// Set the current task.
    ///
    /// Supports being called with interrupts and preemption enabled.
    pub fn setCurrentTask(task: *cascade.Task) callconv(core.inline_in_non_debug) void {
        return getFunction(
            current_functions.scheduling,
            "setCurrentTask",
        )(task);
    }

    /// Prepares the given task for being scheduled.
    ///
    /// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `type_erased_call`.
    ///
    /// This function *must* be called before the task is scheduled and can only be called once.
    pub fn prepareTaskForScheduling(
        task: *Task,
        type_erased_call: core.TypeErasedCall,
    ) callconv(core.inline_in_non_debug) void {
        return getFunction(
            current_functions.scheduling,
            "prepareTaskForScheduling",
        )(task, type_erased_call);
    }

    /// Called before `transition.old_task` is switched to `transition.new_task`.
    ///
    /// Page table switching and managing ability to access user memory has already been performed before this function is called.
    ///
    /// Interrupts are disabled when this function is called.
    pub fn beforeSwitchTask(transition: Task.Transition) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.scheduling,
            "beforeSwitchTask",
        )(transition);
    }

    /// Switches to `new_task`.
    ///
    /// The state of `old_task` is saved to allow it to be resumed later.
    ///
    /// **Note**: It is the caller's responsibility to call `beforeSwitchTask` before calling this function.
    pub fn switchTask(
        old_task: *Task,
        new_task: *Task,
    ) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.scheduling,
            "switchTask",
        )(old_task, new_task);
    }

    /// Switches to `new_task`.
    ///
    /// **Note**: It is the caller's responsibility to call `beforeSwitchTask` before calling this function.
    pub fn switchTaskNoSave(
        new_task: *Task,
    ) callconv(core.inline_in_non_debug) noreturn {
        getFunction(
            current_functions.scheduling,
            "switchTaskNoSave",
        )(new_task);
    }

    /// Calls `type_erased_call` on `new_stack` and saves the state of `old_task`.
    ///
    /// Asserts that the provided `type_erased_call` is noreturn.
    pub fn call(
        old_task: *Task,
        new_stack: *Task.Stack,
        type_erased_call: core.TypeErasedCall,
    ) callconv(core.inline_in_non_debug) void {
        if (core.is_debug) std.debug.assert(type_erased_call.return_type.isNoReturn());

        getFunction(current_functions.scheduling, "call")(
            old_task,
            new_stack,
            type_erased_call,
        );
    }

    /// Calls `type_erased_call` on `new_stack`.
    ///
    /// Asserts that the provided `type_erased_call` is noreturn.
    pub fn callNoSave(
        new_stack: *Task.Stack,
        type_erased_call: core.TypeErasedCall,
    ) callconv(core.inline_in_non_debug) noreturn {
        if (core.is_debug) std.debug.assert(type_erased_call.return_type.isNoReturn());

        getFunction(current_functions.scheduling, "callNoSave")(
            new_stack,
            type_erased_call,
        );
    }

    /// A string to be used in inline assembly to prevent unwinding.
    ///
    /// Add `asm volatile (arch.scheduling.cfi_prevent_unwinding);` to the beginning of a function to prevent unwinding past it.
    pub const cfi_prevent_unwinding = current_decls.scheduling.cfi_prevent_unwinding;
};

pub const user = struct {
    /// Architecture specific per-thread data.
    pub const PerThread = current_decls.user.PerThread;

    /// The range of the address space that is considered user memory.
    ///
    /// Usually the lower half of the address space.
    ///
    /// This must not include either the zero, undefined nor max addresses.
    pub const user_memory_range: cascade.VirtualRange = current_decls.user.user_memory_range;

    comptime {
        std.debug.assert(!user_memory_range.containsAddress(.zero));
        std.debug.assert(!user_memory_range.containsAddress(.undefined_address));
        std.debug.assert(!user_memory_range.containsAddress(.max));
    }

    /// Create the `PerThread` data of a thread.
    ///
    /// Non-architecture specific creation has already been performed but no initialization.
    ///
    /// This function is called in the `Thread` cache constructor.
    pub fn createThread(
        thread: *Thread,
    ) callconv(core.inline_in_non_debug) cascade.mem.cache.ConstructorError!void {
        return getFunction(
            current_functions.user,
            "createThread",
        )(thread);
    }

    /// Destroy the `PerThread` data of a thread.
    ///
    /// Non-architecture specific destruction has not already been performed.
    ///
    /// This function is called in the `Thread` cache destructor.
    pub fn destroyThread(thread: *Thread) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.user,
            "destroyThread",
        )(thread);
    }

    /// Initialize the `PerThread` data of a thread.
    ///
    /// All non-architecture specific initialization has already been performed.
    ///
    /// This function is called in `Thread.internal.create`.
    pub fn initializeThread(thread: *Thread) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.user,
            "initializeThread",
        )(thread);
    }

    pub const SyscallFrame = struct {
        arch_specific: *current_decls.user.SyscallFrame,

        /// Get the syscall this frame represents.
        pub fn syscall(syscall_frame: SyscallFrame) callconv(core.inline_in_non_debug) ?user_cascade.Syscall {
            return getFunction(
                current_functions.user,
                "syscallFromSyscallFrame",
            )(syscall_frame.arch_specific);
        }

        pub const Arg = enum {
            one,
            two,
            three,
            four,
            five,
            six,
            seven,
            eight,
            nine,
            ten,
            eleven,
            twelve,
        };

        pub fn arg(syscall_frame: SyscallFrame, comptime argument: Arg) callconv(core.inline_in_non_debug) usize {
            return getFunction(
                current_functions.user,
                "argFromSyscallFrame",
            )(syscall_frame.arch_specific, argument);
        }

        pub inline fn format(
            syscall_frame: SyscallFrame,
            writer: *std.Io.Writer,
        ) !void {
            return syscall_frame.arch_specific.format(writer);
        }
    };

    pub const EnterUserspaceOptions = struct {
        entry_point: cascade.UserVirtualAddress,
        stack_pointer: cascade.UserVirtualAddress,
    };

    /// Enter userspace for the first time in the current task.
    ///
    /// Asserts that the current task is a user task.
    pub fn enterUserspace(options: EnterUserspaceOptions) callconv(core.inline_in_non_debug) noreturn {
        if (core.is_debug) std.debug.assert(Task.Current.get().task.type == .user);

        getFunction(
            current_functions.user,
            "enterUserspace",
        )(options);
    }

    pub const init = struct {
        /// Perform any per-achitecture initialization needed for userspace processes/threads.
        pub fn initialize() anyerror!void {
            return getFunction(
                current_functions.user.init,
                "initialize",
            )();
        }
    };
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
    pub fn getStandardWallclockStartTime() cascade.time.wallclock.Tick {
        return getFunction(
            current_functions.init,
            "getStandardWallclockStartTime",
        )();
    }

    pub const InitOutput = struct {
        output: Output,
        preference: Preference,

        pub const Output = cascade.init.Output;

        pub const Preference = enum {
            /// Use this output.
            use,

            /// Only use this output if a generic output is not available.
            prefer_generic,
        };
    };

    /// Attempt to get some form of architecture specific init output if it is available.
    ///
    /// If `memory_system_available` is false, then the memory system has not been initialized so heap allocation and the special heap are
    /// not available.
    ///
    /// The first time this function is called `memory_system_available` will be false, this function will be called again after the memory
    /// system is initialized with `memory_system_available` set to true, but only if a generic serial output was not available without
    /// needing the memory system.
    pub fn tryGetSerialOutput(memory_system_available: bool) callconv(core.inline_in_non_debug) ?InitOutput {
        return getFunction(
            current_functions.init,
            "tryGetSerialOutput",
        )(memory_system_available);
    }

    /// Prepares the executor as the bootstrap executor.
    pub fn prepareBootstrapExecutor(
        executor: *cascade.Executor,
        architecture_processor_id: u64,
    ) callconv(core.inline_in_non_debug) void {
        current_functions.init.prepareBootstrapExecutor(executor, architecture_processor_id);
    }

    /// Prepares the provided `Executor` for use.
    ///
    /// **WARNING**: This function will panic if the cpu cannot be prepared.
    pub fn prepareExecutor(
        executor: *cascade.Executor,
        architecture_processor_id: u64,
    ) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.init,
            "prepareExecutor",
        )(executor, architecture_processor_id);
    }

    /// Initialize the executor.
    ///
    /// ** REQUIREMENTS **:
    /// - Must be called by the executor represented by `executor`
    pub fn initExecutor(executor: *cascade.Executor) callconv(core.inline_in_non_debug) void {
        current_functions.init.initExecutor(executor);
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
    /// This function is called in a few different contexts and must leave the system in a reasonable state for each of them:
    ///  - By the bootstrap executor after calling `captureEarlySystemInformation`
    ///  - By the bootstrap executor after calling `captureSystemInformation`
    ///  - By every executor after `captureSystemInformation` has been called
    pub fn configurePerExecutorSystemFeatures() callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.init,
            "configurePerExecutorSystemFeatures",
        )();
    }

    /// Register any architectural time sources.
    ///
    /// For example, on x86_64 this should register the TSC, HPEC, PIT, etc.
    pub fn registerArchitecturalTimeSources(
        candidate_time_sources: *cascade.time.init.CandidateTimeSources,
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
        sendFlushIPI: ?fn (executor: *cascade.Executor) void = null,

        allocateInterrupt: ?fn (
            handler: interrupts.Interrupt.Handler,
        ) interrupts.Interrupt.AllocateError!current_decls.interrupts.Interrupt = null,

        deallocateInterrupt: ?fn (interrupt: current_decls.interrupts.Interrupt) void = null,

        routeInterrupt: ?fn (
            interrupt: current_decls.interrupts.Interrupt,
            external_interrupt: u32,
        ) interrupts.Interrupt.RouteError!void = null,

        /// Creates a stack iterator for the context this interrupt was triggered from.
        createStackIterator: ?fn (
            interrupt_frame: *const current_decls.interrupts.InterruptFrame,
        ) std.debug.StackIterator = null,

        /// Returns the instruction pointer of the context this interrupt was triggered from.
        instructionPointer: ?fn (interrupt_frame: *const current_decls.interrupts.InterruptFrame) cascade.VirtualAddress = null,

        init: struct {
            /// Ensure that any exceptions/faults that occur during early initialization are handled.
            ///
            /// The handler is not expected to do anything other than panic.
            initializeEarlyInterrupts: ?fn () void = null,

            /// Prepare interrupt allocation and routing.
            initializeInterruptRouting: ?fn () void = null,

            /// Switch away from the initial interrupt handlers installed by `initInterrupts` to the standard
            /// system interrupt handlers.
            loadStandardInterruptHandlers: ?fn () void = null,
        },
    },

    paging: struct {
        /// Create a page table in the given physical page.
        ///
        /// **REQUIREMENTS**:
        /// - The provided physical page must be accessible in the direct map.
        createPageTable: ?fn (physical_page: cascade.mem.PhysicalPage.Index) *current_decls.paging.PageTable = null,

        loadPageTable: ?fn (physical_page: cascade.mem.PhysicalPage.Index) void = null,

        /// Copies the top level of `page_table` into `target_page_table`.
        copyTopLevelIntoPageTable: ?fn (
            page_table: *current_decls.paging.PageTable,
            target_page_table: *current_decls.paging.PageTable,
        ) void = null,

        /// Maps `virtual_address` to `physical_page` with mapping type `map_type`.
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
            virtual_address: cascade.VirtualAddress,
            physical_page: cascade.mem.PhysicalPage.Index,
            map_type: cascade.mem.MapType,
            physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
        ) cascade.mem.MapError!void = null,

        /// Unmaps the given virtual range.
        ///
        /// Caller must ensure:
        ///  - the virtual range address and size are aligned to the standard page size
        ///
        /// This function:
        ///  - does not flush the TLB
        unmap: ?fn (
            page_table: *current_decls.paging.PageTable,
            virtual_range: cascade.VirtualRange,
            backing_page_decision: core.CleanupDecision,
            top_level_decision: core.CleanupDecision,
            flush_batch: *cascade.mem.VirtualRangeBatch,
            deallocate_page_list: *cascade.mem.PhysicalPage.List,
        ) void = null,

        /// Changes the protection of the given virtual range.
        ///
        /// Caller must ensure:
        ///  - the virtual range address and size are aligned to the standard page size
        ///
        /// This function:
        ///  - does not flush the TLB
        changeProtection: ?fn (
            page_table: *current_decls.paging.PageTable,
            virtual_range: cascade.VirtualRange,
            previous_map_type: cascade.mem.MapType,
            new_map_type: cascade.mem.MapType,
            flush_batch: *cascade.mem.VirtualRangeBatch,
        ) void = null,

        /// Flushes the cache for the given virtual range on the current executor.
        ///
        /// Caller must ensure:
        ///   - the `virtual_range` address and size must be aligned to the standard page size
        flushCache: ?fn (virtual_range: cascade.VirtualRange) void = null,

        /// Enable the kernel to access user memory.
        ///
        /// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
        /// memory.
        enableAccessToUserMemory: ?fn () void = null,

        /// Disable the kernel from accessing user memory.
        ///
        /// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
        /// memory.
        disableAccessToUserMemory: ?fn () void = null,

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
                range: cascade.VirtualRange,
                physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
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
                virtual_range: cascade.VirtualRange,
                physical_range: cascade.PhysicalRange,
                map_type: cascade.mem.MapType,
                physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
            ) anyerror!void = null,
        },
    },

    user: struct {
        /// Create the `PerThread` data of a thread.
        ///
        /// Non-architecture specific creation has already been performed but no initialization.
        ///
        /// This function is called in the `Thread` cache constructor.
        createThread: ?fn (
            thread: *Thread,
        ) cascade.mem.cache.ConstructorError!void = null,

        /// Destroy the `PerThread` data of a thread.
        ///
        /// Non-architecture specific destruction has not already been performed.
        ///
        /// This function is called in the `Thread` cache destructor.
        destroyThread: ?fn (thread: *Thread) void = null,

        /// Initialize the `PerThread` data of a thread.
        ///
        /// All non-architecture specific initialization has already been performed.
        ///
        /// This function is called in `Thread.internal.create`.
        initializeThread: ?fn (thread: *Thread) void = null,

        /// Enter userspace for the first time in the current task.
        enterUserspace: ?fn (options: user.EnterUserspaceOptions) noreturn = null,

        /// Get the syscall this frame represents.
        syscallFromSyscallFrame: ?fn (
            syscall_frame: *const current_decls.user.SyscallFrame,
        ) callconv(.@"inline") ?user_cascade.Syscall = null,

        /// Get an argument from this frame.
        argFromSyscallFrame: ?fn (
            syscall_frame: *const current_decls.user.SyscallFrame,
            comptime argument: user.SyscallFrame.Arg,
        ) callconv(.@"inline") usize = null,

        init: struct {
            /// Perform any per-achitecture initialization needed for userspace processes/threads.
            initialize: ?fn () anyerror!void = null,
        },
    },

    scheduling: struct {
        /// Perform architecture specific task initialization.
        ///
        /// This function is called very early during init so cannot use any kernel subsystems.
        initializeTaskArchSpecific: fn (task: *cascade.Task) void,

        /// Get the current `Task`.
        ///
        /// Supports being called with interrupts and preemption enabled.
        getCurrentTask: ?fn () callconv(.@"inline") *cascade.Task = null,

        /// Set the current task.
        ///
        /// Supports being called with interrupts and preemption enabled.
        setCurrentTask: ?fn (task: *cascade.Task) callconv(.@"inline") void = null,

        /// Prepares the given task for being scheduled.
        ///
        /// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `type_erased_call`.
        ///
        /// This function *must* be called before the task is scheduled and can only be called once.
        prepareTaskForScheduling: ?fn (
            task: *Task,
            type_erased_call: core.TypeErasedCall,
        ) void = null,

        /// Called before `transition.old_task` is switched to `transition.new_task`.
        ///
        /// Page table switching and managing ability to access user memory has already been performed before this function is called.
        ///
        /// Interrupts are disabled when this function is called.
        beforeSwitchTask: ?fn (transition: Task.Transition) void = null,

        /// Switches to `new_task`.
        ///
        /// The state of `old_task` is saved to allow it to be resumed later.
        ///
        /// **Note**: It is the caller's responsibility to call `beforeSwitchTask` before calling this function.
        switchTask: ?fn (old_task: *Task, new_task: *Task) callconv(.@"inline") void = null,

        /// Switches to `new_task`.
        ///
        /// **Note**: It is the caller's responsibility to call `beforeSwitchTask` before calling this function.
        switchTaskNoSave: ?fn (new_task: *Task) callconv(.@"inline") noreturn = null,

        /// Calls `type_erased_call` on `new_stack` and saves the state of `old_task`.
        call: ?fn (
            old_task: *Task,
            new_stack: *Task.Stack,
            type_erased_call: core.TypeErasedCall,
        ) callconv(.@"inline") void = null,

        /// Calls `type_erased_call` on `new_stack`.
        callNoSave: ?fn (
            new_stack: *Task.Stack,
            type_erased_call: core.TypeErasedCall,
        ) callconv(.@"inline") noreturn = null,
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
        getStandardWallclockStartTime: fn () cascade.time.wallclock.Tick,

        /// Attempt to get some form of architecture specific init output if it is available.
        ///
        /// If `memory_system_available` is false, then the memory system has not been initialized so heap allocation and the special heap are
        /// not available.
        ///
        /// The first time this function is called `memory_system_available` will be false, this function will be called again after the memory
        /// system is initialized with `memory_system_available` set to true, but only if a generic serial output was not available without
        /// needing the memory system.
        tryGetSerialOutput: fn (memory_system_available: bool) ?init.InitOutput,

        /// Prepares the executor as the bootstrap executor.
        prepareBootstrapExecutor: fn (executor: *cascade.Executor, u64) void,

        /// Prepares the provided `Executor` for use.
        ///
        /// **WARNING**: This function will panic if the cpu cannot be prepared.
        prepareExecutor: ?fn (
            executor: *cascade.Executor,
            architecture_processor_id: u64,
        ) void = null,

        initExecutor: fn (executor: *cascade.Executor) void, // non-null as the bootstrap executor needs to call this early

        /// Capture any system information that can be without using mmio.
        ///
        /// For example, on x64 this should capture CPUID but not APIC or ACPI information.
        captureEarlySystemInformation: ?fn () void = null,

        /// Capture any system information that needs mmio.
        ///
        /// For example, on x64 this should capture APIC and ACPI information.
        captureSystemInformation: ?fn (
            options: current_decls.init.CaptureSystemInformationOptions,
        ) anyerror!void = null,

        /// Configure any global system features.
        configureGlobalSystemFeatures: ?fn () void = null,

        /// Configure any per-executor system features.
        configurePerExecutorSystemFeatures: ?fn () void = null,

        /// Register any architectural time sources.
        ///
        /// For example, on x86_64 this should register the TSC, HPEC, PIT, etc.
        registerArchitecturalTimeSources: ?fn (candidate_time_sources: *cascade.time.init.CandidateTimeSources) void = null,

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

        /// The range of the address space that is considered kernel memory.
        ///
        /// Usually the higher half of the address space.
        ///
        /// This must not include either the zero, undefined nor max addresses.
        kernel_memory_range: cascade.VirtualRange,

        PageTable: type,
    },

    scheduling: struct {
        /// Architecture specific per-task data.
        PerTask: type,

        /// A string to be used in inline assembly to prevent unwinding.
        ///
        /// E.g. `asm volatile (arch.scheduling.cfi_prevent_unwinding);`
        cfi_prevent_unwinding: []const u8,
    },

    user: struct {
        /// Architecture specific per-thread data.
        PerThread: type,

        SyscallFrame: type,

        /// The range of the address space that is considered user memory.
        ///
        /// Usually the lower half of the address space.
        ///
        /// This must not include either the zero, undefined nor max addresses.
        user_memory_range: cascade.VirtualRange,
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
