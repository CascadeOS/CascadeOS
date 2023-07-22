// SPDX-License-Identifier: MIT
//
// Originally from [Florence](https://github.com/FlorenceOS/Florence/blob/master/lib/util/bitfields.zig) (see LICENSE-FLORENCE for original license)
//  - `BitField`
//  - `BitType`
//  - `Bit`
//  - `Boolean`

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// Returns `true` if the the bit at index `bit` is set (equals 1).
///
/// Note: that index 0 is the least significant bit, while index `length() - 1` is the most significant bit.
///
/// ```zig
/// const a: u8 = 0b00000010;
///
/// try testing.expect(!isBitSet(a, 0));
/// try testing.expect(isBitSet(a, 1));
/// ```
pub fn isBitSet(target: anytype, comptime bit: comptime_int) bool {
    const TargetType = @TypeOf(target);

    comptime {
        if (@typeInfo(TargetType) == .Int) {
            if (@typeInfo(TargetType).Int.signedness != .unsigned) {
                @compileError("requires an unsigned integer, found " ++ @typeName(TargetType));
            }
            if (bit >= @bitSizeOf(TargetType)) {
                @compileError("bit index is out of bounds of the bit field");
            }
        } else if (@typeInfo(TargetType) == .ComptimeInt) {
            if (target < 0) {
                @compileError("requires an unsigned integer, found " ++ @typeName(TargetType));
            }
        } else {
            @compileError("requires an unsigned integer, found " ++ @typeName(TargetType));
        }
    }

    const mask: TargetType = comptime blk: {
        const MaskType = std.meta.Int(.unsigned, bit + 1);
        var temp: MaskType = std.math.maxInt(MaskType);
        temp <<= bit;
        break :blk temp;
    };

    return (target & mask) != 0;
}

test isBitSet {
    // comptime_int
    {
        const a: comptime_int = 0b00000000;
        try testing.expect(!isBitSet(a, 0));
        try testing.expect(!isBitSet(a, 1));

        const b: comptime_int = 0b11111111;
        try testing.expect(isBitSet(b, 0));
        try testing.expect(isBitSet(b, 1));

        const c: comptime_int = 0b00000010;
        try testing.expect(!isBitSet(c, 0));
        try testing.expect(isBitSet(c, 1));
    }

    // Runtime
    {
        const a: u8 = 0b00000000;
        try testing.expect(!isBitSet(a, 0));
        try testing.expect(!isBitSet(a, 1));

        const b: u8 = 0b11111111;
        try testing.expect(isBitSet(b, 0));
        try testing.expect(isBitSet(b, 1));

        const c: u8 = 0b00000010;
        try testing.expect(!isBitSet(c, 0));
        try testing.expect(isBitSet(c, 1));
    }
}

/// Get the value of the bit at index `bit`.
///
/// Note: that index 0 is the least significant bit, while index `length() - 1` is the most significant bit.
///
/// ```zig
/// const a: u8 = 0b00000010;
///
/// try testing.expect(getBit(a, 0) == 0);
/// try testing.expect(getBit(a, 1) == 1);
/// ```
pub fn getBit(target: anytype, comptime bit: comptime_int) u1 {
    return @intFromBool(isBitSet(target, bit));
}

test getBit {
    // comptime_int
    {
        const a: comptime_int = 0b00000000;
        try testing.expectEqual(@as(u1, 0), getBit(a, 0));
        try testing.expectEqual(@as(u1, 0), getBit(a, 1));

        const b: comptime_int = 0b11111111;
        try testing.expectEqual(@as(u1, 1), getBit(b, 0));
        try testing.expectEqual(@as(u1, 1), getBit(b, 1));

        const c: comptime_int = 0b00000010;
        try testing.expectEqual(@as(u1, 0), getBit(c, 0));
        try testing.expectEqual(@as(u1, 1), getBit(c, 1));
    }

    // Runtime
    {
        const a: u8 = 0b00000000;
        try testing.expectEqual(@as(u1, 0), getBit(a, 0));
        try testing.expectEqual(@as(u1, 0), getBit(a, 1));

        const b: u8 = 0b11111111;
        try testing.expectEqual(@as(u1, 1), getBit(b, 0));
        try testing.expectEqual(@as(u1, 1), getBit(b, 1));

        const c: u8 = 0b00000010;
        try testing.expectEqual(@as(u1, 0), getBit(c, 0));
        try testing.expectEqual(@as(u1, 1), getBit(c, 1));
    }
}

