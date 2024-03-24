// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

const standard_page_size = kernel.arch.paging.standard_page_size.value;

fn allocPage() !*align(standard_page_size) [standard_page_size]u8 {
    const page = try kernel.pmm.allocatePage();
    return kernel.directMapFromPhysical(page.address).toPtr(*align(standard_page_size) [standard_page_size]u8);
}

fn deallocPage(ptr: []u8) void {
    kernel.pmm.deallocatePage(kernel.physicalRangeFromDirectMapUnsafe(core.VirtualRange.fromSlice(u8, ptr)));
}

pub fn Pool(
    comptime T: type,
    comptime number_of_bucket_groups: usize,
    comptime log_scope: @Type(.EnumLiteral),
) type {
    return struct {
        reader_writer_lock: kernel.sync.ReaderWriterSpinLock = .{},

        bucket_group_table: std.BoundedArray(*BucketGroup, number_of_bucket_groups) = .{},

        /// Linked list of full buckets.
        ///
        /// Protected by the reader writer lock.
        full_buckets: ?*BucketHeader = null,

        /// Linked list of available buckets.
        ///
        /// Protected by the reader writer lock.
        available_buckets: ?*BucketHeader = null,

        const log = kernel.log.scoped(log_scope);

        const Self = @This();

        pub fn get(self: *Self) !*T {
            while (true) {
                self.reader_writer_lock.readLock();

                var opt_candidate_bucket = self.available_buckets;
                while (opt_candidate_bucket) |candidate_bucket| : (opt_candidate_bucket = candidate_bucket.next) {
                    const index = candidate_bucket.bitset.toggleFirstSet() orelse continue;

                    if (candidate_bucket.bitset.allUnset()) {
                        const held = self.reader_writer_lock.upgradeReadToWriteLock();
                        defer held.unlock();

                        if (candidate_bucket.bitset.allUnset()) {
                            // we have the lock and the bucket is still full so we move it from the available list to the
                            // full list

                            if (candidate_bucket.in_full_list.cmpxchgStrong(
                                false,
                                true,
                                .acq_rel,
                                .monotonic,
                            ) == null) {
                                self.moveFromAvailableToFull(candidate_bucket);

                                log.debug("moved full bucket to full list", .{});
                            }
                        }
                    } else {
                        self.reader_writer_lock.readUnlock();
                    }

                    log.debug("provided item at index {} in {*}", .{ index, candidate_bucket.bucket });

                    return &candidate_bucket.bucket.?.items[index];
                }

                const held = self.reader_writer_lock.upgradeReadToWriteLock();
                defer held.unlock();

                // no more buckets available, allocate a new one
                if (self.bucket_group_table.len != 0) existing_bucket_group: {
                    const last_bucket_group = self.bucket_group_table.buffer[self.bucket_group_table.len - 1];

                    const bucket_header = last_bucket_group.headers.addOne() catch break :existing_bucket_group;
                    errdefer _ = last_bucket_group.headers.pop();

                    const bucket = try Bucket.create(bucket_header);
                    errdefer bucket.destroy();

                    bucket_header.* = .{
                        .bucket_group = last_bucket_group,
                        .bucket = bucket,
                    };

                    addBucketTo(bucket_header, &self.available_buckets);

                    log.debug("allocated a new bucket {*} in group {*}", .{ bucket, last_bucket_group });

                    continue;
                }

                // allocate a new bucket group
                const new_bucket_group_ptr = self.bucket_group_table.addOne() catch return error.BucketGroupsExhausted;
                errdefer _ = self.bucket_group_table.pop();

                const new_bucket_group = try BucketGroup.create();
                errdefer new_bucket_group.destroy();

                const bucket_header = new_bucket_group.headers.addOne() catch unreachable; // this is a newly constructed bucket group
                errdefer _ = new_bucket_group.headers.pop();

                const bucket = try Bucket.create(bucket_header);
                errdefer bucket.destroy();

                bucket_header.* = .{
                    .bucket_group = new_bucket_group,
                    .bucket = bucket,
                };

                addBucketTo(bucket_header, &self.available_buckets);

                new_bucket_group_ptr.* = new_bucket_group;

                log.debug("allocated a new bucket {*} in a new group {*}", .{ bucket, new_bucket_group });
            }
        }

        pub fn give(self: *Self, item: *T) void {
            const bucket_header = Bucket.getHeader(item);
            const bit_index = bucket_header.getIndex(item);

            self.reader_writer_lock.readLock();

            bucket_header.bitset.set(bit_index);
            log.debug("added item at index {} in {*} to the pool", .{ bit_index, bucket_header.bucket });

            if (bucket_header.in_full_list.load(.acquire)) {
                const held = self.reader_writer_lock.upgradeReadToWriteLock();
                defer held.unlock();

                if (bucket_header.in_full_list.cmpxchgStrong(
                    true,
                    false,
                    .acq_rel,
                    .monotonic,
                ) == null) {
                    self.moveFromFullToAvailable(bucket_header);

                    log.debug("moved previously full {*} to available list", .{bucket_header.bucket});
                }

                return;
            }

            if (bucket_header.bitset.allSet()) {
                const held = self.reader_writer_lock.upgradeReadToWriteLock();
                defer held.unlock();

                if (bucket_header.bitset.allSet()) {
                    removeBucketFrom(bucket_header, &self.available_buckets);

                    log.debug("deallocated now empty bucket {*}", .{bucket_header.bucket});

                    bucket_header.bucket.?.destroy();
                    bucket_header.bucket = null;

                    const bucket_group = bucket_header.bucket_group;
                    for (bucket_group.headers.constSlice()) |*header| {
                        if (header.bucket != null) return;
                    }

                    // all buckets in this group are empty
                    const index = for (self.bucket_group_table.constSlice(), 0..) |candidate_bucket_group, i| {
                        if (candidate_bucket_group == bucket_group) break i;
                    } else unreachable; // it is not possible for a bucket group to not be in `bucket_group_table`
                    _ = self.bucket_group_table.swapRemove(index);

                    log.debug("deallocated now empty bucket group {*}", .{bucket_group});

                    bucket_group.destroy();
                }

                return;
            }

            self.reader_writer_lock.readUnlock();
        }

        /// Move a bucket from the available list to the full list.
        ///
        /// The caller must have the write lock.
        fn moveFromAvailableToFull(self: *Self, bucket: *BucketHeader) void {
            removeBucketFrom(bucket, &self.available_buckets);
            addBucketTo(bucket, &self.full_buckets);
        }

        /// Move a bucket from the full list to the available list.
        ///
        /// The caller must have the write lock.
        fn moveFromFullToAvailable(self: *Self, bucket: *BucketHeader) void {
            removeBucketFrom(bucket, &self.full_buckets);
            addBucketTo(bucket, &self.available_buckets);
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

        const BucketGroup = struct {
            headers: std.BoundedArray(BucketHeader, number_of_buckets) align(standard_page_size) = std.BoundedArray(BucketHeader, number_of_buckets).init(0) catch unreachable,

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
            bitset: containers.AtomicBitSet(Bucket.number_of_items) = containers.AtomicBitSet(Bucket.number_of_items).initFull(),

            in_full_list: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
