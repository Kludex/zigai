//! Purpose: Public YAML typed binding API.
//! Owns: Typed loading wrappers, node-to-Zig conversion, field matching, and typed diagnostics.
//! Does not own: Generic parsing, loading, schema resolution, or loaded node graph construction.
//! Depends on: api/load.zig, api/options.zig, api/diagnostics.zig, and value/value.zig.
//! Tested by: tests/unit/api/typed_test.zig and tests/allocation/failure_injection_test.zig.

const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const load_api = @import("load.zig");
const options_api = @import("options.zig");
const value = @import("../value/value.zig");

const max_path_bytes = 512;

/// Supported alternate struct field-name matching behavior.
pub const FieldNameTransform = enum {
    /// Only exact YAML key to Zig field-name matches are accepted.
    none,
    /// Also allow Zig `snake_case` fields to match YAML `kebab-case` keys.
    snake_to_kebab,
};

/// Errors returned by typed node conversion.
pub const TypedConversionError = error{
    MissingField,
    TypeMismatch,
    LengthMismatch,
    AmbiguousField,
    UnsupportedTargetType,
};

/// Error set returned by typed loading APIs.
pub const TypedError = diagnostics.Error || TypedConversionError;

/// Diagnostic populated for typed conversion failures.
///
/// `message` and `target_type` are library-owned static strings. `path()` returns
/// a slice backed by this diagnostic value and remains valid until the diagnostic
/// is overwritten. Source location fields are `null` when the loaded node graph
/// has no location metadata.
pub const TypedDiagnostic = struct {
    message: []const u8 = "",
    target_type: []const u8 = "",
    offset: ?usize = null,
    line: ?usize = null,
    column: ?usize = null,
    path_len: usize = 0,
    path_buffer: [max_path_bytes]u8 = undefined,

    /// Returns the YAML path associated with the conversion failure.
    pub fn path(self: *const TypedDiagnostic) []const u8 {
        return self.path_buffer[0..self.path_len];
    }
};

/// Options controlling conversion from loaded nodes into Zig values.
pub const TypedConversionOptions = struct {
    /// Alternate field-name transform. Exact matching is always considered first.
    field_name_transform: FieldNameTransform = .none,
    /// Optional diagnostic populated for conversion failures.
    diagnostic: ?*TypedDiagnostic = null,
};

/// Options controlling typed YAML loading.
pub const TypedLoadOptions = struct {
    /// Generic YAML loading options used before typed conversion.
    load: options_api.LoadOptions = .{},
    /// Typed node conversion options used after generic loading succeeds.
    conversion: TypedConversionOptions = .{},
};

