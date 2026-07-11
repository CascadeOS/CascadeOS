// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");
const core = @import("core");

/// Stores a type erased call that supports passing `supported_number_of_args` arguments.
///
/// The return type must be `void`, `noreturn`, `!void` or `!noreturn`.
///
/// If an error is returned then an "unhandled error" panic will occur.
///
/// Argument types that are always supported:
/// - bool
/// - one, many and c pointer
/// - optional one, many and c pointer (unless allowzero)
/// - error set
/// - void
/// - null
/// - undefined
///
/// Argument types that are supported if `@sizeOf(T) <= @sizeOf(usize)`:
/// - int
/// - float
/// - array
/// - auto, packed and extern struct
/// - optional
/// - error union
/// - enum
/// - auto, packed and extern union
/// - vector
///
/// Argument types never supported:
/// - slice (split it into seperate ptr and len arguments)
/// - type
/// - noreturn
/// - comptime_float
/// - comptime_int
/// - fn
/// - opaque
/// - frame
/// - anyframe
/// - enum_literal
pub const TypeErasedCall = extern struct {
    typeErased: *const TypeErasedFn,
    args: [supported_number_of_args]Arg,

    pub const supported_number_of_args = 5;
    pub const TypeErasedFn = fn (Arg, Arg, Arg, Arg, Arg) callconv(.c) void;

    pub inline fn call(type_erased: *const TypeErasedCall) void {
        type_erased.typeErased(
            type_erased.args[0],
            type_erased.args[1],
            type_erased.args[2],
            type_erased.args[3],
            type_erased.args[4],
        );
    }

    pub fn prepare(comptime function: anytype, user_args: std.meta.ArgsTuple(@TypeOf(function))) TypeErasedCall {
        var type_erased: TypeErasedCall = .{
            .typeErased = typeErasedFn(function),
            .args = undefined,
        };

        inline for (user_args, 0..) |user_arg, i| {
            type_erased.args[i] = .from(user_arg);
        }

        return type_erased;
    }

    /// Create a templated `TypeErasedCall`.
    ///
    /// The first parameters of the function must match the provided `template_parameters`.
    ///
    /// See `TypeErasedCall` for more details.
    pub fn Templated(comptime template_parameters: []const type) type {
        if (template_parameters.len > TypeErasedCall.supported_number_of_args) {
            @compileError(
                std.fmt.comptimePrint(
                    "number of template parameters must be less than or equal to {d}",
                    .{TypeErasedCall.supported_number_of_args},
                ),
            );
        }

        return struct {
            type_erased_call: TypeErasedCall,

            /// Calls the templated type erased call.
            ///
            /// `setTemplatedArgs` must be called before calling this function.
            pub inline fn call(templated_type_erased: *@This()) void {
                templated_type_erased.type_erased_call.call();
            }

            /// Prepares the templated type erased call.
            ///
            /// `setTemplatedArgs` must be called before making use of the returned `TypeErasedCall.Templated`.
            pub fn prepare(comptime function: anytype, non_templated_user_args: NonTemplateArgsTuple(@TypeOf(function))) @This() {
                comptime {
                    const function_parameters = @typeInfo(@TypeOf(function)).@"fn".params;
                    if (function_parameters.len < template_parameters.len) {
                        @compileError(
                            std.fmt.comptimePrint(
                                "function requires at least {d} parameters to match the template found {d}",
                                .{ template_parameters.len, function_parameters.len },
                            ),
                        );
                    }

                    for (
                        function_parameters[0..template_parameters.len],
                        template_parameters,
                        0..,
                    ) |function_parameter, TemplateParameterType, i| {
                        const FunctionParameterType = function_parameter.type orelse unreachable;
                        if (FunctionParameterType != TemplateParameterType) {
                            @compileError(
                                std.fmt.comptimePrint(
                                    "function parameter {d} with type '{s}' does not match template parameter with type '{s}'",
                                    .{ i, @typeName(FunctionParameterType), @typeName(TemplateParameterType) },
                                ),
                            );
                        }
                    }
                }

                var templated_type_erased: @This() = .{
                    .type_erased_call = .{
                        .typeErased = typeErasedFn(function),
                        .args = undefined,
                    },
                };

                inline for (non_templated_user_args, template_parameters.len..) |non_templated_user_arg, i| {
                    templated_type_erased.type_erased_call.args[i] = .from(non_templated_user_arg);
                }

                return templated_type_erased;
            }

            pub fn setTemplatedArgs(templated_type_erased: *@This(), templated_user_args: TemplateArgsTuple) void {
                inline for (templated_user_args, 0..) |templated_user_arg, i| {
                    templated_type_erased.type_erased_call.args[i] = .from(templated_user_arg);
                }
            }

            const TemplateArgsTuple: type = std.meta.Tuple(template_parameters);

            fn NonTemplateArgsTuple(comptime Function: type) type {
                @setEvalBranchQuota(10_000);

                const info = @typeInfo(Function);
                if (info != .@"fn") {
                    @compileError("NonTemplateArgsTuple expects a function type");
                }

                const function_info = info.@"fn";
                if (function_info.is_var_args) {
                    @compileError("Cannot create NonTemplateArgsTuple for variadic function");
                }

                const function_params = function_info.params;

                if (function_params.len < template_parameters.len) {
                    @compileError(std.fmt.comptimePrint(
                        "`function` requires at least {d} parameters to match the template found {d}",
                        .{ template_parameters.len, function_params.len },
                    ));
                }

                const non_templated_parameter_count = function_params.len - template_parameters.len;

                var argument_field_list: [non_templated_parameter_count]type = undefined;
                inline for (function_info.params[template_parameters.len..], 0..) |arg, i| {
                    const T = arg.type orelse @compileError("cannot create NonTemplateArgsTuple for function with an 'anytype' parameter");
                    argument_field_list[i] = T;
                }

                return std.meta.Tuple(&argument_field_list);
            }
        };
    }

    pub const Arg = extern union {
        bool: bool,
        unsigned: usize,
        signed: isize,
        float: Float,
        bytes: [@sizeOf(usize)]u8,

        ptr: *anyopaque,
        ptr_allowzero: *allowzero anyopaque,
        ptr_volatile: *volatile anyopaque,
        ptr_allowzero_volatile: *allowzero volatile anyopaque,

        ptr_const: *const anyopaque,
        ptr_allowzero_const: *allowzero const anyopaque,
        ptr_const_volatile: *const volatile anyopaque,
        ptr_allowzero_const_volatile: *allowzero const volatile anyopaque,

        opt_ptr: ?*anyopaque,
        opt_ptr_volatile: ?*volatile anyopaque,

        opt_ptr_const: ?*const anyopaque,
        opt_ptr_const_volatile: ?*const volatile anyopaque,

        const Float = switch (@bitSizeOf(usize)) {
            32 => f32,
            64 => f64,
            else => @compileError("unsupported usize"),
        };

        inline fn from(user_arg: anytype) Arg {
            const UserArgT = @TypeOf(user_arg);
            if (comptime @sizeOf(UserArgT) > @sizeOf(usize)) {
                @compileError("type '" ++ @typeName(UserArgT) ++ "' is larger than a usize");
            }
            switch (@typeInfo(UserArgT)) {
                .void => return undefined,
                .bool => return .{ .bool = user_arg },
                .int => |int| return switch (int.signedness) {
                    .unsigned => .{ .unsigned = user_arg },
                    .signed => .{ .signed = user_arg },
                },
                .float => return .{ .float = user_arg },
                .pointer => |pointer| switch (pointer.size) {
                    .one, .many, .c => return @unionInit(
                        Arg,
                        "ptr" ++ (if (pointer.is_allowzero) "_allowzero" else "") ++ (if (pointer.is_const) "_const" else "") ++ if (pointer.is_volatile) "_volatile" else "",
                        user_arg,
                    ),
                    .slice => {}, // unsupported
                },
                .array => {
                    var arg: Arg = .{ .bytes = undefined };
                    @memcpy(arg.bytes[0..].ptr, std.mem.asBytes(&user_arg));
                    return arg;
                },
                .@"struct" => |stru| switch (stru.layout) {
                    .auto, .@"extern" => {
                        var arg: Arg = .{ .bytes = undefined };
                        @memcpy(arg.bytes[0..].ptr, std.mem.asBytes(&user_arg));
                        return arg;
                    },
                    .@"packed" => return switch (@typeInfo(stru.backing_integer.?).int.signedness) {
                        .unsigned => .{ .unsigned = @bitCast(user_arg) },
                        .signed => .{ .signed = @bitCast(user_arg) },
                    },
                },
                .undefined => return undefined,
                .null => return undefined,
                .optional => |optional| switch (@typeInfo(optional.child)) {
                    .pointer => |pointer| switch (pointer.size) {
                        .one, .many, .c => if (pointer.is_allowzero) {} // unsupported
                        else return @unionInit(
                            Arg,
                            "opt_ptr" ++ (if (pointer.is_allowzero) "_allowzero" else "") ++ (if (pointer.is_const) "_const" else "") ++ if (pointer.is_volatile) "_volatile" else "",
                            user_arg,
                        ),
                        .slice => {}, // unsupported
                    },
                    else => {
                        var arg: Arg = .{ .bytes = undefined };
                        @memcpy(arg.bytes[0..].ptr, std.mem.asBytes(&user_arg));
                        return arg;
                    },
                },
                .error_union => {
                    var arg: Arg = .{ .bytes = undefined };
                    @memcpy(arg.bytes[0..].ptr, std.mem.asBytes(&user_arg));
                    return arg;
                },
                .error_set => .{ .unsigned = @intFromError(user_arg) },
                .@"enum" => |enu| switch (@typeInfo(enu.tag_type).int.signedness) {
                    .unsigned => .{ .unsigned = @intFromEnum(user_arg) },
                    .signed => .{ .signed = @intFromEnum(user_arg) },
                },
                .@"union" => |unio| switch (unio.layout) {
                    .auto, .@"extern" => {
                        var arg: Arg = .{ .bytes = undefined };
                        @memcpy(arg.bytes[0..].ptr, std.mem.asBytes(&user_arg));
                        return arg;
                    },
                    .@"packed" => return switch (@typeInfo(unio.tag_type.?).int.signedness) {
                        .unsigned => .{ .unsigned = @bitCast(user_arg) },
                        .signed => .{ .signed = @bitCast(user_arg) },
                    },
                },
                .vector => |vector| {
                    var arg: Arg = .{ .bytes = undefined };
                    const slice = std.mem.bytesAsSlice(
                        vector.child,
                        arg.bytes[0 .. @sizeOf(vector.child) * vector.len],
                    );
                    slice.* = user_arg;
                    return arg;
                },
                .type,
                .noreturn,
                .comptime_float,
                .comptime_int,
                .@"fn",
                .@"opaque",
                .frame,
                .@"anyframe",
                .enum_literal,
                => {}, // unsupported
            }

            @compileError("unsupported type '" ++ @typeName(UserArgT) ++ "'");
        }

        inline fn to(arg: Arg, comptime UserArgT: type) UserArgT {
            switch (@typeInfo(UserArgT)) {
                .void => return {},
                .bool => return arg.bool,
                .int => |int| return switch (int.signedness) {
                    .unsigned => @truncate(arg.unsigned),
                    .signed => @truncate(arg.signed),
                },
                .float => return arg.float,
                .pointer => |pointer| return @ptrCast(@alignCast(
                    @field(arg, "ptr" ++ (if (pointer.is_allowzero) "_allowzero" else "") ++ (if (pointer.is_const) "_const" else "") ++ if (pointer.is_volatile) "_volatile" else ""),
                )),
                .array => {
                    var user_arg: UserArgT = undefined;
                    @memcpy(std.mem.asBytes(&user_arg), arg.bytes[0..].ptr);
                    return user_arg;
                },
                .@"struct" => |stru| switch (stru.layout) {
                    .auto, .@"extern" => {
                        var user_arg: UserArgT = undefined;
                        @memcpy(std.mem.asBytes(&user_arg), arg.bytes[0..].ptr);
                        return user_arg;
                    },
                    .@"packed" => {
                        const BackingInt = stru.backing_integer.?;
                        return switch (@typeInfo(BackingInt).int) {
                            .unsigned => @bitCast(@as(BackingInt, @truncate(arg.unsigned))),
                            .signed => @bitCast(@as(BackingInt, @truncate(arg.signed))),
                        };
                    },
                },
                .undefined => return undefined,
                .null => return null,
                .optional => |optional| switch (@typeInfo(optional.child)) {
                    .pointer => |pointer| if (pointer.is_allowzero) {} // unsupported
                    else return @ptrCast(@alignCast(
                        @field(arg, "opt_ptr" ++ (if (pointer.is_allowzero) "_allowzero" else "") ++ (if (pointer.is_const) "_const" else "") ++ if (pointer.is_volatile) "_volatile" else ""),
                    )),
                    else => {
                        var user_arg: UserArgT = undefined;
                        @memcpy(std.mem.asBytes(&user_arg), arg.bytes[0..].ptr);
                        return user_arg;
                    },
                },
                .error_union => {
                    var user_arg: UserArgT = undefined;
                    @memcpy(std.mem.asBytes(&user_arg), arg.bytes[0..].ptr);
                    return user_arg;
                },
                .error_set => return @errorCast(@errorFromInt(@as(
                    @Int(.unsigned, @bitSizeOf(anyerror)),
                    @truncate(arg.unsigned),
                ))),
                .@"enum" => |enu| {
                    const BackingInt = enu.tag_type;
                    return switch (@typeInfo(BackingInt).int) {
                        .unsigned => @enumFromInt(@as(BackingInt, @truncate(arg.unsigned))),
                        .signed => @enumFromInt(@as(BackingInt, @truncate(arg.signed))),
                    };
                },
                .@"union" => |unio| switch (unio.layout) {
                    .auto, .@"extern" => {
                        var user_arg: UserArgT = undefined;
                        @memcpy(std.mem.asBytes(&user_arg), arg.bytes[0..].ptr);
                        return user_arg;
                    },
                    .@"packed" => {
                        const BackingInt = unio.tag_type.?;
                        return switch (@typeInfo(BackingInt).int) {
                            .unsigned => @bitCast(@as(BackingInt, @truncate(arg.unsigned))),
                            .signed => @bitCast(@as(BackingInt, @truncate(arg.signed))),
                        };
                    },
                },
                .vector => |vector| return std.mem.bytesAsSlice(
                    vector.child,
                    arg.bytes[0 .. @sizeOf(vector.child) * vector.len],
                ).*,
                .type,
                .noreturn,
                .comptime_float,
                .comptime_int,
                .@"fn",
                .@"opaque",
                .frame,
                .@"anyframe",
                .enum_literal,
                => comptime unreachable,
            }
        }

        comptime {
            core.testing.expectSize(Arg, .of(usize));
        }
    };

    comptime {
        std.testing.refAllDecls(@This());
    }
};

