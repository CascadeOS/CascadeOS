// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

//! Defines the interface of the architecture specific code.

const std = @import("std");

const cascade = @import("cascade");
const core = @import("core");
const user_cascade = @import("user_cascade");

pub const current_arch = @import("cascade_architecture").arch;
pub const Arch = @TypeOf(current_arch);

/// The range of the address space that is considered kernel memory.
///
/// Usually the higher half of the address space.
///
/// Arch is recommend to exclude the last valid page of the range to prevent boundary conditions.
pub const kernel_memory_range: cascade.VirtualRange = current_decls.kernel_memory_range;

/// The range of the address space that is considered user memory.
///
/// Usually the lower half of the address space.
///
/// Arch is recommend to exclude the last valid page of the range to prevent boundary conditions.
/// This is required for correctness on x64 atleast; due to syscall causing sysret with non-canonical return address.
pub const user_memory_range: cascade.VirtualRange = current_decls.user_memory_range;

/// A string to be used in inline assembly to prevent unwinding.
///
/// Add `asm volatile (arch.cfi_prevent_unwinding);` to the beginning of a function to prevent unwinding past it.
pub const cfi_prevent_unwinding = current_decls.cfi_prevent_unwinding;

/// Copies memory from `source` to `destination`.
///
/// Sets `target` to the address any unhandleable page fault should return to after setting the result in the slot.
pub fn safeMemcpy(
    destination: cascade.VirtualRange,
    source: cascade.VirtualRange,
    target: *cascade.KernelVirtualAddress,
) callconv(core.inline_in_non_debug) void {
    getFunction(
        current_functions,
        "safeMemcpy",
    )(destination, source, target);
}

pub const Executor = struct {
    arch_specific: current_decls.Executor,

    pub const Id = current_decls.ExecutorId;

    /// Notify the given executor of a flush request.
    pub fn flushRequestNotify(executor: *const Executor) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.executor,
            "flushRequestNotify",
        )(@alignCast(@fieldParentPtr("arch_specific", executor)));
    }

    /// Send a panic to all other executors.
    ///
    /// ***Caller Requirements***:
    ///   - Interrupts are disabled.
    pub fn sendPanicAllButSelf() callconv(core.inline_in_non_debug) void {
        if (core.is_debug) std.debug.assert(!current.interruptsEnabled());

        getFunction(
            current_functions.executor,
            "sendPanicAllButSelf",
        )();
    }

    pub const current = struct {
        /// Issue an architecture specific hint to the current executor that we are spinning in a loop.
        pub fn spinLoopHint() callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.executor.current,
                "spinLoopHint",
            )();
        }

        /// Halt the current executor.
        pub fn halt() callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.executor.current,
                "halt",
            )();
        }

        /// Disable interrupts on the current executor and halt.
        pub inline fn disableInterruptsAndHalt() noreturn {
            // marked `inline` unconditionally so that it can be called from a naked function.
            getFunction(
                current_functions.executor.current,
                "disableInterruptsAndHalt",
            )();
            comptime unreachable;
        }

        /// Are interrupts enabled on the current executor.
        pub fn interruptsEnabled() callconv(core.inline_in_non_debug) bool {
            return getFunction(
                current_functions.executor.current,
                "interruptsEnabled",
            )();
        }

        /// Enable interrupts on the current executor.
        pub fn enableInterrupts() callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.executor.current,
                "enableInterrupts",
            )();
        }

        /// Disable interrupts on the current executor.
        pub fn disableInterrupts() callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.executor.current,
                "disableInterrupts",
            )();
        }

        /// Flushes the cache for the given virtual range on the current executor.
        ///
        /// ***Caller Requirements***:
        ///  - `virtual_range` must be page aligned
        pub fn flushCache(virtual_range: cascade.VirtualRange) callconv(core.inline_in_non_debug) void {
            if (core.is_debug) std.debug.assert(virtual_range.pageAligned());

            getFunction(
                current_functions.executor.current,
                "flushCache",
            )(virtual_range);
        }

        /// Enable the kernel on the current executor to access user memory.
        ///
        /// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
        /// memory.
        pub fn enableAccessToUserMemory() callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.executor.current,
                "enableAccessToUserMemory",
            )();
        }

        /// Disable the kernel on the current executor from accessing user memory.
        ///
        /// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
        /// memory.
        pub fn disableAccessToUserMemory() callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.executor.current,
                "disableAccessToUserMemory",
            )();
        }
    };

    pub const init = struct {
        /// Prepares this executor as the bootstrap executor.
        pub fn prepareBootstrap(
            executor: *cascade.Executor,
            id: Id,
        ) callconv(core.inline_in_non_debug) void {
            current_functions.executor.init.prepareBootstrap(executor, id);
        }

        /// Prepares the provided `Executor` for use.
        pub fn prepare(
            executor: *cascade.Executor,
            id: Id,
        ) callconv(core.inline_in_non_debug) void {
            getFunction(current_functions.executor.init, "prepare")(executor, id);
        }

        /// Initialize the current executor.
        pub fn initialize(executor: *cascade.Executor) callconv(core.inline_in_non_debug) void {
            current_functions.executor.init.initialize(executor);
        }

        /// Configure any per-executor system features on the current executor.
        ///
        /// This function is called in a few different contexts and must leave the system in a reasonable state for each of them:
        ///  - By the bootstrap executor after calling `init.captureSystemInformation(.early)`
        ///  - By the bootstrap executor after calling `init.captureSystemInformation(.full)`
        ///  - By every executor after `init.captureSystemInformation(.full)` has been called
        pub fn configurePerExecutorSystemFeatures() callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.executor.init,
                "configurePerExecutorSystemFeatures",
            )();
        }

        /// Initialize the local interrupt controller for the current executor.
        ///
        /// For example, on x86_64 this should initialize the APIC.
        pub fn initLocalInterruptController() callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.executor.init,
                "initLocalInterruptController",
            )();
        }
    };
};

