// SPDX-License-Identifier: MIT

const core = @import("core");
const info = kernel.info;
const kernel = @import("kernel");
const PhysicalRange = kernel.PhysicalRange;
const Processor = kernel.Processor;
const Stack = kernel.Stack;
const std = @import("std");
const Thread = kernel.Thread;
const VirtualAddress = kernel.VirtualAddress;
const VirtualRange = kernel.VirtualRange;
const vmm = kernel.vmm;

const current = switch (info.arch) {
    .x86_64 => @import("x86_64/x86_64.zig"),
    .aarch64 => @import("aarch64/aarch64.zig"),
};

/// Issues an architecture specific hint to the CPU that we are spinning in a loop.
pub inline fn spinLoopHint() void {
    checkSupport(current, "spinLoopHint", fn () void);

    current.spinLoopHint();
}

/// Architecture specific processor information.
pub const ArchProcessor = current.ArchProcessor;

/// Get the current processor.
///
/// Panics if interrupts are enabled.
pub inline fn getProcessor() *Processor {
    checkSupport(current, "getProcessor", fn () *Processor);

    core.debugAssert(!interrupts.interruptsEnabled());

    return current.getProcessor();
}

/// Get the current processor, supports returning null for early boot before the processor is set.
///
/// Panics if interrupts are enabled.
pub inline fn earlyGetProcessor() ?*Processor {
    checkSupport(current, "earlyGetProcessor", fn () ?*Processor);

    core.debugAssert(!interrupts.interruptsEnabled());

    return current.earlyGetProcessor();
}

/// Halts the current processor
pub inline fn halt() void {
    checkSupport(current, "halt", fn () void);

    current.halt();
}

/// Functionality that is intended to be used during kernel init only.
pub const init = struct {
    /// Prepares the provided Processor for the bootstrap processor.
    pub inline fn prepareBootstrapProcessor(bootstrap_processor: *Processor) void {
        checkSupport(current.init, "prepareBootstrapProcessor", fn (*Processor) void);

        current.init.prepareBootstrapProcessor(bootstrap_processor);
    }

    /// Prepares the provided Processor for use.
    ///
    /// **WARNING**: This function will panic if the processor cannot be prepared.
    pub inline fn prepareProcessor(processor: *Processor) void {
        checkSupport(current.init, "prepareProcessor", fn (*Processor) void);

        current.init.prepareProcessor(processor);
    }

    /// Performs any actions required to load the provided Processor for the current execution context.
    pub inline fn loadProcessor(processor: *Processor) void {
        checkSupport(current.init, "loadProcessor", fn (*Processor) void);

        current.init.loadProcessor(processor);
    }

    /// Attempt to set up some form of early output.
    pub inline fn setupEarlyOutput() void {
        checkSupport(current.init, "setupEarlyOutput", fn () void);

        current.init.setupEarlyOutput();
    }

    pub const EarlyOutputWriter = current.init.EarlyOutputWriter;

    /// Acquire a `std.io.Writer` for the early output setup by `setupEarlyOutput`.
    pub inline fn getEarlyOutputWriter() ?EarlyOutputWriter {
        checkSupport(current.init, "getEarlyOutputWriter", fn () ?EarlyOutputWriter);

        return current.init.getEarlyOutputWriter();
    }

    /// Initialize the architecture specific registers and structures into the state required for early kernel init.
    ///
    /// One of the requirements of this function is to ensure that any exceptions/faults that occur are correctly handled.
    ///
    /// For example, on x86_64 after this function has completed a GDT, TSS and an IDT with a simple handler on every vector
    /// should be in place.
    pub inline fn earlyArchInitialization() void {
        checkSupport(current.init, "earlyArchInitialization", fn () void);

        current.init.earlyArchInitialization();
    }

    /// Capture any system information that is required for the architecture.
    ///
    /// For example, on x86_64 this should capture the CPUID information.
    pub inline fn captureSystemInformation() void {
        checkSupport(current.init, "captureSystemInformation", fn () void);

        current.init.captureSystemInformation();
    }

    /// Configure any system features.
    ///
    /// For example, on x86_64 this should enable any CPU features that are required.
    pub inline fn configureSystemFeatures() void {
        checkSupport(current.init, "configureSystemFeatures", fn () void);

        current.init.configureSystemFeatures();
    }
};

