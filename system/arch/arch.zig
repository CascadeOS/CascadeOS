// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Defines the interface of the architecture specific code.

/// Architecture specific per-executor data.
pub const PerExecutor = current.PerExecutor;

pub const interrupts = struct {
    /// Disable interrupts and halt the CPU.
    ///
    /// This is a decl not a wrapper function like the other functions so that it can be inlined into a naked function.
    pub const disableInterruptsAndHalt = current.interrupts.disableInterruptsAndHalt;

    /// Disable interrupts.
    pub fn disableInterrupts() callconv(core.inline_in_non_debug) void {
        // `checkSupport` intentionally not called - mandatory function

        current.interrupts.disableInterrupts();
    }

    pub const InterruptHandler = *const fn (context: InterruptContext) void;

    pub const InterruptContext = struct {
        context: current.interrupts.ArchInterruptContext,
    };
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

        pub inline fn load(page_table: PageTable) void {
            checkSupport(current.paging, "loadPageTable", fn (core.PhysicalAddress) void);

            current.paging.loadPageTable(page_table.physical_address);
        }

        pub const page_table_alignment: core.Size = current.paging.page_table_alignment;
        pub const page_table_size: core.Size = current.paging.page_table_size;

        const ArchPageTable = current.paging.ArchPageTable;
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

    /// Load the provided `Executor` as the current executor.
    pub fn loadExecutor(executor: *kernel.Executor) callconv(core.inline_in_non_debug) void {
        checkSupport(current.init, "loadExecutor", fn (*kernel.Executor) void);

        current.init.loadExecutor(executor);
    }

    /// Ensure that any exceptions/faults that occur are handled.
    ///
    /// The `initial_interrupt_handler` will be set as the initial interrupt handler for all interrupts.
    pub fn initInterrupts(initial_interrupt_handler: interrupts.InterruptHandler) callconv(core.inline_in_non_debug) void {
        checkSupport(current.init, "initInterrupts", fn (interrupts.InterruptHandler) void);

        current.init.initInterrupts(initial_interrupt_handler);
    }

    /// Capture any system information that is required for the architecture.
    ///
    /// For example, on x64 this should capture the CPUID information.
    pub fn captureSystemInformation() callconv(core.inline_in_non_debug) !void {
        checkSupport(current.init, "captureSystemInformation", fn () anyerror!void);

        return current.init.captureSystemInformation();
    }

    /// Configure any global system features.
    pub fn configureGlobalSystemFeatures() callconv(core.inline_in_non_debug) !void {
        checkSupport(current.init, "configureGlobalSystemFeatures", fn () anyerror!void);

        return current.init.configureGlobalSystemFeatures();
    }
};

const current = switch (@import("cascade_target").arch) {
    // x64 is first to help zls, atleast while x64 is the main target.
    .x64 => @import("x64/x64.zig").arch_interface,
    .arm64 => @import("arm64/arm64.zig").arch_interface,
};

/// Checks if the current architecture implements the given function.
///
/// If it is unimplemented, this function will panic at runtime.
///
/// If it is implemented, this function will validate it's signature at compile time and do nothing at runtime.
inline fn checkSupport(comptime Container: type, comptime name: []const u8, comptime TargetT: type) void {
    if (comptime name.len == 0) @compileError("zero-length name");

    if (comptime !@hasDecl(Container, name)) {
        core.panic(comptime "`" ++ @tagName(@import("cascade_target").arch) ++ "` does not implement `" ++ name ++ "`", null);
    }

    const DeclT = @TypeOf(@field(Container, name));

    const mismatch_type_msg =
        comptime "Expected `" ++ name ++ "` to be compatible with `" ++ @typeName(TargetT) ++
        "`, but it is `" ++ @typeName(DeclT) ++ "`";

    const decl_type_info = @typeInfo(DeclT).@"fn";
    const target_type_info = @typeInfo(TargetT).@"fn";

    if (decl_type_info.return_type != target_type_info.return_type) {
        const DeclReturnT = decl_type_info.return_type.?;
        const TargetReturnT = target_type_info.return_type.?;

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
        if (decl_param.type != target_param.type) @compileError(mismatch_type_msg);
    }
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
