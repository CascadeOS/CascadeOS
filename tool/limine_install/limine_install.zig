// SPDX-License-Identifier: LicenseRef-NON-AI-MIT OR MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: Copyright (c) 2025 Zig OSDev Community (https://github.com/zig-osdev/zig-limine-install)

const std = @import("std");

pub fn main() u8 {
    const parse_args_result = parseArgs(std.heap.smp_allocator);

    const cwd = std.fs.cwd();
    cwd.copyFile(
        parse_args_result.input_file_path,
        cwd,
        parse_args_result.output_file_path,
        .{},
    ) catch |e| err("failed to copy file '{s}' to '{s}': {t}", .{
        parse_args_result.input_file_path,
        parse_args_result.output_file_path,
        e,
    });

    return @intCast(limine_main(
        @intCast(parse_args_result.limine_arguments.len),
        parse_args_result.limine_arguments.ptr,
    ));
}

const ParseArgResult = struct {
    input_file_path: []const u8,
    output_file_path: []const u8,

    limine_arguments: []const [*:0]const u8,
};

fn parseArgs(allocator: std.mem.Allocator) ParseArgResult {
    var args: std.process.ArgIterator = try .initWithAllocator(allocator);
    if (!args.skip()) err("no self path argument", .{});

    var limine_arguments: std.ArrayListUnmanaged([*:0]const u8) = .{};
    limine_arguments.appendSlice(allocator, &.{ "limine", "bios-install" }) catch err("out of memory", .{});

    var opt_output_file_path: ?[:0]const u8 = null;
    var opt_input_file_path: ?[:0]const u8 = null;
    var opt_partition_index: ?[*:0]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, "-o", arg)) {
            opt_output_file_path = args.next() orelse err("expected output file path after '-o'", .{});
        } else if (std.mem.eql(u8, "-i", arg)) {
            opt_input_file_path = args.next() orelse err("expected input file path after '-i'", .{});
        } else if (std.mem.eql(u8, "-p", arg)) {
            opt_partition_index = args.next() orelse err("expected partition index after '-p'", .{});
        } else {
            limine_arguments.append(allocator, arg.ptr) catch err("out of memory", .{});
        }
    }

    const output_file_path = opt_output_file_path orelse err("output file path not provided", .{});
    limine_arguments.append(allocator, output_file_path.ptr) catch err("out of memory", .{});

    limine_arguments.append(allocator, "--quiet") catch err("out of memory", .{});

    if (opt_partition_index) |partition_index| {
        limine_arguments.append(allocator, partition_index) catch err("out of memory", .{});
    }

    return .{
        .input_file_path = opt_input_file_path orelse err("input file path not provided", .{}),
        .output_file_path = output_file_path,
        .limine_arguments = limine_arguments.toOwnedSlice(allocator) catch err("out of memory", .{}),
    };
}

fn err(comptime msg: []const u8, args: anytype) noreturn {
    if (msg.len != 0) {
        if (msg[msg.len - 1] != '\n')
            std.debug.print(msg ++ "\n", args)
        else
            std.debug.print(msg, args);
    }
    std.process.exit(1);
}

extern fn limine_main(argc: c_int, argv: [*]const [*:0]const u8) c_int;

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