pub const Interrupt = struct {
    arch_specific: current_decls.Interrupt,

    pub const FromError = error{InvalidInterrupt};

    pub fn from(value: usize) callconv(core.inline_in_non_debug) FromError!Interrupt {
        return .{
            .arch_specific = try getFunction(
                current_functions.interrupt,
                "from",
            )(value),
        };
    }

    pub fn to(interrupt: Interrupt) callconv(core.inline_in_non_debug) usize {
        return getFunction(
            current_functions.interrupt,
            "to",
        )(interrupt.arch_specific);
    }

    pub const AllocateError = error{InterruptAllocationFailed};

    pub fn allocate(
        handler: Handler,
    ) callconv(core.inline_in_non_debug) AllocateError!Interrupt {
        return .{
            .arch_specific = try getFunction(
                current_functions.interrupt,
                "allocate",
            )(handler),
        };
    }

    pub fn deallocate(interrupt: Interrupt) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.interrupt,
            "deallocate",
        )(interrupt.arch_specific);
    }

    pub const External = struct {
        arch_specific: current_decls.ExternalInterrupt,

        pub const ExternalFromError = error{InvalidExternalInterrupt};

        pub fn from(value: usize) callconv(core.inline_in_non_debug) ExternalFromError!External {
            return .{
                .arch_specific = try getFunction(
                    current_functions.interrupt.external,
                    "from",
                )(value),
            };
        }

        /// Get the EOI type for the given external interrupt if known.
        pub fn eoiType(external_interrupt: External) callconv(core.inline_in_non_debug) ?Handler.EOI {
            return getFunction(
                current_functions.interrupt.external,
                "eoiType",
            )(external_interrupt.arch_specific);
        }

        pub const RouteError = error{UnableToRouteExternalInterrupt};

        /// Route this external interrupt to the given interrupt.
        ///
        /// Routing the same external interrupt multiple times is undefined behavior.
        pub fn route(external_interrupt: External, interrupt: Interrupt) callconv(core.inline_in_non_debug) RouteError!void {
            return getFunction(
                current_functions.interrupt.external,
                "route",
            )(external_interrupt.arch_specific, interrupt.arch_specific);
        }
    };

    pub const Frame = struct {
        arch_specific: *current_decls.InterruptFrame,

        /// Provides the context this interrupt was triggered from.
        pub fn fillContext(frame: Frame, context: *std.debug.cpu_context.Native) void {
            return getFunction(
                current_functions.interrupt.frame,
                "fillContext",
            )(frame.arch_specific, context);
        }

        /// Returns the instruction pointer of the context this interrupt was triggered from.
        pub fn instructionPointer(frame: Frame) cascade.VirtualAddress {
            // TODO: this is used during panics, so if it is not implemented we will panic during a panic
            //       once arm and riscv are further along make this non-optional
            return getFunction(
                current_functions.interrupt.frame,
                "instructionPointer",
            )(frame.arch_specific);
        }

        /// Sets the instruction pointer that should be used when returning from the interrupt.
        pub fn setInstructionPointer(frame: Frame, instruction_pointer: cascade.VirtualAddress) void {
            return getFunction(
                current_functions.interrupt.frame,
                "setInstructionPointer",
            )(frame.arch_specific, instruction_pointer);
        }

        pub inline fn format(
            frame: Frame,
            writer: *std.Io.Writer,
        ) !void {
            return frame.arch_specific.format(writer);
        }
    };

    pub const Handler = struct {
        eoi: EOI,
        call: Call,

        pub const EOI = enum {
            none,
            before,
            after,

            pub const edge: EOI = .before;
            pub const level: EOI = .after;
        };

        pub const Call = core.TypeErasedCall.Templated(&.{
            Frame,
            cascade.Task.Current.StateBeforeInterrupt,
        });
    };

    pub const init = struct {
        /// Ensure that any exceptions/faults that occur during early initialization are handled.
        ///
        /// The handler is not expected to do anything other than panic.
        pub fn initializeEarlyInterrupts() callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.interrupt.init,
                "initializeEarlyInterrupts",
            )();
        }

        /// Prepare interrupt allocation and routing.
        pub fn initializeInterruptRouting() callconv(core.inline_in_non_debug) !void {
            return getFunction(
                current_functions.interrupt.init,
                "initializeInterruptRouting",
            )();
        }

        /// Switch away from the initial interrupt handlers installed by `initializeEarlyInterrupts` to the standard
        /// system interrupt handlers.
        pub fn loadStandardInterruptHandlers() callconv(core.inline_in_non_debug) void {
            getFunction(
                current_functions.interrupt.init,
                "loadStandardInterruptHandlers",
            )();
        }
    };
};

