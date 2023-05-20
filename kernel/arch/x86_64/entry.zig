// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

const limine = kernel.spec.limine;

/// Generic entry point.
export fn _start() callconv(.Naked) noreturn {
    while (true) {}
}

/// Entry point for limine.
export fn _limine_start() callconv(.Naked) noreturn {
    while (true) {}
}

export var limine_entry_point_request = limine.EntryPoint{
    .entry = _limine_start,
};
