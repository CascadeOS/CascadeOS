const ToolDescription = @import("../.build/ToolDescription.zig");

pub const tools: []const ToolDescription = &.{
    .{ .name = "image_builder", .dependencies = &.{ "core", "fs", "uuid" } },
};