pub const PageTable = struct {
    physical_page: cascade.mem.PhysicalPage.Index,
    arch_specific: *current_decls.PageTable,

    /// The standard page size for the architecture.
    pub const standard_page_size: core.Size = current_decls.standard_page_size;
    pub const standard_page_size_alignment: std.mem.Alignment = standard_page_size.toAlignment();

    /// The largest page size supported by the architecture.
    pub const largest_page_size: core.Size = current_decls.largest_page_size;
    pub const largest_page_size_alignment: std.mem.Alignment = largest_page_size.toAlignment();

    /// Create a page table in the given physical page.
    ///
    /// ***Caller Requirements***:
    ///  - `physical_page` must be accessible in the direct map.
    pub fn create(physical_page: cascade.mem.PhysicalPage.Index) callconv(core.inline_in_non_debug) PageTable {
        return .{
            .physical_page = physical_page,
            .arch_specific = getFunction(
                current_functions.page_table,
                "create",
            )(physical_page),
        };
    }

    pub fn load(page_table: PageTable) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.page_table,
            "load",
        )(page_table.physical_page);
    }

    /// Copies the top level of `source_page_table` into `destination_page_table`.
    pub fn copyTopLevel(
        source_page_table: PageTable,
        destination_page_table: PageTable,
    ) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.page_table,
            "copyTopLevel",
        )(source_page_table.arch_specific, destination_page_table.arch_specific);
    }

    /// Maps `virtual_address` to `physical_page` with mapping type `map_type`.
    ///
    /// ***Caller Requirements***:
    ///  - `virtual_address` is page aligned.
    ///  - `map_type.protection` is not `.none`.
    ///
    /// ***Limitations***:
    ///  - Only supports the standard page size for the architecture.
    ///  - Does not flush the TLB.
    pub fn mapSinglePage(
        page_table: PageTable,
        virtual_address: cascade.VirtualAddress,
        physical_page: cascade.mem.PhysicalPage.Index,
        map_type: cascade.mem.MapType,
        physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
    ) callconv(core.inline_in_non_debug) cascade.mem.MapError!void {
        if (core.is_debug) {
            std.debug.assert(virtual_address.pageAligned());
            std.debug.assert(!map_type.protection.equal(.none));
        }

        return getFunction(
            current_functions.page_table,
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
    /// ***Caller Requirements***:
    ///  - `virtual_range` must be page aligned.
    ///
    /// ***Limitations***:
    ///  - Does not flush the TLB.
    pub fn unmap(
        page_table: PageTable,
        virtual_range: cascade.VirtualRange,
        backing_page_decision: core.CleanupDecision,
        top_level_decision: core.CleanupDecision,
        flush_batch: *cascade.mem.VirtualRangeBatch,
        deallocate_page_list: *cascade.mem.PhysicalPage.List,
    ) callconv(core.inline_in_non_debug) void {
        if (core.is_debug) std.debug.assert(virtual_range.pageAligned());

        getFunction(
            current_functions.page_table,
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
    /// ***Caller Requirements***:
    ///  - `virtual_range` must be page aligned.
    ///  - `new_map_type` protection is not `.none`
    ///
    /// ***Limitations***:
    ///  - Does not flush the TLB.
    pub fn changeProtection(
        page_table: PageTable,
        virtual_range: cascade.VirtualRange,
        previous_map_type: cascade.mem.MapType,
        new_map_type: cascade.mem.MapType,
        flush_batch: *cascade.mem.VirtualRangeBatch,
    ) callconv(core.inline_in_non_debug) void {
        if (core.is_debug) {
            std.debug.assert(virtual_range.pageAligned());
            std.debug.assert(!new_map_type.protection.equal(.none));
        }

        getFunction(
            current_functions.page_table,
            "changeProtection",
        )(page_table.arch_specific, virtual_range, previous_map_type, new_map_type, flush_batch);
    }

    pub const init = struct {
        /// The total size of the virtual address space that one entry in the top level of a page table covers.
        pub fn sizeOfTopLevelEntry() callconv(core.inline_in_non_debug) core.Size {
            return getFunction(
                current_functions.page_table.init,
                "sizeOfTopLevelEntry",
            )();
        }

        /// This function fills in the top level of the page table for the given range.
        ///
        /// ***Caller Requirements***:
        ///  - `range` must have both size and alignment of `sizeOfTopLevelEntry()`.
        ///
        /// ***Limitations***:
        ///  - Does not flush the TLB.
        ///  - Does not rollback on error.
        pub fn fillTopLevel(
            page_table: PageTable,
            range: cascade.VirtualRange,
            physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
        ) callconv(core.inline_in_non_debug) cascade.mem.MapError!void {
            if (core.is_debug) {
                const size = sizeOfTopLevelEntry();
                std.debug.assert(range.size.equal(size));
                std.debug.assert(range.address.aligned(.fromByteUnits(size.value)));
            }

            return getFunction(
                current_functions.page_table.init,
                "fillTopLevel",
            )(page_table.arch_specific, range, physical_page_allocator);
        }

        /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
        ///
        /// Arch should make use of all page sizes available to the architecture.
        ///
        /// ***Caller Requirements***:
        ///  - `virtual_range` must be page aligned.
        ///  - `physical_range` must be page aligned.
        ///  - `virtual_range` size must equal `physical_range` size.
        ///  - `map_type.protection` is not `.none`.
        ///
        /// ***Limitations***:
        ///  - Does not flush the TLB.
        ///  - Does not rollback on error.
        pub fn mapToPhysicalRangeAllPageSizes(
            page_table: PageTable,
            virtual_range: cascade.VirtualRange,
            physical_range: cascade.PhysicalRange,
            map_type: cascade.mem.MapType,
            physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
        ) callconv(core.inline_in_non_debug) cascade.mem.MapError!void {
            if (core.is_debug) {
                std.debug.assert(virtual_range.pageAligned());
                std.debug.assert(physical_range.pageAligned());
                std.debug.assert(virtual_range.size.equal(physical_range.size));
                std.debug.assert(!map_type.protection.equal(.none));
            }

            return getFunction(
                current_functions.page_table.init,
                "mapToPhysicalRangeAllPageSizes",
            )(page_table.arch_specific, virtual_range, physical_range, map_type, physical_page_allocator);
        }
    };
};

pub const Thread = struct {
    arch_specific: current_decls.Thread,

    /// Create the arch specific data of a thread.
    ///
    /// Non-architecture specific creation has already been performed but no initialization.
    ///
    /// This function is called in the `cascade.user.Thread` cache constructor.
    pub fn create(
        thread: *Thread,
    ) callconv(core.inline_in_non_debug) cascade.mem.cache.ConstructorError!void {
        return getFunction(
            current_functions.thread,
            "create",
        )(@alignCast(@fieldParentPtr("arch_specific", thread)));
    }

    /// Destroy the arch specific data of a thread.
    ///
    /// Non-architecture specific destruction has not already been performed.
    ///
    /// This function is called in the `cascade.user.Thread` cache destructor.
    pub fn destroy(thread: *Thread) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.thread,
            "destroy",
        )(@alignCast(@fieldParentPtr("arch_specific", thread)));
    }

    /// Initialize the arch specific data of a thread.
    ///
    /// All non-architecture specific initialization has already been performed.
    ///
    /// This function is called in `cascade.user.Thread.internal.create`.
    pub fn initialize(thread: *Thread) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.thread,
            "initialize",
        )(@alignCast(@fieldParentPtr("arch_specific", thread)));
    }

    pub const current = struct {
        pub const EnterUserspaceOptions = struct {
            entry_point: cascade.UserVirtualAddress,
            stack_pointer: cascade.UserVirtualAddress,
        };

        /// Enter userspace for the first time in the current thread.
        ///
        /// ***Caller Requirements***:
        ///  - This function must be called only once per thread.
        pub fn enterUserspace(options: EnterUserspaceOptions) callconv(core.inline_in_non_debug) noreturn {
            getFunction(
                current_functions.thread.current,
                "enterUserspace",
            )(options);
            comptime unreachable;
        }
    };

    pub const init = struct {
        /// Perform any per-achitecture initialization needed for userspace threads.
        pub fn initialize() anyerror!void {
            return getFunction(
                current_functions.thread.init,
                "initialize",
            )();
        }
    };
};

