// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Defines the interface of the architecture specific code.

pub const interrupts = struct {
    /// Disable interrupts and halt the CPU.
    ///
    /// This is a decl not a wrapper function like the other functions so that it can be inlined into a naked function.
    pub const disableInterruptsAndHalt = current.interrupts.disableInterruptsAndHalt;
};

/// Functionality that is used during kernel init only.
pub const init = struct {
    /// Attempt to set up some form of early output.
    pub fn setupEarlyOutput() callconv(core.inline_in_non_debug) void {
        // `checkSupport` intentionally not called - mandatory function

        current.init.setupEarlyOutput();
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
const kernel = @import("../kernel.zig");
const cascade_target = @import("cascade_target").arch;