fn typeErasedFn(comptime function: anytype) TypeErasedCall.TypeErasedFn {
    const fn_info = @typeInfo(@TypeOf(function)).@"fn";

    const can_error = comptime blk: {
        const ReturnType = fn_info.return_type orelse unreachable;

        if (ReturnType == void) break :blk false;
        if (ReturnType == noreturn) break :blk false;

        switch (@typeInfo(ReturnType)) {
            .error_union => |error_union| {
                if (error_union.payload == void) break :blk true;
                if (error_union.payload == noreturn) break :blk true;
            },
            else => {},
        }

        @compileError("`function` must have a return type of `void`, `noreturn`, `!void` or `!noreturn`");
    };

    const function_parameters = @typeInfo(@TypeOf(function)).@"fn".params;

    return switch (function_parameters.len) {
        0 => struct {
            fn typeErased0(
                _: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
            ) callconv(.c) void {
                return if (comptime can_error)
                    function() catch |err| std.debug.panic("unhandled error: {t}", .{err})
                else
                    function();
            }
        }.typeErased0,
        1 => struct {
            fn typeErased1(
                arg0: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
            ) callconv(.c) void {
                return if (comptime can_error)
                    function(
                        arg0.to(function_parameters[0].type orelse unreachable),
                    ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                else
                    function(
                        arg0.to(function_parameters[0].type orelse unreachable),
                    );
            }
        }.typeErased1,
        2 => struct {
            fn typeErased2(
                arg0: TypeErasedCall.Arg,
                arg1: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
            ) callconv(.c) void {
                return if (comptime can_error)
                    function(
                        arg0.to(function_parameters[0].type orelse unreachable),
                        arg1.to(function_parameters[1].type orelse unreachable),
                    ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                else
                    function(
                        arg0.to(function_parameters[0].type orelse unreachable),
                        arg1.to(function_parameters[1].type orelse unreachable),
                    );
            }
        }.typeErased2,
        3 => struct {
            fn typeErased3(
                arg0: TypeErasedCall.Arg,
                arg1: TypeErasedCall.Arg,
                arg2: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
            ) callconv(.c) void {
                return if (comptime can_error)
                    function(
                        arg0.to(function_parameters[0].type orelse unreachable),
                        arg1.to(function_parameters[1].type orelse unreachable),
                        arg2.to(function_parameters[2].type orelse unreachable),
                    ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                else
                    function(
                        arg0.to(function_parameters[0].type orelse unreachable),
                        arg1.to(function_parameters[1].type orelse unreachable),
                        arg2.to(function_parameters[2].type orelse unreachable),
                    );
            }
        }.typeErased3,
        4 => struct {
            fn typeErased4(
                arg0: TypeErasedCall.Arg,
                arg1: TypeErasedCall.Arg,
                arg2: TypeErasedCall.Arg,
                arg3: TypeErasedCall.Arg,
                _: TypeErasedCall.Arg,
            ) callconv(.c) void {
                return if (comptime can_error)
                    function(
                        arg0.to(function_parameters[0].type orelse unreachable),
                        arg1.to(function_parameters[1].type orelse unreachable),
                        arg2.to(function_parameters[2].type orelse unreachable),
                        arg3.to(function_parameters[3].type orelse unreachable),
                    ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                else
                    function(
                        arg0.to(function_parameters[0].type orelse unreachable),
                        arg1.to(function_parameters[1].type orelse unreachable),
                        arg2.to(function_parameters[2].type orelse unreachable),
                        arg3.to(function_parameters[3].type orelse unreachable),
                    );
            }
        }.typeErased4,
        5 => struct {
            fn typeErased5(
                arg0: TypeErasedCall.Arg,
                arg1: TypeErasedCall.Arg,
                arg2: TypeErasedCall.Arg,
                arg3: TypeErasedCall.Arg,
                arg4: TypeErasedCall.Arg,
            ) callconv(.c) void {
                return if (comptime can_error)
                    function(
                        arg0.to(function_parameters[0].type orelse unreachable),
                        arg1.to(function_parameters[1].type orelse unreachable),
                        arg2.to(function_parameters[2].type orelse unreachable),
                        arg3.to(function_parameters[3].type orelse unreachable),
                        arg4.to(function_parameters[4].type orelse unreachable),
                    ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                else
                    function(
                        arg0.to(function_parameters[0].type orelse unreachable),
                        arg1.to(function_parameters[1].type orelse unreachable),
                        arg2.to(function_parameters[2].type orelse unreachable),
                        arg3.to(function_parameters[3].type orelse unreachable),
                        arg4.to(function_parameters[4].type orelse unreachable),
                    );
            }
        }.typeErased5,
        else => @compileError(
            std.fmt.comptimePrint(
                "number of function parameters must be less than or equal to {d} found {d}",
                .{ TypeErasedCall.supported_number_of_args, function_parameters.len },
            ),
        ),
    };
}