pub const SyscallFrame = struct {
    arch_specific: *current_decls.SyscallFrame,

    /// Get the syscall this frame represents.
    pub fn syscall(syscall_frame: SyscallFrame) callconv(core.inline_in_non_debug) ?user_cascade.Syscall {
        return getFunction(
            current_functions.syscall_frame,
            "syscall",
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

    /// Get an argument from this frame.
    pub fn arg(syscall_frame: SyscallFrame, comptime argument: Arg) callconv(core.inline_in_non_debug) u64 {
        return getFunction(
            current_functions.syscall_frame,
            "arg",
        )(syscall_frame.arch_specific, argument);
    }

    /// Get a user virtual range from ptr and len syscall arguments.
    ///
    /// Returns null if the range is not entirely in user memory.
    ///
    /// ***Limitations***:
    ///  - Does not check that the range is valid in the users address space.
    pub fn getUserRange(syscall_frame: SyscallFrame, comptime ptr_arg: Arg, comptime len_arg: Arg) ?cascade.UserVirtualRange {
        const range: cascade.VirtualRange = .from(
            .from(syscall_frame.arg(ptr_arg)),
            .from(syscall_frame.arg(len_arg), .byte),
        );

        switch (range.tagged()) {
            .user => |user_range| return user_range,
            .kernel, .invalid => return null,
        }
    }

    pub inline fn format(
        syscall_frame: SyscallFrame,
        writer: *std.Io.Writer,
    ) !void {
        return syscall_frame.arch_specific.format(writer);
    }
};

pub const Task = struct {
    arch_specific: current_decls.Task,

    /// Perform architecture specific task initialization.
    ///
    /// This function is called very early during init so cannot use any kernel subsystems.
    pub fn initialize(task: *Task) callconv(core.inline_in_non_debug) void {
        current_functions.task.initialize(@alignCast(@fieldParentPtr("arch_specific", task)));
    }

    /// Get the current task.
    ///
    /// Supports being called with interrupts and preemption enabled.
    pub fn getCurrent() callconv(core.inline_in_non_debug) *cascade.Task {
        return getFunction(
            current_functions.task,
            "getCurrent",
        )();
    }

    /// Set the current task.
    ///
    /// Supports being called with interrupts and preemption enabled.
    pub fn setCurrent(task: *Task) callconv(core.inline_in_non_debug) void {
        return getFunction(
            current_functions.task,
            "setCurrent",
        )(@alignCast(@fieldParentPtr("arch_specific", task)));
    }

    /// Prepare the task for being scheduled.
    ///
    /// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `type_erased_call`.
    ///
    /// ***Caller Requirements***:
    ///  - Must be called before the task is scheduled.
    ///  - Can only be called once.
    pub fn prepareForScheduling(
        task: *Task,
        type_erased_call: core.TypeErasedCall,
    ) callconv(core.inline_in_non_debug) void {
        return getFunction(
            current_functions.task,
            "prepareForScheduling",
        )(@alignCast(@fieldParentPtr("arch_specific", task)), type_erased_call);
    }

    /// Called before `transition.old_task` is switched to `transition.new_task`.
    ///
    /// ***Caller Requirements***:
    ///  - Page table switching and managing ability to access user memory must have already been performed before this function is called.
    ///  - Interrupts must be disabled when this function is called.
    pub fn prepareSwitch(
        transition: cascade.Task.Transition,
    ) callconv(core.inline_in_non_debug) void {
        if (core.is_debug) std.debug.assert(!Executor.current.interruptsEnabled());

        getFunction(
            current_functions.task,
            "prepareSwitch",
        )(transition);
    }

    /// Switches to `new_task`.
    ///
    /// The state of `old_task` is saved to allow it to be resumed later.
    ///
    /// ***Caller Requirements***:
    ///  - `prepareSwitch` must be called before calling this function.
    pub fn performSwitch(
        old_task: *Task,
        new_task: *Task,
    ) callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.task,
            "performSwitch",
        )(
            @alignCast(@fieldParentPtr("arch_specific", old_task)),
            @alignCast(@fieldParentPtr("arch_specific", new_task)),
        );
    }

    /// Switches to `new_task`.
    ///
    /// ***Caller Requirements***:
    ///  - `prepareSwitch` must be called before calling this function.
    pub fn performSwitchNoSave(
        new_task: *Task,
    ) callconv(core.inline_in_non_debug) noreturn {
        getFunction(
            current_functions.task,
            "performSwitchNoSave",
        )(@alignCast(@fieldParentPtr("arch_specific", new_task)));
        comptime unreachable;
    }

    /// Calls `type_erased_call` on `new_stack` and saves the state of `old_task`.
    ///
    /// ***Caller Requirements***:
    ///  - `type_erased_call` must have a return type of `noreturn`.
    pub fn call(
        old_task: *Task,
        new_stack: *cascade.Task.Stack,
        type_erased_call: core.TypeErasedCall,
    ) callconv(core.inline_in_non_debug) void {
        if (core.is_debug) std.debug.assert(type_erased_call.return_type.isNoReturn());

        getFunction(current_functions.task, "call")(
            @alignCast(@fieldParentPtr("arch_specific", old_task)),
            new_stack,
            type_erased_call,
        );
    }

    /// Calls `type_erased_call` on `new_stack`.
    ///
    /// ***Caller Requirements***:
    ///  - `type_erased_call` must have a return type of `noreturn`.
    pub fn callNoSave(
        new_stack: *cascade.Task.Stack,
        type_erased_call: core.TypeErasedCall,
    ) callconv(core.inline_in_non_debug) noreturn {
        if (core.is_debug) std.debug.assert(type_erased_call.return_type.isNoReturn());

        getFunction(current_functions.task, "callNoSave")(
            new_stack,
            type_erased_call,
        );
        comptime unreachable;
    }
};

