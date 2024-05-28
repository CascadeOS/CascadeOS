// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Defines the interface of the architecture specific code.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const current = switch (@import("cascade_target").arch) {
    .x64 => @import("x64/interface.zig"),
};

/// Architecture specific per-cpu information.
pub const ArchCpu = current.ArchCpu;

/// Get the current CPU.
///
/// Assumes that `init.loadCpu()` has been called on the currently running CPU.
///
/// It is the callers responsibility to ensure that the current thread is not re-scheduled on to another CPU.
pub inline fn rawGetCpu() *kernel.Cpu {
    checkSupport(current, "getCpu", fn () *kernel.Cpu);

    return current.getCpu();
}

/// Issues an architecture specific hint to the CPU that we are spinning in a loop.
pub inline fn spinLoopHint() void {
    checkSupport(current, "spinLoopHint", fn () void);

    current.spinLoopHint();
}

/// Halts the current processor
pub inline fn halt() void {
    checkSupport(current, "halt", fn () void);

    current.halt();
}

/// Functionality that is used during kernel init only.
pub const init = struct {
    /// Attempt to set up some form of early output.
    pub inline fn setupEarlyOutput() void {
        checkSupport(current.init, "setupEarlyOutput", fn () void);

        current.init.setupEarlyOutput();
    }

    /// Acquire a writer for the early output setup by `setupEarlyOutput`.
    pub inline fn getEarlyOutput() ?std.io.AnyWriter {
        checkSupport(current.init, "getEarlyOutput", fn () ?current.init.EarlyOutputWriter);

        return if (current.init.getEarlyOutput()) |writer| writer.any() else null;
    }

    /// Ensure that any exceptions/faults that occur are handled.
    pub inline fn initInterrupts() void {
        checkSupport(current.init, "initInterrupts", fn () void);

        current.init.initInterrupts();
    }

    /// Prepares the provided `Cpu` for the bootstrap processor.
    pub inline fn prepareBootstrapCpu(
        bootstrap_cpu: *kernel.Cpu,
    ) void {
        checkSupport(current.init, "prepareBootstrapCpu", fn (*kernel.Cpu) void);

        current.init.prepareBootstrapCpu(bootstrap_cpu);
    }

    /// Load the provided `Cpu` as the current CPU.
    pub inline fn loadCpu(cpu: *kernel.Cpu) void {
        checkSupport(current.init, "loadCpu", fn (*kernel.Cpu) void);

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
};

pub const interrupts = struct {
    /// Disable interrupts and put the CPU to sleep.
    pub inline fn disableInterruptsAndHalt() noreturn {
        checkSupport(current.interrupts, "disableInterruptsAndHalt", fn () noreturn);

        current.interrupts.disableInterruptsAndHalt();
    }

    /// Are interrupts enabled?
    pub inline fn interruptsEnabled() bool {
        checkSupport(current.interrupts, "interruptsEnabled", fn () bool);

        return current.interrupts.interruptsEnabled();
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
    /// Switches to the provided stack and returns.
    ///
    /// It is the caller's responsibility to ensure the stack is valid, with a return address.
    pub inline fn changeStackAndReturn(
        stack_pointer: core.VirtualAddress,
    ) noreturn {
        checkSupport(current.scheduling, "changeStackAndReturn", fn (core.VirtualAddress) noreturn);

        try current.scheduling.changeStackAndReturn(stack_pointer);
    }

    /// It is the caller's responsibility to ensure the stack is valid, with a return address.
    pub inline fn switchToIdle(
        cpu: *kernel.Cpu,
        stack_pointer: core.VirtualAddress,
        opt_old_thread: ?*kernel.Thread,
    ) noreturn {
        checkSupport(current.scheduling, "switchToIdle", fn (*kernel.Cpu, core.VirtualAddress, ?*kernel.Thread) noreturn);

        current.scheduling.switchToIdle(cpu, stack_pointer, opt_old_thread);
    }

    pub inline fn switchToThreadFromIdle(
        cpu: *kernel.Cpu,
        thread: *kernel.Thread,
    ) noreturn {
        checkSupport(current.scheduling, "switchToThreadFromIdle", fn (*kernel.Cpu, *kernel.Thread) noreturn);

        current.scheduling.switchToThreadFromIdle(cpu, thread);
    }

    pub inline fn switchToThreadFromThread(
        cpu: *kernel.Cpu,
        old_thread: *kernel.Thread,
        new_thread: *kernel.Thread,
    ) void {
        checkSupport(current.scheduling, "switchToThreadFromThread", fn (*kernel.Cpu, *kernel.Thread, *kernel.Thread) void);

        current.scheduling.switchToThreadFromThread(cpu, old_thread, new_thread);
    }

    pub const NewThreadFunction = *const fn (
        interrupt_exclusion: kernel.sync.InterruptExclusion,
        thread: *kernel.Thread,
        context: u64,
    ) noreturn;

    pub inline fn prepareNewThread(
        thread: *kernel.Thread,
        context: u64,
        target_function: NewThreadFunction,
    ) error{StackOverflow}!void {
        checkSupport(current.scheduling, "prepareNewThread", fn (
            *kernel.Thread,
            u64,
            NewThreadFunction,
        ) error{StackOverflow}!void);

        return current.scheduling.prepareNewThread(thread, context, target_function);
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
        // core.panic("`" ++ @tagName(@import("cascade_target").arch) ++ "` does not implement `" ++ name ++ "`");
        @compileError("`" ++ @tagName(@import("cascade_target").arch) ++ "` does not implement `" ++ name ++ "`");
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