/// Obtains the `number_of_bits` bits starting at `start_bit`.
///
/// Where `start_bit` is the lowest significant bit to fetch.
///
/// ```zig
/// const a: u8 = 0b01101100;
/// const b = getBits(a, 2, 4);
/// try testing.expectEqual(@as(u4,0b1011), b);
/// ```
pub fn getBits(target: anytype, comptime start_bit: comptime_int, comptime number_of_bits: comptime_int) std.meta.Int(.unsigned, number_of_bits) {
    const TargetType = @TypeOf(target);

    comptime {
        if (number_of_bits == 0) @compileError("non-zero number_of_bits must be provided");

        if (@typeInfo(TargetType) == .Int) {
            if (@typeInfo(TargetType).Int.signedness != .unsigned) {
                @compileError("requires an unsigned integer, found " ++ @typeName(TargetType));
            }
            if (start_bit >= @bitSizeOf(TargetType)) {
                @compileError("start_bit index is out of bounds of the bit field");
            }
            if (start_bit + number_of_bits > @bitSizeOf(TargetType)) {
                @compileError("start_bit + number_of_bits is out of bounds of the bit field");
            }
        } else if (@typeInfo(TargetType) == .ComptimeInt) {
            if (target < 0) {
                @compileError("requires an positive integer, found a negative");
            }
        } else {
            @compileError("requires an unsigned integer, found " ++ @typeName(TargetType));
        }
    }

    return @truncate(target >> start_bit);
}

test getBits {
    // comptime_int
    {
        const a: comptime_int = 0b01101100;
        const b = getBits(a, 2, 4);
        try testing.expectEqual(@as(u4, 0b1011), b);
    }

    // Runtime
    {
        const a: u8 = 0b01101100;
        const b = getBits(a, 2, 4);
        try testing.expectEqual(@as(u4, 0b1011), b);
    }
}

/// Sets the bit at the index `bit` to the value `value` (where true means a value of '1' and false means a value of '0').
///
/// Note: that index 0 is the least significant bit, while index `length() - 1` is the most significant bit.
///
/// ```zig
/// var val: u8 = 0b00000000;
/// try testing.expect(!getBit(val, 0));
/// setBit( &val, 0, true);
/// try testing.expect(getBit(val, 0));
/// ```
pub fn setBit(target: anytype, comptime bit: comptime_int, value: bool) void {
    const ptr_type_info: std.builtin.Type = @typeInfo(@TypeOf(target));
    comptime {
        if (ptr_type_info != .Pointer) @compileError("not a pointer");
    }

    const TargetType = ptr_type_info.Pointer.child;

    comptime {
        if (@typeInfo(TargetType) == .Int) {
            if (@typeInfo(TargetType).Int.signedness != .unsigned) {
                @compileError("requires an unsigned integer, found " ++ @typeName(TargetType));
            }
            if (bit >= @bitSizeOf(TargetType)) {
                @compileError("bit index is out of bounds of the bit field");
            }
        } else if (@typeInfo(TargetType) == .ComptimeInt) {
            @compileError("comptime_int is unsupported");
        } else {
            @compileError("requires an unsigned integer, found " ++ @typeName(TargetType));
        }
    }

    const mask: TargetType = comptime blk: {
        const MaskType = std.meta.Int(.unsigned, bit + 1);
        var temp: MaskType = std.math.maxInt(MaskType);
        temp <<= bit;
        break :blk temp;
    };

    if (value) {
        target.* |= mask;
    } else {
        target.* &= comptime ~(mask);
    }
}