pub const pci = struct {
    /// Read a value from PCI enhanced configuration space.
    pub fn read(comptime T: type, address: cascade.KernelVirtualAddress) callconv(core.inline_in_non_debug) T {
        return switch (T) {
            u8 => getFunction(
                current_functions.pci,
                "readU8",
            )(address),
            u16 => getFunction(
                current_functions.pci,
                "readU16",
            )(address),
            u32 => getFunction(
                current_functions.pci,
                "readU32",
            )(address),
            else => @compileError("unsupported pci read size"),
        };
    }

    /// Write a value to PCI enhanced configuration space.
    pub fn write(comptime T: type, address: cascade.KernelVirtualAddress, value: T) callconv(core.inline_in_non_debug) void {
        switch (T) {
            u8 => getFunction(
                current_functions.pci,
                "writeU8",
            )(address, value),
            u16 => getFunction(
                current_functions.pci,
                "writeU16",
            )(address, value),
            u32 => getFunction(
                current_functions.pci,
                "writeU32",
            )(address, value),
            else => @compileError("unsupported pci write size"),
        }
    }
};

pub const Port = struct {
    arch_specific: current_decls.Port,

    pub const FromError = error{InvalidPort};

    pub fn from(value: usize) callconv(core.inline_in_non_debug) FromError!Port {
        return .{
            .arch_specific = try getFunction(
                current_functions.port,
                "from",
            )(value),
        };
    }

    pub fn read(port: Port, comptime T: type) callconv(core.inline_in_non_debug) T {
        return switch (T) {
            u8 => getFunction(
                current_functions.port,
                "readU8",
            )(port.arch_specific),
            u16 => getFunction(
                current_functions.port,
                "readU16",
            )(port.arch_specific),
            u32 => getFunction(
                current_functions.port,
                "readU32",
            )(port.arch_specific),
            else => @compileError("unsupported port size"),
        };
    }

    pub fn write(port: Port, comptime T: type, value: T) callconv(core.inline_in_non_debug) void {
        switch (T) {
            u8 => getFunction(
                current_functions.port,
                "writeU8",
            )(port.arch_specific, value),
            u16 => getFunction(
                current_functions.port,
                "writeU16",
            )(port.arch_specific, value),
            u32 => getFunction(
                current_functions.port,
                "writeU32",
            )(port.arch_specific, value),
            else => @compileError("unsupported port size"),
        }
    }
};

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

    pub const CaptureSystemInformationStage = enum {
        /// Capture any system information that can be without using MMIO.
        ///
        /// For example, on x64 this should capture CPUID but not APIC or ACPI information.
        early,

        /// Capture any system information that needs mmio.
        ///
        /// For example, on x64 this should capture APIC and ACPI information.
        full,
    };

    pub const CaptureSystemInformationOptions = current_decls.CaptureSystemInformationOptions;

    pub fn captureSystemInformation(
        stage: CaptureSystemInformationStage,
        options: CaptureSystemInformationOptions,
    ) callconv(core.inline_in_non_debug) anyerror!void {
        return getFunction(
            current_functions.init,
            "captureSystemInformation",
        )(stage, options);
    }

    /// Configure any global system features.
    pub fn configureGlobalSystemFeatures() callconv(core.inline_in_non_debug) void {
        getFunction(
            current_functions.init,
            "configureGlobalSystemFeatures",
        )();
    }
};

