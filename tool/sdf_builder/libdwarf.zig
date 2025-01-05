// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub fn initPath(path: [:0]const u8) DwarfDebug {
    var dwarf_debug: c.Dwarf_Debug = undefined;

    var err: c.Dwarf_Error = undefined;

    const result = c.dwarf_init_path(
        path.ptr,
        null,
        0,
        c.DW_GROUPNUMBER_ANY,
        null,
        null,
        &dwarf_debug,
        &err,
    );

    if (result == c.DW_DLV_ERROR) {
        std.debug.print("error: libdwarf ({}) - {s}\n", .{
            c.dwarf_errno(err),
            std.mem.span(c.dwarf_errmsg(err)),
        });

        std.process.exit(1);
    }

    if (result == c.DW_DLV_NO_ENTRY) {
        std.debug.print("error: input file does not seem to have DWARF debug info\n", .{});
        std.process.exit(1);
    }

    return .{ .dwarf_debug = dwarf_debug };
}

pub const DwarfDebug = struct {
    dwarf_debug: c.Dwarf_Debug,

    pub fn deinit(self: DwarfDebug) void {
        _ = c.dwarf_finish(self.dwarf_debug);
    }

    pub fn nextCompileUnit(self: DwarfDebug) ?CompileUnit {
        var cu: CompileUnit = undefined;

        toResult(c.dwarf_next_cu_header_e(
            self.dwarf_debug,
            1,
            &cu.die.die,
            null,
            &cu.version,
            null,
            &cu.address_size,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
        )) catch return null;

        cu.dwarf_debug = self;

        return cu;
    }

    pub fn getRanges(self: DwarfDebug, offset: u64, die: Die) []const Range {
        var result: [*c]c.Dwarf_Ranges = undefined;
        var count: c.Dwarf_Signed = undefined;

        toResult(c.dwarf_get_ranges_b(
            self.dwarf_debug,
            @intCast(offset),
            die.die,
            null,
            &result,
            &count,
            null,
            null,
        )) catch unreachable;

        return @as([*]const Range, @ptrCast(result))[0..@intCast(count)];
    }

    pub fn getDieByOffset(self: DwarfDebug, offset: u64) ?Die {
        var result: Die = undefined;

        toResult(c.dwarf_offdie_b(
            self.dwarf_debug,
            @intCast(offset),
            1,
            &result.die,
            null,
        )) catch return null;

        return result;
    }
};

pub const Range = extern struct {
    range: c.Dwarf_Ranges,

    pub fn address1(self: Range) u64 {
        return @intCast(self.range.dwr_addr1);
    }

    pub fn address2(self: Range) u64 {
        return @intCast(self.range.dwr_addr2);
    }

    pub fn getType(self: Range) RangeType {
        return @enumFromInt(self.range.dwr_type);
    }

    pub const RangeType = enum(c.Dwarf_Ranges_Entry_Type) {
        ENTRY = 0,
        ADDRESS_SELECTION = 1,
        END = 2,
    };

    comptime {
        std.debug.assert(@alignOf(Range) == @alignOf(c.Dwarf_Ranges));
        std.debug.assert(@sizeOf(Range) == @sizeOf(c.Dwarf_Ranges));
        std.debug.assert(@bitSizeOf(Range) == @bitSizeOf(c.Dwarf_Ranges));
    }
};

pub const CompileUnit = struct {
    dwarf_debug: DwarfDebug,
    die: Die,
    version: c.Dwarf_Half,
    address_size: c.Dwarf_Half,

    pub fn getLineContext(self: CompileUnit) LineContext {
        var table_count: c.Dwarf_Small = undefined;
        var line_context: c.Dwarf_Line_Context = undefined;

        toResult(c.dwarf_srclines_b(
            self.die.die,
            null,
            &table_count,
            &line_context,
            null,
        )) catch unreachable;

        return .{ .line_context = line_context };
    }

    pub fn getDie(self: CompileUnit) Die {
        var result: Die = undefined;

        toResult(
            c.dwarf_siblingof_b(
                self.dwarf_debug.dwarf_debug,
                null,
                1,
                &result.die,
                null,
            ),
        ) catch unreachable;

        return result;
    }
};

