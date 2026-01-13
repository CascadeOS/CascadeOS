// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");

const PhysicalPage = @This();

// TODO: replace this with one using `Index` directly rather than pointers
node: std.SinglyLinkedList.Node = .{},

pub inline fn fromNode(node: *std.SinglyLinkedList.Node) *PhysicalPage {
    return @fieldParentPtr("node", node);
}

pub inline fn fromIndex(index: Index) *PhysicalPage {
    return &globals.pages[@intFromEnum(index)];
}

pub const Index = enum(u32) {
    none = 0,

    _,

    /// Returns the physical page that contains the given physical address.
    pub fn fromAddress(physical_address: core.PhysicalAddress) Index {
        return @enumFromInt(physical_address.value / arch.paging.standard_page_size.value);
    }

    /// Returns the base address of the given physical page.
    pub fn baseAddress(index: Index) core.PhysicalAddress {
        return .fromInt(@intFromEnum(index) * arch.paging.standard_page_size.value);
    }

    pub fn fromPage(physical_page: *const PhysicalPage) Index {
        return @enumFromInt(physical_page - &globals.pages[0]);
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
    const node = globals.free_page_list.popFirst() orelse return error.PagesExhausted;

    _ = globals.free_memory.fetchSub(
        arch.paging.standard_page_size.value,
        .release,
    );

    const index: Index = .fromPage(.fromNode(node));

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

    globals.free_page_list.prependList(list.first_node.?, list.last_node.?);
}

pub const List = struct {
    first_node: ?*std.SinglyLinkedList.Node = null,
    last_node: ?*std.SinglyLinkedList.Node = null,
    count: usize = 0,

    pub fn prepend(list: *List, index: Index) void {
        const page: *PhysicalPage = .fromIndex(index);
        const node = &page.node;

        node.next = list.first_node;
        list.first_node = node;
        if (list.last_node == null) {
            @branchHint(.unlikely);
            list.last_node = node;
        }
        list.count += 1;
    }
};

        list.count += 1;
    }
};

const globals = struct {
    /// The list of free pages.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var free_page_list: core.containers.AtomicSinglyLinkedList = .{};

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

            const range: core.PhysicalRange = if (entry.range.address.equal(.zero)) blk: {
                // the zero page is reserved for `Index.none`

                if (entry.range.size.lessThanOrEqual(arch.paging.standard_page_size)) continue;

                break :blk .fromAddr(
                    entry.range.address.moveForward(arch.paging.standard_page_size),
                    entry.range.size.subtract(arch.paging.standard_page_size),
                );
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

    /// Initializes the normal physical page allocator and the pages array.
    ///
    /// Pulls all memory out of the bootstrap physical page allocator and uses it to populate the normal allocator.
    pub fn initializePhysicalMemory(pages_range: core.VirtualRange) void {
        const pages: []PhysicalPage = blk: {
            var byte_slice = pages_range.toByteSlice();
            byte_slice.len = std.mem.alignBackward(
                usize,
                byte_slice.len,
                std.mem.Alignment.of(PhysicalPage).toByteUnits(),
            );
            break :blk @alignCast(std.mem.bytesAsSlice(PhysicalPage, byte_slice));
        };
        globals.pages = pages;

        var total_memory: core.Size = .zero;

        var reserved_memory: core.Size = .zero;
        var reclaimable_memory: core.Size = .zero;
        var unavailable_memory: core.Size = .zero;

        var memory_iter = boot.memoryMap(.forward) catch @panic("no memory map");

        while (memory_iter.next()) |entry| {
            total_memory.addInPlace(entry.range.size);

            const populate_pages_in_range = blk: switch (entry.type) {
                .free, .in_use => true,
                .reserved => {
                    reserved_memory.addInPlace(entry.range.size);
                    break :blk false;
                },
                .bootloader_reclaimable, .acpi_reclaimable => {
                    reclaimable_memory.addInPlace(entry.range.size);
                    break :blk true;
                },
                .unusable, .unknown => {
                    unavailable_memory.addInPlace(entry.range.size);
                    break :blk false;
                },
            };

            if (populate_pages_in_range) {
                const first_page_index: usize = @intFromEnum(PhysicalPage.Index.fromAddress(entry.range.address));
                const last_page_index: usize = @intFromEnum(PhysicalPage.Index.fromAddress(entry.range.last()));

                const slice = pages[first_page_index..(first_page_index + last_page_index)];

                @memset(slice, .{});
            }
        }

        var free_memory: core.Size = .zero;
        var free_page_list: std.SinglyLinkedList = .{};

        for (init_globals.bootstrap_physical_regions.constSlice()) |bootstrap_region| {
            std.debug.assert(bootstrap_region.start_physical_page != .none);

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
                free_page_list.prepend(&pages[current_free_index].node);
            }
        }

        globals.free_page_list.first.store(free_page_list.first, .release);
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

        init_globals.bootstrap_physical_regions = .{};
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
