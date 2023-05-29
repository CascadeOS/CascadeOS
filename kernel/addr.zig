// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub const PhysAddr = Addr(.phys);
pub const VirtAddr = Addr(.virt);
pub const PhysRange = Range(.phys);
pub const VirtRange = Range(.virt);

const Type = enum {
    phys,
    virt,
};

fn Addr(comptime addr_type: Type) type {
    return extern struct {
        value: usize,

        const Self = @This();

        pub const zero: Self = .{ .value = 0 };

        pub inline fn fromInt(value: usize) Self {
            // TODO: check that the address is valid (cannoical)
            return .{ .value = value };
        }

        pub inline fn toKernelVirtual(self: PhysAddr) VirtAddr {
            return .{ .value = self.value + kernel.info.hhdm.addr.value };
        }

        pub inline fn fromPtr(ptr: *const anyopaque) VirtAddr {
            return fromInt(@ptrToInt(ptr));
        }

        pub inline fn toPtr(self: VirtAddr, comptime PtrT: type) PtrT {
            return @intToPtr(PtrT, self.value);
        }

        /// Returns the physical address of the given virtual address if it is in the HHDM.
        ///
        /// ## Safety
        /// It is the caller's responsibility to ensure that the given virtual address is in the HHDM.
        pub fn unsafeToPhysicalFromKernelVirtual(self: VirtAddr) PhysAddr {
            return .{ .value = self.value - kernel.info.hhdm.addr.value };
        }

        /// Returns the physical address of the given virtual address if it is in one of the HHDMs.
        pub fn toPhysicalFromKernelVirtual(self: VirtAddr) error{AddressNotInAnyHHDM}!PhysAddr {
            if (kernel.info.hhdm.contains(self)) {
                return .{ .value = self.value - kernel.info.hhdm.addr.value };
            }
            if (kernel.info.non_cached_hhdm.contains(self)) {
                return .{ .value = self.value - kernel.info.non_cached_hhdm.addr.value };
            }
            return error.AddressNotInAnyHHDM;
        }

        pub inline fn isAligned(self: Self, alignment: core.Size) bool {
            return std.mem.isAligned(self.value, alignment.bytes);
        }

        pub inline fn moveForward(self: Self, size: core.Size) Self {
            return .{ .value = self.value + size.bytes };
        }

        pub inline fn moveForwardInPlace(self: *Self, size: core.Size) void {
            self.value += size.bytes;
        }

        pub inline fn moveBackward(self: Self, size: core.Size) Self {
            return .{ .value = self.value - size.bytes };
        }

        pub inline fn moveBackwardInPlace(self: *Self, size: core.Size) void {
            self.value -= size.bytes;
        }

        pub inline fn lessThan(self: Self, other: Self) bool {
            return self.value < other.value;
        }

        pub inline fn lessThanOrEqual(self: Self, other: Self) bool {
            return self.value <= other.value;
        }

        pub inline fn greaterThan(self: Self, other: Self) bool {
            return self.value > other.value;
        }

        pub inline fn greaterThanOrEqual(self: Self, other: Self) bool {
            return self.value >= other.value;
        }

        pub inline fn equal(self: Self, other: Self) bool {
            return self.value == other.value;
        }

        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            const name = switch (addr_type) {
                .phys => "PhysAddr",
                .virt => "VirtAddr",
            };

            try writer.writeAll(comptime name ++ "{ 0x");
            try std.fmt.formatInt(self.value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);
            try writer.writeAll(" }");
        }
    };
}

comptime {
    std.debug.assert(@sizeOf(PhysAddr) == @sizeOf(usize));
    std.debug.assert(@bitSizeOf(PhysAddr) == @bitSizeOf(usize));
}

comptime {
    std.debug.assert(@sizeOf(VirtAddr) == @sizeOf(usize));
    std.debug.assert(@bitSizeOf(VirtAddr) == @bitSizeOf(usize));
}

fn Range(comptime addr_type: Type) type {
    return extern struct {
        addr: AddrType,
        size: core.Size,

        pub const AddrType: type = switch (addr_type) {
            .phys => PhysAddr,
            .virt => VirtAddr,
        };

        const Self = @This();

        pub inline fn fromAddr(addr: AddrType, size: core.Size) Self {
            return .{
                .addr = addr,
                .size = size,
            };
        }

        pub inline fn toKernelVirtual(self: PhysRange) VirtRange {
            return .{
                .addr = self.addr.toKernelVirtual(),
                .size = self.size,
            };
        }

        pub inline fn end(self: Self) AddrType {
            return self.addr.moveForward(self.size);
        }

        pub inline fn moveForward(self: Self, size: core.Size) Self {
            return .{
                .addr = self.addr.moveForward(size),
                .size = self.size,
            };
        }

        pub inline fn moveForwardInPlace(self: *Self, size: core.Size) void {
            self.addr.moveForwardInPlace(size);
        }

        pub inline fn moveBackward(self: Self, size: core.Size) Self {
            return .{
                .addr = self.addr.moveBackward(size),
                .size = self.size,
            };
        }

        pub inline fn moveBackwardInPlace(self: *Self, size: core.Size) void {
            self.addr.moveBackwardInPlace(size);
        }

        pub fn contains(self: Self, addr: AddrType) bool {
            return addr.greaterThanOrEqual(self.addr) and addr.lessThan(self.end());
        }

        pub fn format(
            value: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            const name = switch (addr_type) {
                .phys => "PhysRange",
                .virt => "VirtRange",
            };

            try writer.writeAll(comptime name ++ "{ ");
            try value.addr.format("", .{}, writer);
            try writer.writeByte(' ');
            try value.size.format("", .{}, writer);
            try writer.writeAll(" }");
        }
    };
}
