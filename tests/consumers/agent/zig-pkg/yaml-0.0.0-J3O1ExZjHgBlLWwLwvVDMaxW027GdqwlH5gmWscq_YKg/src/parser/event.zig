//! Purpose: Define YAML parser event stream payload types.
//! Owns: Public event model and arena-owned event stream container.
//! Does not own: Scanner tokens, parser state machine, schema resolution, or loading.
//! Depends on: common/diagnostic.zig, common/style.zig.
//! Tested by: parser API, direct parser, conformance, and emitter tests.

const std = @import("std");
const diagnostic = @import("../common/diagnostic.zig");
const style = @import("../common/style.zig");

pub const ParseError = diagnostic.ParseError;
pub const Error = diagnostic.Error;
pub const Diagnostic = diagnostic.Diagnostic;
pub const CollectionStyle = style.CollectionStyle;
pub const ScalarStyle = style.ScalarStyle;

/// YAML parsing event produced by `parseEvents`.
///
/// Events form a stream/document/tree sequence similar to the yaml-test-suite
/// event format. String slices inside events are owned by the containing
/// `EventStream`.
pub const Event = union(enum) {
    /// Start of a YAML stream.
    stream_start,
    /// End of a YAML stream.
    stream_end,
    /// Start of a YAML document.
    document_start: DocumentStart,
    /// End of a YAML document.
    document_end: DocumentEnd,
    /// Start of a sequence node.
    sequence_start: CollectionStart,
    /// End of a sequence node.
    sequence_end,
    /// Start of a mapping node.
    mapping_start: CollectionStart,
    /// End of a mapping node.
    mapping_end,
    /// Scalar node event.
    scalar: Scalar,
    /// Alias node event naming a previously anchored node.
    alias: []const u8,
};

/// Metadata attached to a document-start event.
pub const DocumentStart = struct {
    /// Whether the document used an explicit `---` start marker.
    explicit: bool = false,
    /// Whether emission must keep an explicit document start for disambiguation.
    force_document_start: bool = false,
    /// Version from a `%YAML` directive, when present.
    yaml_version: ?[]const u8 = null,
    /// Whether the document prefix contained an application-reserved directive.
    has_reserved_directive: bool = false,
    /// Whether the document node began on the same line as `---`.
    content_same_line: bool = false,
    /// Whether same-line document content was separated from `---` by a tab.
    content_same_line_separated_by_tab: bool = false,
    /// TAG directives whose handles are scoped to this document.
    tag_directives: []const TagDirective = &.{},
};

/// `%TAG` directive handle and prefix scoped to one document.
pub const TagDirective = struct {
    /// Directive handle, such as `!`, `!!`, or `!e!`.
    handle: []const u8,
    /// Directive prefix used to expand shorthand tags.
    prefix: []const u8,
};

/// Metadata attached to a document-end event.
pub const DocumentEnd = struct {
    /// Whether the document used an explicit `...` end marker.
    explicit: bool = false,
};

/// Metadata attached to sequence and mapping start events.
pub const CollectionStart = struct {
    /// Block or flow collection style from the source or requested emitter form.
    style: CollectionStyle,
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

/// Scalar event payload.
pub const Scalar = struct {
    /// Decoded scalar value.
    value: []const u8,
    /// Source or requested presentation style.
    style: ScalarStyle = .plain,
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

pub const EventStream = struct {
    /// Arena owning `events` and all event string data.
    arena: std.heap.ArenaAllocator,
    /// Ordered parser events for a complete YAML stream.
    events: []const Event,

    /// Releases all event data owned by this stream.
    pub fn deinit(self: *EventStream) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

test {
    std.testing.refAllDecls(@This());
}
