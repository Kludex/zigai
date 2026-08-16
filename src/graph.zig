//! Typed, bounded execution for application-defined graphs.
//!
//! Graph definitions own their node and routing arrays. Node names, branch
//! names, and callback contexts remain borrowed and must outlive the graph.
//! Run state, dependencies, inputs, intermediate values, and outputs keep their
//! declared Zig types; the module performs no serialization or implicit copying.

const std = @import("std");

/// Errors a graph callback may deliberately return.
pub const CallbackError = error{
    OutOfMemory,
    Cancelled,
    StepFailed,
};

/// Errors returned while assembling a graph definition.
pub const BuildError = std.mem.Allocator.Error || error{
    LimitExceeded,
    EmptyNodeName,
    NodeNameTooLong,
    DuplicateNodeName,
    InvalidNode,
    DuplicateStart,
    DuplicateEnd,
    MissingStart,
    MissingEnd,
    MissingEntry,
    MissingOutgoingEdge,
    DuplicateOutgoingEdge,
    EmptyBranchName,
    BranchNameTooLong,
    DuplicateBranchName,
    InvalidEdgeKind,
    UnreachableNode,
};

/// Errors returned while advancing or completing a graph run.
pub const RunError = CallbackError || error{
    StepLimitExceeded,
    UnmatchedRoute,
    RunFinished,
};

/// Stable index into one built graph. IDs are definition-local.
pub const NodeId = struct {
    index: usize,
};

/// Safety ceilings for graph definitions and executions.
pub const Limits = struct {
    max_nodes: usize = 1_024,
    max_edges: usize = 1_024,
    max_steps: usize = 10_000,
    max_name_bytes: usize = 128,
};

/// Observable graph lifecycle phase.
pub const EventKind = enum {
    run_start,
    step_start,
    step_end,
    run_end,
    run_failed,
};

/// One borrowed graph lifecycle event.
pub const Event = struct {
    kind: EventKind,
    node_id: ?NodeId = null,
    node_name: ?[]const u8 = null,
    step_number: usize = 0,
    branch_name: ?[]const u8 = null,
    failure_name: ?[]const u8 = null,
};

/// Synchronous, borrowed event observer. The callback must not retain names.
pub const EventSink = struct {
    context: ?*anyopaque = null,
    event_fn: *const fn (context: ?*anyopaque, event: Event) void,

    pub fn emit(self: EventSink, event: Event) void {
        self.event_fn(self.context, event);
    }
};

/// Per-run controls. A requested step limit can only narrow the graph limit.
pub const RunOptions = struct {
    max_steps: ?usize = null,
    events: ?EventSink = null,
};

