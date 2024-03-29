// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

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
        lock: kernel.sync.TicketSpinLock = .{},

        bucket_group_table: std.BoundedArray(*BucketGroup, number_of_bucket_groups) = .{},

        /// Linked list of full buckets.
        full_buckets: ?*BucketHeader = null,

        /// Linked list of buckets with available objects.
        available_buckets: ?*BucketHeader = null,

        const log = kernel.log.scoped(log_scope);
        const BucketBitSet = std.bit_set.ArrayBitSet(usize, Bucket.number_of_items);

        const Self = @This();

        pub const GetError = kernel.pmm.AllocateError || error{BucketGroupsExhausted};

        pub fn get(self: *Self) GetError!*T {
            const held = self.lock.lock();
            defer held.unlock();

            if (self.available_buckets) |candidate_bucket| {
                return self.getItemFromBucket(candidate_bucket) orelse
                    unreachable; // empty bucket in available list
            }

            // no buckets available, allocate a new one

            const bucket = try self.allocateNewBucket();

            return self.getItemFromBucket(bucket) orelse
                unreachable; // freshly allocated bucket is full

        }

        pub fn give(self: *Self, item: *T) void {
            const bucket_header = Bucket.getHeader(item);
            const bit_index = bucket_header.getIndex(item);

            const held = self.lock.lock();
            defer held.unlock();

            bucket_header.bitset.set(bit_index);
            log.debug("added item at index {} in {*} to the pool", .{ bit_index, bucket_header.bucket });

            if (bucket_header.in_full_list) {
                // bucket was previously full, move it to the available list

                self.moveFromFullToAvailable(bucket_header);

                log.debug("moved previously full {*} to available list", .{bucket_header.bucket});

                return;
            }

            if (bitsetAllSet(&bucket_header.bitset)) {
                // bucket is empty
                self.deallocateBucket(bucket_header);
            }
        }

        fn getItemFromBucket(self: *Self, bucket: *BucketHeader) ?*T {
            core.debugAssert(!bucket.in_full_list);

            const index = bucket.bitset.toggleFirstSet() orelse return null;

            if (bitsetAllUnset(&bucket.bitset)) {
                // the bucket is full so we move it from the available list to the full list

                self.moveFromAvailableToFull(bucket);

                log.debug("moved full bucket {*} to full list", .{bucket.bucket});
            }

            log.debug("provided item at index {} in {*}", .{ index, bucket.bucket });

            return &bucket.bucket.?.items[index];
        }

        fn allocateNewBucket(self: *Self) GetError!*BucketHeader {
            const bucket_group, const new_bucket_group = blk: {
                if (self.bucket_group_table.len != 0) {
                    const last_bucket_group = self.bucket_group_table.buffer[self.bucket_group_table.len - 1];
                    if (last_bucket_group.headers.len < last_bucket_group.headers.capacity()) {
                        // the last bucket group in the `bucket_group_table` has room for another bucket
                        break :blk .{ last_bucket_group, false };
                    }
                }

                // allocate a new bucket group
                const new_bucket_group_ptr = self.bucket_group_table.addOne() catch return error.BucketGroupsExhausted;
                errdefer _ = self.bucket_group_table.pop();

                const new_bucket_group = try BucketGroup.create();
                errdefer new_bucket_group.destroy();

                new_bucket_group_ptr.* = new_bucket_group;

                break :blk .{ new_bucket_group, true };
            };
            errdefer if (new_bucket_group) {
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

            addBucketTo(bucket_header, &self.available_buckets);

            if (new_bucket_group) {
                log.debug("allocated a new bucket {*} in a new group {*}", .{ bucket, bucket_group });
            } else {
                log.debug("allocated a new bucket {*} in group {*}", .{ bucket, bucket_group });
            }

            return bucket_header;
        }

        fn deallocateBucket(self: *Self, bucket: *BucketHeader) void {
            core.debugAssert(!bucket.in_full_list);

            removeBucketFrom(bucket, &self.available_buckets);

            log.debug("deallocated now empty bucket {*}", .{bucket.bucket});

            bucket.bucket.?.destroy();
            bucket.bucket = null;

            const this_bucket_group = bucket.bucket_group;
            for (this_bucket_group.headers.constSlice()) |*header| {
                if (header.bucket != null) return; // non-empty bucket in this group
            }
            // all buckets in this group are empty

            const bucket_group_index = for (self.bucket_group_table.constSlice(), 0..) |candidate_bucket_group, i| {
                if (candidate_bucket_group == this_bucket_group) break i;
            } else unreachable; // it is not possible for a bucket group to not be in `bucket_group_table`

            _ = self.bucket_group_table.swapRemove(bucket_group_index);

            log.debug("deallocated now empty bucket group {*}", .{this_bucket_group});

            this_bucket_group.destroy();
        }

        /// Move a bucket from the available list to the full list.
        ///
        /// The caller must have the write lock.
        fn moveFromAvailableToFull(self: *Self, bucket: *BucketHeader) void {
            core.debugAssert(!bucket.in_full_list);

            removeBucketFrom(bucket, &self.available_buckets);
            addBucketTo(bucket, &self.full_buckets);
            bucket.in_full_list = true;
        }

        /// Move a bucket from the full list to the available list.
        ///
        /// The caller must have the write lock.
        fn moveFromFullToAvailable(self: *Self, bucket: *BucketHeader) void {
            core.debugAssert(bucket.in_full_list);

            removeBucketFrom(bucket, &self.full_buckets);
            addBucketTo(bucket, &self.available_buckets);
            bucket.in_full_list = false;
        }

        /// Remove a bucket from the available list.
        ///
        /// The caller must have the write lock.
        fn removeBucketFrom(bucket: *BucketHeader, target_list: *?*BucketHeader) void {
            if (bucket.next) |next| next.previous = bucket.previous;
            if (bucket.previous) |previous| previous.next = bucket.next;
            if (target_list.* == bucket) target_list.* = bucket.next;
        }

        /// Add a bucket to the full list.
        ///
        /// The caller must have the write lock.
        fn addBucketTo(bucket: *BucketHeader, target_list: *?*BucketHeader) void {
            if (target_list.*) |head| {
                head.previous = bucket;
                bucket.next = head;
            } else {
                bucket.next = null;
            }

            bucket.previous = null;

            target_list.* = bucket;
        }

        fn bitsetAllUnset(bitset: *const BucketBitSet) bool {
            for (&bitset.masks) |mask| {
                if (mask != 0) return false;
            }

            return true;
        }

        fn bitsetAllSet(bitset: *const BucketBitSet) bool {
            const num_masks = bitset.masks.len;

            if (num_masks > 1) {
                for (bitset.masks[0 .. num_masks - 1]) |mask| {
                    if (mask != std.math.maxInt(usize)) return false;
                }
            }

            if (bitset.masks[num_masks - 1] != std.math.maxInt(usize) & BucketBitSet.last_item_mask) return false;

            return true;
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

            comptime {
                core.assert(@sizeOf(@This()) <= standard_page_size);
                core.assert(@alignOf(@This()) == standard_page_size);
            }
        };

        const BucketHeader = struct {
            bucket_group: *BucketGroup,

            bucket: ?*Bucket = null,
            next: ?*BucketHeader = null,
            previous: ?*BucketHeader = null,
            bitset: BucketBitSet = BucketBitSet.initFull(),

            in_full_list: bool = false,

            /// Returns the index of the given item in the bucket.
            ///
            /// It is the caller's responsibility to ensure that the pointer is in this bucket.
            pub fn getIndex(self: *const BucketHeader, item: *T) usize {
                return @divExact(@intFromPtr(item) - @intFromPtr(&self.bucket.?.items), @sizeOf(T));
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

            comptime {
                core.assert(@sizeOf(@This()) <= standard_page_size);
                core.assert(@alignOf(@This()) == standard_page_size);
            }
        };
    };
}

fn allocPage() kernel.pmm.AllocateError!*align(standard_page_size) [standard_page_size]u8 {
    const page = try kernel.pmm.allocatePage();
    return kernel.directMapFromPhysical(page.address).toPtr(*align(standard_page_size) [standard_page_size]u8);
}

fn deallocPage(ptr: []u8) void {
    kernel.pmm.deallocatePage(kernel.physicalRangeFromDirectMapUnsafe(core.VirtualRange.fromSlice(u8, ptr)));
}
