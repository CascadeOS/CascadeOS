// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

// TODO: return unused tags to the cache when they exceed a threshold
// TODO: stats
// TODO: next fit

/// A general resource arena providing reasonably low fragmentation with constant time performance.
///
/// Based on [Magazines and Vmem: Extending the Slab Allocator to Many CPUs and Arbitrary Resources](https://www.usenix.org/legacy/publications/library/proceedings/usenix01/full_papers/bonwick/bonwick.pdf) by Jeff Bonwick and Jonathan Adams.
///
/// Written with reference to the following sources, no code was copied:
///  - [bonwick01](https://www.usenix.org/legacy/publications/library/proceedings/usenix01/full_papers/bonwick/bonwick.pdf)
///  - [illumos](https://github.com/illumos/illumos-gate/blob/master/usr/src/uts/common/os/vmem.c)
///  - [lylythechosenone's rust crate](https://github.com/lylythechosenone/vmem/blob/main/src/lib.rs)
///
pub fn Arena(comptime quantum_caching: QuantumCaching) type {
    return struct {
        _name: Name,

        quantum: usize,

        mutex: kernel.sync.Mutex,

        source: ?Source,

        /// List of all boundary tags in the arena.
        ///
        /// In order of ascending `base`.
        all_tags: DoublyLinkedList(AllTagNode),

        /// List of all spans in the arena.
        ///
        /// In order of ascending `base`.
        spans: DoublyLinkedList(KindNode),

        /// Hash table of allocated boundary tags.
        allocation_table: [NUMBER_OF_HASH_BUCKETS]DoublyLinkedList(KindNode),

        /// Power-of-two freelists.
        freelists: [NUMBER_OF_FREELISTS]DoublyLinkedList(KindNode),

        /// Bitmap of freelists that are non-empty.
        freelist_bitmap: Bitmap,

        /// List of unused boundary tags.
        unused_tags: SinglyLinkedList,

        /// Number of unused boundary tags.
        unused_tags_count: usize,

        quantum_caches: QuantumCaches,

        pub fn name(resource_arena: *const @This()) []const u8 {
            return resource_arena._name.constSlice();
        }

        pub fn init(
            arena: *@This(),
            options: InitOptions,
        ) InitError!void {
            if (!std.mem.isValidAlign(options.quantum)) return InitError.InvalidQuantum;

            log.debug("{s}: init with quantum 0x{x}", .{ options.name.constSlice(), options.quantum });

            arena.* = .{
                ._name = options.name,
                .quantum = options.quantum,
                .mutex = .{},
                .source = options.source,
                .all_tags = .empty,
                .spans = .empty,
                .allocation_table = @splat(.empty),
                .freelists = @splat(.empty),
                .freelist_bitmap = .empty,
                .unused_tags = .empty,
                .unused_tags_count = 0,
                .quantum_caches = .{
                    .allocation = undefined, // set below
                    .max_cached_size = undefined, // set below
                },
            };

            switch (quantum_caching) {
                .none => {},
                .normal => |count| {
                    std.debug.assert(count > 0);

                    const quantum_caches = kernel.mem.heap.allocator.alloc(RawCache, count) catch
                        @panic("quantum cache allocation failed"); // TODO: return this error

                    for (quantum_caches, 0..) |*quantum_cache, i| {
                        var cache_name: kernel.mem.cache.Name = .{};
                        cache_name.writer().print("{s} qcache {}", .{ arena.name(), i + 1 }) catch unreachable;

                        quantum_cache.init(.{
                            .name = cache_name,
                            .size = options.quantum * (i + 1),
                            .alignment = .fromByteUnits(options.quantum),
                        });
                        arena.quantum_caches.caches.append(quantum_cache) catch unreachable;
                    }

                    arena.quantum_caches.allocation = quantum_caches;
                    arena.quantum_caches.max_cached_size = count * options.quantum;
                },
                .heap => |count| {
                    std.debug.assert(count > 0);

                    var frames: kernel.mem.phys.FrameList = .{};

                    var caches_created: usize = 0;

                    const frames_to_allocate = arch.paging.standard_page_size.amountToCover(
                        core.Size.of(RawCache).multiplyScalar(count),
                    );

                    for (0..frames_to_allocate) |_| {
                        const frame = kernel.mem.phys.allocator.allocate() catch
                            @panic("heap quantum cache allocation failed");
                        frames.push(frame);

                        const frame_caches = kernel.mem.directMapFromPhysical(frame.baseAddress())
                            .toPtr(*[QUANTUM_CACHES_PER_FRAME]RawCache);

                        for (frame_caches) |*cache| {
                            caches_created += 1;

                            var cache_name: kernel.mem.cache.Name = .{};
                            cache_name.writer().print("heap qcache {}", .{caches_created}) catch unreachable;

                            cache.init(.{
                                .name = cache_name,
                                .size = options.quantum * (caches_created),
                                .alignment = .fromByteUnits(options.quantum),
                            });

                            arena.quantum_caches.caches.append(cache) catch unreachable;

                            if (caches_created == count) break;
                        }
                    }

                    arena.quantum_caches.allocation = frames;
                    arena.quantum_caches.max_cached_size = count * options.quantum;
                },
            }
        }

        /// Destroy the resource arena.
        ///
        /// Assumes that no concurrent access to the resource arena is happening, does not lock.
        ///
        /// Panics if there are any allocations in the resource arena.
        pub fn deinit(arena: *@This(), current_task: *kernel.Task) void {
            log.debug("{s}: deinit", .{arena.name()});

            if (quantum_caching.haveQuantumCache()) {
                for (arena.quantum_caches.caches.constSlice()) |quantum_cache| {
                    quantum_cache.deinit(current_task);
                }

                switch (quantum_caching) {
                    .no => {},
                    .yes => kernel.mem.heap.allocator.free(arena.quantum_caches.allocation),
                    .heap => kernel.mem.phys.allocator.deallocate(arena.quantum_caches.allocation),
                }
            }

            var tags_to_release: SinglyLinkedList = .empty;

            var any_allocations = false;

            // return imported spans and add all used boundary tags to the `tags_to_release` list
            while (arena.all_tags.pop()) |node| {
                const tag = node.toTag();

                switch (tag.kind) {
                    .imported_span => arena.source.?.callRelease(
                        current_task,
                        .{
                            .base = tag.base,
                            .len = tag.len,
                        },
                    ),
                    .allocated => any_allocations = true,
                    else => {},
                }

                tags_to_release.push(node);
            }

            // add all unused tags to the `tags_to_release` list
            while (arena.unused_tags.pop()) |node| {
                tags_to_release.push(node);
            }

            // return all tags to the global tag cache
            var any_tags_to_release = tags_to_release.first != null;
            while (any_tags_to_release) {
                const capacity = MAX_TAGS_PER_ALLOCATION * 4;
                var temp_tag_buffer: std.BoundedArray(*BoundaryTag, capacity) = .{};

                while (temp_tag_buffer.len < capacity) {
                    const node = tags_to_release.pop() orelse {
                        any_tags_to_release = false;
                        break;
                    };

                    temp_tag_buffer.appendAssumeCapacity(node.toTag());
                }

                globals.tag_cache.deallocateMany(current_task, capacity, temp_tag_buffer.constSlice());
            }

            if (any_allocations) {
                // TODO: log instead?
                std.debug.panic(
                    "leaks detected when deinitializing arena '{s}'",
                    .{arena.name()},
                );
            }

            arena.* = undefined;
        }

        /// Add the span [base, base + len) to the arena.
        ///
        /// Both `base` and `len` must be aligned to the arena's quantum.
        ///
        /// O(N) runtime.
        pub fn addSpan(arena: *@This(), current_task: *kernel.Task, base: usize, len: usize) AddSpanError!void {
            log.debug("{s}: adding span [0x{x}, 0x{x})", .{ arena.name(), base, base + len });

            try arena.ensureBoundaryTags(current_task);
            defer arena.mutex.unlock(current_task);

            const span_tag, const free_tag =
                try arena.getTagsForNewSpan(base, len, .span);
            errdefer {
                arena.pushUnusedTag(span_tag);
                arena.pushUnusedTag(free_tag);
            }

            try arena.addSpanInner(span_tag, free_tag, .add);
        }

        fn getTagsForNewSpan(
            arena: *@This(),
            base: usize,
            len: usize,
            span_type: enum { imported_span, span },
        ) AddSpanError!struct { *BoundaryTag, *BoundaryTag } {
            if (len == 0) return AddSpanError.ZeroLength;

            if (std.math.maxInt(usize) - base < len) return AddSpanError.WouldWrap;

            if (!std.mem.isAligned(base, arena.quantum) or
                !std.mem.isAligned(len, arena.quantum))
            {
                return AddSpanError.Unaligned;
            }
            errdefer comptime unreachable;

            const span_tag = arena.popUnusedTag();
            span_tag.* = .{
                .base = base,
                .len = len,
                .all_tag_node = .empty,
                .kind_node = .empty,
                .kind = switch (span_type) {
                    .imported_span => .imported_span,
                    .span => .span,
                },
            };

            const free_tag = arena.popUnusedTag();
            free_tag.* = .{
                .base = base,
                .len = len,
                .all_tag_node = .empty,
                .kind_node = .empty,
                .kind = .free,
            };

            return .{ span_tag, free_tag };
        }

        fn addSpanInner(
            arena: *@This(),
            span_tag: *BoundaryTag,
            free_tag: *BoundaryTag,
            comptime freelist_decision: enum { add, nop },
        ) error{Overlap}!void {
            std.debug.assert(span_tag.kind == .span or span_tag.kind == .imported_span);
            std.debug.assert(free_tag.kind == .free);

            const opt_previous_span = try arena.findSpanListPreviousSpan(span_tag.base, span_tag.len);

            errdefer comptime unreachable;

            const previous_all_tag_node = findSpanAllTagInsertionPoint(opt_previous_span);

            // insert the new span into the list of spans
            arena.spans.insertAfter(
                &span_tag.kind_node,
                if (opt_previous_span) |previous_span| &previous_span.kind_node else null,
            );

            // insert the new span tag into the list of all tags
            arena.all_tags.insertAfter(
                &span_tag.all_tag_node,
                previous_all_tag_node,
            );

            // insert the new free tag into the list of all tags (after the span tag)
            arena.all_tags.insertAfter(
                &free_tag.all_tag_node,
                &span_tag.all_tag_node,
            );

            switch (freelist_decision) {
                // insert the new free tag into the appropriate freelist
                .add => arena.pushToFreelist(free_tag),
                .nop => {},
            }
        }

        fn findSpanListPreviousSpan(
            arena: *const @This(),
            base: usize,
            len: usize,
        ) error{Overlap}!?*BoundaryTag {
            const end = base + len - 1;

            var opt_next_span_kind_node: ?*KindNode = arena.spans.first;

            var candidate_previous_span: ?*BoundaryTag = null;

            while (opt_next_span_kind_node) |next_span_kind_node| : ({
                opt_next_span_kind_node = next_span_kind_node.next;
            }) {
                const next_span = next_span_kind_node.toTag();
                std.debug.assert(next_span.kind == .span or next_span.kind == .imported_span);

                if (next_span.base > end) break;

                const next_span_end = next_span.base + next_span.len - 1;

                if (next_span_end >= base) return error.Overlap;

                candidate_previous_span = next_span;
            }

            return candidate_previous_span;
        }

        fn findSpanAllTagInsertionPoint(
            opt_previous_span: ?*BoundaryTag,
        ) ?*AllTagNode {
            if (opt_previous_span) |previous_span| {
                std.debug.assert(previous_span.kind == .span or previous_span.kind == .imported_span);

                if (previous_span.kind_node.next) |next_span_kind_node| {
                    const next_span = next_span_kind_node.toTag();
                    std.debug.assert(next_span.kind == .span or next_span.kind == .imported_span);

                    return next_span.all_tag_node.previous;
                }

                var opt_candidate_node: ?*AllTagNode = &previous_span.all_tag_node;

                while (opt_candidate_node) |candidate_node| {
                    const next = candidate_node.next;
                    if (next == null) break;
                    opt_candidate_node = next;
                }

                return opt_candidate_node;
            }

            return null;
        }

        /// Allocate a block of length `len` from the arena.
        pub fn allocate(arena: *@This(), current_task: *kernel.Task, len: usize, policy: Policy) AllocateError!Allocation {
            if (len == 0) return AllocateError.ZeroLength;

            const quantum_aligned_len = std.mem.alignForward(usize, len, arena.quantum);

            log.verbose("{s}: allocating len 0x{x} (quantum_aligned_len: 0x{x}) with policy {t}", .{
                arena.name(),
                len,
                quantum_aligned_len,
                policy,
            });

            if (quantum_caching.haveQuantumCache()) {
                if (quantum_aligned_len <= arena.quantum_caches.max_cached_size) {
                    const cache_index: usize = (quantum_aligned_len / arena.quantum) - 1;
                    const cache = arena.quantum_caches.caches.constSlice()[cache_index];
                    std.debug.assert(cache.object_size == quantum_aligned_len);

                    const buffer = cache.allocate(current_task) catch
                        return AllocateError.RequestedLengthUnavailable; // TODO: is there a better way to handle this?
                    std.debug.assert(buffer.len == quantum_aligned_len);

                    return .{
                        .base = @intFromPtr(buffer.ptr),
                        .len = buffer.len,
                    };
                }
            }

            try arena.ensureBoundaryTags(current_task);
            errdefer arena.mutex.unlock(current_task); // unconditionally unlock mutex on error

            const target_tag: *BoundaryTag = while (true) {
                break switch (policy) {
                    .instant_fit => arena.findInstantFit(quantum_aligned_len),
                    .best_fit => arena.findBestFit(quantum_aligned_len),
                    .first_fit => arena.findFirstFit(quantum_aligned_len),
                } orelse {
                    const source = arena.source orelse return AllocateError.RequestedLengthUnavailable;

                    break arena.importFromSource(current_task, source, quantum_aligned_len) catch
                        return AllocateError.RequestedLengthUnavailable;
                };
            };
            std.debug.assert(target_tag.kind == .free);
            errdefer comptime unreachable;

            arena.splitFreeTag(target_tag, quantum_aligned_len);

            target_tag.kind = .allocated;
            std.debug.assert(target_tag.len == quantum_aligned_len);

            arena.insertIntoAllocationTable(target_tag);

            arena.mutex.unlock(current_task);

            const allocation: Allocation = .{
                .base = target_tag.base,
                .len = quantum_aligned_len,
            };

            log.verbose("{s}: allocated {f}", .{ arena.name(), allocation });

            return allocation;
        }

        fn findInstantFit(arena: *@This(), quantum_aligned_len: usize) ?*BoundaryTag {
            if (arena.performStrictInstantFit(quantum_aligned_len)) |tag| {
                @branchHint(.likely);
                return tag;
            }

            return arena.performStrictFirstFit(quantum_aligned_len);
        }

        fn findBestFit(arena: *@This(), quantum_aligned_len: usize) ?*BoundaryTag {
            // search the freelist that would contain the exact length tag
            {
                var opt_best_tag: ?*BoundaryTag = null;
                var opt_node: ?*KindNode = arena.freelists[indexOfFreelistContainingLen(quantum_aligned_len)].first;

                while (opt_node) |node| : (opt_node = node.next) {
                    const tag = node.toTag();
                    std.debug.assert(tag.kind == .free);

                    if (tag.len == quantum_aligned_len) {
                        arena.removeFromFreelist(tag);
                        return tag;
                    }

                    if (tag.len < quantum_aligned_len) continue;

                    if (opt_best_tag) |best_tag| {
                        if (tag.len < best_tag.len) opt_best_tag = tag;
                    } else {
                        opt_best_tag = tag;
                    }
                }

                if (opt_best_tag) |best_tag| {
                    arena.removeFromFreelist(best_tag);
                    return best_tag;
                }
            }

            // search a freelist that is guaranteed to contain a tag that is large enough for the requested size
            if (arena.indexOfNonEmptyFreelistInstantFit(quantum_aligned_len)) |index| {
                const smallest_possible_len = smallestPossibleLenInFreelist(index);

                var opt_best_tag: ?*BoundaryTag = null;
                var opt_node: ?*KindNode = arena.freelists[index].first;

                while (opt_node) |node| : (opt_node = node.next) {
                    const tag = node.toTag();
                    std.debug.assert(tag.kind == .free);

                    // if this tag is the smallest possible len in this freelist we can never do better
                    if (tag.len == smallest_possible_len) {
                        arena.removeFromFreelist(tag);
                        return tag;
                    }

                    if (opt_best_tag) |best_tag| {
                        if (tag.len < best_tag.len) opt_best_tag = tag;
                    } else {
                        opt_best_tag = tag;
                    }
                }

                if (opt_best_tag) |best_tag| {
                    arena.removeFromFreelist(best_tag);
                    return best_tag;
                }
            }

            return null;
        }

        fn findFirstFit(arena: *@This(), quantum_aligned_len: usize) ?*BoundaryTag {
            if (arena.performStrictFirstFit(quantum_aligned_len)) |tag| return tag;
            return arena.performStrictInstantFit(quantum_aligned_len);
        }

        /// Find a free tag in any freelist that is guaranteed to satisfy the requested size.
        fn performStrictInstantFit(arena: *@This(), quantum_aligned_len: usize) ?*BoundaryTag {
            const index = arena.indexOfNonEmptyFreelistInstantFit(quantum_aligned_len) orelse {
                @branchHint(.unlikely);
                return null;
            };
            const tag = arena.popFromFreelist(index) orelse unreachable;
            std.debug.assert(tag.kind == .free);
            return tag;
        }

        /// Search for the first fit tag in the freelist containing the requested size.
        fn performStrictFirstFit(arena: *@This(), quantum_aligned_len: usize) ?*BoundaryTag {
            var opt_node: ?*KindNode = arena.freelists[indexOfFreelistContainingLen(quantum_aligned_len)].first;

            while (opt_node) |node| : (opt_node = node.next) {
                const tag = node.toTag();
                std.debug.assert(tag.kind == .free);
                if (tag.len >= quantum_aligned_len) {
                    arena.removeFromFreelist(tag);
                    return tag;
                }
            }

            return null;
        }

        /// Attempt to import a block of length `len` from the arena's source.
        ///
        /// The mutex must be locked upon entry and will be locked upon exit.
        fn importFromSource(
            arena: *@This(),
            current_task: *kernel.Task,
            source: Source,
            len: usize,
        ) (AllocateError || AddSpanError)!*BoundaryTag {
            arena.mutex.unlock(current_task);

            log.verbose("{s}: importing len 0x{x} from source {s}", .{ arena.name(), len, source.name });

            var need_to_lock_mutex = true;
            defer if (need_to_lock_mutex) arena.mutex.lock(current_task);

            const allocation = try source.callImport(current_task, len, .instant_fit);
            errdefer source.callRelease(current_task, allocation);

            try arena.ensureBoundaryTags(current_task);
            need_to_lock_mutex = false;

            const span_tag, const free_tag =
                try arena.getTagsForNewSpan(allocation.base, allocation.len, .imported_span);
            errdefer {
                arena.pushUnusedTag(span_tag);
                arena.pushUnusedTag(free_tag);
            }

            try arena.addSpanInner(span_tag, free_tag, .nop);

            log.verbose("{s}: imported {f} from source {s}", .{ arena.name(), allocation, source.name });

            return free_tag;
        }

        fn splitFreeTag(arena: *@This(), tag: *BoundaryTag, allocation_len: usize) void {
            std.debug.assert(tag.kind == .free);
            std.debug.assert(tag.len >= allocation_len);

            if (tag.len == allocation_len) return;

            const new_tag = arena.popUnusedTag();

            new_tag.* = .{
                .base = tag.base + allocation_len,
                .len = tag.len - allocation_len,
                .all_tag_node = .empty,
                .kind_node = .empty,
                .kind = .free,
            };

            tag.len = allocation_len;

            arena.all_tags.insertAfter(
                &new_tag.all_tag_node,
                &tag.all_tag_node,
            );

            arena.pushToFreelist(new_tag);
        }

        /// Deallocate the allocation.
        ///
        /// Panics if the allocation does not match a previous call to `allocate`.
        pub fn deallocate(arena: *@This(), current_task: *kernel.Task, allocation: Allocation) void {
            log.verbose("{s}: deallocating {f}", .{ arena.name(), allocation });

            std.debug.assert(std.mem.isAligned(allocation.base, arena.quantum));
            std.debug.assert(std.mem.isAligned(allocation.len, arena.quantum));

            if (quantum_caching.haveQuantumCache()) {
                if (allocation.len <= arena.quantum_caches.max_cached_size) {
                    const cache_index: usize = (allocation.len / arena.quantum) - 1;
                    const cache = arena.quantum_caches.caches.constSlice()[cache_index];
                    std.debug.assert(cache.object_size == allocation.len);

                    const buffer_ptr: [*]u8 = @ptrFromInt(allocation.base);
                    const buffer = buffer_ptr[0..allocation.len];

                    cache.deallocate(current_task, buffer);

                    return;
                }
            }

            arena.mutex.lock(current_task);

            var need_to_unlock_mutex = true;
            defer if (need_to_unlock_mutex) arena.mutex.unlock(current_task);

            const tag = arena.removeFromAllocationTable(allocation.base) orelse {
                std.debug.panic(
                    "no allocation at '{}' found",
                    .{allocation.base},
                );
            };
            std.debug.assert(tag.kind == .allocated);

            if (allocation.len != tag.len) {
                std.debug.panic(
                    "provided len '{}' does not match len '{}' of allocation at '{}'",
                    .{ allocation.len, tag.len, allocation.base },
                );
            }

            tag.kind = .free;

            coalesce_previous_tag: {
                const previous_node = tag.all_tag_node.previous orelse
                    unreachable; // a free tag will always have atleast its containing spans tag before it

                const previous_tag = previous_node.toTag();

                if (previous_tag.kind != .free) break :coalesce_previous_tag;
                std.debug.assert(previous_tag.base + previous_tag.len == tag.base);

                arena.removeFromFreelist(previous_tag);
                arena.all_tags.remove(&previous_tag.all_tag_node);

                tag.base = previous_tag.base;
                tag.len = previous_tag.len + tag.len;

                arena.pushUnusedTag(previous_tag);
            }

            coalesce_next_tag: {
                const next_node = tag.all_tag_node.next orelse break :coalesce_next_tag;
                const next_tag = next_node.toTag();

                if (next_tag.kind != .free) break :coalesce_next_tag;
                std.debug.assert(tag.base + tag.len == next_tag.base);

                arena.removeFromFreelist(next_tag);
                arena.all_tags.remove(&next_tag.all_tag_node);

                tag.len = tag.len + next_tag.len;

                arena.pushUnusedTag(next_tag);
            }

            if (arena.source) |source| {
                const previous_node = tag.all_tag_node.previous orelse
                    unreachable; // a free tag will always have atleast its containing spans' tag before it

                const previous_tag = previous_node.toTag();

                if (previous_tag.kind == .imported_span and previous_tag.len == tag.len) {
                    std.debug.assert(previous_tag.base == tag.base);

                    arena.spans.remove(&previous_tag.kind_node);
                    arena.all_tags.remove(&previous_tag.all_tag_node);
                    arena.all_tags.remove(&tag.all_tag_node);

                    const allocation_to_release: Allocation = .{ .base = previous_tag.base, .len = previous_tag.len };

                    previous_tag.* = .empty(.free);

                    arena.pushUnusedTag(previous_tag);
                    arena.pushUnusedTag(tag);

                    arena.mutex.unlock(current_task);
                    need_to_unlock_mutex = false;

                    source.callRelease(current_task, allocation_to_release);

                    log.verbose(
                        "{s}: released {f} to source {s}",
                        .{ arena.name(), allocation_to_release, source.name },
                    );

                    return;
                }
            }

            arena.pushToFreelist(tag);
        }

        /// Attempts to ensure that there are at least `min_unused_tags_count` unused tags.
        ///
        /// Upon non-error return, the mutex is locked.
        fn ensureBoundaryTags(arena: *@This(), current_task: *kernel.Task) EnsureBoundaryTagsError!void {
            arena.mutex.lock(current_task);
            errdefer arena.mutex.unlock(current_task);

            if (arena.unused_tags_count >= MAX_TAGS_PER_ALLOCATION) return;

            var tags = std.BoundedArray(
                *BoundaryTag,
                MAX_TAGS_PER_ALLOCATION,
            ).init(MAX_TAGS_PER_ALLOCATION - arena.unused_tags_count) catch unreachable;

            globals.tag_cache.allocateMany(current_task, MAX_TAGS_PER_ALLOCATION, tags.slice()) catch
                return EnsureBoundaryTagsError.OutOfBoundaryTags;

            for (tags.slice()) |tag| {
                tag.* = .empty(.free);

                arena.pushUnusedTag(tag);
            }
        }

        fn insertIntoAllocationTable(arena: *@This(), tag: *BoundaryTag) void {
            std.debug.assert(tag.kind == .allocated);

            const index: HashIndex = @truncate(Wyhash.hash(0, std.mem.asBytes(&tag.base)));
            arena.allocation_table[index].push(&tag.kind_node);
        }

        fn removeFromAllocationTable(arena: *@This(), base: usize) ?*BoundaryTag {
            const index: HashIndex = @truncate(Wyhash.hash(0, std.mem.asBytes(&base)));
            const bucket = &arena.allocation_table[index];

            var opt_node = bucket.first;
            while (opt_node) |node| : (opt_node = node.next) {
                const tag = node.toTag();
                std.debug.assert(tag.kind == .allocated);

                if (tag.base != base) continue;

                bucket.remove(node);
                return tag;
            }

            return null;
        }

        fn pushToFreelist(arena: *@This(), tag: *BoundaryTag) void {
            std.debug.assert(tag.kind == .free);

            const index = indexOfFreelistContainingLen(tag.len);

            arena.freelists[index].push(&tag.kind_node);
            arena.freelist_bitmap.set(index);
        }

        fn popFromFreelist(arena: *@This(), index: UsizeShiftInt) ?*BoundaryTag {
            const freelist = &arena.freelists[index];

            const node = freelist.pop() orelse return null;

            if (freelist.isEmpty()) arena.freelist_bitmap.unset(index);

            const tag = node.toTag();
            std.debug.assert(tag.kind == .free);
            return tag;
        }

        fn removeFromFreelist(arena: *@This(), tag: *BoundaryTag) void {
            std.debug.assert(tag.kind == .free);

            const index = indexOfFreelistContainingLen(tag.len);
            const freelist = &arena.freelists[index];

            freelist.remove(&tag.kind_node);
            if (freelist.isEmpty()) arena.freelist_bitmap.unset(index);
        }

        fn popUnusedTag(arena: *@This()) *BoundaryTag {
            std.debug.assert(arena.unused_tags_count > 0);
            arena.unused_tags_count -= 1;
            const tag = arena.unused_tags.pop().?.toTag();
            std.debug.assert(tag.kind == .free);
            return tag;
        }

        fn pushUnusedTag(arena: *@This(), tag: *BoundaryTag) void {
            std.debug.assert(tag.kind == .free);
            arena.unused_tags.push(&tag.all_tag_node);
            arena.unused_tags_count += 1;
        }

        fn indexOfNonEmptyFreelistInstantFit(arena: *const @This(), len: usize) ?UsizeShiftInt {
            const pow2_len = std.math.ceilPowerOfTwoAssert(usize, len);
            const index = @ctz(arena.freelist_bitmap.value & ~(pow2_len - 1));
            return if (index == NUMBER_OF_FREELISTS) null else @intCast(index);
        }

        pub const CreateSourceOptions = struct {
            custom_import: ?fn (
                arena_ptr: *anyopaque,
                current_task: *kernel.Task,
                len: usize,
                policy: Policy,
            ) AllocateError!Allocation = null,

            custom_release: ?fn (
                arena_ptr: *anyopaque,
                current_task: *kernel.Task,
                allocation: Allocation,
            ) void = null,
        };

        pub fn createSource(arena: *@This(), comptime options: CreateSourceOptions) Source {
            const ArenaT = @This();
            return .{
                .name = arena.name(),
                .arena_ptr = arena,
                .import = if (options.custom_import) |custom_import|
                    custom_import
                else
                    struct {
                        fn importWrapper(
                            arena_ptr: *anyopaque,
                            current_task: *kernel.Task,
                            len: usize,
                            policy: Policy,
                        ) AllocateError!Allocation {
                            const a: *ArenaT = @ptrCast(@alignCast(arena_ptr));
                            return a.allocate(current_task, len, policy);
                        }
                    }.importWrapper,
                .release = if (options.custom_release) |custom_release|
                    custom_release
                else
                    struct {
                        fn releaseWrapper(
                            arena_ptr: *anyopaque,
                            current_task: *kernel.Task,
                            allocation: Allocation,
                        ) void {
                            const a: *ArenaT = @ptrCast(@alignCast(arena_ptr));
                            a.deallocate(current_task, allocation);
                        }
                    }.releaseWrapper,
            };
        }

        const QuantumCaches = struct {
            caches: if (quantum_caching != .none)
                std.BoundedArray(*RawCache, MAX_NUMBER_OF_QUANTUM_CACHES)
            else
                void = if (quantum_caching != .none) .{} else {},

            /// The largest size of a cached object.
            max_cached_size: if (quantum_caching != .none) usize else void,

            allocation: QuantumCaches.Allocation,

            const Allocation = switch (quantum_caching) {
                .none => void,
                .normal => []RawCache,
                .heap => kernel.mem.phys.FrameList,
            };
        };
    };
}