/// Returns a graph type with statically known state, dependencies, boundary
/// values, and intermediate values.
pub fn Graph(
    comptime State: type,
    comptime Deps: type,
    comptime Input: type,
    comptime Value: type,
    comptime Output: type,
) type {
    return struct {
        const Self = @This();

        /// Typed context passed to every graph callback. The allocator and all
        /// pointers are borrowed for the current call.
        pub const Context = struct {
            gpa: std.mem.Allocator,
            state: *State,
            deps: *Deps,
            node_id: ?NodeId,
            step_number: usize,
        };

        /// Converts the graph input into its first intermediate value.
        pub const Start = struct {
            context: ?*anyopaque = null,
            run_fn: *const fn (
                context: ?*anyopaque,
                run: *Context,
                input: Input,
            ) CallbackError!Value,
        };

        /// Executes one typed workflow step.
        pub const Step = struct {
            name: []const u8,
            context: ?*anyopaque = null,
            run_fn: *const fn (
                context: ?*anyopaque,
                run: *Context,
                input: Value,
            ) CallbackError!Value,
        };

        /// A decision preserves the typed intermediate value while selecting
        /// one of the node's registered named branches.
        pub const DecisionResult = struct {
            /// Borrowed name matched against this decision's registered routes.
            branch: []const u8,
            /// Typed value passed to the selected destination or end callback.
            value: Value,
        };

        /// Selects a named outgoing branch from the current typed value.
        pub const Decision = struct {
            name: []const u8,
            context: ?*anyopaque = null,
            run_fn: *const fn (
                context: ?*anyopaque,
                run: *Context,
                input: Value,
            ) CallbackError!DecisionResult,
        };

        /// Converts the terminal intermediate value to the graph output.
        pub const End = struct {
            context: ?*anyopaque = null,
            run_fn: *const fn (
                context: ?*anyopaque,
                run: *Context,
                input: Value,
            ) CallbackError!Output,
        };

        const Destination = union(enum) {
            node: NodeId,
            finish,
        };

        const Node = union(enum) {
            step: Step,
            decision: Decision,

            fn name(self: Node) []const u8 {
                return switch (self) {
                    inline else => |node| node.name,
                };
            }
        };

        const Edge = struct {
            from: NodeId,
            branch: ?[]const u8 = null,
            destination: Destination,
        };

        const Route = struct {
            branch: ?[]const u8,
            destination: Destination,
        };

        const RouteSpan = struct {
            start: usize,
            len: usize,
        };

        /// Mutable graph definition. Call `deinit` even after a successful
        /// `build`; success leaves it empty and reusable.
        pub const Builder = struct {
            limits: Limits = .{},
            start: ?Start = null,
            end: ?End = null,
            entry: ?NodeId = null,
            nodes: std.ArrayList(Node) = .empty,
            edges: std.ArrayList(Edge) = .empty,

            pub fn deinit(self: *Builder, gpa: std.mem.Allocator) void {
                self.nodes.deinit(gpa);
                self.edges.deinit(gpa);
                self.* = .{ .limits = self.limits };
            }

            pub fn setStart(self: *Builder, start: Start) BuildError!void {
                if (self.start != null) return error.DuplicateStart;
                self.start = start;
            }

            pub fn setEnd(self: *Builder, end: End) BuildError!void {
                if (self.end != null) return error.DuplicateEnd;
                self.end = end;
            }

            /// Registers one step and returns its graph-local ID. The step name
            /// and callback context remain borrowed by the built graph.
            pub fn addStep(
                self: *Builder,
                gpa: std.mem.Allocator,
                step: Step,
            ) BuildError!NodeId {
                if (step.name.len == 0) return error.EmptyNodeName;
                if (step.name.len > self.limits.max_name_bytes) return error.NodeNameTooLong;
                for (self.nodes.items) |existing| {
                    if (std.mem.eql(u8, existing.name(), step.name)) return error.DuplicateNodeName;
                }
                if (self.nodes.items.len >= self.limits.max_nodes) return error.LimitExceeded;
                const id = NodeId{ .index = self.nodes.items.len };
                try self.nodes.append(gpa, .{ .step = step });
                return id;
            }

            /// Registers a typed decision node with named outgoing branches.
            pub fn addDecision(
                self: *Builder,
                gpa: std.mem.Allocator,
                decision: Decision,
            ) BuildError!NodeId {
                if (decision.name.len == 0) return error.EmptyNodeName;
                if (decision.name.len > self.limits.max_name_bytes) return error.NodeNameTooLong;
                for (self.nodes.items) |existing| {
                    if (std.mem.eql(u8, existing.name(), decision.name)) return error.DuplicateNodeName;
                }
                if (self.nodes.items.len >= self.limits.max_nodes) return error.LimitExceeded;
                const id = NodeId{ .index = self.nodes.items.len };
                try self.nodes.append(gpa, .{ .decision = decision });
                return id;
            }

            pub fn setEntry(self: *Builder, node: NodeId) BuildError!void {
                try self.validateNode(node);
                self.entry = node;
            }

            /// Connects a step to exactly one following step.
            pub fn connect(
                self: *Builder,
                gpa: std.mem.Allocator,
                from: NodeId,
                to: NodeId,
            ) BuildError!void {
                try self.validateNode(from);
                try self.validateNode(to);
                if (self.nodes.items[from.index] != .step) return error.InvalidEdgeKind;
                try self.addEdge(gpa, .{ .from = from, .destination = .{ .node = to } });
            }

            /// Marks a step as the terminal producer consumed by `End`.
            pub fn finish(self: *Builder, gpa: std.mem.Allocator, from: NodeId) BuildError!void {
                try self.validateNode(from);
                if (self.nodes.items[from.index] != .step) return error.InvalidEdgeKind;
                try self.addEdge(gpa, .{ .from = from, .destination = .finish });
            }

            /// Connects one named decision branch to another node.
            pub fn branch(
                self: *Builder,
                gpa: std.mem.Allocator,
                from: NodeId,
                name: []const u8,
                to: NodeId,
            ) BuildError!void {
                try self.validateNode(from);
                try self.validateNode(to);
                try self.addBranch(gpa, from, name, .{ .node = to });
            }

            /// Connects one named decision branch to the graph's end callback.
            pub fn branchFinish(
                self: *Builder,
                gpa: std.mem.Allocator,
                from: NodeId,
                name: []const u8,
            ) BuildError!void {
                try self.validateNode(from);
                try self.addBranch(gpa, from, name, .finish);
            }

            /// Validates and consumes the registered node and edge arrays.
            pub fn build(self: *Builder, gpa: std.mem.Allocator) BuildError!Self {
                const start = self.start orelse return error.MissingStart;
                const end = self.end orelse return error.MissingEnd;
                const entry = self.entry orelse return error.MissingEntry;
                for (self.nodes.items, 0..) |_, index| {
                    if (self.edgeCount(.{ .index = index }) == 0) return error.MissingOutgoingEdge;
                }

                const route_spans = try gpa.alloc(RouteSpan, self.nodes.items.len);
                errdefer gpa.free(route_spans);
                const routes = try gpa.alloc(Route, self.edges.items.len);
                errdefer gpa.free(routes);
                var route_index: usize = 0;
                for (route_spans, 0..) |*span, index| {
                    span.* = .{ .start = route_index, .len = 0 };
                    for (self.edges.items) |edge| {
                        if (edge.from.index != index) continue;
                        routes[route_index] = .{
                            .branch = edge.branch,
                            .destination = edge.destination,
                        };
                        route_index += 1;
                        span.len += 1;
                    }
                }
                try self.validateReachability(gpa, entry);
                const nodes = try self.nodes.toOwnedSlice(gpa);
                errdefer gpa.free(nodes);
                self.edges.deinit(gpa);
                self.edges = .empty;
                self.start = null;
                self.end = null;
                self.entry = null;
                return .{
                    .limits = self.limits,
                    .start = start,
                    .end = end,
                    .entry = entry,
                    .nodes = nodes,
                    .route_spans = route_spans,
                    .routes = routes,
                };
            }

            fn validateNode(self: Builder, node: NodeId) BuildError!void {
                if (node.index >= self.nodes.items.len) return error.InvalidNode;
            }

            fn addEdge(self: *Builder, gpa: std.mem.Allocator, edge: Edge) BuildError!void {
                if (self.edges.items.len >= self.limits.max_edges) return error.LimitExceeded;
                if (self.edgeCount(edge.from) != 0) return error.DuplicateOutgoingEdge;
                try self.edges.append(gpa, edge);
            }

            fn addBranch(
                self: *Builder,
                gpa: std.mem.Allocator,
                from: NodeId,
                name: []const u8,
                destination: Destination,
            ) BuildError!void {
                if (self.nodes.items[from.index] != .decision) return error.InvalidEdgeKind;
                if (name.len == 0) return error.EmptyBranchName;
                if (name.len > self.limits.max_name_bytes) return error.BranchNameTooLong;
                if (self.edges.items.len >= self.limits.max_edges) return error.LimitExceeded;
                for (self.edges.items) |edge| {
                    if (edge.from.index != from.index) continue;
                    if (std.mem.eql(u8, edge.branch.?, name)) return error.DuplicateBranchName;
                }
                try self.edges.append(gpa, .{
                    .from = from,
                    .branch = name,
                    .destination = destination,
                });
            }

            fn edgeCount(self: Builder, from: NodeId) usize {
                var count: usize = 0;
                for (self.edges.items) |edge| {
                    if (edge.from.index == from.index) count += 1;
                }
                return count;
            }

            fn validateReachability(
                self: Builder,
                gpa: std.mem.Allocator,
                entry: NodeId,
            ) BuildError!void {
                const visited = try gpa.alloc(bool, self.nodes.items.len);
                defer gpa.free(visited);
                @memset(visited, false);
                const stack = try gpa.alloc(NodeId, self.nodes.items.len);
                defer gpa.free(stack);
                var stack_len: usize = 1;
                stack[0] = entry;
                visited[entry.index] = true;
                while (stack_len > 0) {
                    stack_len -= 1;
                    const current = stack[stack_len];
                    for (self.edges.items) |edge| {
                        if (edge.from.index != current.index) continue;
                        switch (edge.destination) {
                            .node => |next| {
                                if (!visited[next.index]) {
                                    visited[next.index] = true;
                                    stack[stack_len] = next;
                                    stack_len += 1;
                                }
                            },
                            .finish => {},
                        }
                    }
                }
                for (visited) |reachable| {
                    if (!reachable) return error.UnreachableNode;
                }
            }
        };

        /// Result of advancing one graph step.
        pub const Advance = union(enum) {
            step: struct {
                completed: NodeId,
                next: NodeId,
                step_number: usize,
            },
            complete: Output,
        };

        const Status = union(enum) {
            running,
            complete,
            failed: RunError,
        };

        /// Manually advanced graph run. The graph, state, dependencies, and any
        /// memory referenced by `Value` must outlive this value.
        pub const Run = struct {
            graph: *const Self,
            gpa: std.mem.Allocator,
            state: *State,
            deps: *Deps,
            value: Value,
            current: NodeId,
            step_count: usize = 0,
            max_steps: usize,
            events: ?EventSink,
            status: Status = .running,

            pub fn next(self: *Run) RunError!Advance {
                switch (self.status) {
                    .running => {},
                    .complete => return error.RunFinished,
                    .failed => |failure| return failure,
                }
                if (self.step_count >= self.max_steps) return self.fail(null, error.StepLimitExceeded);

                const node = self.graph.nodes[self.current.index];
                const node_name = node.name();
                self.step_count += 1;
                self.emit(.{
                    .kind = .step_start,
                    .node_id = self.current,
                    .node_name = node_name,
                    .step_number = self.step_count,
                });
                var run_context = self.context(self.current);
                const selected_branch: ?[]const u8 = switch (node) {
                    .step => |step| branch: {
                        self.value = step.run_fn(step.context, &run_context, self.value) catch |failure|
                            return self.fail(self.current, failure);
                        break :branch null;
                    },
                    .decision => |decision| branch: {
                        const result = decision.run_fn(
                            decision.context,
                            &run_context,
                            self.value,
                        ) catch |failure| return self.fail(self.current, failure);
                        self.value = result.value;
                        break :branch result.branch;
                    },
                };
                self.emit(.{
                    .kind = .step_end,
                    .node_id = self.current,
                    .node_name = node_name,
                    .step_number = self.step_count,
                    .branch_name = selected_branch,
                });

                const completed = self.current;
                const destination = self.graph.findDestination(completed, selected_branch) orelse
                    return self.failWithBranch(completed, error.UnmatchedRoute, selected_branch);
                switch (destination) {
                    .node => |next_node| {
                        self.current = next_node;
                        return .{ .step = .{
                            .completed = completed,
                            .next = next_node,
                            .step_number = self.step_count,
                        } };
                    },
                    .finish => {
                        run_context = self.context(completed);
                        const output = self.graph.end.run_fn(
                            self.graph.end.context,
                            &run_context,
                            self.value,
                        ) catch |failure| return self.fail(completed, failure);
                        self.status = .complete;
                        self.emit(.{
                            .kind = .run_end,
                            .node_id = completed,
                            .node_name = node_name,
                            .step_number = self.step_count,
                            .branch_name = selected_branch,
                        });
                        return .{ .complete = output };
                    },
                }
            }

            pub fn nextNode(self: Run) ?NodeId {
                return switch (self.status) {
                    .running => self.current,
                    .complete, .failed => null,
                };
            }

            /// Borrows the current intermediate value until the next advance.
            pub fn currentValue(self: *const Run) *const Value {
                return &self.value;
            }

            pub fn stepsCompleted(self: Run) usize {
                return self.step_count;
            }

            fn context(self: Run, node_id: NodeId) Context {
                return .{
                    .gpa = self.gpa,
                    .state = self.state,
                    .deps = self.deps,
                    .node_id = node_id,
                    .step_number = self.step_count,
                };
            }

            fn fail(self: *Run, node_id: ?NodeId, failure: RunError) RunError {
                return self.failWithBranch(node_id, failure, null);
            }

            fn failWithBranch(
                self: *Run,
                node_id: ?NodeId,
                failure: RunError,
                branch_name: ?[]const u8,
            ) RunError {
                self.status = .{ .failed = failure };
                const node_name = if (node_id) |id| self.graph.nodes[id.index].name() else null;
                self.emit(.{
                    .kind = .run_failed,
                    .node_id = node_id,
                    .node_name = node_name,
                    .step_number = self.step_count,
                    .branch_name = branch_name,
                    .failure_name = @errorName(failure),
                });
                return failure;
            }

            fn emit(self: Run, event: Event) void {
                if (self.events) |sink| sink.emit(event);
            }
        };

        limits: Limits,
        start: Start,
        end: End,
        entry: NodeId,
        nodes: []Node,
        route_spans: []RouteSpan,
        routes: []Route,

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.nodes);
            gpa.free(self.route_spans);
            gpa.free(self.routes);
            self.* = undefined;
        }

        fn findDestination(
            self: *const Self,
            node: NodeId,
            branch: ?[]const u8,
        ) ?Destination {
            const span = self.route_spans[node.index];
            for (self.routes[span.start..][0..span.len]) |route| {
                if (branch == null and route.branch == null) return route.destination;
                if (branch != null and route.branch != null and
                    std.mem.eql(u8, branch.?, route.branch.?)) return route.destination;
            }
            return null;
        }

        /// Starts a manually advanced run. The start callback executes before
        /// this function returns.
        pub fn iter(
            self: *const Self,
            gpa: std.mem.Allocator,
            state: *State,
            deps: *Deps,
            input: Input,
            options: RunOptions,
        ) RunError!Run {
            const max_steps = if (options.max_steps) |requested|
                @min(requested, self.limits.max_steps)
            else
                self.limits.max_steps;
            var context = Context{
                .gpa = gpa,
                .state = state,
                .deps = deps,
                .node_id = null,
                .step_number = 0,
            };
            const value = self.start.run_fn(self.start.context, &context, input) catch |failure| {
                if (options.events) |sink| sink.emit(.{
                    .kind = .run_failed,
                    .failure_name = @errorName(failure),
                });
                return failure;
            };
            if (options.events) |sink| sink.emit(.{
                .kind = .run_start,
                .node_id = self.entry,
                .node_name = self.nodes[self.entry.index].name(),
            });
            return .{
                .graph = self,
                .gpa = gpa,
                .state = state,
                .deps = deps,
                .value = value,
                .current = self.entry,
                .max_steps = max_steps,
                .events = options.events,
            };
        }

        /// Runs until the graph produces its typed output or fails.
        pub fn run(
            self: *const Self,
            gpa: std.mem.Allocator,
            state: *State,
            deps: *Deps,
            input: Input,
            options: RunOptions,
        ) RunError!Output {
            var execution = try self.iter(gpa, state, deps, input, options);
            while (true) switch (try execution.next()) {
                .step => {},
                .complete => |output| return output,
            };
        }
    };
}