test setBit {
    var val: u8 = 0b00000000;
    try testing.expect(!isBitSet(val, 0));
    setBit(&val, 0, true);
    try testing.expect(isBitSet(val, 0));
    setBit(&val, 0, false);
    try testing.expect(!isBitSet(val, 0));
}

/// Sets the range of bits starting at `start_bit` upto and excluding `start_bit` + `number_of_bits`.
///
/// ```zig
/// var val: u8 = 0b10000000;
/// setBits(&val, 2, 4, 0b00001101);
/// try testing.expectEqual(@as(u8, 0b10110100), val);
/// ```
///
/// ## Panic
/// This method will panic if the `value` exceeds the bit range of the type of `target`
pub fn setBits(target: anytype, comptime start_bit: comptime_int, comptime number_of_bits: comptime_int, value: anytype) void {
    const ptr_type_info: std.builtin.Type = @typeInfo(@TypeOf(target));
    comptime {
        if (ptr_type_info != .Pointer) @compileError("not a pointer");
    }

    const TargetType = ptr_type_info.Pointer.child;
    const end_bit = start_bit + number_of_bits;

    comptime {
        if (number_of_bits == 0) @compileError("non-zero number_of_bits must be provided");

        if (@typeInfo(TargetType) == .Int) {
            if (@typeInfo(TargetType).Int.signedness != .unsigned) {
                @compileError("requires an unsigned integer, found " ++ @typeName(TargetType));
            }
            if (start_bit >= @bitSizeOf(TargetType)) {
                @compileError("start_bit index is out of bounds of the bit field");
            }
            if (end_bit > @bitSizeOf(TargetType)) {
                @compileError("start_bit + number_of_bits is out of bounds of the bit field");
            }
        } else if (@typeInfo(TargetType) == .ComptimeInt) {
            @compileError("comptime_int is unsupported");
        } else {
            @compileError("requires an unsigned integer, found " ++ @typeName(TargetType));
        }
    }

    const peer_value: TargetType = value;

    if (std.debug.runtime_safety) {
        if (getBits(peer_value, 0, (end_bit - start_bit)) != peer_value) @panic("value exceeds bit range");
    }

    const bitmask: TargetType = comptime blk: {
        var bitmask = ~@as(TargetType, 0);
        bitmask <<= (@bitSizeOf(TargetType) - end_bit);
        bitmask >>= (@bitSizeOf(TargetType) - end_bit);
        bitmask >>= start_bit;
        bitmask <<= start_bit;
        break :blk ~bitmask;
    };

    target.* = (target.* & bitmask) | (peer_value << start_bit);
}

test setBits {
    var val: u8 = 0b10000000;
    setBits(&val, 2, 4, 0b00001101);
    try testing.expectEqual(@as(u8, 0b10110100), val);
}

/// Casts a pointer while preserving const/volatile qualifiers.
inline fn PtrCastPreserveCV(comptime T: type, comptime PtrToT: type, comptime NewT: type) type {
    return switch (PtrToT) {
        *T => *NewT,
        *const T => *const NewT,
        *volatile T => *volatile NewT,
        *const volatile T => *const volatile NewT,
        else => @compileError("invalid type " ++ @typeName(PtrToT) ++ " given to PtrCastPreserveCV"),
    };
}

/// Defines a bitfield.
pub fn Bitfield(
    /// The type of the underlying integer containing the bitfield.
    comptime FieldType: type,
    /// The starting bit index of the bitfield.
    comptime shift_amount: usize,
    /// The number of bits in the bitfield.
    comptime num_bits: usize,
) type {
    if (shift_amount + num_bits > @bitSizeOf(FieldType)) {
        @compileError("bitfield doesn't fit");
    }

    const self_mask: FieldType = ((1 << num_bits) - 1) << shift_amount;

    const ValueType = std.meta.Int(.unsigned, num_bits);

    return extern struct {
        dummy: FieldType,

        const Self = @This();

        /// A function to access the underlying integer as `FieldType`.
        /// Uses `anytype` to support both const and non-const access.
        inline fn field(self: anytype) PtrCastPreserveCV(Self, @TypeOf(self), FieldType) {
            return @ptrCast(self);
        }

        pub fn write(self: *Self, val: ValueType) void {
            self.field().* &= ~self_mask;
            self.field().* |= @as(FieldType, @intCast(val)) << shift_amount;
        }

        pub fn read(self: Self) ValueType {
            const val: FieldType = self.field().*;
            return @intCast((val & self_mask) >> shift_amount);
        }
    };
}

