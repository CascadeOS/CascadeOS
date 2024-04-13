// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

const standard_page_size = kernel.arch.paging.standard_page_size.value;

/// A thread-safe pool of objects that are mapped using the direct map.
///
/// As this pool utilizes the direct map it does not need address space management, meaning it can be used in the
/// implementation of address space management.
pub fn DirectMapPool(
    comptime T: type,
    comptime number_of_bucket_groups: usize,
    comptime log_scope: @Type(.EnumLiteral),
) type {
    return struct {
        mutex: kernel.sync.Mutex = .{},

        bucket_group_table: std.BoundedArray(*BucketGroup, number_of_bucket_groups) = .{},

        available_buckets: containers.DoublyLinkedLIFO = .{},

        const log = kernel.log.scoped(log_scope);
        const BucketBitSet = struct {
            bitset: ArrayBitSet,

            const ArrayBitSet = std.bit_set.ArrayBitSet(usize, Bucket.number_of_items);

            inline fn set(self: *BucketBitSet, index: usize) void {
                self.bitset.set(index);
            }

            inline fn initFull() BucketBitSet {
                return .{ .bitset = ArrayBitSet.initFull() };
            }

            inline fn toggleFirstSet(self: *BucketBitSet) ?usize {
                return self.bitset.toggleFirstSet();
            }

            fn allUnset(self: *const BucketBitSet) bool {
                for (&self.bitset.masks) |mask| {
                    if (mask != 0) return false;
                }

                return true;
            }

            fn allSet(self: *const BucketBitSet) bool {
                const bitset = &self.bitset;

                const num_masks = bitset.masks.len;

                if (num_masks > 1) {
                    for (bitset.masks[0 .. num_masks - 1]) |mask| {
                        if (mask != std.math.maxInt(usize)) return false;
                    }
                }

                if (bitset.masks[num_masks - 1] != std.math.maxInt(usize) & ArrayBitSet.last_item_mask) return false;

                return true;
            }
        };

        const Self = @This();

        pub const GetError = kernel.pmm.AllocateError || error{BucketGroupsExhausted};

        pub fn get(self: *Self) GetError!*T {
            const held = self.mutex.acquire();
            defer held.release();

            const bucket_header = blk: {
                if (self.available_buckets.peek()) |bucket_node|
                    break :blk BucketHeader.fromNode(bucket_node);

                // no buckets available, allocate a new one

                break :blk try self.allocateNewBucket();
            };

            return self.getItemFromBucket(bucket_header) orelse
                unreachable; // bucket is either freshly allocated or in available list so there must be a free item
        }

        pub fn give(self: *Self, item: *T) void {
            const bucket_header = Bucket.getHeader(item);
            const bit_index = bucket_header.getIndex(item);

            const held = self.mutex.acquire();
            defer held.release();

            bucket_header.bitset.set(bit_index);
            log.debug("added item at index {} in {} to the pool", .{ bit_index, bucket_header });

            if (bucket_header.empty) {
                // bucket was previously empty, move it to the available list

                self.addBucketToAvailableBuckets(bucket_header);

                log.debug("moved previously empty {} to available list", .{bucket_header});

                return;
            }

            if (bucket_header.bitset.allSet()) {
                log.debug("deallocating {}", .{bucket_header});

                // bucket is full, no items are in use
                self.deallocateBucket(bucket_header);
            }
        }

        fn getItemFromBucket(self: *Self, bucket_header: *BucketHeader) ?*T {
            const index = bucket_header.bitset.toggleFirstSet() orelse return null;

            if (bucket_header.bitset.allUnset()) {
                // the bucket is empty so we remove it from the available list

                self.removeBucketFromAvailableBuckets(bucket_header);

                log.debug("removed empty {} from available list", .{bucket_header});
            }

            log.debug("provided item at index {} in {}", .{ index, bucket_header });

            return &bucket_header.bucket.?.items[index];
        }

        fn allocateNewBucket(self: *Self) GetError!*BucketHeader {
            var is_new_bucket_group = false;

            const bucket_group = blk: {
                if (self.bucket_group_table.len != 0) {
                    const last_bucket_group = self.bucket_group_table.buffer[self.bucket_group_table.len - 1];
                    if (last_bucket_group.headers.len < last_bucket_group.headers.capacity()) {
                        // the last bucket group in the `bucket_group_table` has room for another bucket
                        break :blk last_bucket_group;
                    }
                }

                // allocate a new bucket group
                const new_bucket_group_ptr = self.bucket_group_table.addOne() catch return error.BucketGroupsExhausted;
                errdefer _ = self.bucket_group_table.pop();

                const new_bucket_group = try BucketGroup.create();
                errdefer new_bucket_group.destroy();

                new_bucket_group_ptr.* = new_bucket_group;

                is_new_bucket_group = true;
                break :blk new_bucket_group;
            };
            errdefer if (is_new_bucket_group) {
                bucket_group.destroy();
                _ = self.bucket_group_table.pop();
            };

            const bucket_header = bucket_group.headers.addOne() catch {
                // the block above ensures that the bucket group has room for another bucket or is a freshly
                // allocated bucket group.
                unreachable;
            };
            errdefer _ = bucket_group.headers.pop();

            const bucket = try Bucket.create(bucket_header);
            errdefer bucket.destroy();

            bucket_header.* = .{
                .bucket_group = bucket_group,
                .bucket = bucket,
            };

            self.addBucketToAvailableBuckets(bucket_header);

            if (is_new_bucket_group) {
                log.debug("allocated {} in a new {}", .{ bucket_header, bucket_group });
            } else {
                log.debug("allocated {} in {}", .{ bucket_header, bucket_group });
            }

            return bucket_header;
        }

        fn deallocateBucket(self: *Self, bucket_header: *BucketHeader) void {
            core.debugAssert(!bucket_header.empty);

            self.removeBucketFromAvailableBuckets(bucket_header);

            bucket_header.bucket.?.destroy();
            bucket_header.bucket = null;

            const this_bucket_group = bucket_header.bucket_group;
            for (this_bucket_group.headers.constSlice()) |header| {
                if (header.bucket != null) return; // bucket still in use in this group
            }

            const bucket_group_index = for (self.bucket_group_table.constSlice(), 0..) |candidate_bucket_group, i| {
                if (candidate_bucket_group == this_bucket_group) break i;
            } else unreachable; // it is not possible for a bucket group to not be in `bucket_group_table`

            this_bucket_group.destroy();

            _ = self.bucket_group_table.swapRemove(bucket_group_index);
        }

        /// Add a bucket to the available list.
        ///
        /// The caller must have the write lock.
        fn addBucketToAvailableBuckets(self: *Self, bucket_header: *BucketHeader) void {
            self.available_buckets.push(&bucket_header.node);
            bucket_header.empty = false;
        }

        /// Remove a bucket from the available list.
        ///
        /// The caller must have the write lock.
        fn removeBucketFromAvailableBuckets(self: *Self, bucket_header: *BucketHeader) void {
            core.debugAssert(!bucket_header.empty);
            self.available_buckets.remove(&bucket_header.node);
            bucket_header.empty = true;
        }

        const BucketGroup = struct {
            headers: std.BoundedArray(BucketHeader, number_of_buckets) align(standard_page_size) = .{},

            pub const number_of_buckets = (standard_page_size - @sizeOf(u8)) / @sizeOf(BucketHeader);

            pub fn create() !*BucketGroup {
                const bucket_group: *BucketGroup = @ptrCast(try allocPage());
                bucket_group.* = .{};
                return bucket_group;
            }

            pub fn destroy(self: *BucketGroup) void {
                deallocPage(std.mem.asBytes(self));
            }

            pub fn print(bucket_group: *const BucketGroup, writer: std.io.AnyWriter, indent: usize) !void {
                _ = indent;

                try writer.writeAll("BucketGroup<0x");
                try std.fmt.formatInt(
                    @intFromPtr(bucket_group),
                    16,
                    .lower,
                    .{},
                    writer,
                );
                try writer.writeAll(">{ headers: ");
                try std.fmt.formatInt(
                    bucket_group.headers.len,
                    10,
                    .lower,
                    .{},
                    writer,
                );
                try writer.writeAll(" }");
            }

            pub inline fn format(
                bucket_group: *const BucketGroup,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = options;
                _ = fmt;
                return if (@TypeOf(writer) == std.io.AnyWriter)
                    print(bucket_group, writer, 0)
                else
                    print(bucket_group, writer.any(), 0);
            }

            fn __helpZls() void {
                BucketGroup.print(undefined, @as(std.fs.File.Writer, undefined), 0);
            }

            comptime {
                core.assert(@sizeOf(@This()) <= standard_page_size);
                core.assert(@alignOf(@This()) == standard_page_size);
            }
        };

        const BucketHeader = struct {
            bucket_group: *BucketGroup,

            bucket: ?*Bucket = null,
            bitset: BucketBitSet = BucketBitSet.initFull(),

            node: containers.DoubleNode = .{},

            /// If this is true then all items in this bucket are in use.
            empty: bool = false,

            /// Returns the index of the given item in the bucket.
            ///
            /// It is the caller's responsibility to ensure that the pointer is in this bucket.
            pub fn getIndex(self: *const BucketHeader, item: *T) usize {
                return @divExact(@intFromPtr(item) - @intFromPtr(&self.bucket.?.items), @sizeOf(T));
            }

            inline fn fromNode(node: *containers.DoubleNode) *BucketHeader {
                return @fieldParentPtr("node", node);
            }

            pub fn print(bucket_header: *const BucketHeader, writer: std.io.AnyWriter, indent: usize) !void {
                _ = indent;

                try writer.writeAll("Bucket<0x");
                try std.fmt.formatInt(
                    @intFromPtr(bucket_header),
                    16,
                    .lower,
                    .{},
                    writer,
                );
                try writer.writeAll(">{ empty: ");
                try writer.print("{}", .{bucket_header.empty});
                try writer.writeAll(" }");
            }

            pub inline fn format(
                bucket_header: *const BucketHeader,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = options;
                _ = fmt;
                return if (@TypeOf(writer) == std.io.AnyWriter)
                    print(bucket_header, writer, 0)
                else
                    print(bucket_header, writer.any(), 0);
            }

            fn __helpZls() void {
                BucketHeader.print(undefined, @as(std.fs.File.Writer, undefined), 0);
            }
        };

        const Bucket = struct {
            header: *BucketHeader align(standard_page_size),
            items: [number_of_items]T = undefined,

            const size_of_header_field = if (@sizeOf(*BucketHeader) > @alignOf(T)) @sizeOf(*BucketHeader) else @alignOf(T);
            pub const number_of_items = (standard_page_size - size_of_header_field) / @sizeOf(T);

            pub fn create(header: *BucketHeader) !*Bucket {
                const bucket: *Bucket = @ptrCast(try allocPage());
                bucket.* = .{
                    .header = header,
                };
                return bucket;
            }

            pub fn destroy(self: *Bucket) void {
                deallocPage(std.mem.asBytes(self));
            }

            /// Returns the header of the bucket that contains the given pointer.
            ///
            /// It is the caller's responsibility to ensure that the pointer is in a bucket.
            pub fn getHeader(ptr: *T) *BucketHeader {
                const bucket: *Bucket = @ptrFromInt(
                    std.mem.alignBackward(usize, @intFromPtr(ptr), standard_page_size),
                );
                return bucket.header;
            }

            pub inline fn format(_: *Bucket, comptime _: []const u8, _: std.fmt.FormatOptions, _: anytype) !void {
                @compileError("dont format a bucket, format its header");
            }

            comptime {
                core.assert(@sizeOf(@This()) <= standard_page_size);
                core.assert(@alignOf(@This()) == standard_page_size);
            }
        };

        comptime {
            core.assert(@sizeOf(T) <= standard_page_size);
            core.assert(@alignOf(T) <= standard_page_size);
        }
    };
}

fn allocPage() kernel.pmm.AllocateError!*align(standard_page_size) [standard_page_size]u8 {
    const page = try kernel.pmm.allocatePage();
    return kernel.directMapFromPhysical(page.address).toPtr(*align(standard_page_size) [standard_page_size]u8);
}

fn deallocPage(ptr: []u8) void {
    kernel.pmm.deallocatePage(kernel.physicalRangeFromDirectMapUnsafe(core.VirtualRange.fromSlice(u8, ptr)));
}
