// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const KernelComponent = @This();

/// The name of the kernel component:
///   - used as the name of the module provided `@import("{name}");`
///   - used to build the root file path `kernel/{name}/{name}.zig`
name: []const u8,

/// The other kernel components that this component can access via `@import`.
component_dependencies: []const Dependency = &.{},

/// The libraries that this component can access via `@import`.
library_dependencies: []const Dependency = &.{},

pub const Dependency = struct {
    name: []const u8,
    condition: Condition = .always,

    pub const Condition = union(enum) {
        always,
        architecture: []const CascadeTarget.Architecture,
    };
};

const std = @import("std");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