test "graph runs typed steps and emits stable lifecycle events" {
    const State = struct { total: u64 = 0 };
    const Deps = struct { multiplier: u64 };
    const Workflow = Graph(State, Deps, u64, u64, u64);
    const Callbacks = struct {
        fn start(_: ?*anyopaque, _: *Workflow.Context, input: u64) CallbackError!u64 {
            return input;
        }

        fn add(context: ?*anyopaque, run: *Workflow.Context, input: u64) CallbackError!u64 {
            const amount: *const u64 = @ptrCast(@alignCast(context.?));
            run.state.total += amount.*;
            return input + amount.*;
        }

        fn multiply(_: ?*anyopaque, run: *Workflow.Context, input: u64) CallbackError!u64 {
            return input * run.deps.multiplier;
        }

        fn end(_: ?*anyopaque, _: *Workflow.Context, input: u64) CallbackError!u64 {
            return input;
        }
    };
    const Capture = struct {
        events: [8]Event = undefined,
        count: usize = 0,

        fn emit(context: ?*anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.events[self.count] = event;
            self.count += 1;
        }
    };

    var amount: u64 = 3;
    var builder: Workflow.Builder = .{};
    defer builder.deinit(std.testing.allocator);
    try builder.setStart(.{ .run_fn = Callbacks.start });
    try builder.setEnd(.{ .run_fn = Callbacks.end });
    const add = try builder.addStep(std.testing.allocator, .{
        .name = "add",
        .context = &amount,
        .run_fn = Callbacks.add,
    });
    const multiply = try builder.addStep(std.testing.allocator, .{
        .name = "multiply",
        .run_fn = Callbacks.multiply,
    });
    try builder.setEntry(add);
    try builder.connect(std.testing.allocator, add, multiply);
    try builder.finish(std.testing.allocator, multiply);
    var graph = try builder.build(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);

    var state: State = .{};
    var deps = Deps{ .multiplier = 4 };
    var capture: Capture = .{};
    const output = try graph.run(std.testing.allocator, &state, &deps, 2, .{
        .events = .{ .context = &capture, .event_fn = Capture.emit },
    });
    try std.testing.expectEqual(@as(u64, 20), output);
    try std.testing.expectEqual(@as(u64, 3), state.total);
    try std.testing.expectEqual(@as(usize, 6), capture.count);
    try std.testing.expectEqualSlices(EventKind, &.{
        .run_start,
        .step_start,
        .step_end,
        .step_start,
        .step_end,
        .run_end,
    }, &.{
        capture.events[0].kind,
        capture.events[1].kind,
        capture.events[2].kind,
        capture.events[3].kind,
        capture.events[4].kind,
        capture.events[5].kind,
    });
    try std.testing.expectEqualStrings("add", capture.events[0].node_name.?);
    try std.testing.expectEqual(@as(usize, 2), capture.events[5].step_number);

    var manual = try graph.iter(std.testing.allocator, &state, &deps, 1, .{});
    try std.testing.expectEqual(add, manual.nextNode().?);
    const first = (try manual.next()).step;
    try std.testing.expectEqual(add, first.completed);
    try std.testing.expectEqual(multiply, first.next);
    try std.testing.expectEqual(@as(u64, 4), manual.currentValue().*);
    const complete = (try manual.next()).complete;
    try std.testing.expectEqual(@as(u64, 16), complete);
    try std.testing.expectEqual(@as(?NodeId, null), manual.nextNode());
    try std.testing.expectEqual(@as(usize, 2), manual.stepsCompleted());
    try std.testing.expectError(error.RunFinished, manual.next());
}