test Bitfield {
    const S = extern union {
        low: Bitfield(u32, 0, 16),
        high: Bitfield(u32, 16, 16),
        val: u32,
    };

    try std.testing.expect(@sizeOf(S) == 4);
    try std.testing.expect(@bitSizeOf(S) == 32);

    var s: S = .{ .val = 0x13376969 };

    try std.testing.expect(s.low.read() == 0x6969);
    try std.testing.expect(s.high.read() == 0x1337);

    s.low.write(0x1337);
    s.high.write(0x6969);

    try std.testing.expect(s.val == 0x69691337);
}

/// Defines a struct representing a single bit.
fn BitType(
    /// The type of the underlying integer containing the bit.
    comptime FieldType: type,
    /// The bit index of the bit.
    comptime shift_amount: usize,
    /// The type of the bit value, either u1 or bool.
    comptime ValueType: type,
) type {
    const self_bit: FieldType = (1 << shift_amount);

    return extern struct {
        bits: Bitfield(FieldType, shift_amount, 1),

        const Self = @This();

        pub fn read(self: Self) ValueType {
            return @bitCast(@as(u1, @truncate(self.bits.field().* >> shift_amount)));
        }

        pub fn write(self: *Self, val: ValueType) void {
            if (@bitCast(val)) {
                self.bits.field().* |= self_bit;
            } else {
                self.bits.field().* &= ~self_bit;
            }
        }
    };
}

/// Defines a struct representing a single bit with a u1 value.
pub fn Bit(
    /// The type of the underlying integer containing the bit.
    comptime FieldType: type,
    /// The bit index of the bit.
    comptime shift_amount: usize,
) type {
    return BitType(FieldType, shift_amount, u1);
}

test Bit {
    const S = extern union {
        low: Bit(u32, 0),
        high: Bit(u32, 1),
        val: u32,
    };

    try std.testing.expect(@sizeOf(S) == 4);
    try std.testing.expect(@bitSizeOf(S) == 32);

    var s: S = .{ .val = 1 };

    try std.testing.expect(s.low.read() == 1);
    try std.testing.expect(s.high.read() == 0);

    s.low.write(0);
    s.high.write(1);

    try std.testing.expect(s.val == 2);
}

/// Defines a struct representing a single bit with a boolean value.
pub fn Boolean(
    /// The type of the underlying integer containing the bit.
    comptime FieldType: type,
    /// The bit index of the bit.
    comptime shift_amount: usize,
) type {
    return BitType(FieldType, shift_amount, bool);
}

test Boolean {
    const S = extern union {
        low: Boolean(u32, 0),
        high: Boolean(u32, 1),
        val: u32,
    };

    try std.testing.expect(@sizeOf(S) == 4);
    try std.testing.expect(@bitSizeOf(S) == 32);

    var s: S = .{ .val = 2 };

    try std.testing.expect(s.low.read() == false);
    try std.testing.expect(s.high.read() == true);

    s.low.write(true);
    s.high.write(false);

    try std.testing.expect(s.val == 1);
}

comptime {
    refAllDeclsRecursive(@This(), true);
}

fn refAllDeclsRecursive(comptime T: type, comptime first: bool) void {
    comptime {
        if (!@import("builtin").is_test) return;

        inline for (std.meta.declarations(T)) |decl| {
            // don't analyze if the decl is not pub unless we are the first level of this call chain
            if (!first and !decl.is_pub) continue;

            if (std.mem.eql(u8, decl.name, "std")) continue;

            if (!@hasDecl(T, decl.name)) continue;

            defer _ = @field(T, decl.name);

            if (@TypeOf(@field(T, decl.name)) != type) continue;

            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name), false),
                else => {},
            }
        }
        return;
    }
}
