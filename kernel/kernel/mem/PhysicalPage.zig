// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");

const PhysicalPage = @This();

node: List.Node = .{},

pub inline fn fromIndex(index: Index) *PhysicalPage {
    if (core.is_debug) std.debug.assert(index != .none);
    return &globals.pages[@intFromEnum(index)];
}

pub const Index = enum(u32) {
    none = std.math.maxInt(u32),

    _,

    /// Returns the physical page that contains the given physical address.
    pub fn fromAddress(physical_address: core.PhysicalAddress) Index {
        return @enumFromInt(physical_address.value / arch.paging.standard_page_size.value);
    }

    /// Returns the base address of the given physical page.
    pub fn baseAddress(index: Index) core.PhysicalAddress {
        return .fromInt(@intFromEnum(index) * arch.paging.standard_page_size.value);
    }
};

pub const allocator: Allocator = .{
    .allocate = allocate,
    .deallocate = deallocate,
};

pub const Allocator = struct {
    allocate: Allocate,
    deallocate: Deallocate,

    pub const AllocateError = error{PagesExhausted};

    pub const Allocate = *const fn () AllocateError!Index;
    pub const Deallocate = *const fn (list: List) void;
};

fn allocate() Allocator.AllocateError!Index {
    const index = globals.free_page_list.popFirst() orelse return error.PagesExhausted;

    _ = globals.free_memory.fetchSub(
        arch.paging.standard_page_size.value,
        .release,
    );

    if (core.is_debug) {
        const virtual_range: core.VirtualRange = .fromAddr(
            kernel.mem.directMapFromPhysical(index.baseAddress()),
            arch.paging.standard_page_size,
        );

        @memset(virtual_range.toByteSlice(), undefined);
    }

    return index;
}

fn deallocate(list: List) void {
    if (list.count == 0) {
        @branchHint(.unlikely);
        return;
    }

    _ = globals.free_memory.fetchAdd(
        arch.paging.standard_page_size.multiplyScalar(list.count).value,
        .release,
    );

    globals.free_page_list.prependList(list);
}

/// A non-atomic singly linked list of physical pages.
///
/// Tracks both first and last index to allow `List.Atomic` to atomically prepend the whole list.
///
/// Tracks the count to allow `deallocate` to atomically update the amount of free memory.
pub const List = struct {
    first_index: Index = .none,
    last_index: Index = .none,
    count: u32 = 0,

    pub const Node = struct {
        next: Index = .none,
    };

    pub fn prepend(list: *List, index: Index) void {
        const page: *PhysicalPage = .fromIndex(index);

        page.node.next = list.first_index;
        list.first_index = index;
        if (list.last_index == .none) {
            @branchHint(.unlikely);
            list.last_index = index;
        }
        list.count += 1;
    }

    pub const Atomic = struct {
        first_index: std.atomic.Value(Index) = .init(.none),

        /// Removes the first index from the list and returns it.
        pub fn popFirst(atomic_list: *Atomic) ?Index {
            var first = atomic_list.first_index.load(.monotonic);

            while (first != .none) {
                const page: *PhysicalPage = .fromIndex(first);
                const node = &page.node;

                if (atomic_list.first_index.cmpxchgWeak(
                    first,
                    node.next,
                    .acq_rel,
                    .monotonic,
                )) |new_first| {
                    first = new_first;
                    continue;
                }

                node.* = .{};
                return first;
            }

            return null;
        }

        /// Prepend a single index to the front of the list.
        ///
        /// Asserts that `index` is not `.none`.
        pub fn prepend(atomic_list: *Atomic, index: Index) void {
            atomic_list.prependList(.{
                .first_index = index,
                .last_index = index,
                .count = 1,
            });
        }

        /// Prepend a linked list to the front of the list.
        ///
        /// The provided list is expected to be already linked correctly.
        ///
        /// `first_index` and `last_index` can be the same index.
        ///
        /// Asserts that `first_index` and `last_index` are not `.none`.
        pub fn prependList(atomic_list: *Atomic, list: List) void {
            if (core.is_debug) {
                std.debug.assert(list.first_index != .none);
                std.debug.assert(list.last_index != .none);
            }

            const last_page: *PhysicalPage = .fromIndex(list.last_index);
            const last_node = &last_page.node;
            const new_first_index = list.first_index;

            var first = atomic_list.first_index.load(.monotonic);

            while (true) {
                last_node.next = first;

                if (atomic_list.first_index.cmpxchgWeak(
                    first,
                    new_first_index,
                    .acq_rel,
                    .monotonic,
                )) |new_first| {
                    first = new_first;
                    continue;
                }

                return;
            }
        }
    };
};

