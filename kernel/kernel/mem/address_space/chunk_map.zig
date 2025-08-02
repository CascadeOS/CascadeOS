// SPDX-License-Identifier: MIT and BSD-2-Clause
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn ChunkMap(comptime T: type) type {
    return struct {
        chunks: std.AutoHashMapUnmanaged(u32, Chunk) = .{},

        const Chunk = [slots_per_chunk]?*T;

        pub fn get(chunk_map: *const @This(), index: u32) ?*T {
            const chunk = chunk_map.getChunk(index) orelse return null;
            return chunk[chunkOffset(index)];
        }

        pub fn getChunk(chunk_map: *const @This(), index: u32) ?*Chunk {
            return chunk_map.chunks.getPtr(chunkIndex(index)) orelse null;
        }

        pub fn ensureChunk(chunk_map: *@This(), index: u32) !*Chunk {
            const chunk = try chunk_map.chunks.getOrPut(kernel.mem.heap.allocator, chunkIndex(index));
            if (!chunk.found_existing) {
                chunk.value_ptr.* = @splat(null);
            }
            return chunk.value_ptr;
        }

        pub inline fn chunkIndex(index: u32) u32 {
            // valid as `slots_per_chunk` is a power of two
            return index >> slots_per_chunk_shift;
        }

        pub inline fn chunkOffset(index: u32) u32 {
            // valid as `slots_per_chunk` is a power of two
            return index & (slots_per_chunk - 1);
        }
    };
}

const slots_per_chunk_shift = std.math.log2(slots_per_chunk);
const slots_per_chunk = 16;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(slots_per_chunk));
}

const std = @import("std");
const kernel = @import("kernel");
