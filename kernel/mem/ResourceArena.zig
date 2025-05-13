// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A general resource arena providing reasonably low fragmentation with constant time performance.
//!
//! Based on [Magazines and Vmem: Extending the Slab Allocator to Many CPUs and Arbitrary Resources](https://www.usenix.org/legacy/publications/library/proceedings/usenix01/full_papers/bonwick/bonwick.pdf) by Jeff Bonwick and Jonathan Adams.
//!
//! Written with reference to the following sources, no code was copied:
//!  - [bonwick01](https://www.usenix.org/legacy/publications/library/proceedings/usenix01/full_papers/bonwick/bonwick.pdf)
//!  - [illumos](https://github.com/illumos/illumos-gate/blob/master/usr/src/uts/common/os/vmem.c)
//!  - [lylythechosenone's rust crate](https://github.com/lylythechosenone/vmem/blob/main/src/lib.rs)
//!

// TODO: stats
// TODO: next fit

const ResourceArena = @This();

_name: Name,

quantum: usize,

mutex: kernel.sync.Mutex,

source: ?Source,

/// List of all boundary tags in the arena.
///
/// In order of ascending `base`.
all_tags: DoubleLinkedList(AllTagNode),

/// List of all spans in the arena.
///
/// In order of ascending `base`.
spans: DoubleLinkedList(KindNode),

/// Hash table of allocated boundary tags.
allocation_table: [NUMBER_OF_HASH_BUCKETS]DoubleLinkedList(KindNode),

/// Power-of-two freelists.
freelists: [NUMBER_OF_FREELISTS]DoubleLinkedList(KindNode),

/// Bitmap of freelists that are non-empty.
freelist_bitmap: Bitmap,

/// List of unused boundary tags.
unused_tags: SingleLinkedList,

/// Number of unused boundary tags.
unused_tags_count: usize,

/// The largest size of a cached object.
max_cached_size: usize,

quantum_caches: std.BoundedArray(*RawCache, MAX_NUMBER_OF_QUANTUM_CACHES),

quantum_cache_allocation: QuantumCacheAllocation,

pub fn name(self: *const ResourceArena) []const u8 {
    return self._name.constSlice();
}

pub const Source = struct {
    arena: *ResourceArena,

    import: *const fn (
        arena: *ResourceArena,
        current_task: *kernel.Task,
        len: usize,
        policy: Policy,
    ) AllocateError!Allocation = allocate,

    release: *const fn (
        arena: *ResourceArena,
        current_task: *kernel.Task,
        allocation: Allocation,
    ) void = deallocate,

    fn callImport(
        source: *const Source,
        current_task: *kernel.Task,
        len: usize,
        policy: Policy,
    ) callconv(core.inline_in_non_debug) AllocateError!Allocation {
        return source.import(source.arena, current_task, len, policy);
    }

    fn callRelease(
        source: *const Source,
        current_task: *kernel.Task,
        allocation: Allocation,
    ) callconv(core.inline_in_non_debug) void {
        source.release(source.arena, current_task, allocation);
    }
};

pub const CreateOptions = struct {
    source: ?Source = null,

    quantum_caching: QuantumCaching,

    pub const QuantumCaching = union(enum) {
        no,

        /// The number of multiples of the quantum to cache.
        ///
        /// Uses the heap resource arena to allocate the caches.
        yes: u6,

        /// The number of multiples of the quantum to cache.
        ///
        /// This should only be used by the heap resource arena itself.
        ///
        /// Uses the physical memory allocator and the hhdm to allocate the caches.
        heap: u6,
    };
};

pub const CreateError = error{
    /// The `quantum` is not a power of two.
    InvalidQuantum,

    /// The length of `name` exceeds `resource_arena_name_length`.
    NameTooLong,
};

const QuantumCacheAllocation = union(enum) {
    no,
    yes: []RawCache,
    heap: std.BoundedArray(kernel.mem.phys.Frame, FRAMES_FOR_MAX_NUMBER_OF_QUANTUM_CACHES),
};