pub const interrupts = struct {
    /// Disable interrupts and put the CPU to sleep.
    pub inline fn disableInterruptsAndHalt() noreturn {
        checkSupport(current.interrupts, "disableInterruptsAndHalt", fn () noreturn);

        current.interrupts.disableInterruptsAndHalt();
    }

    /// Disable interrupts.
    pub inline fn disableInterrupts() void {
        checkSupport(current.interrupts, "disableInterrupts", fn () void);

        current.interrupts.disableInterrupts();
    }

    /// Enable interrupts.
    pub inline fn enableInterrupts() void {
        checkSupport(current.interrupts, "enableInterrupts", fn () void);

        current.interrupts.enableInterrupts();
    }

    /// Are interrupts enabled?
    pub inline fn interruptsEnabled() bool {
        checkSupport(current.interrupts, "interruptsEnabled", fn () bool);

        return current.interrupts.interruptsEnabled();
    }

    pub const InterruptGuard = struct {
        enable_interrupts: bool,

        pub inline fn release(self: InterruptGuard) void {
            if (self.enable_interrupts) enableInterrupts();
        }
    };

    pub fn interruptGuard() InterruptGuard {
        const interrupts_enabled = interruptsEnabled();

        if (interrupts_enabled) disableInterrupts();

        return .{
            .enable_interrupts = interrupts_enabled,
        };
    }
};

pub const paging = struct {
    /// The standard page size for the architecture.
    pub const standard_page_size: core.Size = current.paging.standard_page_size;

    /// Returns the largest page size supported by the architecture.
    pub inline fn largestPageSize() core.Size {
        checkSupport(current.paging, "largestPageSize", fn () core.Size);

        return current.paging.largestPageSize();
    }

    /// The virtual address of the higher half.
    pub const higher_half: VirtualAddress = current.paging.higher_half;

    /// The page table type for the architecture.
    pub const PageTable: type = current.paging.PageTable;

    /// Initializes a page table.
    pub inline fn initPageTable(page_table: *PageTable) void {
        checkSupport(current.paging, "initPageTable", fn (*PageTable) void);

        return current.paging.initPageTable(page_table);
    }

    /// This function is only called during kernel init, it is required to:
    ///   1. search the higher half of the *top level* of the given page table for a free entry
    ///   2. allocate a backing frame for it
    ///   3. map the free entry to the fresh backing frame and ensure it is zeroed
    ///   4. return the `VirtualRange` representing the entire virtual range that entry covers
    pub inline fn getTopLevelRangeAndFillFirstLevel(page_table: *PageTable) MapError!VirtualRange {
        checkSupport(current.paging, "getTopLevelRangeAndFillFirstLevel", fn (*PageTable) MapError!VirtualRange);

        // TODO: randomize location of the heap/stacks https://github.com/CascadeOS/CascadeOS/issues/56
        // the chance that the heap will occupy the the very first higher half table is very high
        // especially due to kaslr. to reduce this problem we need to add a bit of random.
        return current.paging.getTopLevelRangeAndFillFirstLevel(page_table);
    }

    pub const MapError = error{
        AlreadyMapped,
        AllocationFailed,
        Unexpected,
    };

    /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
    ///
    /// This function will only use the architecture's `standard_page_size`.
    pub inline fn mapToPhysicalRange(
        page_table: *PageTable,
        virtual_range: VirtualRange,
        physical_range: PhysicalRange,
        map_type: vmm.MapType,
    ) MapError!void {
        checkSupport(current.paging, "mapToPhysicalRange", fn (
            *PageTable,
            VirtualRange,
            PhysicalRange,
            vmm.MapType,
        ) MapError!void);

        return current.paging.mapToPhysicalRange(page_table, virtual_range, physical_range, map_type);
    }

    /// Unmaps the `virtual_range`.
    ///
    /// This function assumes only the architecture's `standard_page_size` is used for the mapping.
    pub fn unmap(
        page_table: *PageTable,
        virtual_range: VirtualRange,
    ) void {
        checkSupport(current.paging, "unmap", fn (*PageTable, VirtualRange) void);

        current.paging.unmap(page_table, virtual_range);
    }

    /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
    ///
    /// This function is allowed to use all page sizes available to the architecture.
    pub inline fn mapToPhysicalRangeAllPageSizes(
        page_table: *PageTable,
        virtual_range: VirtualRange,
        physical_range: PhysicalRange,
        map_type: vmm.MapType,
    ) MapError!void {
        checkSupport(current.paging, "mapToPhysicalRangeAllPageSizes", fn (
            *PageTable,
            VirtualRange,
            PhysicalRange,
            vmm.MapType,
        ) MapError!void);

        return current.paging.mapToPhysicalRangeAllPageSizes(page_table, virtual_range, physical_range, map_type);
    }

    /// Switches to the given page table.
    pub inline fn switchToPageTable(page_table: *const PageTable) void {
        checkSupport(current.paging, "switchToPageTable", fn (*const PageTable) void);

        current.paging.switchToPageTable(page_table);
    }
};

