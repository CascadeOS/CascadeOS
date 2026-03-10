// SPDX-License-Identifier: LicenseRef-NON-AI-MIT OR MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: Zig contributors

const std = @import("std");
const Symbol = std.debug.Symbol;
const Error = std.debug.SelfInfoError;
const Dwarf = std.debug.Dwarf;
pub const UnwindContext = Dwarf.SelfUnwinder;

const arch = @import("arch");
const boot = @import("boot");
const cascade = @import("cascade");
const core = @import("core");

const native_endian = @import("builtin").target.cpu.arch.endian();
const SelfInfo = @This();

lock: cascade.sync.TicketSpinLock,

module: ?Module,
ranges: std.ArrayList(Module.Range),

unwind_cache: ?[]Dwarf.SelfUnwinder.CacheEntry,

pub const init: SelfInfo = .{
    .lock = .{},
    .module = null,
    .ranges = .empty,
    .unwind_cache = null,
};

pub fn deinit(_: *SelfInfo, _: std.Io) void {
    @panic("deinit not supported");
}

pub fn getSymbol(si: *SelfInfo, _: std.Io, address: usize) Error!Symbol {
    const gpa = std.debug.getDebugInfoAllocator();

    si.lock.lock();
    defer si.lock.unlock();

    const module = try si.getModule(gpa, address);

    const vaddr = address - module.load_offset;

    const loaded_elf = try module.getLoadedElf(gpa);
    if (loaded_elf.file.dwarf) |*dwarf| {
        if (!loaded_elf.scanned_dwarf) {
            dwarf.open(gpa, native_endian) catch |err| switch (err) {
                error.InvalidDebugInfo,
                error.MissingDebugInfo,
                error.OutOfMemory,
                => |e| return e,
                error.EndOfStream,
                error.Overflow,
                error.ReadFailed,
                error.StreamTooLong,
                => return error.InvalidDebugInfo,
            };
            loaded_elf.scanned_dwarf = true;
        }
        if (dwarf.getSymbol(gpa, native_endian, vaddr)) |sym| {
            return sym;
        } else |err| switch (err) {
            error.MissingDebugInfo => {},

            error.InvalidDebugInfo,
            error.OutOfMemory,
            => |e| return e,

            error.ReadFailed,
            error.EndOfStream,
            error.Overflow,
            error.StreamTooLong,
            => return error.InvalidDebugInfo,
        }
    }
    // When DWARF is unavailable, fall back to searching the symtab.
    return loaded_elf.file.searchSymtab(gpa, vaddr) catch |err| switch (err) {
        error.NoSymtab, error.NoStrtab => return error.MissingDebugInfo,
        error.BadSymtab => return error.InvalidDebugInfo,
        error.OutOfMemory => |e| return e,
    };
}

pub fn getModuleName(_: *SelfInfo, _: std.Io, _: usize) Error![]const u8 {
    return "kernel";
}

pub fn getModuleSlide(_: *SelfInfo, _: std.Io, _: usize) Error!usize {
    @compileError("getModuleSlide unimplemented");
}

pub fn unwindFrame(si: *SelfInfo, _: std.Io, context: *UnwindContext) Error!usize {
    const gpa = std.debug.getDebugInfoAllocator();

    si.lock.lock();
    defer si.lock.unlock();

    if (si.unwind_cache) |cache| {
        if (UnwindContext.CacheEntry.find(cache, context.pc)) |entry| {
            return context.next(gpa, entry);
        }
    }

    const module = try si.getModule(gpa, context.pc);

    if (si.unwind_cache == null) {
        si.unwind_cache = try gpa.alloc(Dwarf.SelfUnwinder.CacheEntry, 2048);
        @memset(si.unwind_cache.?, .empty);
    }

    const unwind_sections = try module.getUnwindSections(gpa);
    for (unwind_sections) |*unwind| {
        if (context.computeRules(gpa, unwind, module.load_offset, null)) |entry| {
            entry.populate(si.unwind_cache.?);
            return context.next(gpa, &entry);
        } else |err| switch (err) {
            error.MissingDebugInfo => continue,

            error.InvalidDebugInfo,
            error.UnsupportedDebugInfo,
            error.OutOfMemory,
            => |e| return e,

            error.EndOfStream,
            error.StreamTooLong,
            error.ReadFailed,
            error.Overflow,
            error.InvalidOpcode,
            error.InvalidOperation,
            error.InvalidOperand,
            => return error.InvalidDebugInfo,

            error.UnimplementedUserOpcode,
            error.UnsupportedAddrSize,
            => return error.UnsupportedDebugInfo,
        }
    }
    return error.MissingDebugInfo;
}

pub const can_unwind: bool = switch (arch.current_arch) {
    .arm => true,
    .riscv => true,
    .x64 => true,
};

comptime {
    if (can_unwind) std.debug.assert(Dwarf.supportsUnwinding(&@import("builtin").target));
}

