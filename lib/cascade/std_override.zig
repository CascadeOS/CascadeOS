// SPDX-License-Identifier: 0BSD
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const cascade = @import("cascade");

pub const std_options = struct {
    pub const debug_threaded_io: ?*std.Io.Threaded = null; // TODO
    pub const debug_io: std.Io = undefined; // TODO
    pub const FilePermissions = enum {}; // TODO
    pub const cwd: std.Io.Dir = undefined; // TODO

    pub fn debugInfoSearchPaths(exe_path: []const u8) std.debug.ElfFile.DebugInfoSearchPaths {
        _ = exe_path;
        // TODO
        return .{
            .debuginfod_client = null,
            .global_debug = &.{},
            .exe_dir = null,
        };
    }
};

pub const debug = struct {
    pub const SelfInfo = void; // TODO

    pub fn handleSegfault(addr: ?usize, name: []const u8, opt_ctx: ?std.debug.CpuContextPtr) noreturn {
        _ = addr;
        _ = name;
        _ = opt_ctx;
        // TODO
        @panic("SEGFAULT");
    }
};

pub const heap = struct {
    pub const page_size_min = cascade.page_size;
    pub const page_size_max = page_size_min; // TODO

    pub fn queryPageSize() usize {
        return page_size_min;
    }
};

pub const os = struct {
    pub const PATH_MAX = 4096; // TODO
    pub const NAME_MAX = 256; // TODO

    pub const heap = struct {
        pub const page_allocator: std.mem.Allocator = undefined; // TODO
    };
};

pub const panic = std.debug.FullPanic(struct {
    fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        _ = msg;
        _ = first_trace_addr;
        // TODO
        @trap();
    }
}.panic);