/// This contains the functions that the architecture specific code must implement.
///
/// Any optional functions that are not implemented will result in a runtime panic when called.
pub const Functions = struct {
    /// Copies memory from `source` to `destination`.
    ///
    /// Sets `target` to the address any unhandleable page fault should return to after setting the result in the slot.
    safeMemcpy: ?fn (
        destination: cascade.VirtualRange,
        source: cascade.VirtualRange,
        target: *cascade.KernelVirtualAddress,
    ) void = null,

    executor: struct {
        /// Notify the given executor of a flush request.
        flushRequestNotify: ?fn (executor: *const cascade.Executor) void = null,

        /// Send a panic to all other executors.
        ///
        /// ***Caller Requirements***:
        ///   - Interrupts are disabled.
        sendPanicAllButSelf: ?fn () void = null,

        current: struct {
            /// Issue an architecture specific hint to the current executor that we are spinning in a loop.
            spinLoopHint: ?fn () callconv(.@"inline") void = null,

            /// Halt the current executor.
            halt: ?fn () void = null,

            /// Disable interrupts on the current executor and halt.
            ///
            /// Non-optional because it is used during early initialization.
            disableInterruptsAndHalt: fn () callconv(.@"inline") noreturn,

            /// Are interrupts enabled on the current executor.
            interruptsEnabled: ?fn () bool = null,

            /// Enable interrupts on the current executor.
            enableInterrupts: ?fn () void = null,

            /// Disable interrupts on the current executor.
            ///
            /// Non-optional because it is used during early initialization.
            disableInterrupts: fn () void,

            /// Flushes the cache for the given virtual range on the current executor.
            ///
            /// ***Caller Requirements***:
            ///  - `virtual_range` must be page aligned
            flushCache: ?fn (virtual_range: cascade.VirtualRange) void = null,

            /// Enable the kernel on the current executor to access user memory.
            ///
            /// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
            /// memory.
            enableAccessToUserMemory: ?fn () void = null,

            /// Disable the kernel on the current executor from accessing user memory.
            ///
            /// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
            /// memory.
            disableAccessToUserMemory: ?fn () void = null,
        },

        init: struct {
            /// Prepares this executor as the bootstrap executor.
            prepareBootstrap: fn (executor: *cascade.Executor, id: current_decls.ExecutorId) void,

            /// Prepares the provided `Executor` for use.
            prepare: ?fn (executor: *cascade.Executor, id: current_decls.ExecutorId) void = null,

            /// Initialize the current executor.
            initialize: fn (executor: *cascade.Executor) void,

            /// Configure any per-executor system features on the current executor.
            ///
            /// This function is called in a few different contexts and must leave the system in a reasonable state for each of them:
            ///  - By the bootstrap executor after calling `init.captureSystemInformation(.early)`
            ///  - By the bootstrap executor after calling `init.captureSystemInformation(.full)`
            ///  - By every executor after `init.captureSystemInformation(.full)` has been called
            configurePerExecutorSystemFeatures: ?fn () void = null,

            /// Initialize the local interrupt controller for the current executor.
            ///
            /// For example, on x86_64 this should initialize the APIC.
            initLocalInterruptController: ?fn () void = null,
        },
    },

    interrupt: struct {
        from: ?fn (value: usize) Interrupt.FromError!current_decls.Interrupt = null,

        to: ?fn (nterrupt: current_decls.Interrupt) usize = null,

        allocate: ?fn (handler: Interrupt.Handler) Interrupt.AllocateError!current_decls.Interrupt = null,

        deallocate: ?fn (interrupt: current_decls.Interrupt) void = null,

        frame: struct {
            /// Provides the context this interrupt was triggered from.
            fillContext: ?fn (
                interrupt_frame: *const current_decls.InterruptFrame,
                context: *std.debug.cpu_context.Native,
            ) void = null,

            /// Returns the instruction pointer of the context this interrupt was triggered from.
            getInstructionPointer: ?fn (interrupt_frame: *const current_decls.InterruptFrame) cascade.VirtualAddress = null,

            /// Sets the instruction pointer that should be used when returning from the interrupt.
            setInstructionPointer: ?fn (
                interrupt_frame: *current_decls.InterruptFrame,
                instruction_pointer: cascade.VirtualAddress,
            ) void = null,
        },

        external: struct {
            from: ?fn (value: usize) Interrupt.External.ExternalFromError!current_decls.ExternalInterrupt = null,

            /// Get the EOI type for the given external interrupt if known.
            eoiType: ?fn (
                external_interrupt: current_decls.ExternalInterrupt,
            ) ?Interrupt.Handler.EOI = null,

            /// Route this external interrupt to the given interrupt.
            ///
            /// Routing the same external interrupt multiple times is undefined behavior.
            route: ?fn (
                external_interrupt: current_decls.ExternalInterrupt,
                interrupt: current_decls.Interrupt,
            ) Interrupt.External.RouteError!void = null,
        },

        init: struct {
            /// Ensure that any exceptions/faults that occur during early initialization are handled.
            ///
            /// The handler is not expected to do anything other than panic.
            initializeEarlyInterrupts: ?fn () void = null,

            /// Prepare interrupt allocation and routing.
            initializeInterruptRouting: ?fn () void = null,

            /// Switch away from the initial interrupt handlers installed by `initializeEarlyInterrupts` to the standard
            /// system interrupt handlers.
            loadStandardInterruptHandlers: ?fn () void = null,
        },
    },

    page_table: struct {
        /// Create a page table in the given physical page.
        ///
        /// ***Caller Requirements***:
        ///  - `physical_page` must be accessible in the direct map.
        create: ?fn (physical_page: cascade.mem.PhysicalPage.Index) *current_decls.PageTable = null,

        load: ?fn (physical_page: cascade.mem.PhysicalPage.Index) void = null,

        /// Copies the top level of `source_page_table` into `destination_page_table`.
        copyTopLevel: ?fn (
            source_page_table: *current_decls.PageTable,
            destination_page_table: *current_decls.PageTable,
        ) void = null,

        /// Maps `virtual_address` to `physical_page` with mapping type `map_type`.
        ///
        /// ***Caller Requirements***:
        ///  - `virtual_address` is page aligned.
        ///  - `map_type.protection` is not `.none`.
        ///
        /// ***Limitations***:
        ///  - Only supports the standard page size for the architecture.
        ///  - Does not flush the TLB.
        mapSinglePage: ?fn (
            page_table: *current_decls.PageTable,
            virtual_address: cascade.VirtualAddress,
            physical_page: cascade.mem.PhysicalPage.Index,
            map_type: cascade.mem.MapType,
            physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
        ) cascade.mem.MapError!void = null,

        /// Unmaps the given virtual range.
        ///
        /// ***Caller Requirements***:
        ///  - `virtual_range` must be page aligned.
        ///
        /// ***Limitations***:
        ///  - Does not flush the TLB.
        unmap: ?fn (
            page_table: *current_decls.PageTable,
            virtual_range: cascade.VirtualRange,
            backing_page_decision: core.CleanupDecision,
            top_level_decision: core.CleanupDecision,
            flush_batch: *cascade.mem.VirtualRangeBatch,
            deallocate_page_list: *cascade.mem.PhysicalPage.List,
        ) void = null,

        /// Changes the protection of the given virtual range.
        ///
        /// ***Caller Requirements***:
        ///  - `virtual_range` must be page aligned.
        ///  - `new_map_type` protection is not `.none`
        ///
        /// ***Limitations***:
        ///  - Does not flush the TLB.
        changeProtection: ?fn (
            page_table: *current_decls.PageTable,
            virtual_range: cascade.VirtualRange,
            previous_map_type: cascade.mem.MapType,
            new_map_type: cascade.mem.MapType,
            flush_batch: *cascade.mem.VirtualRangeBatch,
        ) void = null,

        init: struct {
            /// The total size of the virtual address space that one entry in the top level of a page table covers.
            sizeOfTopLevelEntry: ?fn () core.Size = null,

            /// This function fills in the top level of the page table for the given range.
            ///
            /// ***Caller Requirements***:
            ///  - `range` must have both size and alignment of `sizeOfTopLevelEntry()`.
            ///
            /// ***Limitations***:
            ///  - Does not flush the TLB.
            ///  - Does not rollback on error.
            fillTopLevel: ?fn (
                page_table: *current_decls.PageTable,
                range: cascade.VirtualRange,
                physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
            ) cascade.mem.MapError!void = null,

            /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
            ///
            /// Arch should make use of all page sizes available to the architecture.
            ///
            /// ***Caller Requirements***:
            ///  - `virtual_range` must be page aligned.
            ///  - `physical_range` must be page aligned.
            ///  - `virtual_range` size must equal `physical_range` size.
            ///  - `map_type.protection` is not `.none`.
            ///
            /// ***Limitations***:
            ///  - Does not flush the TLB.
            ///  - Does not rollback on error.
            mapToPhysicalRangeAllPageSizes: ?fn (
                page_table: *current_decls.PageTable,
                virtual_range: cascade.VirtualRange,
                physical_range: cascade.PhysicalRange,
                map_type: cascade.mem.MapType,
                physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
            ) cascade.mem.MapError!void = null,
        },
    },

    thread: struct {
        /// Create the arch specific data of a thread.
        ///
        /// Non-architecture specific creation has already been performed but no initialization.
        ///
        /// This function is called in the `cascade.user.Thread` cache constructor.
        create: ?fn (
            thread: *cascade.user.Thread,
        ) cascade.mem.cache.ConstructorError!void = null,

        /// Destroy the arch specific data of a thread.
        ///
        /// Non-architecture specific destruction has not already been performed.
        ///
        /// This function is called in the `cascade.user.Thread` cache destructor.
        destroy: ?fn (thread: *cascade.user.Thread) void = null,

        /// Initialize the arch specific data of a thread.
        ///
        /// All non-architecture specific initialization has already been performed.
        ///
        /// This function is called in `cascade.user.Thread.internal.create`.
        initialize: ?fn (thread: *cascade.user.Thread) void = null,

        current: struct {
            /// Enter userspace for the first time in the current thread.
            ///
            /// ***Caller Requirements***:
            ///  - This function must be called only once per thread.
            enterUserspace: ?fn (options: Thread.current.EnterUserspaceOptions) noreturn = null,
        },

        init: struct {
            /// Perform any per-achitecture initialization needed for userspace threads.
            initialize: ?fn () anyerror!void = null,
        },
    },

    syscall_frame: struct {
        /// Get the syscall this frame represents.
        syscall: ?fn (syscall_frame: *const current_decls.SyscallFrame) ?user_cascade.Syscall = null,

        /// Get an argument from this frame.
        arg: ?fn (syscall_frame: *const current_decls.SyscallFrame, comptime argument: SyscallFrame.Arg) u64 = null,
    },

    task: struct {
        /// Perform architecture specific task initialization.
        ///
        /// This function is called very early during init so cannot use any kernel subsystems.
        initialize: fn (task: *cascade.Task) void,

        /// Get the current `Task`.
        ///
        /// Supports being called with interrupts and preemption enabled.
        getCurrent: ?fn () callconv(.@"inline") *cascade.Task = null,

        /// Set the current task.
        ///
        /// Supports being called with interrupts and preemption enabled.
        setCurrent: ?fn (task: *cascade.Task) callconv(.@"inline") void = null,

        /// Prepare the task for being scheduled.
        ///
        /// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `type_erased_call`.
        ///
        /// ***Caller Requirements***:
        ///  - Must be called before the task is scheduled.
        ///  - Can only be called once.
        prepareForScheduling: ?fn (task: *cascade.Task, type_erased_call: core.TypeErasedCall) void = null,

        /// Called before `transition.old_task` is switched to `transition.new_task`.
        ///
        /// ***Caller Requirements***:
        ///  - Page table switching and managing ability to access user memory must have already been performed before this function is called.
        ///  - Interrupts must be disabled when this function is called.
        prepareSwitch: ?fn (transition: cascade.Task.Transition) void = null,

        /// Switches to `new_task`.
        ///
        /// The state of `old_task` is saved to allow it to be resumed later.
        ///
        /// ***Caller Requirements***:
        ///  - `prepareSwitch` must be called before calling this function.
        performSwitch: ?fn (
            old_task: *cascade.Task,
            new_task: *cascade.Task,
        ) callconv(.@"inline") void = null,

        /// Switches to `new_task`.
        ///
        /// ***Caller Requirements***:
        ///  - `prepareSwitch` must be called before calling this function.
        performSwitchNoSave: ?fn (new_task: *cascade.Task) callconv(.@"inline") noreturn = null,

        /// Calls `type_erased_call` on `new_stack` and saves the state of `old_task`.
        ///
        /// ***Caller Requirements***:
        ///  - `type_erased_call` must have a return type of `noreturn`.
        call: ?fn (
            old_task: *cascade.Task,
            new_stack: *cascade.Task.Stack,
            type_erased_call: core.TypeErasedCall,
        ) callconv(.@"inline") void = null,

        /// Calls `type_erased_call` on `new_stack`.
        ///
        /// ***Caller Requirements***:
        ///  - `type_erased_call` must have a return type of `noreturn`.
        callNoSave: ?fn (new_stack: *cascade.Task.Stack, type_erased_call: core.TypeErasedCall) callconv(.@"inline") noreturn = null,
    },

    pci: struct {
        readU8: ?fn (address: cascade.KernelVirtualAddress) u8 = null,
        readU16: ?fn (address: cascade.KernelVirtualAddress) u16 = null,
        readU32: ?fn (address: cascade.KernelVirtualAddress) u32 = null,
        writeU8: ?fn (address: cascade.KernelVirtualAddress, value: u8) void = null,
        writeU16: ?fn (address: cascade.KernelVirtualAddress, value: u16) void = null,
        writeU32: ?fn (address: cascade.KernelVirtualAddress, value: u32) void = null,
    },

    port: struct {
        from: ?fn (value: usize) Port.FromError!current_decls.Port = null,
        readU8: ?fn (port: current_decls.Port) u8 = null,
        readU16: ?fn (port: current_decls.Port) u16 = null,
        readU32: ?fn (port: current_decls.Port) u32 = null,
        writeU8: ?fn (port: current_decls.Port, value: u8) void = null,
        writeU16: ?fn (port: current_decls.Port, value: u16) void = null,
        writeU32: ?fn (port: current_decls.Port, value: u32) void = null,
    },

    init: struct {
        /// Read current wallclock time from the standard wallclock source of the current architecture.
        ///
        /// For example on x86_64 this is the TSC.
        ///
        /// Non-optional because it is used during early initialization.
        getStandardWallclockStartTime: fn () cascade.time.wallclock.Tick,

        /// Register any architectural time sources.
        ///
        /// For example, on x86_64 this should register the TSC, HPEC, PIT, etc.
        registerArchitecturalTimeSources: ?fn (candidate_time_sources: *cascade.time.init.CandidateTimeSources) void = null,

        /// Attempt to get some form of architecture specific init output if it is available.
        ///
        /// If `memory_system_available` is false, then the memory system has not been initialized so heap allocation and the special heap are
        /// not available.
        ///
        /// The first time this function is called `memory_system_available` will be false, this function will be called again after the memory
        /// system is initialized with `memory_system_available` set to true, but only if a generic serial output was not available without
        /// needing the memory system.
        tryGetSerialOutput: fn (memory_system_available: bool) ?init.InitOutput,

        captureSystemInformation: ?fn (
            stage: init.CaptureSystemInformationStage,
            options: current_decls.CaptureSystemInformationOptions,
        ) anyerror!void = null,

        /// Configure any global system features.
        configureGlobalSystemFeatures: ?fn () void = null,
    },
};

