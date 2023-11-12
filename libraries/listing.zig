const LibraryDescription = @import("../build/LibraryDescription.zig");

pub const libraries: []const LibraryDescription = &.{
    .{ .name = "ansi" },
    .{ .name = "bitjuggle" },
    .{ .name = "containers", .dependencies = &.{ "core", "bitjuggle" } },
    .{ .name = "core" },
    .{ .name = "fs", .dependencies = &.{ "core", "uuid" } },
    .{ .name = "limine", .dependencies = &.{"core"} },
    .{ .name = "uuid", .dependencies = &.{"core"} },
};
