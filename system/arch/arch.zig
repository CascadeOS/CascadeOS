// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Defines the interface of the architecture specific code.

pub const interrupts = struct {
    /// Disable interrupts and halt the CPU.
    pub inline fn disableInterruptsAndHalt() noreturn {
        // `checkSupport` intentionally not called - mandatory function

        current.interrupts.disableInterruptsAndHalt();
    }

    /// Disable interrupts.
    pub inline fn disableInterrupts() void {
        // `checkSupport` intentionally not called - mandatory function

        current.interrupts.disableInterrupts();
    }
};

/// Functionality that is used during kernel init only.
pub const init = struct {
    /// Attempt to set up some form of early output.
    pub inline fn setupEarlyOutput() void {
        // `checkSupport` intentionally not called - mandatory function

        current.init.setupEarlyOutput();
    }

    /// Write to early output.
    ///
    /// Cannot fail, any errors are ignored.
    pub inline fn writeToEarlyOutput(bytes: []const u8) void {
        // `checkSupport` intentionally not called - mandatory function

        current.init.writeToEarlyOutput(bytes);
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
        core.panic("`" ++ @tagName(@import("cascade_target").arch) ++ "` does not implement `" ++ name ++ "`", null);
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
