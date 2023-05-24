const build = @import("../build.zig");
const LibraryDescription = build.LibraryDescription;

pub const libraries: []const LibraryDescription = &.{
    .{ .name = "core" },
};
