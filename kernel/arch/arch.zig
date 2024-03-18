// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Defines the interface of the architecture specific code.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const current = switch (@import("cascade_target").arch) {
    .x86_64 => @import("x86_64/interface.zig"),
};

/// Architecture specific per-cpu information.
pub const ArchCpu = current.ArchCpu;

/// Issues an architecture specific hint to the CPU that we are spinning in a loop.
pub inline fn spinLoopHint() void {
    checkSupport(current, "spinLoopHint", fn () void);

    current.spinLoopHint();
}

/// Get the current CPU.
///
/// Assumes that `init.loadCpu()` has been called on the currently running CPU.
///
/// Asserts that interrupts are disabled.
pub inline fn getCpu() *kernel.Cpu {
    checkSupport(current, "getCpu", fn () *kernel.Cpu);

    return current.getCpu();
}

/// Functionality that is used during kernel init only.
pub const init = struct {
    pub const EarlyOutputWriter = current.init.EarlyOutputWriter;

    /// Attempt to set up some form of early output.
    pub inline fn setupEarlyOutput() void {
        checkSupport(current.init, "setupEarlyOutput", fn () void);

        current.init.setupEarlyOutput();
    }

    /// Acquire a writer for the early output setup by `setupEarlyOutput`.
    pub inline fn getEarlyOutput() ?current.init.EarlyOutputWriter {
        checkSupport(current.init, "getEarlyOutput", fn () ?current.init.EarlyOutputWriter);

        return current.init.getEarlyOutput();
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
    /// For example, on x86_64 this should capture the CPUID information.
    pub inline fn captureSystemInformation() void {
        checkSupport(current.init, "captureSystemInformation", fn () void);

        current.init.captureSystemInformation();
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
};

pub const paging = struct {
    /// The standard page size for the architecture.
    pub const standard_page_size: core.Size = current.paging.standard_page_size;

    /// All the page sizes supported by the architecture in order of smallest to largest.
    pub const all_page_sizes: []const core.Size = current.paging.all_page_sizes;

    /// The virtual address of the higher half.
    pub const higher_half: core.VirtualAddress = current.paging.higher_half;

    /// The page table type for the architecture.
    pub const PageTable: type = current.paging.PageTable;

    /// Switches to the page table given by `page_table_address`.
    pub inline fn switchToPageTable(page_table_address: core.PhysicalAddress) void {
        checkSupport(current.paging, "switchToPageTable", fn (core.PhysicalAddress) void);

        current.paging.switchToPageTable(page_table_address);
    }

    pub const MapError = error{
        AlreadyMapped,
        OutOfMemory,
        Unexpected,
    };

    /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
    ///
    /// Caller must ensure:
    ///  - the virtual range address and size are aligned to the standard page size
    ///  - the physical range address and size are aligned to the standard page size
    ///  - the virtual range size is equal to the physical range size
    ///
    /// This function is allowed to use all page sizes available to the architecture.
    pub inline fn mapToPhysicalRangeAllPageSizes(
        page_table: *PageTable,
        virtual_range: core.VirtualRange,
        physical_range: core.PhysicalRange,
        map_type: kernel.vmm.MapType,
    ) MapError!void {
        checkSupport(current.paging, "mapToPhysicalRangeAllPageSizes", fn (
            *PageTable,
            core.VirtualRange,
            core.PhysicalRange,
            kernel.vmm.MapType,
        ) MapError!void);

        return current.paging.mapToPhysicalRangeAllPageSizes(page_table, virtual_range, physical_range, map_type);
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

    if (decl_type_info.return_type != target_type_info.return_type) @compileError(mismatch_type_msg);

    if (decl_type_info.params.len != target_type_info.params.len) @compileError(mismatch_type_msg);

    inline for (decl_type_info.params, target_type_info.params) |decl_param, target_param| {
        if (decl_param.type != target_param.type) @compileError(mismatch_type_msg);
    }
}