test "graph latches callback and step-limit failures" {
    const Workflow = Graph(u8, u8, u8, u8, u8);
    const Callbacks = struct {
        fn start(context: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            if (context != null) return error.StepFailed;
            return input;
        }

        fn step(context: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            if (context != null) return error.Cancelled;
            return input + 1;
        }

        fn end(context: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            if (context != null) return error.OutOfMemory;
            return input;
        }
    };
    const Capture = struct {
        last: ?Event = null,
        fn emit(context: ?*anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.last = event;
        }
    };
    var marker: u8 = 0;
    var state: u8 = 0;
    var deps: u8 = 0;

    var builder: Workflow.Builder = .{ .limits = .{ .max_steps = 2 } };
    defer builder.deinit(std.testing.allocator);
    try builder.setStart(.{ .run_fn = Callbacks.start });
    try builder.setEnd(.{ .run_fn = Callbacks.end });
    const loop = try builder.addStep(std.testing.allocator, .{ .name = "loop", .run_fn = Callbacks.step });
    try builder.setEntry(loop);
    try builder.connect(std.testing.allocator, loop, loop);
    var graph = try builder.build(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);

    var capture: Capture = .{};
    var execution = try graph.iter(std.testing.allocator, &state, &deps, 0, .{
        .max_steps = 10,
        .events = .{ .context = &capture, .event_fn = Capture.emit },
    });
    _ = (try execution.next()).step;
    _ = (try execution.next()).step;
    try std.testing.expectError(error.StepLimitExceeded, execution.next());
    try std.testing.expectError(error.StepLimitExceeded, execution.next());
    try std.testing.expectEqual(EventKind.run_failed, capture.last.?.kind);
    try std.testing.expectEqualStrings("StepLimitExceeded", capture.last.?.failure_name.?);

    var failed_start = graph;
    failed_start.start.context = &marker;
    capture.last = null;
    try std.testing.expectError(error.StepFailed, failed_start.iter(
        std.testing.allocator,
        &state,
        &deps,
        0,
        .{ .events = .{ .context = &capture, .event_fn = Capture.emit } },
    ));
    try std.testing.expectEqualStrings("StepFailed", capture.last.?.failure_name.?);

    var failed_step = graph;
    failed_step.nodes[0].step.context = &marker;
    var step_run = try failed_step.iter(std.testing.allocator, &state, &deps, 0, .{});
    try std.testing.expectError(error.Cancelled, step_run.next());
    try std.testing.expectError(error.Cancelled, step_run.next());

    var terminal_builder: Workflow.Builder = .{};
    defer terminal_builder.deinit(std.testing.allocator);
    try terminal_builder.setStart(.{ .run_fn = Callbacks.start });
    try terminal_builder.setEnd(.{ .context = &marker, .run_fn = Callbacks.end });
    const terminal = try terminal_builder.addStep(std.testing.allocator, .{
        .name = "terminal",
        .run_fn = Callbacks.step,
    });
    try terminal_builder.setEntry(terminal);
    try terminal_builder.finish(std.testing.allocator, terminal);
    var terminal_graph = try terminal_builder.build(std.testing.allocator);
    defer terminal_graph.deinit(std.testing.allocator);
    try std.testing.expectError(error.OutOfMemory, terminal_graph.run(
        std.testing.allocator,
        &state,
        &deps,
        0,
        .{},
    ));
    terminal_graph.end.context = null;
    try std.testing.expectEqual(@as(u8, 1), try terminal_graph.run(
        std.testing.allocator,
        &state,
        &deps,
        0,
        .{},
    ));
}

