// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

const cascade = @import("cascade");

/// Exports the cascade entry point, must be called at comptime, a pub `_start` decl must also be declared in the root file:
///
/// ```zig
/// pub const _start = void;
/// comptime {
///     cascade.exportEntry();
/// }
/// ```
pub fn exportEntry() void {
    comptime if (@import("cascade_flag").is_cascade) @export(&_cascade_entry, .{ .name = "_start" });
}

fn _cascade_entry() callconv(.naked) noreturn {
    if (builtin.unwind_tables != .none or !builtin.strip_debug_info) {
        switch (builtin.cpu.arch) {
            .aarch64 => asm volatile (".cfi_undefined lr"),
            .riscv64 => if (builtin.zig_backend != .stage2_riscv64) asm volatile (".cfi_undefined ra"),
            .x86_64 => asm volatile (".cfi_undefined %%rip"),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        }
    }

    if (builtin.cpu.arch == .riscv64 and builtin.zig_backend != .stage2_riscv64) {
        asm volatile (
            \\ .weak __global_pointer$
            \\ .hidden __global_pointer$
            \\ .option push
            \\ .option norelax
            \\ lla gp, __global_pointer$
            \\ .option pop
        );
    }

    asm volatile (switch (builtin.cpu.arch) {
            .aarch64 =>
            \\mov fp, #0
            \\mov lr, #0
            \\mov x0, sp
            \\and sp, x0, #-16
            \\b %[callMainAndExit]
            ,
            .riscv64 =>
            \\li fp, 0
            \\li ra, 0
            \\mv a0, sp
            \\andi sp, sp, -16
            \\tail %[callMainAndExit]@plt
            ,
            .x86_64 =>
            \\xor %%ebp, %%ebp
            \\mov %%rsp, %%rdi
            \\and $-16, %%rsp
            \\callq %[callMainAndExit:P]
            ,
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        }
        :
        : [callMainAndExit] "X" (&callMainAndExit),
    );
}

fn callMainAndExit(entry_stack_pointer: [*]usize) callconv(.c) noreturn {
    _ = entry_stack_pointer;

    @setRuntimeSafety(false);
    @disableInstrumentation();

    // TODO: perform relocation `std.pie.relocate`
    if (builtin.link_mode == .static and builtin.position_independent_executable) {
        @panic("position independent executables not supported");
    }

    const opt_init_array_start = @extern([*]const *const fn () callconv(.c) void, .{
        .name = "__init_array_start",
        .linkage = .weak,
    });
    const opt_init_array_end = @extern([*]const *const fn () callconv(.c) void, .{
        .name = "__init_array_end",
        .linkage = .weak,
    });
    if (opt_init_array_start) |init_array_start| {
        const init_array_end = opt_init_array_end.?;
        const slice = init_array_start[0 .. init_array_end - init_array_start];
        for (slice) |func| func();
    }

    const env_block: std.process.Environ.Block = .empty; // TODO: enviroment vars are not supported for `.os == .other`

    // TODO: support threaded io
    // if (std.Options.debug_threaded_io) |t| {
    //     t.environ = .{ .process_environ = .{ .block = env_block } };
    // }

    // TODO: std.Thread.maybeAttachSignalStack();
    // TODO: std.debug.maybeEnableSegfaultHandler();

    const return_value = callMain(
        {}, // TODO: args are not supported for `.os == .other`
        env_block,
    );
    _ = return_value; // TODO: don't just throw this away

    // TODO: exit the process rather than just the current thread
    cascade.exitThread();
}

inline fn callMain(args: std.process.Args.Vector, environ: std.process.Environ.Block) u8 {
    const fn_info = @typeInfo(@TypeOf(root.main)).@"fn";
    if (fn_info.params.len == 0) return wrapMain(root.main());
    if (fn_info.params[0].type.? == std.process.Init.Minimal) return wrapMain(root.main(.{
        .args = .{ .vector = args },
        .environ = .{ .block = environ },
    }));

    // TODO: support all the stuff below
    @compileError("juicy main is unsupported");

    // const gpa = if (use_debug_allocator)
    //     debug_allocator.allocator()
    // else if (!builtin.single_threaded)
    //     std.heap.smp_allocator
    // else
    //     comptime unreachable;

    // defer if (use_debug_allocator) {
    //     _ = debug_allocator.deinit(); // Leaks do not affect return code.
    // };

    // var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena_allocator.deinit();

    // var threaded: std.Io.Threaded = .init(gpa, .{
    //     .argv0 = .init(.{ .vector = args }),
    //     .environ = .{ .block = environ },
    // });
    // defer threaded.deinit();

    // var environ_map = std.process.Environ.createMap(.{ .block = environ }, gpa) catch |err|
    //     std.process.fatal("failed to parse environment variables: {t}", .{err});
    // defer environ_map.deinit();

    // const preopens = std.process.Preopens.init(arena_allocator.allocator()) catch |err|
    //     std.process.fatal("failed to init preopens: {t}", .{err});

    // return wrapMain(root.main(.{
    //     .minimal = .{
    //         .args = .{ .vector = args },
    //         .environ = .{ .block = environ },
    //     },
    //     .arena = &arena_allocator,
    //     .gpa = gpa,
    //     .io = threaded.io(),
    //     .environ_map = &environ_map,
    //     .preopens = preopens,
    // }));
}

inline fn wrapMain(result: anytype) u8 {
    const ReturnType = @TypeOf(result);
    switch (ReturnType) {
        void => return 0,
        noreturn => unreachable,
        u8 => return result,
        else => {},
    }
    if (@typeInfo(ReturnType) != .error_union) @compileError(bad_main_ret);

    const unwrapped_result = result catch |err| {
        std.log.err("{t}", .{err});

        // TODO: need to implement some io stuff
        // if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace);

        return 1;
    };

    return switch (@TypeOf(unwrapped_result)) {
        noreturn => unreachable,
        void => 0,
        u8 => unwrapped_result,
        else => @compileError(bad_main_ret),
    };
}

const bad_main_ret = "expected return type of main to be 'void', '!void', 'noreturn', 'u8', or '!u8'";
