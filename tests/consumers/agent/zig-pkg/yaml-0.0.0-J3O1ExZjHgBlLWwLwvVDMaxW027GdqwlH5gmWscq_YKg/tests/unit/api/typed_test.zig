//! Purpose: Consolidate public root API typed binding behavior regression tests.
//! Owns: Public typed loading, stream loading, node conversion, and typed diagnostics assertions.
//! Does not own: Generic load, parse, emit, dump, or conformance behavior assertions.
//! Depends on: tests/unit/api/support.zig.
//! Tested by: zig build test-unit.

const support = @import("support.zig");

const std = support.std;
const yaml = support.yaml;

test "typed API re-exports public option and wrapper types" {
    const Config = struct { name: []const u8 };

    const transform: yaml.FieldNameTransform = .none;
    const conversion_options: yaml.TypedConversionOptions = .{};
    const load_options: yaml.TypedLoadOptions = .{};
    var diagnostic: yaml.TypedDiagnostic = .{};

    _ = transform;
    _ = conversion_options;
    _ = load_options;
    _ = yaml.TypedValue(Config);
    _ = yaml.TypedDocument(Config);
    _ = yaml.TypedStream(Config);
    try std.testing.expectEqualStrings("", diagnostic.path());
}

test "loadTyped converts primitive scalars and string slices" {
    var int_document = try yaml.loadTyped(u8, std.testing.allocator, "42\n");
    defer int_document.deinit();
    try std.testing.expectEqual(@as(u8, 42), int_document.value);

    var bool_document = try yaml.loadTyped(bool, std.testing.allocator, "true\n");
    defer bool_document.deinit();
    try std.testing.expectEqual(true, bool_document.value);

    var float_document = try yaml.loadTyped(f32, std.testing.allocator, "12.5\n");
    defer float_document.deinit();
    try std.testing.expectEqual(@as(f32, 12.5), float_document.value);

    var string_document = try yaml.loadTyped([]const u8, std.testing.allocator, "name\n");
    defer string_document.deinit();
    try std.testing.expectEqualStrings("name", string_document.value);
}

test "loadTyped converts sequences to arrays and slices" {
    const Config = struct {
        ports: [3]u16,
        names: []const []const u8,
    };

    var document = try yaml.loadTyped(Config, std.testing.allocator,
        \\ports: [80, 443, 8443]
        \\names: [api, admin]
        \\
    );
    defer document.deinit();

    try std.testing.expectEqualSlices(u16, &.{ 80, 443, 8443 }, &document.value.ports);
    try std.testing.expectEqual(@as(usize, 2), document.value.names.len);
    try std.testing.expectEqualStrings("api", document.value.names[0]);
    try std.testing.expectEqualStrings("admin", document.value.names[1]);
}

test "loadTyped converts structs with optionals defaults enums and nested values" {
    const Color = enum { red, blue };
    const Nested = struct { enabled: bool };
    const Config = struct {
        name: []const u8,
        color: Color,
        count: u8 = 5,
        note: ?[]const u8,
        nested: Nested,
        tags: []const []const u8,
    };

    var document = try yaml.loadTyped(Config, std.testing.allocator,
        \\name: demo
        \\color: red
        \\nested:
        \\  enabled: true
        \\tags: [one, two]
        \\
    );
    defer document.deinit();

    try std.testing.expectEqualStrings("demo", document.value.name);
    try std.testing.expectEqual(Color.red, document.value.color);
    try std.testing.expectEqual(@as(u8, 5), document.value.count);
    try std.testing.expectEqual(@as(?[]const u8, null), document.value.note);
    try std.testing.expectEqual(true, document.value.nested.enabled);
    try std.testing.expectEqualStrings("one", document.value.tags[0]);
    try std.testing.expectEqualStrings("two", document.value.tags[1]);
}

