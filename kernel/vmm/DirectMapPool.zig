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

            const bucket = blk: {
                if (self.available_buckets.peek()) |bucket_node|
                    break :blk Bucket.fromNode(bucket_node);

                // no buckets available, allocate a new one

                break :blk try self.allocateNewBucket();
            };

            return self.getItemFromBucket(bucket) orelse
                unreachable; // bucket is either freshly allocated or in available list so there must be a free item
        }

        pub fn give(self: *Self, item: *T) void {
            const bucket = Bucket.getBucketFromItemPtr(item);
            const bit_index = bucket.getIndexFromItemPtr(item);

            const held = self.mutex.acquire();
            defer held.release();

            bucket.bitset.set(bit_index);
            log.debug("added item at index {} in {} to the pool", .{ bit_index, bucket });

            if (bucket.empty) {
                // bucket was previously empty, move it to the available list

                self.addBucketToAvailableBuckets(bucket);

                log.debug("moved previously empty {} to available list", .{bucket});

                return;
            }

            if (bucket.bitset.allSet()) {
                log.debug("deallocating {}", .{bucket});

                // bucket is full, no items are in use
                self.deallocateBucket(bucket);
            }
        }

        fn getItemFromBucket(self: *Self, bucket: *Bucket) ?*T {
            const index = bucket.bitset.toggleFirstSet() orelse return null;

            if (bucket.bitset.allUnset()) {
                // the bucket is empty so we remove it from the available list

                self.removeBucketFromAvailableBuckets(bucket);

                log.debug("removed empty {} from available list", .{bucket});
            }

            log.debug("provided item at index {} in {}", .{ index, bucket });

            return &bucket.items[index];
        }

        fn allocateNewBucket(self: *Self) GetError!*Bucket {
            var is_new_bucket_group = false;

            const bucket_group = blk: {
                if (self.bucket_group_table.len != 0) {
                    const last_bucket_group = self.bucket_group_table.buffer[self.bucket_group_table.len - 1];
                    if (last_bucket_group.buckets.len < last_bucket_group.buckets.capacity()) {
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

            const bucket_ptr = bucket_group.buckets.addOne() catch {
                // the block above ensures that the bucket group has room for another bucket or is a freshly
                // allocated bucket group.
                unreachable;
            };
            errdefer _ = bucket_group.buckets.pop();

            const bucket = try Bucket.create(bucket_group);
            errdefer bucket.destroy();

            bucket_ptr.* = bucket;

            self.addBucketToAvailableBuckets(bucket);

            if (is_new_bucket_group) {
                log.debug("allocated {} in a new {}", .{ bucket, bucket_group });
            } else {
                log.debug("allocated {} in {}", .{ bucket, bucket_group });
            }

            return bucket;
        }

        fn deallocateBucket(self: *Self, bucket: *Bucket) void {
            core.debugAssert(!bucket.empty);

            self.removeBucketFromAvailableBuckets(bucket);

            const bucket_group = bucket.bucket_group;

            const bucket_index = for (bucket_group.buckets.constSlice(), 0..) |candidate_bucket, i| {
                if (candidate_bucket == bucket) break i;
            } else unreachable; // it is not possible for a bucket to not be in `buckets`

            _ = bucket_group.buckets.swapRemove(bucket_index);

            bucket.destroy();

            if (bucket_group.buckets.len != 0) return; // bucket group still contains available buckets

            const bucket_group_index = for (self.bucket_group_table.constSlice(), 0..) |candidate_bucket_group, i| {
                if (candidate_bucket_group == bucket_group) break i;
            } else unreachable; // it is not possible for a bucket group to not be in `bucket_group_table`

            _ = self.bucket_group_table.swapRemove(bucket_group_index);

            bucket_group.destroy();
        }

        /// Add a bucket to the available list.
        ///
        /// The caller must have the write lock.
        fn addBucketToAvailableBuckets(self: *Self, bucket: *Bucket) void {
            self.available_buckets.push(&bucket.node);
            bucket.empty = false;
        }

        /// Remove a bucket from the available list.
        ///
        /// The caller must have the write lock.
        fn removeBucketFromAvailableBuckets(self: *Self, bucket: *Bucket) void {
            core.debugAssert(!bucket.empty);
            self.available_buckets.remove(&bucket.node);
            bucket.empty = true;
        }

        const BucketGroup = struct {
            buckets: std.BoundedArray(*Bucket, number_of_buckets) align(standard_page_size) = .{},

            pub const number_of_buckets = (standard_page_size - @sizeOf(u8)) / @sizeOf(*Bucket);

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
                try writer.writeAll(">{ buckets: ");
                try std.fmt.formatInt(
                    bucket_group.buckets.len,
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

        const Bucket = struct {
            bucket_group: *BucketGroup align(standard_page_size),

            bitset: BucketBitSet = BucketBitSet.initFull(),

            node: containers.DoubleNode = .{},

            /// If this is true then all items in this bucket are in use.
            empty: bool = false,

            items: [number_of_items]T = undefined,

            // TODO: Calculate this.
            //
            // We want to do something like `(standard_page_size - @offsetOf(Bucket, "items")) / @sizeOf(T)` but
            // `BucketBitSet`s size depends on `number_of_items` making this self-referential.
            pub const number_of_items = 63;

            pub fn create(bucket_group: *BucketGroup) !*Bucket {
                const bucket: *Bucket = @ptrCast(try allocPage());

                bucket.* = .{
                    .bucket_group = bucket_group,
                };

                return bucket;
            }

            pub fn destroy(self: *Bucket) void {
                deallocPage(std.mem.asBytes(self));
            }

            /// Returns the the bucket that contains the given pointer.
            ///
            /// It is the caller's responsibility to ensure that the pointer is in a bucket.
            pub fn getBucketFromItemPtr(item: *T) *Bucket {
                return @ptrFromInt(
                    std.mem.alignBackward(usize, @intFromPtr(item), standard_page_size),
                );
            }

            /// Returns the index of the given item in the bucket.
            ///
            /// It is the caller's responsibility to ensure that the pointer is in this bucket.
            pub fn getIndexFromItemPtr(self: *const Bucket, item: *T) usize {
                return @divExact(@intFromPtr(item) - @intFromPtr(&self.items), @sizeOf(T));
            }

            inline fn fromNode(node: *containers.DoubleNode) *Bucket {
                return @alignCast(@fieldParentPtr("node", node));
            }

            pub fn print(bucket: *const Bucket, writer: std.io.AnyWriter, indent: usize) !void {
                _ = indent;

                try writer.writeAll("Bucket<0x");
                try std.fmt.formatInt(
                    @intFromPtr(bucket),
                    16,
                    .lower,
                    .{},
                    writer,
                );
                try writer.writeAll(">{ empty: ");
                try writer.print("{}", .{bucket.empty});
                try writer.writeAll(" }");
            }

            pub inline fn format(
                bucket: *const Bucket,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = options;
                _ = fmt;
                return if (@TypeOf(writer) == std.io.AnyWriter)
                    print(bucket, writer, 0)
                else
                    print(bucket, writer.any(), 0);
            }

            fn __helpZls() void {
                Bucket.print(undefined, @as(std.fs.File.Writer, undefined), 0);
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