pub fn create(
    arena: *ResourceArena,
    arena_name: []const u8,
    quantum: usize,
    options: CreateOptions,
) CreateError!void {
    if (!std.mem.isValidAlign(quantum)) return CreateError.InvalidQuantum;

    log.debug("{s}: creating arena with quantum 0x{x}", .{ arena_name, quantum });

    arena.* = .{
        ._name = Name.fromSlice(arena_name) catch return CreateError.NameTooLong,
        .quantum = quantum,
        .mutex = .{},
        .source = options.source,
        .all_tags = .empty,
        .spans = .empty,
        .allocation_table = @splat(.empty),
        .freelists = @splat(.empty),
        .freelist_bitmap = .empty,
        .unused_tags = .empty,
        .unused_tags_count = 0,
        .max_cached_size = undefined, // set below
        .quantum_caches = .{},
        .quantum_cache_allocation = undefined, // set below
    };

    switch (options.quantum_caching) {
        .no => {
            arena.max_cached_size = 0;
            arena.quantum_cache_allocation = .no;
        },
        .yes => |count| {
            std.debug.assert(count > 0);

            const quantum_caches = kernel.mem.heap.allocator.alloc(RawCache, count) catch
                @panic("quantum cache allocation failed"); // TODO: return this error

            for (quantum_caches, 0..) |*quantum_cache, i| {
                var cache_name: kernel.mem.cache.Name = .{};
                cache_name.writer().print("{s} qcache {}", .{ arena.name(), i + 1 }) catch unreachable;

                quantum_cache.init(.{
                    .cache_name = cache_name,
                    .size = quantum * (i + 1),
                    .alignment = .fromByteUnits(quantum),
                });
                arena.quantum_caches.append(quantum_cache) catch unreachable;
            }

            arena.quantum_cache_allocation = .{ .yes = quantum_caches };
            arena.max_cached_size = count * quantum;
        },
        .heap => |count| {
            std.debug.assert(count > 0);

            var frames: std.BoundedArray(
                kernel.mem.phys.Frame,
                FRAMES_FOR_MAX_NUMBER_OF_QUANTUM_CACHES,
            ) = .{};

            var caches_created: usize = 0;

            const frames_to_allocate = kernel.arch.paging.standard_page_size.amountToCover(
                core.Size.of(RawCache).multiplyScalar(count),
            );

            for (0..frames_to_allocate) |_| {
                const frame = kernel.mem.phys.allocator.allocate() catch
                    @panic("heap quantum cache allocation failed");
                frames.append(frame) catch unreachable;

                const frame_caches = kernel.mem.directMapFromPhysical(frame.baseAddress())
                    .toPtr(*[QUANTUM_CACHES_PER_FRAME]RawCache);

                for (frame_caches) |*cache| {
                    caches_created += 1;

                    var cache_name: kernel.mem.cache.Name = .{};
                    cache_name.writer().print("heap qcache {}", .{caches_created}) catch unreachable;

                    cache.init(.{
                        .cache_name = cache_name,
                        .size = quantum * (caches_created),
                        .alignment = .fromByteUnits(quantum),
                    });

                    arena.quantum_caches.append(cache) catch unreachable;

                    if (caches_created == count) break;
                }
            }

            arena.quantum_cache_allocation = .{ .heap = frames };
            arena.max_cached_size = count * quantum;
        },
    }
}

