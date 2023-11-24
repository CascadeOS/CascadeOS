// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const current = switch (kernel.info.arch) {
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

pub inline fn getProcessor() *kernel.Processor {
    checkSupport(current, "getProcessor", fn () *kernel.Processor);

    return current.getProcessor();
}

/// Unlike `getProcessor`, this allows the pointer to be null, which allows detecting if the Processor has not yet been initialized.
pub inline fn safeGetProcessor() ?*kernel.Processor {
    checkSupport(current, "safeGetProcessor", fn () ?*kernel.Processor);

    return current.safeGetProcessor();
}

/// Functionality that is intended to be used during kernel init only.
pub const init = struct {
    /// Prepares the provided Processor for the bootstrap processor.
    pub inline fn prepareBootstrapProcessor(bootstrap_processor: *kernel.Processor) void {
        checkSupport(current.init, "prepareBootstrapProcessor", fn (*kernel.Processor) void);

        current.init.prepareBootstrapProcessor(bootstrap_processor);
    }

    /// Prepares the provided Processor for use.
    pub inline fn prepareProcessor(processor: *kernel.Processor) void {
        checkSupport(current.init, "prepareProcessor", fn (*kernel.Processor) void);

        current.init.prepareProcessor(processor);
    }

    /// Performs any actions required to load the provided Processor for the current execution context.
    pub inline fn loadProcessor(processor: *kernel.Processor) void {
        checkSupport(current.init, "loadProcessor", fn (*kernel.Processor) void);

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

        disableInterrupts();

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
    pub const higher_half: kernel.VirtualAddress = current.paging.higher_half;

    /// The page table type for the architecture.
    pub const PageTable: type = current.paging.PageTable;

    /// Allocates a new page table.
    pub inline fn allocatePageTable() error{PageAllocationFailed}!*PageTable {
        checkSupport(current.paging, "allocatePageTable", fn () error{PageAllocationFailed}!*PageTable);

        return current.paging.allocatePageTable();
    }

    /// This function is only called during kernel init, it is required to:
    ///   1. search the higher half of the *top level* of the given page table for a free entry
    ///   2. allocate a backing frame for it
    ///   3. map the free entry to the fresh backing frame and ensure it is zeroed
    ///   4. return the `VirtualRange` representing the entire virtual range that entry covers
    pub inline fn getTopLevelRangeAndFillFirstLevel(page_table: *PageTable) MapError!kernel.VirtualRange {
        checkSupport(current.paging, "getTopLevelRangeAndFillFirstLevel", fn (*PageTable) MapError!kernel.VirtualRange);

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
    pub inline fn mapStandardRange(
        page_table: *PageTable,
        virtual_range: kernel.VirtualRange,
        physical_range: kernel.PhysicalRange,
        map_type: kernel.vmm.MapType,
    ) MapError!void {
        checkSupport(current.paging, "mapStandardRange", fn (
            *PageTable,
            kernel.VirtualRange,
            kernel.PhysicalRange,
            kernel.vmm.MapType,
        ) MapError!void);

        return current.paging.mapStandardRange(page_table, virtual_range, physical_range, map_type);
    }

    /// Unmaps the `virtual_range`.
    ///
    /// This function assumes only the architecture's `standard_page_size` is used for the mapping.
    pub fn unmapStandardRange(
        page_table: *PageTable,
        virtual_range: kernel.VirtualRange,
    ) void {
        checkSupport(current.paging, "unmapStandardRange", fn (*PageTable, kernel.VirtualRange) void);

        current.paging.unmapStandardRange(page_table, virtual_range);
    }

    /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
    ///
    /// This function is allowed to use all page sizes available to the architecture.
    pub inline fn mapRangeUseAllPageSizes(
        page_table: *PageTable,
        virtual_range: kernel.VirtualRange,
        physical_range: kernel.PhysicalRange,
        map_type: kernel.vmm.MapType,
    ) MapError!void {
        checkSupport(current.paging, "mapRangeUseAllPageSizes", fn (
            *PageTable,
            kernel.VirtualRange,
            kernel.PhysicalRange,
            kernel.vmm.MapType,
        ) MapError!void);

        return current.paging.mapRangeUseAllPageSizes(page_table, virtual_range, physical_range, map_type);
    }

    /// Switches to the given page table.
    pub inline fn switchToPageTable(page_table: *const PageTable) void {
        checkSupport(current.paging, "switchToPageTable", fn (*const PageTable) void);

        current.paging.switchToPageTable(page_table);
    }
};

/// Checks if the current architecture implements the given function.
///
/// If it is unimplemented, this function will panic at runtime.
///
/// If it is implemented, this function will validate it's signature at compile time and do nothing at runtime.
inline fn checkSupport(comptime Container: type, comptime name: []const u8, comptime TargetT: type) void {
    if (comptime name.len == 0) @compileError("zero-length name");

    if (!@hasDecl(Container, name)) {
        core.panic("`" ++ @tagName(kernel.info.arch) ++ "` does not implement `" ++ name ++ "`");
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