pub const Die = struct {
    die: c.Dwarf_Die,

    pub fn nextSibling(self: Die) ?Die {
        var result: Die = undefined;

        toResult(c.dwarf_siblingof_c(
            self.die,
            &result.die,
            null,
        )) catch return null;

        return result;
    }

    pub fn tag(self: Die) DW_TAG {
        var result: c.Dwarf_Half = undefined;

        toResult(c.dwarf_tag(
            self.die,
            &result,
            null,
        )) catch unreachable;

        return @enumFromInt(result);
    }

    pub fn child(self: Die) ?Die {
        var result: Die = undefined;

        toResult(c.dwarf_child(
            self.die,
            &result.die,
            null,
        )) catch return null;

        return result;
    }

    pub fn name(self: Die, dwarf_debug: DwarfDebug) ?[]const u8 {
        if (self.simpleName()) |n| return n;

        if (self.getAttribute(.abstract_origin)) |abstract_origin_attribute| blk: {
            const abstract_origin = abstract_origin_attribute.sectionRelativeOffset();

            const origin_die = dwarf_debug.getDieByOffset(abstract_origin) orelse break :blk;

            if (origin_die.simpleName()) |n| return n;
        }

        if (self.getAttribute(.specification)) |specification_attribute| blk: {
            const specification_offset = specification_attribute.sectionRelativeOffset();

            const specification_die = dwarf_debug.getDieByOffset(specification_offset) orelse break :blk;

            if (specification_die.simpleName()) |n| return n;
        }

        return null;
    }

    pub fn simpleName(self: Die) ?[:0]const u8 {
        var name_ptr: [*c]u8 = undefined;

        toResult(c.dwarf_diename(
            self.die,
            &name_ptr,
            null,
        )) catch return null;

        return std.mem.sliceTo(name_ptr, 0);
    }

    pub fn abbreviationCode(self: Die) u64 {
        return @intCast(c.dwarf_die_abbrev_code(self.die));
    }

    pub fn getLowHighPC(self: Die) ?LowHighPC {
        const low_pc = blk: {
            var result: c.Dwarf_Addr = undefined;

            toResult(c.dwarf_lowpc(
                self.die,
                &result,
                null,
            )) catch return null;

            break :blk result;
        };

        var high_pc: c.Dwarf_Addr = undefined;
        var form: c.Dwarf_Half = undefined;
        var form_class: c.Dwarf_Form_Class = undefined;

        toResult(c.dwarf_highpc_b(
            self.die,
            &high_pc,
            &form,
            &form_class,
            null,
        )) catch return null;

        if (form != c.DW_FORM_CLASS_ADDRESS) high_pc += low_pc;

        return .{ .low_pc = @intCast(low_pc), .high_pc = @intCast(high_pc) };
    }

    pub fn getAttribute(self: Die, attribute: DW_AT) ?Attribute {
        var result: Attribute = undefined;

        toResult(
            c.dwarf_attr(
                self.die,
                @intFromEnum(attribute),
                &result.attribute,
                null,
            ),
        ) catch return null;

        return result;
    }

    pub fn getAttributes(self: Die) []const Attribute {
        var result: [*c]c.Dwarf_Attribute = undefined;
        var result_count: c.Dwarf_Signed = undefined;

        toResult(c.dwarf_attrlist(
            self.die,
            &result,
            &result_count,
            null,
        )) catch unreachable;

        const ptr: [*]const Attribute = @ptrCast(result);
        return ptr[0..@intCast(result_count)];
    }
};

pub const Attribute = struct {
    attribute: c.Dwarf_Attribute,

    pub fn sectionRelativeOffset(self: Attribute) u64 {
        var result: c.Dwarf_Off = undefined;
        var is_info: c.Dwarf_Bool = undefined;

        toResult(c.dwarf_global_formref_b(
            self.attribute,
            &result,
            &is_info,
            null,
        )) catch unreachable;

        return result;
    }

    pub fn attributeNumber(self: Attribute) DW_AT {
        var result: c.Dwarf_Half = undefined;

        toResult(c.dwarf_whatattr(self.attribute, &result, null)) catch unreachable;

        return @enumFromInt(result);
    }
};

pub const LowHighPC = struct {
    low_pc: u64,
    high_pc: u64,
};

pub const LineContext = struct {
    line_context: c.Dwarf_Line_Context,

    pub fn getLines(self: LineContext) []const Line {
        var lines: [*c]c.Dwarf_Line = undefined;
        var line_count: c.Dwarf_Signed = undefined;

        toResult(
            c.dwarf_srclines_from_linecontext(
                self.line_context,
                &lines,
                &line_count,
                null,
            ),
        ) catch unreachable;

        return @as([*]const Line, @ptrCast(lines))[0..@intCast(line_count)];
    }
};