pub const QuantumCaching = union(enum) {
    none,

    /// The number of multiples of the quantum to cache.
    ///
    /// Uses the heap resource arena to allocate the caches.
    normal: u6,

    /// The number of multiples of the quantum to cache.
    ///
    /// This should only be used by the heap resource arena itself.
    ///
    /// Uses the physical memory allocator and the hhdm to allocate the caches.
    heap: u6,

    inline fn haveQuantumCache(comptime quantum_caching: QuantumCaching) bool {
        return switch (quantum_caching) {
            .none => false,
            .normal, .heap => true,
        };
    }
};

pub const InitOptions = struct {
    name: Name,

    quantum: usize,

    source: ?Source = null,
};

pub const Policy = enum {
    instant_fit,
    first_fit,
    best_fit,
};

pub const Allocation = struct {
    base: usize,
    len: usize,

    pub inline fn format(
        allocation: Allocation,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("Allocation{{ base: 0x{x}, len: 0x{x} }}", .{ allocation.base, allocation.len });
    }
};

pub const Source = struct {
    name: []const u8,

    arena_ptr: *anyopaque,

    import: *const fn (
        arena_ptr: *anyopaque,
        current_task: *kernel.Task,
        len: usize,
        policy: Policy,
    ) AllocateError!Allocation,

    release: *const fn (
        arena_ptr: *anyopaque,
        current_task: *kernel.Task,
        allocation: Allocation,
    ) void,

    fn callImport(
        source: *const Source,
        current_task: *kernel.Task,
        len: usize,
        policy: Policy,
    ) callconv(core.inline_in_non_debug) AllocateError!Allocation {
        return source.import(source.arena_ptr, current_task, len, policy);
    }

    fn callRelease(
        source: *const Source,
        current_task: *kernel.Task,
        allocation: Allocation,
    ) callconv(core.inline_in_non_debug) void {
        source.release(source.arena_ptr, current_task, allocation);
    }
};