/// Destroy the resource arena.
///
/// Assumes that no concurrent access to the resource arena is happening, does not lock.
///
/// Panics if there are any allocations in the resource arena.
pub fn destroy(arena: *ResourceArena, current_task: *kernel.Task) void {
    log.debug("{s}: destroying arena", .{arena.name()});

    for (arena.quantum_caches.constSlice()) |quantum_cache| {
        quantum_cache.deinit(current_task);
    }

    switch (arena.quantum_cache_allocation) {
        .no => {},
        .yes => |caches| kernel.mem.heap.allocator.free(caches),
        .heap => |frames| {
            for (frames.constSlice()) |frame| {
                kernel.mem.phys.allocator.deallocate(frame);
            }
        },
    }

    var tags_to_release: SingleLinkedList = .empty;

    var any_allocations = false;

    // return imported spans and add all used boundary tags to the `tags_to_release` list
    while (arena.all_tags.pop()) |node| {
        const tag = node.toTag();

        switch (tag.kind) {
            .imported_span => arena.source.?.callRelease(
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

    // add all the tags in the `tags_to_release` list to the global unused tags list
    while (tags_to_release.pop()) |node| {
        globals.unused_tags.push(node);
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

pub const AddSpanError = error{
    ZeroLength,
    WouldWrap,
    Unaligned,
    Overlap,
} || EnsureBoundaryTagsError;

/// Add the span [base, base + len) to the arena.
///
/// Both `base` and `len` must be aligned to the arena's quantum.
///
/// O(N) runtime.
pub fn addSpan(arena: *ResourceArena, current_task: *kernel.Task, base: usize, len: usize) AddSpanError!void {
    log.debug("{s}: adding span [0x{x}, 0x{x})", .{ arena.name(), base, base + len });

    try arena.ensureBoundaryTags(current_task);
    defer arena.mutex.unlock(current_task);

    const span_tag, const free_tag =
        try arena.getTagsForNewSpan(base, len, false);
    errdefer {
        arena.pushUnusedTag(span_tag);
        arena.pushUnusedTag(free_tag);
    }

    try arena.addSpanInner(span_tag, free_tag, true);
}

fn getTagsForNewSpan(
    arena: *ResourceArena,
    base: usize,
    len: usize,
    imported_span: bool,
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
        .kind = if (imported_span) .imported_span else .span,
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
    arena: *ResourceArena,
    span_tag: *BoundaryTag,
    free_tag: *BoundaryTag,
    comptime add_free_span_to_freelist: bool,
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

    // insert the new free tag into the appropriate freelist
    if (add_free_span_to_freelist) {
        arena.pushToFreelist(free_tag);
    }
}

fn findSpanListPreviousSpan(
    arena: *const ResourceArena,
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

pub const Policy = enum {
    instant_fit,
    first_fit,
    best_fit,
};

pub const Allocation = struct {
    base: usize,
    len: usize,

    pub fn print(self: Allocation, writer: std.io.AnyWriter, indent: usize) !void {
        _ = indent;
        try writer.print("Allocation{{ base: 0x{x}, len: 0x{x} }}", .{ self.base, self.len });
    }

    pub inline fn format(
        self: Allocation,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(self, writer, 0)
        else
            print(self, writer.any(), 0);
    }
};

pub const AllocateError = error{
    ZeroLength,
    RequestedLengthUnavailable,
} || EnsureBoundaryTagsError;

/// Allocate a block of length `len` from the arena.
pub fn allocate(arena: *ResourceArena, current_task: *kernel.Task, len: usize, policy: Policy) AllocateError!Allocation {
    if (len == 0) return AllocateError.ZeroLength;

    const quantum_aligned_len = std.mem.alignForward(usize, len, arena.quantum);

    log.debug("{s}: allocating len 0x{x} (quantum_aligned_len: 0x{x}) with policy {s}", .{
        arena.name(),
        len,
        quantum_aligned_len,
        @tagName(policy),
    });

    if (quantum_aligned_len <= arena.max_cached_size) {
        const cache_index: usize = (quantum_aligned_len / arena.quantum) - 1;
        const cache = arena.quantum_caches.constSlice()[cache_index];
        std.debug.assert(cache.object_size == quantum_aligned_len);

        const buffer = cache.allocate(current_task) catch
            return AllocateError.RequestedLengthUnavailable; // TODO: is there a better way to handle this?
        std.debug.assert(buffer.len == quantum_aligned_len);

        return .{
            .base = @intFromPtr(buffer.ptr),
            .len = buffer.len,
        };
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

    log.debug("{s}: allocated {}", .{ arena.name(), allocation });

    return allocation;
}

fn findInstantFit(arena: *ResourceArena, quantum_aligned_len: usize) ?*BoundaryTag {
    if (arena.performStrictInstantFit(quantum_aligned_len)) |tag| {
        @branchHint(.likely);
        return tag;
    }

    return arena.performStrictFirstFit(quantum_aligned_len);
}

fn findBestFit(arena: *ResourceArena, quantum_aligned_len: usize) ?*BoundaryTag {
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

fn findFirstFit(arena: *ResourceArena, quantum_aligned_len: usize) ?*BoundaryTag {
    if (arena.performStrictFirstFit(quantum_aligned_len)) |tag| return tag;
    return arena.performStrictInstantFit(quantum_aligned_len);
}

/// Find a free tag in any freelist that is guaranteed to satisfy the requested size.
fn performStrictInstantFit(arena: *ResourceArena, quantum_aligned_len: usize) ?*BoundaryTag {
    const index = arena.indexOfNonEmptyFreelistInstantFit(quantum_aligned_len) orelse {
        @branchHint(.unlikely);
        return null;
    };
    const tag = arena.popFromFreelist(index) orelse unreachable;
    std.debug.assert(tag.kind == .free);
    return tag;
}

/// Search for the first fit tag in the freelist containing the requested size.
fn performStrictFirstFit(arena: *ResourceArena, quantum_aligned_len: usize) ?*BoundaryTag {
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
    arena: *ResourceArena,
    current_task: *kernel.Task,
    source: Source,
    len: usize,
) (AllocateError || AddSpanError)!*BoundaryTag {
    arena.mutex.unlock(current_task);

    log.debug("{s}: importing len 0x{x} from source {s}", .{ arena.name(), len, source.arena.name() });

    var need_to_lock_mutex = true;
    defer if (need_to_lock_mutex) arena.mutex.lock(current_task);

    const allocation = try source.callImport(current_task, len, .instant_fit);
    errdefer source.callRelease(current_task, allocation);

    try arena.ensureBoundaryTags(current_task);
    need_to_lock_mutex = false;

    const span_tag, const free_tag =
        try arena.getTagsForNewSpan(allocation.base, allocation.len, true);
    errdefer {
        arena.pushUnusedTag(span_tag);
        arena.pushUnusedTag(free_tag);
    }

    try arena.addSpanInner(span_tag, free_tag, false);

    log.debug("{s}: imported {} from source {s}", .{ arena.name(), allocation, source.arena.name() });

    return free_tag;
}

fn splitFreeTag(arena: *ResourceArena, tag: *BoundaryTag, allocation_len: usize) void {
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
pub fn deallocate(arena: *ResourceArena, current_task: *kernel.Task, allocation: Allocation) void {
    log.debug("{s}: deallocating {}", .{ arena.name(), allocation });

    std.debug.assert(std.mem.isAligned(allocation.base, arena.quantum));
    std.debug.assert(std.mem.isAligned(allocation.len, arena.quantum));

    if (allocation.len <= arena.max_cached_size) {
        const cache_index: usize = (allocation.len / arena.quantum) - 1;
        const cache = arena.quantum_caches.constSlice()[cache_index];
        std.debug.assert(cache.object_size == allocation.len);

        const buffer_ptr: [*]u8 = @ptrFromInt(allocation.base);
        const buffer = buffer_ptr[0..allocation.len];

        cache.free(current_task, buffer);

        return;
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

            log.debug("{s}: released {} to source {s}", .{ arena.name(), allocation_to_release, source.arena.name() });

            return;
        }
    }

    arena.pushToFreelist(tag);
}

pub const EnsureBoundaryTagsError = error{
    OutOfBoundaryTags,
};

/// Attempts to ensure that there are at least `min_unused_tags_count` unused tags.
///
/// Upon non-error return, the mutex is locked.
fn ensureBoundaryTags(arena: *ResourceArena, current_task: *kernel.Task) EnsureBoundaryTagsError!void {
    const static = struct {
        var allocate_tags_lock: kernel.sync.Mutex = .{};
    };

    while (true) {
        arena.mutex.lock(current_task);

        if (arena.unused_tags_count >= MAX_TAGS_PER_ALLOCATION) return;

        while (arena.unused_tags_count < MAX_TAGS_PER_ALLOCATION) {
            const node = globals.unused_tags.pop() orelse break;
            arena.pushUnusedTag(node.toTag());
        } else {
            return; // loop condition was false meaning we have enough tags
        }

        arena.mutex.unlock(current_task);
        static.allocate_tags_lock.lock(current_task);

        if (!globals.unused_tags.isEmpty()) {
            // someone else has populated the global unused tags, so try again
            static.allocate_tags_lock.unlock(current_task);
            continue;
        }

        log.debug("{s}: performing boundary tag allocation", .{arena.name()});

        const tags = blk: {
            const physical_frame = kernel.mem.phys.allocator.allocate() catch
                return EnsureBoundaryTagsError.OutOfBoundaryTags;
            errdefer comptime unreachable;

            const ptr = kernel.mem.directMapFromPhysical(physical_frame.baseAddress()).toPtr([*]BoundaryTag);
            break :blk ptr[0..TAGS_PER_PAGE];
        };
        errdefer comptime unreachable;
        std.debug.assert(tags.len >= MAX_TAGS_PER_ALLOCATION);

        @memset(tags, .empty(.free));

        const extra_tags = tags[MAX_TAGS_PER_ALLOCATION..];

        // give the extra tags to the global unused tags list
        for (extra_tags) |*tag| {
            globals.unused_tags.push(&tag.all_tag_node);
        }

        static.allocate_tags_lock.unlock(current_task);
        arena.mutex.lock(current_task);

        const maximum_needed_tags = tags[0..MAX_TAGS_PER_ALLOCATION];

        var tag_index: usize = 0;

        // restock the arena's unused tags
        while (arena.unused_tags_count < MAX_TAGS_PER_ALLOCATION) {
            arena.pushUnusedTag(&maximum_needed_tags[tag_index]);
            tag_index += 1;
        }

        // give the left over tags to the global unused tags list
        for (maximum_needed_tags[tag_index..]) |*tag| {
            globals.unused_tags.push(&tag.all_tag_node);
        }

        return;
    }
}

fn insertIntoAllocationTable(arena: *ResourceArena, tag: *BoundaryTag) void {
    std.debug.assert(tag.kind == .allocated);

    const index: HashIndex = @truncate(Wyhash.hash(0, std.mem.asBytes(&tag.base)));
    arena.allocation_table[index].push(&tag.kind_node);
}

fn removeFromAllocationTable(arena: *ResourceArena, base: usize) ?*BoundaryTag {
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

fn pushToFreelist(arena: *ResourceArena, tag: *BoundaryTag) void {
    std.debug.assert(tag.kind == .free);

    const index = indexOfFreelistContainingLen(tag.len);

    arena.freelists[index].push(&tag.kind_node);
    arena.freelist_bitmap.set(index);
}

fn popFromFreelist(arena: *ResourceArena, index: usize) ?*BoundaryTag {
    const freelist = &arena.freelists[index];

    const node = freelist.pop() orelse return null;

    if (freelist.isEmpty()) arena.freelist_bitmap.unset(index);

    const tag = node.toTag();
    std.debug.assert(tag.kind == .free);
    return tag;
}

fn removeFromFreelist(arena: *ResourceArena, tag: *BoundaryTag) void {
    std.debug.assert(tag.kind == .free);

    const index = indexOfFreelistContainingLen(tag.len);
    const freelist = &arena.freelists[index];

    freelist.remove(&tag.kind_node);
    if (freelist.isEmpty()) arena.freelist_bitmap.unset(index);
}

fn popUnusedTag(arena: *ResourceArena) *BoundaryTag {
    std.debug.assert(arena.unused_tags_count > 0);
    arena.unused_tags_count -= 1;
    const tag = arena.unused_tags.pop().?.toTag();
    std.debug.assert(tag.kind == .free);
    return tag;
}

fn pushUnusedTag(arena: *ResourceArena, tag: *BoundaryTag) void {
    std.debug.assert(tag.kind == .free);
    arena.unused_tags.push(&tag.all_tag_node);
    arena.unused_tags_count += 1;
}

fn indexOfNonEmptyFreelistInstantFit(arena: *const ResourceArena, len: usize) ?usize {
    const pow2_len = std.math.ceilPowerOfTwoAssert(usize, len);
    const index = @ctz(arena.freelist_bitmap.value & ~(pow2_len - 1));
    return if (index == NUMBER_OF_FREELISTS) null else index;
}

const BoundaryTag = struct {
    base: usize,
    len: usize,

    all_tag_node: AllTagNode,
    kind_node: KindNode,

    kind: Kind,

    const Kind = enum(u8) {
        /// the `all_tag_node` list is in order of ascending `base`
        /// the `kind_node` list is in order of ascending `base`
        /// `kind_node` linked into `ResourceArena.spans` along with `imported_span`
        span,

        /// the `all_tag_node` list is in order of ascending `base`
        /// the `kind_node` list is in order of ascending `base`
        /// `kind_node` linked into `ResourceArena.spans` along with `span`
        imported_span,

        /// the `all_tag_node` list is in order of ascending `base`
        /// the `kind_node` list has no guarantee of order
        /// `kind_node` linked into the matching power-of-2 freelist in `ResourceArena.freelists`
        free,

        /// the `all_tag_node` list is in order of ascending `base`
        /// the `kind_node` list has no guarantee of order
        /// `kind_node` linked into matching hash bucket in `ResourceArena.allocation_table`
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

    pub fn print(self: BoundaryTag, writer: std.io.AnyWriter, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("BoundaryTag{\n");

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("base: 0x{x},\n", .{self.base});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("len: 0x{x},\n", .{self.len});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("kind: {s},\n", .{@tagName(self.kind)});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.writeAll("all_tag_node: ");
        try self.all_tag_node.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.writeByteNTimes(' ', new_indent);
        try writer.writeAll("kind_node: ");
        try self.kind_node.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.writeByteNTimes(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(
        self: BoundaryTag,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(self, writer, 0)
        else
            print(self, writer.any(), 0);
    }
};

const AllTagNode = struct {
    previous: ?*AllTagNode,
    next: ?*AllTagNode,

    fn toTag(self: *AllTagNode) *BoundaryTag {
        return @fieldParentPtr("all_tag_node", self);
    }

    const empty: AllTagNode = .{ .previous = null, .next = null };

    pub fn print(self: AllTagNode, writer: std.io.AnyWriter, indent: usize) !void {
        _ = indent;

        try writer.writeAll("AllTagNode{ previous: ");
        if (self.previous != null) {
            try writer.writeAll("set");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(", next: ");
        if (self.next != null) {
            try writer.writeAll("set");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(" }");
    }

    pub inline fn format(
        self: AllTagNode,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(self, writer, 0)
        else
            print(self, writer.any(), 0);
    }
};

const KindNode = struct {
    previous: ?*KindNode,
    next: ?*KindNode,

    fn toTag(self: *KindNode) *BoundaryTag {
        return @fieldParentPtr("kind_node", self);
    }

    const empty: KindNode = .{ .previous = null, .next = null };

    pub fn print(self: KindNode, writer: std.io.AnyWriter, indent: usize) !void {
        _ = indent;

        try writer.writeAll("KindNode{ previous: ");
        if (self.previous != null) {
            try writer.writeAll("set");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(", next: ");
        if (self.next != null) {
            try writer.writeAll("set");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(" }");
    }

    pub inline fn format(
        self: KindNode,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(self, writer, 0)
        else
            print(self, writer.any(), 0);
    }
};

const Bitmap = struct {
    value: usize,

    const empty: Bitmap = .{ .value = 0 };

    fn set(self: *Bitmap, index: usize) void {
        self.value |= maskBit(index);
    }

    fn unset(self: *Bitmap, index: usize) void {
        self.value &= ~maskBit(index);
    }

    inline fn maskBit(index: usize) usize {
        return @as(usize, 1) << @as(UsizeShiftInt, @intCast(index));
    }
};

/// A single linked list, that uses `AllTagNode.next` as the link.
const SingleLinkedList = struct {
    first: ?*AllTagNode,

    const empty: SingleLinkedList = .{ .first = null };

    fn push(self: *SingleLinkedList, node: *AllTagNode) void {
        std.debug.assert(node.previous == null and node.next == null);

        node.* = .{ .next = self.first, .previous = null };

        self.first = node;
    }

    fn pop(self: *SingleLinkedList) ?*AllTagNode {
        const node = self.first orelse return null;
        std.debug.assert(node.previous == null);

        self.first = node.next;

        node.* = .empty;

        return node;
    }
};

/// A double linked list, that uses `Node` as the link.
fn DoubleLinkedList(comptime Node: type) type {
    return struct {
        first: ?*Node,

        const Self = @This();

        const empty: Self = .{ .first = null };

        /// Push a node to the front of the list.
        fn push(self: *Self, node: *Node) void {
            std.debug.assert(node.previous == null and node.next == null);

            const opt_first = self.first;

            node.next = opt_first;

            if (opt_first) |first| {
                std.debug.assert(first.previous == null);
                first.previous = node;
            }

            node.previous = null;
            self.first = node;
        }

        /// Pop a node from the front of the list.
        fn pop(self: *Self) ?*Node {
            const first = self.first orelse return null;
            std.debug.assert(first.previous == null);

            const opt_next = first.next;

            if (opt_next) |next| {
                std.debug.assert(next.previous == first);
                next.previous = null;
            }

            self.first = opt_next;

            first.* = .empty;

            return first;
        }

        /// Removes a node from the list.
        fn remove(self: *Self, node: *Node) void {
            if (node.previous) |previous| {
                std.debug.assert(previous.next == node);
                previous.next = node.next;
            } else {
                self.first = node.next;
            }

            if (node.next) |next| {
                std.debug.assert(next.previous == node);
                next.previous = node.previous;
            }

            node.* = .empty;
        }

        pub fn insertAfter(self: *Self, node: *Node, opt_previous: ?*Node) void {
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
                if (self.first) |first| {
                    std.debug.assert(first.previous == null);
                    first.previous = node;
                    node.next = first;
                }

                self.first = node;
            }
        }

        inline fn isEmpty(self: *const Self) bool {
            return self.first == null;
        }
    };
}

/// An atomic single linked list, that uses `AllTagNode.next` as the link.
const AtomicSingleLinkedList = struct {
    first: std.atomic.Value(?*AllTagNode),

    const empty: AtomicSingleLinkedList = .{ .first = .init(null) };

    pub fn isEmpty(self: *const AtomicSingleLinkedList) bool {
        return self.first.load(.acquire) == null;
    }

    fn push(self: *AtomicSingleLinkedList, node: *AllTagNode) void {
        std.debug.assert(node.previous == null and node.next == null);

        var opt_first = self.first.load(.monotonic);

        while (true) {
            node.next = opt_first;

            if (self.first.cmpxchgWeak(
                opt_first,
                node,
                .acq_rel,
                .monotonic,
            )) |new_value| {
                opt_first = new_value;
                continue;
            }

            return;
        }
    }

    fn pop(self: *AtomicSingleLinkedList) ?*AllTagNode {
        var opt_first = self.first.load(.monotonic);

        while (opt_first) |first| {
            if (self.first.cmpxchgWeak(
                opt_first,
                first.next,
                .acq_rel,
                .monotonic,
            )) |new_value| {
                opt_first = new_value;
                continue;
            }
            std.debug.assert(first.previous == null);

            first.* = .empty;

            break;
        }

        return opt_first;
    }
};

inline fn indexOfFreelistContainingLen(len: usize) usize {
    return NUMBER_OF_FREELISTS - 1 - @clz(len);
}

inline fn smallestPossibleLenInFreelist(index: usize) usize {
    const truncated_len: UsizeShiftInt = @truncate(index);
    return @as(usize, 1) << @truncate(truncated_len);
}

const MAX_NUMBER_OF_QUANTUM_CACHES = 64;
const QUANTUM_CACHES_PER_FRAME = kernel.arch.paging.standard_page_size.divide(core.Size.of(RawCache)).value;
const FRAMES_FOR_MAX_NUMBER_OF_QUANTUM_CACHES = MAX_NUMBER_OF_QUANTUM_CACHES / QUANTUM_CACHES_PER_FRAME;

const NUMBER_OF_HASH_BUCKETS = 64;
const HashIndex: type = std.math.Log2Int(std.meta.Int(.unsigned, NUMBER_OF_HASH_BUCKETS));

const NUMBER_OF_FREELISTS = @bitSizeOf(usize);
const UsizeShiftInt: type = std.math.Log2Int(usize);

const TAGS_PER_SPAN_CREATE = 2;
const TAGS_PER_EXACT_ALLOCATION = 0;
const TAGS_PER_PARTIAL_ALLOCATION = 1;
const MAX_TAGS_PER_ALLOCATION = TAGS_PER_SPAN_CREATE + TAGS_PER_PARTIAL_ALLOCATION;

const TAGS_PER_PAGE = kernel.arch.paging.standard_page_size.value / @sizeOf(BoundaryTag);

pub const Name = std.BoundedArray(u8, kernel.config.resource_arena_name_length);

const globals = struct {
    /// The global list of unused boundary tags.
    var unused_tags: AtomicSingleLinkedList = .empty;
};

const RawCache = kernel.mem.cache.RawCache;

const std = @import("std");
const Wyhash = std.hash.Wyhash;
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.resource_arena);
