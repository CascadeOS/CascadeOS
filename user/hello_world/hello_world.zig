// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: CascadeOS Contributors

const cascade = @import("cascade");

pub fn main() void {
    // TODO: actually print "hello world"...
}

// TODO: we only want this decl when building for cascade, this is not currently possible - needs seperate root files atm
pub const _start = void;
comptime {
    cascade.exportEntry();
}