test "convertNode copies values independent of the loaded document" {
    const Config = struct {
        name: []const u8,
        tags: []const []const u8,
    };

    var loaded = try yaml.load(std.testing.allocator,
        \\name: demo
        \\tags: [one, two]
        \\
    );

    var typed = try yaml.convertNode(Config, std.testing.allocator, loaded.root, .{});
    loaded.deinit();
    defer typed.deinit();

    try std.testing.expectEqualStrings("demo", typed.value.name);
    try std.testing.expectEqualStrings("one", typed.value.tags[0]);
    try std.testing.expectEqualStrings("two", typed.value.tags[1]);
}

test "loadStreamTyped converts every document in the stream" {
    var stream = try yaml.loadStreamTyped(u16, std.testing.allocator,
        \\--- 80
        \\--- 443
        \\
    );
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 2), stream.values.len);
    try std.testing.expectEqual(@as(u16, 80), stream.values[0]);
    try std.testing.expectEqual(@as(u16, 443), stream.values[1]);
}

test "field-name transforms are explicit and ambiguous transformed matches fail" {
    const Config = struct { http_port: u16 };

    try std.testing.expectError(error.MissingField, yaml.loadTyped(Config, std.testing.allocator,
        \\http-port: 8080
        \\
    ));

    var transformed = try yaml.loadTypedWithOptions(Config, std.testing.allocator,
        \\http-port: 8080
        \\
    , .{ .conversion = .{ .field_name_transform = .snake_to_kebab } });
    defer transformed.deinit();
    try std.testing.expectEqual(@as(u16, 8080), transformed.value.http_port);

    try std.testing.expectError(error.AmbiguousField, yaml.loadTypedWithOptions(Config, std.testing.allocator,
        \\http_port: 8080
        \\http-port: 8081
        \\
    , .{ .load = .{ .duplicate_key_behavior = .allow }, .conversion = .{ .field_name_transform = .snake_to_kebab } }));
}

test "struct conversion ignores unknown complex mapping keys" {
    const Config = struct { name: []const u8 };

    var document = try yaml.loadTyped(Config, std.testing.allocator,
        \\? [ignored]
        \\: value
        \\name: demo
        \\
    );
    defer document.deinit();

    try std.testing.expectEqualStrings("demo", document.value.name);
}

test "tagged unions convert only unambiguous single-key mappings" {
    const Choice = union(enum) {
        text: []const u8,
        count: u8,
    };

    var text = try yaml.loadTyped(Choice, std.testing.allocator,
        \\text: hello
        \\
    );
    defer text.deinit();
    try std.testing.expectEqualStrings("hello", text.value.text);

    try std.testing.expectError(error.AmbiguousField, yaml.loadTyped(Choice, std.testing.allocator,
        \\text: hello
        \\count: 2
        \\
    ));
}

test "typed diagnostics include nested path and target type without source location" {
    const Item = struct { count: u8 };
    const Config = struct { items: []const Item };
    var diagnostic: yaml.TypedDiagnostic = .{};

    try std.testing.expectError(error.TypeMismatch, yaml.loadTypedWithOptions(Config, std.testing.allocator,
        \\items:
        \\  - count: nope
        \\
    , .{ .conversion = .{ .diagnostic = &diagnostic } }));

    try std.testing.expectEqualStrings("type mismatch", diagnostic.message);
    try std.testing.expectEqualStrings("$.items[0].count", diagnostic.path());
    try std.testing.expectEqualStrings("u8", diagnostic.target_type);
    try std.testing.expectEqual(@as(?usize, null), diagnostic.offset);
    try std.testing.expectEqual(@as(?usize, null), diagnostic.line);
    try std.testing.expectEqual(@as(?usize, null), diagnostic.column);
}

test "typed loading preserves parser and loader diagnostics" {
    var diagnostic: yaml.Diagnostic = .{};
    var typed_diagnostic: yaml.TypedDiagnostic = .{};

    try std.testing.expectError(error.InvalidSyntax, yaml.loadTypedWithOptions(u8, std.testing.allocator,
        \\[unterminated
        \\
    , .{
        .load = .{ .diagnostic = &diagnostic },
        .conversion = .{ .diagnostic = &typed_diagnostic },
    }));

    try std.testing.expect(diagnostic.message.len != 0);
    try std.testing.expectEqualStrings("", typed_diagnostic.message);
}
