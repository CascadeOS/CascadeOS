// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");

pub fn AtomicBitSet(comptime size: usize) type {
    return extern struct {
        const Self = @This();

        const AtomicUsize = std.atomic.Value(usize);

        /// The bit masks, ordered with lower indices first.
        /// Padding bits at the end are undefined.
        masks: [num_masks]AtomicUsize,

        /// Creates a bit set with all elements present.
        pub fn initFull() Self {
            if (num_masks == 0) {
                return .{ .masks = .{} };
            } else {
                return .{
                    .masks = [_]AtomicUsize{AtomicUsize.init(~@as(usize, 0))} ** (num_masks - 1) ++
                        [_]AtomicUsize{AtomicUsize.init(last_item_mask)},
                };
            }
        }

        pub fn set(self: *Self, index: usize) void {
            core.assert(index < size);

            const mask_bit = maskBit(index);
            const mask_index = maskIndex(index);

            const target_mask = &self.masks[mask_index];

            var old_mask = target_mask.load(.acquire);

            while (true) {
                if (target_mask.cmpxchgWeak(
                    old_mask,
                    old_mask | mask_bit,
                    .acq_rel,
                    .acquire,
                )) |val| {
                    old_mask = val;
                    continue;
                }

                return;
            }
        }

        /// Returns true if all the bits are unset.
        pub fn allUnset(self: *const Self) bool {
            for (&self.masks) |*mask| {
                if (mask.load(.acquire) != 0) return false;
            }

            return true;
        }

        /// Returns true if all the bits are set.
        pub fn allSet(self: *const Self) bool {
            if (num_masks > 1) {
                for (self.masks[0 .. num_masks - 1]) |*mask| {
                    if (mask.load(.acquire) != std.math.maxInt(usize)) return false;
                }
            }

            if (self.masks[num_masks - 1].load(.acquire) != std.math.maxInt(usize) & last_item_mask) return false;

            return true;
        }

        /// Finds the index of the first set bit, and unsets it.
        ///
        /// If no bits are set, returns null.
        pub fn toggleFirstSet(self: *Self) ?usize {
            var offset: usize = 0;

            for (&self.masks) |*mask| {
                var mask_value = mask.load(.acquire);

                while (mask_value != 0) {
                    const index = @ctz(mask_value);

                    if (mask.cmpxchgWeak(
                        mask_value,
                        mask_value & (mask_value - 1),
                        .acq_rel,
                        .acquire,
                    )) |val| {
                        mask_value = val;
                        continue;
                    }

                    return offset + index;
                }

                offset += @bitSizeOf(usize);
            }

            return null;
        }

        /// The integer type used to shift a mask in this bit set
        const ShiftInt = std.math.Log2Int(usize);

        /// bits in one mask
        const mask_len = @bitSizeOf(usize);
        /// total number of masks
        const num_masks = (size + mask_len - 1) / mask_len;
        /// padding bits in the last mask (may be 0)
        const last_pad_bits = mask_len * num_masks - size;
        /// Mask of valid bits in the last mask.
        /// All functions will ensure that the invalid
        /// bits in the last mask are zero.
        const last_item_mask = ~@as(usize, 0) >> last_pad_bits;

        fn maskBit(index: usize) usize {
            return @as(usize, 1) << @as(ShiftInt, @truncate(index));
        }
        fn maskIndex(index: usize) usize {
            return index >> @bitSizeOf(ShiftInt);
        }

        comptime {
            core.assert(num_masks != 0);
        }
    };
}

comptime {
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (switch (@typeInfo(T)) {
        .Struct => |info| info.decls,
        .Enum => |info| info.decls,
        .Union => |info| info.decls,
        .Opaque => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
