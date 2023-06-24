const LibraryDescription = @import("../.build/LibraryDescription.zig");

pub const libraries: []const LibraryDescription = &.{
    .{ .name = "ansi" },
    .{ .name = "bitjuggle" },
    .{ .name = "core" },
    .{ .name = "fs", .dependencies = &.{ "core", "uuid" } },
    .{ .name = "uuid", .dependencies = &.{"core"} },
};