pub const Line = extern struct {
    dwarf_line: c.Dwarf_Line,

    pub fn line(self: Line) u64 {
        var result: c.Dwarf_Unsigned = undefined;

        toResult(c.dwarf_lineno(
            self.dwarf_line,
            &result,
            null,
        )) catch unreachable;

        return @intCast(result);
    }

    pub fn column(self: Line) u64 {
        var result: c.Dwarf_Unsigned = undefined;

        toResult(c.dwarf_lineoff_b(
            self.dwarf_line,
            &result,
            null,
        )) catch unreachable;

        return @intCast(result);
    }

    pub fn address(self: Line) u64 {
        var result: c.Dwarf_Addr = undefined;

        toResult(c.dwarf_lineaddr(
            self.dwarf_line,
            &result,
            null,
        )) catch unreachable;

        return @intCast(result);
    }

    pub fn file(self: Line) []const u8 {
        var result: [*c]u8 = undefined;

        toResult(c.dwarf_linesrc(
            self.dwarf_line,
            &result,
            null,
        )) catch unreachable;

        return std.mem.sliceTo(result, 0);
    }

    comptime {
        std.debug.assert(@alignOf(Line) == @alignOf(c.Dwarf_Line));
        std.debug.assert(@sizeOf(Line) == @sizeOf(c.Dwarf_Line));
        std.debug.assert(@bitSizeOf(Line) == @bitSizeOf(c.Dwarf_Line));
    }
};

pub const DW_AT = enum(c.Dwarf_Half) {
    sibling = 0x01,
    location = 0x02,
    name = 0x03,
    ordering = 0x09,
    subscr_data = 0x0a,
    byte_size = 0x0b,
    bit_offset = 0x0c,
    bit_size = 0x0d,
    element_list = 0x0f,
    stmt_list = 0x10,
    low_pc = 0x11,
    high_pc = 0x12,
    language = 0x13,
    member = 0x14,
    discr = 0x15,
    discr_value = 0x16,
    visibility = 0x17,
    import = 0x18,
    string_length = 0x19,
    common_reference = 0x1a,
    comp_dir = 0x1b,
    const_value = 0x1c,
    containing_type = 0x1d,
    default_value = 0x1e,
    @"inline" = 0x20,
    is_optional = 0x21,
    lower_bound = 0x22,
    producer = 0x25,
    prototyped = 0x27,
    return_addr = 0x2a,
    start_scope = 0x2c,
    bit_stride = 0x2e,
    upper_bound = 0x2f,
    abstract_origin = 0x31,
    accessibility = 0x32,
    address_class = 0x33,
    artificial = 0x34,
    base_types = 0x35,
    calling_convention = 0x36,
    count = 0x37,
    data_member_location = 0x38,
    decl_column = 0x39,
    decl_file = 0x3a,
    decl_line = 0x3b,
    declaration = 0x3c,
    discr_list = 0x3d,
    encoding = 0x3e,
    external = 0x3f,
    frame_base = 0x40,
    friend = 0x41,
    identifier_case = 0x42,
    macro_info = 0x43,
    namelist_items = 0x44,
    priority = 0x45,
    segment = 0x46,
    specification = 0x47,
    static_link = 0x48,
    type = 0x49,
    use_location = 0x4a,
    variable_parameter = 0x4b,
    virtuality = 0x4c,
    vtable_elem_location = 0x4d,

    // DWARF 3 values.
    allocated = 0x4e,
    associated = 0x4f,
    data_location = 0x50,
    byte_stride = 0x51,
    entry_pc = 0x52,
    use_UTF8 = 0x53,
    extension = 0x54,
    ranges = 0x55,
    trampoline = 0x56,
    call_column = 0x57,
    call_file = 0x58,
    call_line = 0x59,
    description = 0x5a,
    binary_scale = 0x5b,
    decimal_scale = 0x5c,
    small = 0x5d,
    decimal_sign = 0x5e,
    digit_count = 0x5f,
    picture_string = 0x60,
    mutable = 0x61,
    threads_scaled = 0x62,
    explicit = 0x63,
    object_pointer = 0x64,
    endianity = 0x65,
    elemental = 0x66,
    pure = 0x67,
    recursive = 0x68,

    // DWARF 4.
    signature = 0x69,
    main_subprogram = 0x6a,
    data_bit_offset = 0x6b,
    const_expr = 0x6c,
    enum_class = 0x6d,
    linkage_name = 0x6e,

    // DWARF 5
    string_length_bit_size = 0x6f,
    string_length_byte_size = 0x70,
    rank = 0x71,
    str_offsets_base = 0x72,
    addr_base = 0x73,
    rnglists_base = 0x74,
    dwo_name = 0x76,
    reference = 0x77,
    rvalue_reference = 0x78,
    macros = 0x79,
    call_all_calls = 0x7a,
    call_all_source_calls = 0x7b,
    call_all_tail_calls = 0x7c,
    call_return_pc = 0x7d,
    call_value = 0x7e,
    call_origin = 0x7f,
    call_parameter = 0x80,
    call_pc = 0x81,
    call_tail_call = 0x82,
    call_target = 0x83,
    call_target_clobbered = 0x84,
    call_data_location = 0x85,
    call_data_value = 0x86,
    noreturn = 0x87,
    alignment = 0x88,
    export_symbols = 0x89,
    deleted = 0x8a,
    defaulted = 0x8b,
    loclists_base = 0x8c,
    lo_user = 0x2000,
    hi_user = 0x3fff,

    _,
};

