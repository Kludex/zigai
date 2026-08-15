const std = @import("std");
const zigai = @import("zigai");

test "upstream v2.31.0 golden fixture round-trips every stable message family" {
    const fixture = @embedFile("fixtures/pydantic_ai/messages-v2.31.0.json");
    var owned = try zigai.codecs.pydantic_ai.parse(std.testing.allocator, fixture);
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 2), owned.messages.len);

    const encoded = try zigai.codecs.pydantic_ai.stringify(std.testing.allocator, owned.messages);
    defer std.testing.allocator.free(encoded);
    var reparsed = try zigai.codecs.pydantic_ai.parse(std.testing.allocator, encoded);
    defer reparsed.deinit();
    try std.testing.expectEqual(owned.messages.len, reparsed.messages.len);
}