fn getModule(si: *SelfInfo, gpa: std.mem.Allocator, address: usize) Error!*Module {
    std.debug.assert(si.lock.isLockedByCurrent());

    if (si.module == null) {
        const load_offset = if (boot.kernelBaseAddress()) |base_address|
            cascade.config.mem.kernel_base_address.difference(base_address.virtual).value
        else
            0;

        const kernel_elf_slice = boot.kernelExecutableFile() orelse return error.MissingDebugInfo;

        const header = cascade.user.elf.Header.parse(kernel_elf_slice) catch return error.InvalidDebugInfo;

        const program_headers_location = header.programHeaderTableLocation();

        var program_headers = header.iterateProgramHeaders(
            kernel_elf_slice[program_headers_location.base..][0..program_headers_location.length],
        );

        var build_id: ?[]const u8 = null;
        var gnu_eh_frame: ?[]const u8 = null;

        var ranges: std.ArrayList(Module.Range) = .empty;
        errdefer ranges.deinit(gpa);

        while (program_headers.next()) |program_header| {
            switch (program_header.type) {
                .load => try ranges.append(gpa, .{
                    .start = program_header.virtual_address + load_offset,
                    .len = program_header.memory_size,
                }),
                .gnu_eh_frame => {
                    const segment_ptr: [*]const u8 = @ptrFromInt(load_offset + program_header.virtual_address);
                    gnu_eh_frame = segment_ptr[0..program_header.memory_size];
                },
                .note => {
                    std.debug.assert(program_header.file_size == program_header.memory_size);
                    var r: std.Io.Reader = .fixed(kernel_elf_slice[program_header.offset..][0..program_header.file_size]);
                    const name_size = r.takeInt(u32, native_endian) catch continue;
                    const desc_size = r.takeInt(u32, native_endian) catch continue;
                    const note_type = r.takeInt(u32, native_endian) catch continue;
                    const name = r.take(name_size) catch continue;
                    if (note_type != std.elf.NT_GNU_BUILD_ID) continue;
                    if (!std.mem.eql(u8, name, "GNU\x00")) continue;
                    const desc = r.take(desc_size) catch continue;
                    build_id = desc;
                },
                else => {},
            }
        }

        si.ranges = ranges;
        si.module = .{
            .load_offset = load_offset,
            .build_id = build_id,
            .gnu_eh_frame = gnu_eh_frame,
            .unwind = null,
            .loaded_elf = null,
            .mapped_elf = kernel_elf_slice,
        };
    }

    const module = &si.module.?;

    for (si.ranges.items) |range| {
        if (address >= range.start and address < range.start + range.len) {
            return module;
        }
    }

    return error.MissingDebugInfo;
}