pub const DW_TAG = enum(c.Dwarf_Half) {
    padding = 0x00,
    array_type = 0x01,
    class_type = 0x02,
    entry_point = 0x03,
    enumeration_type = 0x04,
    formal_parameter = 0x05,
    imported_declaration = 0x08,
    label = 0x0a,
    lexical_block = 0x0b,
    member = 0x0d,
    pointer_type = 0x0f,
    reference_type = 0x10,
    compile_unit = 0x11,
    string_type = 0x12,
    structure_type = 0x13,
    subroutine = 0x14,
    subroutine_type = 0x15,
    typedef = 0x16,
    union_type = 0x17,
    unspecified_parameters = 0x18,
    variant = 0x19,
    common_block = 0x1a,
    common_inclusion = 0x1b,
    inheritance = 0x1c,
    inlined_subroutine = 0x1d,
    module = 0x1e,
    ptr_to_member_type = 0x1f,
    set_type = 0x20,
    subrange_type = 0x21,
    with_stmt = 0x22,
    access_declaration = 0x23,
    base_type = 0x24,
    catch_block = 0x25,
    const_type = 0x26,
    constant = 0x27,
    enumerator = 0x28,
    file_type = 0x29,
    friend = 0x2a,
    namelist = 0x2b,
    namelist_item = 0x2c,
    packed_type = 0x2d,
    subprogram = 0x2e,
    template_type_param = 0x2f,
    template_value_param = 0x30,
    thrown_type = 0x31,
    try_block = 0x32,
    variant_part = 0x33,
    variable = 0x34,
    volatile_type = 0x35,

    // DWARF 3
    dwarf_procedure = 0x36,
    restrict_type = 0x37,
    interface_type = 0x38,
    namespace = 0x39,
    imported_module = 0x3a,
    unspecified_type = 0x3b,
    partial_unit = 0x3c,
    imported_unit = 0x3d,
    condition = 0x3f,
    shared_type = 0x40,

    // DWARF 4
    type_unit = 0x41,
    rvalue_reference_type = 0x42,
    template_alias = 0x43,

    // DWARF 5
    coarray_type = 0x44,
    generic_subrange = 0x45,
    dynamic_type = 0x46,
    atomic_type = 0x47,
    call_site = 0x48,
    call_site_parameter = 0x49,
    skeleton_unit = 0x4a,
    immutable_type = 0x4b,
    lo_user = 0x4080,
    hi_user = 0xffff,

    _,
};

const DwarfError = error{DwarfError};

fn toResultNoEntry(return_value: c_int) DwarfError!bool {
    return switch (return_value) {
        c.DW_DLV_ERROR => error.DwarfError,
        c.DW_DLV_NO_ENTRY => false,
        c.DW_DLV_OK => true,
        else => @panic("unknown libdwarf return value"),
    };
}

fn toResult(return_value: c_int) !void {
    switch (return_value) {
        c.DW_DLV_OK => {},
        c.DW_DLV_ERROR, c.DW_DLV_NO_ENTRY => return error.DwarfError,
        else => |v| core.panicFmt("unknown libdwarf return value: {}", .{v}, null),
    }
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");

const c = @cImport({
    @cInclude("dwarf.h");
    @cInclude("libdwarf.h");
});