/// This contains the declarations that the architecture specific code must provide.
pub const Decls = struct {
    /// The range of the address space that is considered kernel memory.
    ///
    /// Usually the higher half of the address space.
    ///
    /// Arch is recommend to exclude the last valid page of the range to prevent boundary conditions.
    ///
    /// **Arch Requirements**:
    ///  - Must not include `.zero`, `.undefined_address` or `.max` addresses.
    ///  - Must not overlap with `user_memory_range`.
    kernel_memory_range: cascade.VirtualRange,

    /// The range of the address space that is considered user memory.
    ///
    /// Usually the lower half of the address space.
    ///
    /// Arch is recommend to exclude the last valid page of the range to prevent boundary conditions.
    /// This is required for correctness on x64 atleast; due to syscall causing sysret with non-canonical return address.
    ///
    /// **Arch Requirements**:
    ///  - Must not include `.zero`, `.undefined_address` or `.max` addresses.
    ///  - Must not overlap with `kernel_memory_range`.
    user_memory_range: cascade.VirtualRange,

    /// A string to be used in inline assembly to prevent unwinding.
    ///
    /// E.g. `asm volatile (arch.cfi_prevent_unwinding);`
    cfi_prevent_unwinding: []const u8,

    Executor: type,

    /// The architecture specific executor id.
    ///
    /// This is expected to be an enum.
    ///
    /// On x64 this is the APIC ID, ARM it is MPIDR, etc.
    ExecutorId: type,

    Interrupt: type,

    InterruptFrame: type,

    ExternalInterrupt: type,

    PageTable: type,

    /// The standard page size for the architecture.
    standard_page_size: core.Size,

    /// The largest page size supported by the architecture.
    largest_page_size: core.Size,

    Thread: type,

    SyscallFrame: type,

    Task: type,

    Port: type,

    CaptureSystemInformationOptions: type,
};

comptime {
    std.debug.assert(!current_decls.kernel_memory_range.anyOverlap(current_decls.user_memory_range));
    std.debug.assert(!current_decls.kernel_memory_range.containsAddress(.zero));
    std.debug.assert(!current_decls.kernel_memory_range.containsAddress(.undefined_address));
    std.debug.assert(!current_decls.kernel_memory_range.containsAddress(.max));
}

comptime {
    std.debug.assert(!current_decls.user_memory_range.anyOverlap(current_decls.kernel_memory_range));
    std.debug.assert(!current_decls.user_memory_range.containsAddress(.zero));
    std.debug.assert(!current_decls.user_memory_range.containsAddress(.undefined_address));
    std.debug.assert(!current_decls.user_memory_range.containsAddress(.max));
}

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
