const LibraryDescription = @import("../.build/LibraryDescription.zig");

pub const libraries: []const LibraryDescription = &.{
    .{ .name = "bitjuggle" },
    .{ .name = "core" },
};