test "graph decisions select named branches and latch unmatched routes" {
    const Workflow = Graph(u8, u8, u8, u8, u8);
    const Callbacks = struct {
        fn start(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }

        fn choose(context: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!Workflow.DecisionResult {
            if (context != null) return error.Cancelled;
            return .{
                .branch = if (input == 0) "missing" else if (input % 2 == 0) "even" else "odd",
                .value = input + 1,
            };
        }

        fn identity(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }

        fn end(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
    };
    const Capture = struct {
        last: ?Event = null,

        fn emit(context: ?*anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.last = event;
        }
    };

    var builder: Workflow.Builder = .{};
    defer builder.deinit(std.testing.allocator);
    try builder.setStart(.{ .run_fn = Callbacks.start });
    try builder.setEnd(.{ .run_fn = Callbacks.end });
    const choose = try builder.addDecision(std.testing.allocator, .{
        .name = "choose",
        .run_fn = Callbacks.choose,
    });
    const even = try builder.addStep(std.testing.allocator, .{
        .name = "even",
        .run_fn = Callbacks.identity,
    });
    try builder.setEntry(choose);
    try builder.branch(std.testing.allocator, choose, "even", even);
    try builder.branchFinish(std.testing.allocator, choose, "odd");
    try builder.finish(std.testing.allocator, even);
    var graph = try builder.build(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);

    var state: u8 = 0;
    var deps: u8 = 0;
    try std.testing.expectEqual(@as(u8, 3), try graph.run(
        std.testing.allocator,
        &state,
        &deps,
        2,
        .{},
    ));
    try std.testing.expectEqual(@as(u8, 2), try graph.run(
        std.testing.allocator,
        &state,
        &deps,
        1,
        .{},
    ));

    var capture: Capture = .{};
    var unmatched = try graph.iter(std.testing.allocator, &state, &deps, 0, .{
        .events = .{ .context = &capture, .event_fn = Capture.emit },
    });
    try std.testing.expectError(error.UnmatchedRoute, unmatched.next());
    try std.testing.expectError(error.UnmatchedRoute, unmatched.next());
    try std.testing.expectEqualStrings("UnmatchedRoute", capture.last.?.failure_name.?);
    try std.testing.expectEqualStrings("missing", capture.last.?.branch_name.?);

    var marker: u8 = 0;
    var failed = graph;
    failed.nodes[choose.index].decision.context = &marker;
    try std.testing.expectError(error.Cancelled, failed.run(
        std.testing.allocator,
        &state,
        &deps,
        2,
        .{},
    ));
}

test "graph builder validates decision branches and reachability" {
    const Workflow = Graph(u8, u8, u8, u8, u8);
    const Callbacks = struct {
        fn start(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn step(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn decide(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!Workflow.DecisionResult {
            return .{ .branch = "done", .value = input };
        }
        fn end(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
    };
    const decision = Workflow.Decision{ .name = "decision", .run_fn = Callbacks.decide };
    const step = Workflow.Step{ .name = "step", .run_fn = Callbacks.step };

    var names: Workflow.Builder = .{ .limits = .{ .max_nodes = 1, .max_name_bytes = 8 } };
    defer names.deinit(std.testing.allocator);
    try std.testing.expectError(error.EmptyNodeName, names.addDecision(std.testing.allocator, .{
        .name = "",
        .run_fn = Callbacks.decide,
    }));
    try std.testing.expectError(error.NodeNameTooLong, names.addDecision(std.testing.allocator, .{
        .name = "too-large",
        .run_fn = Callbacks.decide,
    }));
    _ = try names.addStep(std.testing.allocator, step);
    try std.testing.expectError(error.DuplicateNodeName, names.addDecision(std.testing.allocator, .{
        .name = "step",
        .run_fn = Callbacks.decide,
    }));
    try std.testing.expectError(error.LimitExceeded, names.addDecision(std.testing.allocator, decision));

    var kinds: Workflow.Builder = .{ .limits = .{ .max_name_bytes = 8 } };
    defer kinds.deinit(std.testing.allocator);
    const route = try kinds.addDecision(std.testing.allocator, decision);
    const target = try kinds.addStep(std.testing.allocator, step);
    try std.testing.expectError(error.InvalidNode, kinds.branch(
        std.testing.allocator,
        .{ .index = 9 },
        "done",
        target,
    ));
    try std.testing.expectError(error.InvalidNode, kinds.branch(
        std.testing.allocator,
        route,
        "done",
        .{ .index = 9 },
    ));
    try std.testing.expectError(error.InvalidNode, kinds.branchFinish(
        std.testing.allocator,
        .{ .index = 9 },
        "done",
    ));
    try std.testing.expectError(error.InvalidEdgeKind, kinds.connect(
        std.testing.allocator,
        route,
        target,
    ));
    try std.testing.expectError(error.InvalidEdgeKind, kinds.finish(std.testing.allocator, route));
    try std.testing.expectError(error.InvalidEdgeKind, kinds.branchFinish(
        std.testing.allocator,
        target,
        "done",
    ));
    try std.testing.expectError(error.EmptyBranchName, kinds.branchFinish(
        std.testing.allocator,
        route,
        "",
    ));
    try std.testing.expectError(error.BranchNameTooLong, kinds.branchFinish(
        std.testing.allocator,
        route,
        "too-large",
    ));
    try kinds.branch(std.testing.allocator, route, "done", target);
    try std.testing.expectError(error.DuplicateBranchName, kinds.branchFinish(
        std.testing.allocator,
        route,
        "done",
    ));
    try kinds.setStart(.{ .run_fn = Callbacks.start });
    try kinds.setEnd(.{ .run_fn = Callbacks.end });
    try kinds.setEntry(route);
    try kinds.finish(std.testing.allocator, target);
    var valid = try kinds.build(std.testing.allocator);
    defer valid.deinit(std.testing.allocator);
    var state: u8 = 0;
    var deps: u8 = 0;
    try std.testing.expectEqual(@as(u8, 7), try valid.run(
        std.testing.allocator,
        &state,
        &deps,
        7,
        .{},
    ));

    var bounded: Workflow.Builder = .{ .limits = .{ .max_edges = 1 } };
    defer bounded.deinit(std.testing.allocator);
    const bounded_decision = try bounded.addDecision(std.testing.allocator, decision);
    try bounded.branchFinish(std.testing.allocator, bounded_decision, "first");
    try std.testing.expectError(error.LimitExceeded, bounded.branchFinish(
        std.testing.allocator,
        bounded_decision,
        "second",
    ));

    var unreachable_builder: Workflow.Builder = .{};
    defer unreachable_builder.deinit(std.testing.allocator);
    try unreachable_builder.setStart(.{ .run_fn = Callbacks.start });
    try unreachable_builder.setEnd(.{ .run_fn = Callbacks.end });
    const entry = try unreachable_builder.addDecision(std.testing.allocator, decision);
    const orphan = try unreachable_builder.addStep(std.testing.allocator, step);
    try unreachable_builder.setEntry(entry);
    try unreachable_builder.branchFinish(std.testing.allocator, entry, "done");
    try unreachable_builder.finish(std.testing.allocator, orphan);
    try std.testing.expectError(error.UnreachableNode, unreachable_builder.build(std.testing.allocator));
}

test "graph builder rejects invalid bounded definitions" {
    const Workflow = Graph(u8, u8, u8, u8, u8);
    const Callbacks = struct {
        fn start(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn step(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn end(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
    };
    const start = Workflow.Start{ .run_fn = Callbacks.start };
    const end = Workflow.End{ .run_fn = Callbacks.end };
    const step = Workflow.Step{ .name = "step", .run_fn = Callbacks.step };

    var empty: Workflow.Builder = .{};
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectError(error.MissingStart, empty.build(std.testing.allocator));
    try empty.setStart(start);
    try std.testing.expectError(error.DuplicateStart, empty.setStart(start));
    try std.testing.expectError(error.MissingEnd, empty.build(std.testing.allocator));
    try empty.setEnd(end);
    try std.testing.expectError(error.DuplicateEnd, empty.setEnd(end));
    try std.testing.expectError(error.MissingEntry, empty.build(std.testing.allocator));
    try std.testing.expectError(error.InvalidNode, empty.setEntry(.{ .index = 0 }));
    try std.testing.expectError(error.EmptyNodeName, empty.addStep(std.testing.allocator, .{
        .name = "",
        .run_fn = Callbacks.step,
    }));

    var bounded: Workflow.Builder = .{ .limits = .{ .max_nodes = 1, .max_edges = 1, .max_name_bytes = 4 } };
    defer bounded.deinit(std.testing.allocator);
    try std.testing.expectError(error.NodeNameTooLong, bounded.addStep(std.testing.allocator, .{
        .name = "large",
        .run_fn = Callbacks.step,
    }));
    const only = try bounded.addStep(std.testing.allocator, step);
    try std.testing.expectError(error.DuplicateNodeName, bounded.addStep(std.testing.allocator, step));
    try std.testing.expectError(error.LimitExceeded, bounded.addStep(std.testing.allocator, .{
        .name = "next",
        .run_fn = Callbacks.step,
    }));
    try std.testing.expectError(error.InvalidNode, bounded.connect(
        std.testing.allocator,
        .{ .index = 2 },
        only,
    ));
    try std.testing.expectError(error.InvalidNode, bounded.connect(
        std.testing.allocator,
        only,
        .{ .index = 2 },
    ));
    try std.testing.expectError(error.InvalidNode, bounded.finish(std.testing.allocator, .{ .index = 2 }));
    try bounded.finish(std.testing.allocator, only);
    try std.testing.expectError(error.LimitExceeded, bounded.finish(std.testing.allocator, only));

    var duplicate_edge: Workflow.Builder = .{};
    defer duplicate_edge.deinit(std.testing.allocator);
    const duplicate = try duplicate_edge.addStep(std.testing.allocator, step);
    try duplicate_edge.finish(std.testing.allocator, duplicate);
    try std.testing.expectError(
        error.DuplicateOutgoingEdge,
        duplicate_edge.finish(std.testing.allocator, duplicate),
    );

    var incomplete: Workflow.Builder = .{};
    defer incomplete.deinit(std.testing.allocator);
    try incomplete.setStart(start);
    try incomplete.setEnd(end);
    const missing = try incomplete.addStep(std.testing.allocator, step);
    try incomplete.setEntry(missing);
    try std.testing.expectError(error.MissingOutgoingEdge, incomplete.build(std.testing.allocator));
    try incomplete.finish(std.testing.allocator, missing);
    var valid = try incomplete.build(std.testing.allocator);
    defer valid.deinit(std.testing.allocator);
    var state: u8 = 0;
    var deps: u8 = 0;
    try std.testing.expectEqual(@as(u8, 4), try valid.run(
        std.testing.allocator,
        &state,
        &deps,
        4,
        .{},
    ));
}

fn buildGraphWithAllocator(gpa: std.mem.Allocator) !void {
    const Workflow = Graph(u8, u8, u8, u8, u8);
    const Callbacks = struct {
        fn start(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn step(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn end(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
    };
    var builder: Workflow.Builder = .{};
    defer builder.deinit(gpa);
    try builder.setStart(.{ .run_fn = Callbacks.start });
    try builder.setEnd(.{ .run_fn = Callbacks.end });
    const first = try builder.addStep(gpa, .{ .name = "first", .run_fn = Callbacks.step });
    const second = try builder.addStep(gpa, .{ .name = "second", .run_fn = Callbacks.step });
    try builder.setEntry(first);
    try builder.connect(gpa, first, second);
    try builder.finish(gpa, second);
    var graph = try builder.build(gpa);
    defer graph.deinit(gpa);
    var state: u8 = 0;
    var deps: u8 = 0;
    _ = try graph.run(gpa, &state, &deps, 0, .{});
}

test "graph builder cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        buildGraphWithAllocator,
        .{},
    );
}
