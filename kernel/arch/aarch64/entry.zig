// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

const limine = kernel.spec.limine;

fn setup(bootloader: Bootloader) noreturn {
    _ = bootloader;

    @panic("UNIMPLEMENTED"); // TODO: implement initial system setup
}

const Bootloader = enum {
    unknown,
    limine,
};

/// Generic entry point.
export fn _start() callconv(.Naked) noreturn {
    @call(.never_inline, setup, .{.unknown});
    @panic("setup returned");
}

/// Entry point for limine.
export fn _limine_start() callconv(.Naked) noreturn {
    @call(.never_inline, setup, .{.limine});
    @panic("setup returned");
}

export var limine_entry_point_request = limine.EntryPoint{
    .entry = _limine_start,
};
