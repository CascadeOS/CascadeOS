// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

/// Stores a type erased call that supports passing up to four "argument slots".
///
/// Each supported argument type uses up one of the argument slots with exception of slices which use two.
///
/// The return type must be `void`, `noreturn`, `!void` or `!noreturn`.
///
/// If an error is returned then an "unhandled error" panic will occur.
///
/// Argument types that are always supported:
/// - bool
/// - pointer and optional pointer
/// - error set
/// - slice
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
    typeErased: TypeErasedFn,
    arg_slots: [number_of_arg_slots]usize,

    pub const TypeErasedFn = *const fn (usize, usize, usize, usize) callconv(.c) void;
    pub const number_of_arg_slots = 4;

    pub inline fn call(type_erased: TypeErasedCall) void {
        type_erased.typeErased(
            type_erased.arg_slots[0],
            type_erased.arg_slots[1],
            type_erased.arg_slots[2],
            type_erased.arg_slots[3],
        );
    }

    pub fn prepare(comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) TypeErasedCall {
        const returns_error = comptime blk: {
            const ReturnType = @typeInfo(@TypeOf(function)).@"fn".return_type.?;

            if (ReturnType == void or ReturnType == noreturn) break :blk false;

            switch (@typeInfo(ReturnType)) {
                .error_union => |error_union| {
                    if (error_union.payload == void or error_union.payload == noreturn) break :blk true;
                },
                else => {},
            }

            @compileError("`function` must have a return type of `void`, `noreturn`, `!void` or `!noreturn`");
        };

        // we check for any slices as in that case a more complex implementation is required
        const has_any_slices = comptime blk: {
            const args_info = @typeInfo(@TypeOf(args)).@"struct";
            std.debug.assert(args_info.is_tuple);

            var any_slices = false;
            var required_arg_slots = 0;

            for (args_info.fields) |field| {
                if (isSlice(field.type)) {
                    required_arg_slots += 2;
                    any_slices = true;
                } else {
                    required_arg_slots += 1;
                }
            }

            if (required_arg_slots > number_of_arg_slots) {
                @compileError(std.fmt.comptimePrint(
                    if (any_slices)
                        "only {d} argument slots supported found {d} (slices take up two argument slots)"
                    else
                        "only {d} argument slots supported found {d}",
                    .{ number_of_arg_slots, required_arg_slots },
                ));
            }

            break :blk any_slices;
        };

        var type_erased: TypeErasedCall = .{
            .typeErased = if (has_any_slices)
                struct {
                    fn typeErasedSlice(arg0: usize, arg1: usize, arg2: usize, arg3: usize) callconv(.c) void {
                        const raw_args: [number_of_arg_slots]usize = .{ arg0, arg1, arg2, arg3 };

                        var inner_args: std.meta.ArgsTuple(@TypeOf(function)) = undefined;

                        var raw_i: usize = 0;
                        inline for (&inner_args, 0..) |*arg, arg_i| {
                            if (isSlice(@TypeOf(args[arg_i]))) {
                                const ptr = argFromUsize(@TypeOf(args[arg_i].ptr), raw_args[raw_i]);
                                raw_i += 1;
                                const len = argFromUsize(@TypeOf(args[arg_i].len), raw_args[raw_i]);
                                raw_i += 1;
                                arg.* = ptr[0..len];
                            } else {
                                arg.* = argFromUsize(@TypeOf(args[arg_i]), raw_args[raw_i]);
                                raw_i += 1;
                            }
                        }

                        return if (returns_error)
                            @call(.auto, function, inner_args) catch |err| std.debug.panic(
                                "unhandled error: {t}",
                                .{err},
                            )
                        else
                            @call(.auto, function, inner_args);
                    }
                }.typeErasedSlice
            else switch (comptime args.len) {
                0 => struct {
                    fn typeErased0Args(_: usize, _: usize, _: usize, _: usize) callconv(.c) void {
                        return if (returns_error)
                            function() catch |err| std.debug.panic("unhandled error: {t}", .{err})
                        else
                            function();
                    }
                }.typeErased0Args,
                1 => struct {
                    fn typeErased1Args(arg0: usize, _: usize, _: usize, _: usize) callconv(.c) void {
                        return if (returns_error)
                            function(
                                argFromUsize(@TypeOf(args[0]), arg0),
                            ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                        else
                            function(
                                argFromUsize(@TypeOf(args[0]), arg0),
                            );
                    }
                }.typeErased1Args,
                2 => struct {
                    fn typeErased2Args(arg0: usize, arg1: usize, _: usize, _: usize) callconv(.c) void {
                        return if (returns_error)
                            function(
                                argFromUsize(@TypeOf(args[0]), arg0),
                                argFromUsize(@TypeOf(args[1]), arg1),
                            ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                        else
                            function(
                                argFromUsize(@TypeOf(args[0]), arg0),
                                argFromUsize(@TypeOf(args[1]), arg1),
                            );
                    }
                }.typeErased2Args,
                3 => struct {
                    fn typeErased3Ags(arg0: usize, arg1: usize, arg2: usize, _: usize) callconv(.c) void {
                        return if (returns_error)
                            function(
                                argFromUsize(@TypeOf(args[0]), arg0),
                                argFromUsize(@TypeOf(args[1]), arg1),
                                argFromUsize(@TypeOf(args[2]), arg2),
                            ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                        else
                            function(
                                argFromUsize(@TypeOf(args[0]), arg0),
                                argFromUsize(@TypeOf(args[1]), arg1),
                                argFromUsize(@TypeOf(args[2]), arg2),
                            );
                    }
                }.typeErased3Ags,
                4 => struct {
                    fn typeErased4Args(arg0: usize, arg1: usize, arg2: usize, arg3: usize) callconv(.c) void {
                        return if (returns_error)
                            function(
                                argFromUsize(@TypeOf(args[0]), arg0),
                                argFromUsize(@TypeOf(args[1]), arg1),
                                argFromUsize(@TypeOf(args[2]), arg2),
                                argFromUsize(@TypeOf(args[3]), arg3),
                            ) catch |err| std.debug.panic("unhandled error: {t}", .{err})
                        else
                            function(
                                argFromUsize(@TypeOf(args[0]), arg0),
                                argFromUsize(@TypeOf(args[1]), arg1),
                                argFromUsize(@TypeOf(args[2]), arg2),
                                argFromUsize(@TypeOf(args[3]), arg3),
                            );
                    }
                }.typeErased4Args,
                else => unreachable,
            },
            .arg_slots = undefined,
        };

        var arg_slot: usize = 0;
        inline for (args) |arg| {
            if (isSlice(@TypeOf(arg))) {
                type_erased.arg_slots[arg_slot] = usizeFromArg(arg.ptr);
                arg_slot += 1;
                type_erased.arg_slots[arg_slot] = usizeFromArg(arg.len);
                arg_slot += 1;
            } else {
                type_erased.arg_slots[arg_slot] = usizeFromArg(arg);
                arg_slot += 1;
            }
        }

        return type_erased;
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

inline fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => true,
            else => false,
        },
        else => false,
    };
}
