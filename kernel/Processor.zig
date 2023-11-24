// SPDX-License-Identifier: MIT

//! Represents a single execution resource.
//!
//! Even though this is called `Processor` it represents a single core in a multi-core system.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const Processor = @This();

id: usize,

panicked: bool = false,

_arch: kernel.arch.ArchProcessor,

pub inline fn arch(self: *Processor) *kernel.arch.ArchProcessor {
    return &self._arch;
}

pub const format = core.formatStructIgnoreReservedAndHiddenFields;
