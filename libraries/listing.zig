const LibraryDescription = @import("../.build/LibraryDescription.zig");

pub const libraries: []const LibraryDescription = &.{
    .{ .name = "ansi" },
    .{ .name = "bitjuggle" },
    .{ .name = "core" },
    .{ .name = "uuid", .dependencies = &.{"core"} },
};
