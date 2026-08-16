//! Raw frame transport boundary for realtime WebSocket and WebRTC sidebands.
//!
//! Protocol adapters own JSON framing above this interface. A channel owns the
//! live transport; sent slices are borrowed only for the callback invocation.

const std = @import("std");
const base = @import("base.zig");

/// One raw transport frame.
pub const Frame = union(enum) {
    text: []const u8,
    binary: []const u8,
    closed: Close,

    pub const Close = struct {
        code: ?u16 = null,
        reason: []const u8 = "",
        clean: bool = false,
    };
};

/// Arena-owned raw frame.
pub const OwnedFrame = struct {
    arena: std.heap.ArenaAllocator,
    value: Frame,

    pub fn deinit(self: *OwnedFrame) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn copy(gpa: std.mem.Allocator, frame: Frame) !OwnedFrame {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const value: Frame = switch (frame) {
            .text => |text| .{ .text = try arena.allocator().dupe(u8, text) },
            .binary => |bytes| .{ .binary = try arena.allocator().dupe(u8, bytes) },
            .closed => |close| .{ .closed = .{
                .code = close.code,
                .reason = try arena.allocator().dupe(u8, close.reason),
                .clean = close.clean,
            } },
        };
        return .{ .arena = arena, .value = value };
    }
};

/// Live raw frame channel.
pub const Channel = struct {
    context: *anyopaque,
    kind: base.TransportKind,
    send_text_fn: *const fn (context: *anyopaque, text: []const u8) anyerror!void,
    send_binary_fn: ?*const fn (context: *anyopaque, bytes: []const u8) anyerror!void = null,
    receive_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator) anyerror!OwnedFrame,
    close_fn: *const fn (context: *anyopaque) void,
    is_transport_error_fn: ?*const fn (context: *anyopaque, failure: anyerror) bool = null,

    pub fn sendText(self: Channel, text: []const u8) !void {
        return self.send_text_fn(self.context, text);
    }

    pub fn sendBinary(self: Channel, bytes: []const u8) !void {
        const send = self.send_binary_fn orelse return error.BinaryFramesUnsupported;
        return send(self.context, bytes);
    }

    pub fn receive(self: Channel, gpa: std.mem.Allocator) !OwnedFrame {
        return self.receive_fn(self.context, gpa);
    }

    pub fn close(self: Channel) void {
        self.close_fn(self.context);
    }

    pub fn isTransportError(self: Channel, failure: anyerror) bool {
        const classify = self.is_transport_error_fn orelse return false;
        return classify(self.context, failure);
    }
};

/// Opens one authenticated WebSocket or WebRTC sideband channel.
pub const Dialer = struct {
    context: *anyopaque,
    open_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator) anyerror!Channel,

    pub fn open(self: Dialer, gpa: std.mem.Allocator) !Channel {
        return self.open_fn(self.context, gpa);
    }
};

fn copyFrameWithAllocator(gpa: std.mem.Allocator) !void {
    var frame = try OwnedFrame.copy(gpa, .{ .closed = .{
        .code = 1000,
        .reason = "done",
        .clean = true,
    } });
    defer frame.deinit();
    try std.testing.expectEqualStrings("done", frame.value.closed.reason);
}

test "raw realtime frames own every payload allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, copyFrameWithAllocator, .{});
    var text = try OwnedFrame.copy(std.testing.allocator, .{ .text = "text" });
    defer text.deinit();
    try std.testing.expectEqualStrings("text", text.value.text);
    var binary = try OwnedFrame.copy(std.testing.allocator, .{ .binary = "binary" });
    defer binary.deinit();
    try std.testing.expectEqualStrings("binary", binary.value.binary);
}
