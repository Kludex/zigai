//! Purpose: Emit flow-style YAML collections from parser events.
//! Owns: Flow sequence, flow mapping, empty-flow shorthand, and flow-node recursion.
//! Does not own: Document framing, block layout, scalar escaping, or public emitter API.
//! Depends on: common/diagnostic.zig, emitter.zig, parser/event.zig, scalar.zig.
//! Tested by: tests/unit/api/root_api_test.zig and conformance emitter tests.

const std = @import("std");
const common = @import("../common/diagnostic.zig");
const event_types = @import("../parser/event.zig");
const scalar_emit = @import("scalar.zig");
const State = @import("emitter.zig").State;

const CollectionStart = event_types.CollectionStart;
const Error = common.Error;
const ParseError = common.ParseError;

const appendEmittedAlias = scalar_emit.appendEmittedAlias;
const appendEmittedCollectionProperties = scalar_emit.appendEmittedCollectionProperties;
const appendEmittedScalarNode = scalar_emit.appendEmittedScalarNode;

pub fn emitFlowSequence(self: *State, out: anytype) Error!void {
    try self.enterEmitCollection();
    defer self.leaveEmitCollection();

    try out.*.append(self.allocator, '[');

    var first_item = true;
    while (self.index < self.events.len and self.events[self.index] != .sequence_end) {
        if (!first_item) try out.*.appendSlice(self.allocator, ", ");
        first_item = false;

        try emitFlowNode(self, out);
    }

    if (self.index >= self.events.len) return ParseError.InvalidSyntax;
    try out.*.append(self.allocator, ']');
    self.index += 1;
}

pub fn emitEmptySequenceIfPresent(
    self: *State,
    out: anytype,
    collection: CollectionStart,
    prefix: ?[]const u8,
) Error!bool {
    if (self.index >= self.events.len) return ParseError.InvalidSyntax;
    if (self.events[self.index] != .sequence_end) return false;

    if (prefix) |value| try out.*.appendSlice(self.allocator, value);
    if (try appendEmittedCollectionProperties(self.allocator, out, collection)) {
        try out.*.append(self.allocator, ' ');
    }
    try out.*.appendSlice(self.allocator, "[]");
    self.index += 1;
    return true;
}

pub fn emitEmptyMappingIfPresent(
    self: *State,
    out: anytype,
    collection: CollectionStart,
    prefix: ?[]const u8,
) Error!bool {
    if (self.index >= self.events.len) return ParseError.InvalidSyntax;
    if (self.events[self.index] != .mapping_end) return false;

    if (prefix) |value| try out.*.appendSlice(self.allocator, value);
    if (try appendEmittedCollectionProperties(self.allocator, out, collection)) {
        try out.*.append(self.allocator, ' ');
    }
    try out.*.appendSlice(self.allocator, "{}");
    self.index += 1;
    return true;
}

pub fn emitFlowMapping(self: *State, out: anytype) Error!void {
    try self.enterEmitCollection();
    defer self.leaveEmitCollection();

    try out.*.append(self.allocator, '{');

    var first_pair = true;
    while (self.index < self.events.len and self.events[self.index] != .mapping_end) {
        if (!first_pair) try out.*.appendSlice(self.allocator, ", ");
        first_pair = false;

        try emitFlowNode(self, out);
        if (self.index >= self.events.len or self.events[self.index] == .mapping_end) {
            return ParseError.InvalidSyntax;
        }
        try out.*.appendSlice(self.allocator, ": ");
        try emitFlowNode(self, out);
    }

    if (self.index >= self.events.len) return ParseError.InvalidSyntax;
    try out.*.append(self.allocator, '}');
    self.index += 1;
}

pub fn emitFlowNode(self: *State, out: anytype) Error!void {
    if (self.index >= self.events.len) return ParseError.InvalidSyntax;

    switch (self.events[self.index]) {
        .scalar => |item| {
            try appendEmittedScalarNode(self.allocator, out, self.emittedFlowScalar(item));
            self.index += 1;
        },
        .alias => |alias| {
            try appendEmittedAlias(self.allocator, out, alias);
            self.index += 1;
        },
        .sequence_start => |collection| {
            self.index += 1;
            if (try emitEmptySequenceIfPresent(self, out, collection, null)) return;
            if (try appendEmittedCollectionProperties(self.allocator, out, collection)) {
                try out.*.append(self.allocator, ' ');
            }
            try emitFlowSequence(self, out);
        },
        .mapping_start => |collection| {
            self.index += 1;
            if (try emitEmptyMappingIfPresent(self, out, collection, null)) return;
            if (try appendEmittedCollectionProperties(self.allocator, out, collection)) {
                try out.*.append(self.allocator, ' ');
            }
            try emitFlowMapping(self, out);
        },
        else => return ParseError.Unsupported,
    }
}