pub const InitError = error{
    /// The `quantum` is not a power of two.
    InvalidQuantum,
};

pub const AddSpanError = error{
    ZeroLength,
    WouldWrap,
    Unaligned,
    Overlap,
} || EnsureBoundaryTagsError;

pub const AllocateError = error{
    ZeroLength,
    RequestedLengthUnavailable,
} || EnsureBoundaryTagsError;

pub const EnsureBoundaryTagsError = error{
    OutOfBoundaryTags,
};

pub const Name = std.BoundedArray(u8, kernel.config.resource_arena_name_length);

const BoundaryTag = struct {
    base: usize,
    len: usize,

    all_tag_node: AllTagNode,
    kind_node: KindNode,

    kind: Kind,

    const Kind = enum(u8) {
        /// the `all_tag_node` list is in order of ascending `base`
        /// the `kind_node` list is in order of ascending `base`
        /// `kind_node` linked into `Arena.spans` along with `imported_span`
        span,

        /// the `all_tag_node` list is in order of ascending `base`
        /// the `kind_node` list is in order of ascending `base`
        /// `kind_node` linked into `Arena.spans` along with `span`
        imported_span,

        /// the `all_tag_node` list is in order of ascending `base`
        /// the `kind_node` list has no guarantee of order
        /// `kind_node` linked into the matching power-of-2 freelist in `Arena.freelists`
        free,

        /// the `all_tag_node` list is in order of ascending `base`
        /// the `kind_node` list has no guarantee of order
        /// `kind_node` linked into matching hash bucket in `Arena.allocation_table`
        allocated,
    };

    fn empty(kind: Kind) BoundaryTag {
        return .{
            .base = 0,
            .len = 0,
            .all_tag_node = .empty,
            .kind_node = .empty,
            .kind = kind,
        };
    }

    pub fn print(boundary_tag: BoundaryTag, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("BoundaryTag{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("base: 0x{x},\n", .{boundary_tag.base});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("len: 0x{x},\n", .{boundary_tag.len});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("kind: {t},\n", .{boundary_tag.kind});

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("all_tag_node: ");
        try boundary_tag.all_tag_node.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("kind_node: ");
        try boundary_tag.kind_node.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(boundary_tag: BoundaryTag, writer: *std.Io.Writer) !void {
        return boundary_tag.print(writer, 0);
    }
};

const AllTagNode = struct {
    previous: ?*AllTagNode,
    next: ?*AllTagNode,

    fn toTag(all_tag_node: *AllTagNode) *BoundaryTag {
        return @fieldParentPtr("all_tag_node", all_tag_node);
    }

    const empty: AllTagNode = .{ .previous = null, .next = null };

    pub fn print(all_tag_node: AllTagNode, writer: *std.Io.Writer, indent: usize) !void {
        _ = indent;

        try writer.writeAll("AllTagNode{ previous: ");
        if (all_tag_node.previous != null) {
            try writer.writeAll("set");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(", next: ");
        if (all_tag_node.next != null) {
            try writer.writeAll("set");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(" }");
    }

    pub inline fn format(all_tag_node: AllTagNode, writer: *std.Io.Writer) !void {
        return all_tag_node.print(writer, 0);
    }
};

const KindNode = struct {
    previous: ?*KindNode,
    next: ?*KindNode,

    fn toTag(kind_node: *KindNode) *BoundaryTag {
        return @fieldParentPtr("kind_node", kind_node);
    }

    const empty: KindNode = .{ .previous = null, .next = null };

    pub fn print(kind_node: KindNode, writer: *std.Io.Writer, indent: usize) !void {
        _ = indent;

        try writer.writeAll("KindNode{ previous: ");
        if (kind_node.previous != null) {
            try writer.writeAll("set");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(", next: ");
        if (kind_node.next != null) {
            try writer.writeAll("set");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(" }");
    }

    pub inline fn format(kind_node: KindNode, writer: *std.Io.Writer) !void {
        return kind_node.print(writer, 0);
    }
};

const Bitmap = struct {
    value: usize,

    const empty: Bitmap = .{ .value = 0 };

    fn set(bitmap: *Bitmap, index: UsizeShiftInt) void {
        bitmap.value |= maskBit(index);
    }

    fn unset(bitmap: *Bitmap, index: UsizeShiftInt) void {
        bitmap.value &= ~maskBit(index);
    }

    inline fn maskBit(index: UsizeShiftInt) usize {
        const one: usize = 1;
        return one << index;
    }
};

/// A singly linked list, that uses `AllTagNode.next` as the link.
const SinglyLinkedList = struct {
    first: ?*AllTagNode,

    const empty: SinglyLinkedList = .{ .first = null };

    fn push(singly_linked_list: *SinglyLinkedList, node: *AllTagNode) void {
        std.debug.assert(node.previous == null and node.next == null);

        node.* = .{ .next = singly_linked_list.first, .previous = null };

        singly_linked_list.first = node;
    }

    fn pop(singly_linked_list: *SinglyLinkedList) ?*AllTagNode {
        const node = singly_linked_list.first orelse return null;
        std.debug.assert(node.previous == null);

        singly_linked_list.first = node.next;

        node.* = .empty;

        return node;
    }
};

/// A doubly linked list, that uses `Node` as the link.
fn DoublyLinkedList(comptime Node: type) type {
    return struct {
        first: ?*Node,

        const DoublyLinkedListT = @This();

        const empty: DoublyLinkedListT = .{ .first = null };

        /// Push a node to the front of the list.
        fn push(doubly_linked_list: *DoublyLinkedListT, node: *Node) void {
            std.debug.assert(node.previous == null and node.next == null);

            const opt_first = doubly_linked_list.first;

            node.next = opt_first;

            if (opt_first) |first| {
                std.debug.assert(first.previous == null);
                first.previous = node;
            }

            node.previous = null;
            doubly_linked_list.first = node;
        }

        /// Pop a node from the front of the list.
        fn pop(doubly_linked_list: *DoublyLinkedListT) ?*Node {
            const first = doubly_linked_list.first orelse return null;
            std.debug.assert(first.previous == null);

            const opt_next = first.next;

            if (opt_next) |next| {
                std.debug.assert(next.previous == first);
                next.previous = null;
            }

            doubly_linked_list.first = opt_next;

            first.* = .empty;

            return first;
        }

        /// Removes a node from the list.
        fn remove(doubly_linked_list: *DoublyLinkedListT, node: *Node) void {
            if (node.previous) |previous| {
                std.debug.assert(previous.next == node);
                previous.next = node.next;
            } else {
                doubly_linked_list.first = node.next;
            }

            if (node.next) |next| {
                std.debug.assert(next.previous == node);
                next.previous = node.previous;
            }

            node.* = .empty;
        }

        pub fn insertAfter(doubly_linked_list: *DoublyLinkedListT, node: *Node, opt_previous: ?*Node) void {
            std.debug.assert(node.previous == null and node.next == null);

            if (opt_previous) |previous| {
                if (previous.next) |next| {
                    std.debug.assert(next.previous == previous);
                    next.previous = node;
                    node.next = next;
                }

                previous.next = node;
                node.previous = previous;
            } else {
                if (doubly_linked_list.first) |first| {
                    std.debug.assert(first.previous == null);
                    first.previous = node;
                    node.next = first;
                }

                doubly_linked_list.first = node;
            }
        }

        inline fn isEmpty(doubly_linked_list: *const DoublyLinkedListT) bool {
            return doubly_linked_list.first == null;
        }
    };
}

inline fn indexOfFreelistContainingLen(len: usize) UsizeShiftInt {
    return @intCast(NUMBER_OF_FREELISTS - 1 - @clz(len));
}

inline fn smallestPossibleLenInFreelist(index: usize) usize {
    const truncated_len: UsizeShiftInt = @truncate(index);
    const one: usize = 1;
    return one << @truncate(truncated_len);
}

const MAX_NUMBER_OF_QUANTUM_CACHES = 64;
const QUANTUM_CACHES_PER_FRAME = arch.paging.standard_page_size.divide(core.Size.of(RawCache)).value;

const NUMBER_OF_HASH_BUCKETS = 64;
const HashIndex: type = std.math.Log2Int(std.meta.Int(.unsigned, NUMBER_OF_HASH_BUCKETS));

const NUMBER_OF_FREELISTS = @bitSizeOf(usize);
const UsizeShiftInt: type = std.math.Log2Int(usize);

const TAGS_PER_SPAN_CREATE = 2;
const TAGS_PER_EXACT_ALLOCATION = 0;
const TAGS_PER_PARTIAL_ALLOCATION = 1;
const MAX_TAGS_PER_ALLOCATION = TAGS_PER_SPAN_CREATE + TAGS_PER_PARTIAL_ALLOCATION;

const TAGS_PER_PAGE = arch.paging.standard_page_size.value / @sizeOf(BoundaryTag);

const globals = struct {
    /// Initialized during `global_init.initializeCache`.
    var tag_cache: kernel.mem.cache.Cache(BoundaryTag, null, null) = undefined;
};

pub const global_init = struct {
    pub fn initializeCache() !void {
        globals.tag_cache.init(.{
            .name = try .fromSlice("boundary tag"),
            .slab_source = .pmm,
        });
    }
};

const arch = @import("arch");
const kernel = @import("kernel");

const core = @import("core");
const log = kernel.debug.log.scoped(.resource_arena);
const RawCache = kernel.mem.cache.RawCache;
const std = @import("std");
const Wyhash = std.hash.Wyhash;
