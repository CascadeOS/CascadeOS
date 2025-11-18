// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

/// Stores a type erased call that supports passing `supported_number_of_args` arguments.
///
/// The return type must be `void`, `noreturn`, `!void` or `!noreturn`.
///
/// If an error is returned then an "unhandled error" panic will occur.
///
/// Argument types that are always supported:
/// - bool
/// - pointer and optional pointer
/// - error set
///
/// Argument types that are supported if its size is less than or equal to the size of `usize`:
/// - int
/// - float
/// - array
/// - struct, packed struct and extern struct
/// - optional
/// - enum
/// - union, tagged union, packed union and extern union
pub const TypeErasedCall = extern struct {
    typeErased: *const TypeErasedFn,
    args: [supported_number_of_args]usize,

    pub const supported_number_of_args = 5;

    pub const TypeErasedFn = fn (usize, usize, usize, usize, usize) callconv(.c) void;

    pub inline fn call(type_erased: TypeErasedCall) void {
        type_erased.typeErased(
            type_erased.args[0],
            type_erased.args[1],
            type_erased.args[2],
            type_erased.args[3],
            type_erased.args[4],
        );
    }

    pub fn prepare(comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) TypeErasedCall {
        var type_erased: TypeErasedCall = .{
            .typeErased = typeErasedFn(function),
            .args = undefined,
        };

        inline for (args, 0..) |arg, i| {
            type_erased.args[i] = usizeFromArg(arg);
        }

        return type_erased;
    }

    /// Create a templated type erased call that supports passing `supported_number_of_args` arguments.
    ///
    /// The first parameters of the function must match the provided `template_parameters`.
    ///
    /// The return type must be `void`, `noreturn`, `!void` or `!noreturn`.
    ///
    /// If an error is returned then an "unhandled error" panic will occur.
    ///
    /// Argument types that are always supported:
    /// - bool
    /// - pointer and optional pointer
    /// - error set
    ///
    /// Argument types that are supported if its size is less than or equal to the size of `usize`:
    /// - int
    /// - float
    /// - array
    /// - struct, packed struct and extern struct
    /// - optional
    /// - enum
    /// - union, tagged union, packed union and extern union
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
            pub fn prepare(comptime function: anytype, args: NonTemplateArgsTuple(@TypeOf(function))) @This() {
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

                    for (function_parameters[0..template_parameters.len], template_parameters, 0..) |function_parameter, template_parameter, i| {
                        if (function_parameter.type.? != template_parameter) {
                            @compileError(
                                std.fmt.comptimePrint(
                                    "function parameter {d} with type '{s}' does not match template parameter with type '{s}'",
                                    .{ i, @typeName(function_parameter.type.?), @typeName(template_parameter) },
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

                inline for (args, template_parameters.len..) |arg, i| {
                    templated_type_erased.type_erased_call.args[i] = usizeFromArg(arg);
                }

                return templated_type_erased;
            }

            pub fn setTemplatedArgs(templated_type_erased: *@This(), template_args: TemplateArgsTuple) void {
                inline for (template_args, 0..) |arg, i| {
                    templated_type_erased.type_erased_call.args[i] = usizeFromArg(arg);
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
};

inline fn usizeFromArg(arg: anytype) usize {
    const ArgT = @TypeOf(arg);
    if (comptime @sizeOf(ArgT) > @sizeOf(usize)) {
        @compileError("type '" ++ @typeName(ArgT) ++ "' is larger than a usize");
    }
    switch (@typeInfo(ArgT)) {
        .bool => return @intFromBool(arg),
        .int => |int| return if (int.signedness == .signed) @bitCast(@as(isize, arg)) else arg,
        .float => {
            const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @bitCast(arg);
            return int_value;
        },
        .pointer => return @intFromPtr(arg),
        .array => {
            const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @bitCast(arg);
            return int_value;
        },
        .@"struct" => |stru| {
            switch (stru.layout) {
                .@"extern", .@"packed" => {
                    const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @bitCast(arg);
                    return int_value;
                },
                .auto => {},
            }
            const bytes = std.mem.asBytes(&arg);
            const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @bitCast(bytes.*);
            return int_value;
        },
        .optional => |opt| {
            if (comptime @typeInfo(opt.child) != .pointer) {
                const bytes = std.mem.asBytes(&arg);
                const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @bitCast(bytes.*);
                return int_value;
            }
            return @intFromPtr(arg);
        },
        .error_set => return @intFromError(arg),
        .@"enum" => |enu| return if (@typeInfo(enu.tag_type).int.signedness == .signed)
            @bitCast(@intFromEnum(arg))
        else
            return @intFromEnum(arg),
        .@"union" => |uni| {
            switch (uni.layout) {
                .@"extern", .@"packed" => {
                    const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @bitCast(arg);
                    return int_value;
                },
                .auto => {},
            }
            const bytes = std.mem.asBytes(&arg);
            const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @bitCast(bytes.*);
            return int_value;
        },
        else => @compileError("unsupported type '" ++ @typeName(ArgT) ++ "'"),
    }
}

inline fn argFromUsize(comptime ArgT: type, value: usize) ArgT {
    switch (@typeInfo(ArgT)) {
        .bool => return value != 0,
        .int => |int| {
            if (int.signedness == .signed) {
                const signed_value: isize = @bitCast(value);
                return @truncate(signed_value);
            }
            return @truncate(value);
        },
        .float => {
            const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @truncate(value);
            return @bitCast(int_value);
        },
        .pointer => return @ptrFromInt(value),
        .array => {
            const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @truncate(value);
            return @bitCast(int_value);
        },
        .@"struct" => |stru| {
            switch (stru.layout) {
                .@"extern", .@"packed" => {
                    const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @truncate(value);
                    return @bitCast(int_value);
                },
                .auto => {},
            }
            const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @truncate(value);
            return std.mem.bytesToValue(ArgT, std.mem.asBytes(&int_value));
        },
        .optional => |opt| {
            if (comptime @typeInfo(opt.child) != .pointer) {
                const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @truncate(value);
                return std.mem.bytesToValue(ArgT, std.mem.asBytes(&int_value));
            }
            return @ptrFromInt(value);
        },
        .error_set => {
            const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @truncate(value);
            return @errorCast(@errorFromInt(int_value));
        },
        .@"enum" => |enu| {
            if (@typeInfo(enu.tag_type).int.signedness == .signed) {
                const signed_value: isize = @bitCast(value);
                return @enumFromInt(@as(enu.tag_type, @truncate(signed_value)));
            }
            return @enumFromInt(@as(enu.tag_type, @truncate(value)));
        },
        .@"union" => |uni| {
            switch (uni.layout) {
                .@"extern", .@"packed" => {
                    const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @truncate(value);
                    return @bitCast(int_value);
                },
                .auto => {},
            }
            const int_value: std.meta.Int(.unsigned, @sizeOf(ArgT) * 8) = @truncate(value);
            return std.mem.bytesToValue(ArgT, std.mem.asBytes(&int_value));
        },
        else => unreachable, // `usizeFromArg` prevents us from reaching here
    }
}

fn typeErasedFn(comptime function: anytype) TypeErasedCall.TypeErasedFn {
    const fn_info = @typeInfo(@TypeOf(function)).@"fn";

    const returns_error = comptime blk: {
        const ReturnType = fn_info.return_type.?;

        if (ReturnType == void or ReturnType == noreturn) break :blk false;

        switch (@typeInfo(ReturnType)) {
            .error_union => |error_union| {
                if (error_union.payload == void or error_union.payload == noreturn) break :blk true;
            },
            else => {},
        }

        @compileError("`function` must have a return type of `void`, `noreturn`, `!void` or `!noreturn`");
    };

    const function_parameters = @typeInfo(@TypeOf(function)).@"fn".params;

    return switch (function_parameters.len) {
        0 => struct {
            fn typeErased0Args(_: usize, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
                return if (returns_error)
                    function() catch |err| std.debug.panic("unhandled error: {t}", .{err})
                else
                    function();
            }
        }.typeErased0Args,
        1 => struct {
            fn typeErased1Args(arg0: usize, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
                return if (returns_error)
                    function(
                        argFromUsize(function_parameters[0].type.?, arg0),
                    ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                else
                    function(
                        argFromUsize(function_parameters[0].type.?, arg0),
                    );
            }
        }.typeErased1Args,
        2 => struct {
            fn typeErased2Args(arg0: usize, arg1: usize, _: usize, _: usize, _: usize) callconv(.c) void {
                return if (returns_error)
                    function(
                        argFromUsize(function_parameters[0].type.?, arg0),
                        argFromUsize(function_parameters[1].type.?, arg1),
                    ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                else
                    function(
                        argFromUsize(function_parameters[0].type.?, arg0),
                        argFromUsize(function_parameters[1].type.?, arg1),
                    );
            }
        }.typeErased2Args,
        3 => struct {
            fn typeErased3Ags(arg0: usize, arg1: usize, arg2: usize, _: usize, _: usize) callconv(.c) void {
                return if (returns_error)
                    function(
                        argFromUsize(function_parameters[0].type.?, arg0),
                        argFromUsize(function_parameters[1].type.?, arg1),
                        argFromUsize(function_parameters[2].type.?, arg2),
                    ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                else
                    function(
                        argFromUsize(function_parameters[0].type.?, arg0),
                        argFromUsize(function_parameters[1].type.?, arg1),
                        argFromUsize(function_parameters[2].type.?, arg2),
                    );
            }
        }.typeErased3Ags,
        4 => struct {
            fn typeErased4Args(arg0: usize, arg1: usize, arg2: usize, arg3: usize, _: usize) callconv(.c) void {
                return if (returns_error)
                    function(
                        argFromUsize(function_parameters[0].type.?, arg0),
                        argFromUsize(function_parameters[1].type.?, arg1),
                        argFromUsize(function_parameters[2].type.?, arg2),
                        argFromUsize(function_parameters[3].type.?, arg3),
                    ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                else
                    function(
                        argFromUsize(function_parameters[0].type.?, arg0),
                        argFromUsize(function_parameters[1].type.?, arg1),
                        argFromUsize(function_parameters[2].type.?, arg2),
                        argFromUsize(function_parameters[3].type.?, arg3),
                    );
            }
        }.typeErased4Args,
        5 => struct {
            fn typeErased5Args(arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) callconv(.c) void {
                return if (returns_error)
                    function(
                        argFromUsize(function_parameters[0].type.?, arg0),
                        argFromUsize(function_parameters[1].type.?, arg1),
                        argFromUsize(function_parameters[2].type.?, arg2),
                        argFromUsize(function_parameters[3].type.?, arg3),
                        argFromUsize(function_parameters[4].type.?, arg4),
                    ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                else
                    function(
                        argFromUsize(function_parameters[0].type.?, arg0),
                        argFromUsize(function_parameters[1].type.?, arg1),
                        argFromUsize(function_parameters[2].type.?, arg2),
                        argFromUsize(function_parameters[3].type.?, arg3),
                        argFromUsize(function_parameters[4].type.?, arg4),
                    );
            }
        }.typeErased5Args,
        else => @compileError(
            std.fmt.comptimePrint(
                "number of function parameters must be less than or equal to {d} found {d}",
                .{ TypeErasedCall.supported_number_of_args, function_parameters.len },
            ),
        ),
    };
}