pub const scheduling = struct {
    /// Switches to the provided stack and returns.
    ///
    /// It is the caller's responsibility to ensure the stack is valid, with a return address.
    pub inline fn changeStackAndReturn(stack_pointer: VirtualAddress) noreturn {
        checkSupport(current.scheduling, "changeStackAndReturn", fn (VirtualAddress) noreturn);

        try current.scheduling.changeStackAndReturn(stack_pointer);
    }

    pub inline fn switchToThreadFromIdle(processor: *Processor, thread: *Thread) noreturn {
        checkSupport(current.scheduling, "switchToThreadFromIdle", fn (*Processor, *Thread) noreturn);

        current.scheduling.switchToThreadFromIdle(processor, thread);
    }

    pub inline fn switchToThreadFromThread(processor: *Processor, old_thread: *Thread, new_thread: *Thread) void {
        checkSupport(current.scheduling, "switchToThreadFromThread", fn (*Processor, *Thread, *Thread) void);

        current.scheduling.switchToThreadFromThread(processor, old_thread, new_thread);
    }

    /// It is the caller's responsibility to ensure the stack is valid, with a return address.
    pub inline fn switchToIdle(processor: *Processor, stack_pointer: VirtualAddress, opt_old_thread: ?*Thread) noreturn {
        checkSupport(current.scheduling, "switchToIdle", fn (*Processor, VirtualAddress, ?*Thread) noreturn);

        current.scheduling.switchToIdle(processor, stack_pointer, opt_old_thread);
    }

    pub inline fn prepareStackForNewThread(
        stack: *Stack,
        thread: *kernel.Thread,
        context: u64,
        target_function: *const fn (thread: *kernel.Thread, context: u64) noreturn,
    ) error{StackOverflow}!void {
        checkSupport(current.scheduling, "prepareStackForNewThread", fn (
            *Stack,
            *kernel.Thread,
            u64,
            *const fn (thread: *kernel.Thread, context: u64) noreturn,
        ) error{StackOverflow}!void);

        return current.scheduling.prepareStackForNewThread(stack, thread, context, target_function);
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
        core.panic("`" ++ @tagName(info.arch) ++ "` does not implement `" ++ name ++ "`");
    }

    const DeclT = @TypeOf(@field(Container, name));

    const mismatch_type_msg =
        comptime "Expected `" ++ name ++ "` to be compatible with `" ++ @typeName(TargetT) ++
        "`, but it is `" ++ @typeName(DeclT) ++ "`";

    const decl_type_info = @typeInfo(DeclT).Fn;
    const target_type_info = @typeInfo(TargetT).Fn;

    if (decl_type_info.return_type != target_type_info.return_type) @compileError(mismatch_type_msg);

    if (decl_type_info.params.len != target_type_info.params.len) @compileError(mismatch_type_msg);

    inline for (decl_type_info.params, target_type_info.params) |decl_param, target_param| {
        if (decl_param.type != target_param.type) @compileError(mismatch_type_msg);
    }
}