const Module = struct {
    load_offset: usize,

    build_id: ?[]const u8,
    gnu_eh_frame: ?[]const u8,

    /// `null` means unwind information has not yet been loaded.
    unwind: ?(Error!UnwindSections),

    /// `null` means the ELF file has not yet been loaded.
    loaded_elf: ?(Error!LoadedElf),

    mapped_elf: []align(std.heap.page_size_min) const u8,

    const LoadedElf = struct {
        file: ElfFile,
        scanned_dwarf: bool,
    };

    const ElfFile = @import("ElfFile.zig");

    const UnwindSections = struct {
        buf: [2]Dwarf.Unwind,
        len: usize,
    };

    const Range = struct {
        start: usize,
        len: usize,
    };

    /// Assumes we already have the lock.
    fn getUnwindSections(mod: *Module, gpa: std.mem.Allocator) Error![]Dwarf.Unwind {
        if (mod.unwind == null) mod.unwind = mod.loadUnwindSections(gpa);
        const us = &(mod.unwind.? catch |err| return err);
        return us.buf[0..us.len];
    }
    fn loadUnwindSections(mod: *Module, gpa: std.mem.Allocator) Error!UnwindSections {
        var us: UnwindSections = .{
            .buf = undefined,
            .len = 0,
        };
        if (mod.gnu_eh_frame) |section_bytes| {
            const section_vaddr: u64 = @intFromPtr(section_bytes.ptr) - mod.load_offset;
            const header = Dwarf.Unwind.EhFrameHeader.parse(section_vaddr, section_bytes, @sizeOf(usize), native_endian) catch |err| switch (err) {
                error.ReadFailed => unreachable, // it's all fixed buffers
                error.InvalidDebugInfo => |e| return e,
                error.EndOfStream, error.Overflow => return error.InvalidDebugInfo,
                error.UnsupportedAddrSize => return error.UnsupportedDebugInfo,
            };
            us.buf[us.len] = .initEhFrameHdr(header, section_vaddr, @ptrFromInt(@as(usize, @intCast(mod.load_offset + header.eh_frame_vaddr))));
            us.len += 1;
        } else {
            // There is no `.eh_frame_hdr` section. There may still be an `.eh_frame` or `.debug_frame`
            // section, but we'll have to load the binary to get at it.
            const loaded = try mod.getLoadedElf(gpa);
            // If both are present, we can't just pick one -- the info could be split between them.
            // `.debug_frame` is likely to be the more complete section, so we'll prioritize that one.
            if (loaded.file.debug_frame) |*debug_frame| {
                us.buf[us.len] = .initSection(.debug_frame, debug_frame.vaddr, debug_frame.bytes);
                us.len += 1;
            }
            if (loaded.file.eh_frame) |*eh_frame| {
                us.buf[us.len] = .initSection(.eh_frame, eh_frame.vaddr, eh_frame.bytes);
                us.len += 1;
            }
        }
        errdefer for (us.buf[0..us.len]) |*u| u.deinit(gpa);
        for (us.buf[0..us.len]) |*u| u.prepare(gpa, @sizeOf(usize), native_endian, true, false) catch |err| switch (err) {
            error.ReadFailed => unreachable, // it's all fixed buffers
            error.InvalidDebugInfo,
            error.MissingDebugInfo,
            error.OutOfMemory,
            => |e| return e,
            error.EndOfStream,
            error.Overflow,
            error.StreamTooLong,
            error.InvalidOperand,
            error.InvalidOpcode,
            error.InvalidOperation,
            => return error.InvalidDebugInfo,
            error.UnsupportedAddrSize,
            error.UnsupportedDwarfVersion,
            error.UnimplementedUserOpcode,
            => return error.UnsupportedDebugInfo,
        };
        return us;
    }

    /// Assumes we already have the lock.
    fn getLoadedElf(mod: *Module, gpa: std.mem.Allocator) Error!*LoadedElf {
        if (mod.loaded_elf == null) mod.loaded_elf = loadElf(mod, gpa);
        return if (mod.loaded_elf.?) |*elf| elf else |err| err;
    }

    fn loadElf(mod: *Module, gpa: std.mem.Allocator) Error!LoadedElf {
        const load_result = ElfFile.load(gpa, mod.mapped_elf);

        var elf_file = load_result catch |err| switch (err) {
            error.OutOfMemory,
            error.Unexpected,
            error.Canceled,
            => |e| return e,

            error.Overflow,
            error.TruncatedElfFile,
            error.InvalidCompressedSection,
            error.InvalidElfMagic,
            error.InvalidElfVersion,
            error.InvalidElfClass,
            error.InvalidElfEndian,
            => return error.InvalidDebugInfo,

            error.SystemResources,
            error.MemoryMappingNotSupported,
            error.AccessDenied,
            error.LockedMemoryLimitExceeded,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.Streaming,
            => return error.ReadFailed,
        };
        errdefer elf_file.deinit(gpa);

        if (elf_file.endian != native_endian) return error.InvalidDebugInfo;
        if (elf_file.is_64 != (@sizeOf(usize) == 8)) return error.InvalidDebugInfo;

        return .{
            .file = elf_file,
            .scanned_dwarf = false,
        };
    }
};

pub fn printLineFromFile(_: std.Io, writer: *std.Io.Writer, source_location: std.debug.SourceLocation) !void {
    const static = struct {
        const embedded_source_files_import = @import("embedded_source_files");

        const embedded_source_files: std.StaticStringMap([]const u8) = .initComptime(embedded_source_files: {
            @setEvalBranchQuota(1_000_000);

            var array: [embedded_source_files_import.file_paths.len]struct {
                []const u8,
                []const u8,
            } = undefined;

            for (embedded_source_files_import.file_paths, 0..) |name, i| {
                array[i] = .{ name, @embedFile(name) };
            }
            break :embedded_source_files array[0..];
        });
    };

    const file_contents = blk: {
        const build_prefix = static.embedded_source_files_import.build_prefix;

        const path = if (std.mem.startsWith(u8, source_location.file_name, build_prefix))
            source_location.file_name[build_prefix.len..]
        else
            source_location.file_name;

        break :blk static.embedded_source_files.get(path) orelse
            return error.NoSuchFile;
    };

    const line = blk: {
        var line_iter = std.mem.splitScalar(u8, file_contents, '\n');
        var line_index: u64 = 1;

        while (line_iter.next()) |line| : (line_index += 1) {
            if (line_index != source_location.line) continue;
            break :blk line;
        }

        return error.NoSuchLine;
    };

    try writer.writeAll(line);
    try writer.writeByte('\n');
}

pub fn getDebugInfoAllocator() std.mem.Allocator {
    return globals.debug_info_allocator.allocator();
}

const globals = struct {
    var debug_info_allocator_backing: [core.Size.from(16, .mib).value]u8 = undefined; // TODO: figure out how big this need to be in debug/release safe
    var debug_info_allocator: std.heap.FixedBufferAllocator = .init(&debug_info_allocator_backing);
};