/// Owning typed value converted from an existing loaded `Node` graph.
///
/// YAML-converted strings, slices, nested allocations, and conversion-owned
/// metadata are owned by this wrapper. Call `deinit` to release them.
pub fn TypedValue(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        const Self = @This();

        /// Releases all conversion allocations owned by this value.
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

/// Owning typed value loaded from a single YAML document.
///
/// YAML-converted strings, slices, nested allocations, and conversion-owned
/// metadata are owned by this wrapper. Call `deinit` to release them.
pub fn TypedDocument(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        const Self = @This();

        /// Releases all conversion allocations owned by this document.
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

/// Owning typed values loaded from a YAML stream.
///
/// The `values` slice and every YAML conversion allocation inside each value are
/// owned by this wrapper. Call `deinit` to release them.
pub fn TypedStream(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        values: []const T,

        const Self = @This();

        /// Releases all conversion allocations owned by this stream.
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

/// Converts an already loaded node graph into an owning typed value.
pub fn convertNode(comptime T: type, allocator: std.mem.Allocator, node: *const value.Node, options: TypedConversionOptions) TypedError!TypedValue(T) {
    const converted = try convertOwned(T, allocator, node, options);
    return .{ .arena = converted.arena, .value = converted.value };
}

/// Loads one YAML document and converts it into an owning typed value.
pub fn loadTyped(comptime T: type, allocator: std.mem.Allocator, input: []const u8) TypedError!TypedDocument(T) {
    return loadTypedWithOptions(T, allocator, input, .{});
}

/// Loads one YAML document with options and converts it into an owning typed value.
pub fn loadTypedWithOptions(comptime T: type, allocator: std.mem.Allocator, input: []const u8, options: TypedLoadOptions) TypedError!TypedDocument(T) {
    var loaded = try load_api.loadWithOptions(allocator, input, options.load);
    defer loaded.deinit();

    const converted = try convertOwned(T, allocator, loaded.root, options.conversion);
    return .{ .arena = converted.arena, .value = converted.value };
}

/// Loads a YAML stream and converts every document into an owning typed value.
pub fn loadStreamTyped(comptime T: type, allocator: std.mem.Allocator, input: []const u8) TypedError!TypedStream(T) {
    return loadStreamTypedWithOptions(T, allocator, input, .{});
}

/// Loads a YAML stream with options and converts every document into an owning typed value.
pub fn loadStreamTypedWithOptions(comptime T: type, allocator: std.mem.Allocator, input: []const u8, options: TypedLoadOptions) TypedError!TypedStream(T) {
    var loaded = try load_api.loadStreamWithOptions(allocator, input, options.load);
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();
    const values = try arena_allocator.alloc(T, loaded.documents.len);
    var context = ConversionContext.init(options.conversion);

    for (loaded.documents, 0..) |document, index| {
        const saved = context.pushIndex(index);
        values[index] = try convertValue(T, arena_allocator, document, &context);
        context.pop(saved);
    }

    return .{ .arena = arena, .values = values };
}

fn OwnedConversion(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,
    };
}

fn convertOwned(comptime T: type, allocator: std.mem.Allocator, node: *const value.Node, options: TypedConversionOptions) TypedError!OwnedConversion(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var context = ConversionContext.init(options);
    const converted = try convertValue(T, arena.allocator(), node, &context);
    return .{ .arena = arena, .value = converted };
}

fn convertValue(comptime T: type, allocator: std.mem.Allocator, node: *const value.Node, context: *ConversionContext) TypedError!T {
    return switch (@typeInfo(T)) {
        .bool => convertBool(T, node, context),
        .int => convertInt(T, node, context),
        .float => convertFloat(T, node, context),
        .pointer => |pointer| convertPointer(T, pointer, allocator, node, context),
        .array => |array| convertArray(T, array, allocator, node, context),
        .@"struct" => |structure| convertStruct(T, structure, allocator, node, context),
        .optional => |optional| convertOptional(T, optional.child, allocator, node, context),
        .@"enum" => convertEnum(T, node, context),
        .@"union" => |union_info| convertUnion(T, union_info, allocator, node, context),
        else => conversionError(context, T, error.UnsupportedTargetType, "unsupported target type"),
    };
}

fn convertBool(comptime T: type, node: *const value.Node, context: *ConversionContext) TypedError!T {
    if (node.* != .bool_value) return conversionError(context, T, error.TypeMismatch, "type mismatch");
    return node.bool_value.value;
}

fn convertInt(comptime T: type, node: *const value.Node, context: *ConversionContext) TypedError!T {
    if (node.* != .int_value) return conversionError(context, T, error.TypeMismatch, "type mismatch");
    return std.math.cast(T, node.int_value.value) orelse conversionError(context, T, error.TypeMismatch, "type mismatch");
}

fn convertFloat(comptime T: type, node: *const value.Node, context: *ConversionContext) TypedError!T {
    if (node.* != .float_value) return conversionError(context, T, error.TypeMismatch, "type mismatch");
    return @as(T, @floatCast(node.float_value.value));
}

fn convertPointer(comptime T: type, pointer: std.builtin.Type.Pointer, allocator: std.mem.Allocator, node: *const value.Node, context: *ConversionContext) TypedError!T {
    if (pointer.size != .slice or pointer.sentinel_ptr != null) {
        return conversionError(context, T, error.UnsupportedTargetType, "unsupported target type");
    }

    if (pointer.child == u8 and node.* == .scalar) {
        return try allocator.dupe(u8, node.scalar.value);
    }

    if (node.* != .sequence) return conversionError(context, T, error.TypeMismatch, "type mismatch");

    const items = try allocator.alloc(pointer.child, node.sequence.items.len);
    for (node.sequence.items, 0..) |item, index| {
        const saved = context.pushIndex(index);
        items[index] = try convertValue(pointer.child, allocator, item, context);
        context.pop(saved);
    }
    return items;
}

fn convertArray(comptime T: type, array: std.builtin.Type.Array, allocator: std.mem.Allocator, node: *const value.Node, context: *ConversionContext) TypedError!T {
    if (node.* != .sequence) return conversionError(context, T, error.TypeMismatch, "type mismatch");
    if (node.sequence.items.len != array.len) return conversionError(context, T, error.LengthMismatch, "length mismatch");

    var result: T = undefined;
    for (node.sequence.items, 0..) |item, index| {
        const saved = context.pushIndex(index);
        result[index] = try convertValue(array.child, allocator, item, context);
        context.pop(saved);
    }
    return result;
}

fn convertOptional(comptime T: type, comptime Child: type, allocator: std.mem.Allocator, node: *const value.Node, context: *ConversionContext) TypedError!T {
    if (node.* == .null_value) return null;
    return try convertValue(Child, allocator, node, context);
}

fn convertEnum(comptime T: type, node: *const value.Node, context: *ConversionContext) TypedError!T {
    if (node.* != .scalar) return conversionError(context, T, error.TypeMismatch, "type mismatch");
    return std.meta.stringToEnum(T, node.scalar.value) orelse conversionError(context, T, error.TypeMismatch, "type mismatch");
}

fn convertStruct(comptime T: type, structure: std.builtin.Type.Struct, allocator: std.mem.Allocator, node: *const value.Node, context: *ConversionContext) TypedError!T {
    if (structure.is_tuple) return conversionError(context, T, error.UnsupportedTargetType, "unsupported target type");
    if (node.* != .mapping) return conversionError(context, T, error.TypeMismatch, "type mismatch");

    try rejectAmbiguousKeys(T, structure, node.mapping, context);

    var result: T = undefined;
    inline for (structure.fields) |field| {
        if (field.is_comptime) return conversionError(context, T, error.UnsupportedTargetType, "unsupported target type");

        const matched = findFieldValue(field.name, node.mapping, context.options.field_name_transform) catch |err| {
            const saved = context.pushField(field.name);
            defer context.pop(saved);
            return conversionError(context, field.type, err, "ambiguous field");
        };

        if (matched) |field_node| {
            const saved = context.pushField(field.name);
            @field(result, field.name) = try convertValue(field.type, allocator, field_node, context);
            context.pop(saved);
        } else if (field.defaultValue()) |default_value| {
            @field(result, field.name) = default_value;
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else {
            const saved = context.pushField(field.name);
            defer context.pop(saved);
            return conversionError(context, field.type, error.MissingField, "missing field");
        }
    }

    return result;
}

fn convertUnion(comptime T: type, union_info: std.builtin.Type.Union, allocator: std.mem.Allocator, node: *const value.Node, context: *ConversionContext) TypedError!T {
    if (union_info.tag_type == null) return conversionError(context, T, error.UnsupportedTargetType, "unsupported target type");
    if (node.* != .mapping) return conversionError(context, T, error.TypeMismatch, "type mismatch");
    if (node.mapping.pairs.len != 1) return conversionError(context, T, error.AmbiguousField, "ambiguous field");

    const pair = node.mapping.pairs[0];
    const key = scalarKey(pair.key) orelse return conversionError(context, T, error.TypeMismatch, "type mismatch");

    inline for (union_info.fields) |field| {
        if (std.mem.eql(u8, field.name, key)) {
            const saved = context.pushField(field.name);
            if (field.type == void) {
                if (pair.value.* != .null_value) return conversionError(context, field.type, error.TypeMismatch, "type mismatch");
                context.pop(saved);
                return @unionInit(T, field.name, {});
            }

            const payload = try convertValue(field.type, allocator, pair.value, context);
            context.pop(saved);
            return @unionInit(T, field.name, payload);
        }
    }

    return conversionError(context, T, error.TypeMismatch, "type mismatch");
}

fn rejectAmbiguousKeys(comptime T: type, structure: std.builtin.Type.Struct, mapping: value.MappingNode, context: *ConversionContext) TypedError!void {
    for (mapping.pairs) |pair| {
        const key = scalarKey(pair.key) orelse continue;
        var matches: usize = 0;
        inline for (structure.fields) |field| {
            if (!field.is_comptime and fieldMatches(field.name, key, context.options.field_name_transform)) {
                matches += 1;
            }
        }
        if (matches > 1) {
            const saved = context.pushField(key);
            defer context.pop(saved);
            return conversionError(context, T, error.AmbiguousField, "ambiguous field");
        }
    }
}

fn findFieldValue(comptime field_name: []const u8, mapping: value.MappingNode, transform: FieldNameTransform) TypedConversionError!?*const value.Node {
    var matched: ?*const value.Node = null;
    for (mapping.pairs) |pair| {
        const key = scalarKey(pair.key) orelse continue;
        if (!fieldMatches(field_name, key, transform)) continue;
        if (matched != null) return error.AmbiguousField;
        matched = pair.value;
    }
    return matched;
}

fn fieldMatches(comptime field_name: []const u8, key: []const u8, transform: FieldNameTransform) bool {
    if (std.mem.eql(u8, field_name, key)) return true;
    return switch (transform) {
        .none => false,
        .snake_to_kebab => snakeMatchesKebab(field_name, key),
    };
}

fn snakeMatchesKebab(comptime field_name: []const u8, key: []const u8) bool {
    if (field_name.len != key.len) return false;
    var changed = false;
    for (field_name, key) |field_byte, key_byte| {
        const expected = if (field_byte == '_') blk: {
            changed = true;
            break :blk '-';
        } else field_byte;
        if (expected != key_byte) return false;
    }
    return changed;
}

fn scalarKey(node: *const value.Node) ?[]const u8 {
    return switch (node.*) {
        .scalar => |scalar| scalar.value,
        else => null,
    };
}

fn conversionError(context: *ConversionContext, comptime T: type, err: TypedConversionError, message: []const u8) TypedConversionError {
    context.setDiagnostic(T, message);
    return err;
}

const ConversionContext = struct {
    options: TypedConversionOptions,
    path_buffer: [max_path_bytes]u8 = undefined,
    path_len: usize = 1,

    fn init(options: TypedConversionOptions) ConversionContext {
        var context: ConversionContext = .{ .options = options };
        context.path_buffer[0] = '$';
        return context;
    }

    fn pushField(self: *ConversionContext, name: []const u8) usize {
        const saved = self.path_len;
        self.append(".");
        self.append(name);
        return saved;
    }

    fn pushIndex(self: *ConversionContext, index: usize) usize {
        const saved = self.path_len;
        var index_buffer: [32]u8 = undefined;
        const index_text = std.fmt.bufPrint(&index_buffer, "[{d}]", .{index}) catch unreachable;
        self.append(index_text);
        return saved;
    }

    fn pop(self: *ConversionContext, saved: usize) void {
        self.path_len = saved;
    }

    fn append(self: *ConversionContext, text: []const u8) void {
        const available = self.path_buffer.len - self.path_len;
        const copy_len = @min(available, text.len);
        std.mem.copyForwards(u8, self.path_buffer[self.path_len..][0..copy_len], text[0..copy_len]);
        self.path_len += copy_len;
    }

    fn setDiagnostic(self: *const ConversionContext, comptime T: type, message: []const u8) void {
        if (self.options.diagnostic) |diagnostic| {
            diagnostic.message = message;
            diagnostic.target_type = @typeName(T);
            diagnostic.offset = null;
            diagnostic.line = null;
            diagnostic.column = null;
            diagnostic.path_len = @min(diagnostic.path_buffer.len, self.path_len);
            std.mem.copyForwards(u8, diagnostic.path_buffer[0..diagnostic.path_len], self.path_buffer[0..diagnostic.path_len]);
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