const globals = struct {
    /// The list of free pages.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var free_page_list: List.Atomic = .{};

    /// The free physical memory.
    ///
    /// Updates to this value are eventually consistent.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var free_memory: std.atomic.Value(u64) = undefined;

    /// The total physical memory.
    ///
    /// Does not change during the lifetime of the system.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var total_memory: core.Size = undefined;

    /// The reserved physical memory.
    ///
    /// Does not change during the lifetime of the system.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var reserved_memory: core.Size = undefined;

    /// The reclaimable physical memory.
    ///
    /// Will be reduced when the memory is reclaimed. // TODO: reclaim memory
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var reclaimable_memory: core.Size = undefined;

    /// The unavailable physical memory.
    ///
    /// Does not change during the lifetime of the system.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var unavailable_memory: core.Size = undefined;

    /// A `PhysicalPage` for each physical page.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var pages: []PhysicalPage = undefined;
};

pub const init = struct {
    const boot = @import("boot");
    const init_log = kernel.debug.log.scoped(.mem_init);

    pub const bootstrap_allocator: Allocator = .{
        .allocate = struct {
            fn allocate() !Index {
                const non_empty_region: *FreePhysicalRegion =
                    region: for (init_globals.bootstrap_physical_regions.slice()) |*region| {
                        if (region.first_free_page_index < region.page_count) break :region region;
                    } else {
                        for (init_globals.bootstrap_physical_regions.constSlice()) |region| {
                            init_log.warn("  region: {}", .{region});
                        }

                        @panic("no empty region in bootstrap physical page allocator");
                    };

                const first_free_page_index = non_empty_region.first_free_page_index;
                non_empty_region.first_free_page_index = first_free_page_index + 1;

                return @enumFromInt(@intFromEnum(non_empty_region.start_physical_page) + first_free_page_index);
            }
        }.allocate,
        .deallocate = struct {
            fn deallocate(_: List) void {
                @panic("deallocate not supported");
            }
        }.deallocate,
    };

    /// Initialize the bootstrap physical page allocator that is used for allocating physical pages before the full memory
    /// system is initialized.
    pub fn initializeBootstrapAllocator() void {
        var memory_map = boot.memoryMap(.forward) catch @panic("no memory map");
        while (memory_map.next()) |entry| {
            if (entry.type != .free) continue;

            const range: core.PhysicalRange = if (entry.range.containsAddress(Index.baseAddress(.none))) blk: {
                // trim the range to ensure the `.none` page is not counted as a free page

                // TODO: this discards all memory above the `.none` page, but only in the range that contains it
                //       instead once that page is encountered we should stop trying to find more free regions here
                //       then in `initializePhysicalMemory` we should print a warning if there is memory above or equal to the `.none` page
                //       if that ever happens then `Index` would need to be changed to use a larger type

                init_log.warn("memory map entry contains `PhysicalPage.Index.none`: {f}", .{entry});

                const new_size: core.Size = .from(Index.baseAddress(.none).value - entry.range.address.value, .byte);
                std.debug.assert(new_size.isAligned(arch.paging.standard_page_size));

                if (new_size.equal(.zero)) continue;

                break :blk .fromAddr(entry.range.address, new_size);
            } else entry.range;

            init_globals.bootstrap_physical_regions.append(.{
                .start_physical_page = .fromAddress(range.address),
                .first_free_page_index = 0,
                .page_count = @intCast(std.math.divExact(
                    usize,
                    range.size.value,
                    arch.paging.standard_page_size.value,
                ) catch std.debug.panic(
                    "memory map entry size is not a multiple of page size: {f}",
                    .{entry},
                )),
            }) catch @panic("exceeded max number of physical regions");
        }
    }

    /// Maps the pages array sparsely, only backing regions corresponding to usable physical memory.
    pub fn mapPagesArray(
        kernel_page_table: arch.paging.PageTable,
        pages_array_range: core.VirtualRange,
    ) !void {
        const pages_array_base = pages_array_range.address;

        var current_range_start: ?usize = null;
        var current_range_end: usize = 0;

        var memory_iter = boot.memoryMap(.forward) catch @panic("no memory map");

        while (memory_iter.next()) |entry| {
            if (!entry.type.isUsable()) continue;

            const entry_range_start = std.mem.alignBackward(
                usize,
                @intFromEnum(Index.fromAddress(
                    entry.range.address,
                )) * @sizeOf(PhysicalPage),
                arch.paging.standard_page_size.value,
            );

            const entry_range_end = std.mem.alignForward(
                usize,
                (@intFromEnum(Index.fromAddress(
                    entry.range.last(),
                )) + 1) * @sizeOf(PhysicalPage),
                arch.paging.standard_page_size.value,
            );

            if (current_range_start) |range_start| {
                if (entry_range_start <= current_range_end) {
                    // extend the current range
                    current_range_end = @max(current_range_end, entry_range_end);
                } else {
                    // map the current range and start a new one

                    try kernel.mem.mapRangeAndBackWithPhysicalPages(
                        kernel_page_table,
                        .fromAddr(
                            pages_array_base.moveForward(.from(range_start, .byte)),
                            .from(current_range_end - range_start, .byte),
                        ),
                        .{ .protection = .read_write, .type = .kernel },
                        .kernel,
                        .keep,
                        bootstrap_allocator,
                    );

                    current_range_start = entry_range_start;
                    current_range_end = entry_range_end;
                }
            } else {
                current_range_start = entry_range_start;
                current_range_end = entry_range_end;
            }
        }

        if (current_range_start) |range_start| {
            // handle the last range
            try kernel.mem.mapRangeAndBackWithPhysicalPages(
                kernel_page_table,
                .fromAddr(
                    pages_array_base.moveForward(.from(range_start, .byte)),
                    .from(current_range_end - range_start, .byte),
                ),
                .{ .protection = .read_write, .type = .kernel },
                .kernel,
                .keep,
                bootstrap_allocator,
            );
        }
    }

    /// Initializes the normal physical page allocator and the pages array.
    ///
    /// Pulls all memory out of the bootstrap physical page allocator and uses it to populate the normal allocator.
    pub fn initializePhysicalMemory(pages_range: core.VirtualRange) void {
        const pages: []PhysicalPage = @alignCast(std.mem.bytesAsSlice(
            PhysicalPage,
            pages_range.toByteSlice(),
        ));
        globals.pages = pages;

        var total_memory: core.Size = .zero;
        var reserved_memory: core.Size = .zero;
        var reclaimable_memory: core.Size = .zero;
        var unavailable_memory: core.Size = .zero;

        var memory_iter = boot.memoryMap(.forward) catch @panic("no memory map");

        while (memory_iter.next()) |entry| {
            total_memory.addInPlace(entry.range.size);

            switch (entry.type) {
                .free, .in_use => {},
                .reserved => reserved_memory.addInPlace(entry.range.size),
                .bootloader_reclaimable, .acpi_reclaimable => reclaimable_memory.addInPlace(entry.range.size),
                .unusable, .unknown => unavailable_memory.addInPlace(entry.range.size),
            }

            if (entry.type.isUsable()) {
                const first_page_index: usize = @intFromEnum(PhysicalPage.Index.fromAddress(entry.range.address));
                const length = entry.range.size.divide(arch.paging.standard_page_size) + 1;

                const slice = pages[first_page_index..][0..length];

                @memset(slice, .{});
            }

            if (entry.range.address.equal(.zero)) {
                pages[0] = undefined;
            }
        }

        var free_memory: core.Size = .zero;

        const bootstrap_regions = init_globals.bootstrap_physical_regions;
        init_globals.bootstrap_physical_regions = undefined;

        for (bootstrap_regions.constSlice()) |bootstrap_region| {
            std.debug.assert(
                (@intFromEnum(bootstrap_region.start_physical_page) + bootstrap_region.page_count - 1) < @intFromEnum(Index.none),
            );

            const in_use_pages = bootstrap_region.first_free_page_index;
            const free_pages = bootstrap_region.page_count - in_use_pages;

            free_memory.addInPlace(arch.paging.standard_page_size.multiplyScalar(free_pages));

            if (init_log.levelEnabled(.debug)) {
                if (in_use_pages == 0) {
                    init_log.debug(
                        "pulled {} ({f}) free pages out of bootstrap page allocator region",
                        .{
                            free_pages,
                            arch.paging.standard_page_size.multiplyScalar(free_pages),
                        },
                    );
                } else if (in_use_pages == bootstrap_region.page_count) {
                    init_log.debug(
                        "pulled {} ({f}) in use pages out of bootstrap page allocator region",
                        .{
                            in_use_pages,
                            arch.paging.standard_page_size.multiplyScalar(in_use_pages),
                        },
                    );
                } else {
                    init_log.debug(
                        "pulled {} ({f}) free pages and {} ({f}) in use pages out of bootstrap page allocator region",
                        .{
                            free_pages,
                            arch.paging.standard_page_size.multiplyScalar(free_pages),
                            in_use_pages,
                            arch.paging.standard_page_size.multiplyScalar(in_use_pages),
                        },
                    );
                }
            }

            var current_free_index: u32 = @intFromEnum(bootstrap_region.start_physical_page) + bootstrap_region.first_free_page_index;
            const last_free_index: u32 = @intFromEnum(bootstrap_region.start_physical_page) + bootstrap_region.page_count - 1;

            while (current_free_index <= last_free_index) : (current_free_index += 1) {
                globals.free_page_list.prepend(@enumFromInt(current_free_index));
            }
        }

        globals.free_memory.store(free_memory.value, .release);
        globals.total_memory = total_memory;
        globals.reserved_memory = reserved_memory;
        globals.reclaimable_memory = reclaimable_memory;
        globals.unavailable_memory = unavailable_memory;

        const used_memory = total_memory
            .subtract(free_memory)
            .subtract(reserved_memory)
            .subtract(reclaimable_memory)
            .subtract(unavailable_memory);

        init_log.debug("total memory:         {f}", .{total_memory});
        init_log.debug("  free memory:        {f}", .{free_memory});
        init_log.debug("  used memory:        {f}", .{used_memory});
        init_log.debug("  reserved memory:    {f}", .{reserved_memory});
        init_log.debug("  reclaimable memory: {f}", .{reclaimable_memory});
        init_log.debug("  unavailable memory: {f}", .{unavailable_memory});
    }

    const FreePhysicalRegion = struct {
        /// The first page of the region.
        start_physical_page: Index,

        /// Index of the first free page in this region.
        first_free_page_index: u32,

        /// Total number of pages in the region.
        page_count: u32,

        pub const List = core.containers.BoundedArray(FreePhysicalRegion, max_regions);
        const max_regions: usize = 64;
    };

    const init_globals = struct {
        /// The physical regions used by the bootstrap allocator.
        ///
        /// Initialized during `init.initializeBootstrapPageAllocator`.
        var bootstrap_physical_regions: FreePhysicalRegion.List = .{};
    };
};
