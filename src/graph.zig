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
    /// A map emitted too many values or its fork would create too many tasks.
    FanOutLimitExceeded,
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
    /// A fan-out was registered without a branch callback.
    MissingParallelBranch,
};

/// Errors returned while advancing or completing a graph run.
pub const RunError = CallbackError || error{
    StepLimitExceeded,
    UnmatchedRoute,
    /// A run or graph definition configured zero available concurrency.
    InvalidRunOptions,
    /// A parallel fork was requested without an I/O runtime.
    ParallelExecutionRequiresIo,
    /// The I/O runtime could not admit a parallel branch callback.
    ParallelExecutionUnavailable,
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
    /// Maximum values one map callback may emit.
    max_fan_out_items: usize = 1_024,
    /// Maximum branch callbacks created by one fan-out execution.
    max_fan_out_tasks: usize = 4_096,
    /// Maximum branch callbacks registered on one fan-out node.
    max_parallel_branches: usize = 64,
    /// Definition ceiling for callbacks concurrently in flight.
    max_concurrency: usize = 64,
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
    /// Maximum fan-out callbacks in flight. Values above one require `io`.
    max_concurrency: usize = 1,
    /// Runtime used only when a fan-out executes more than one callback at once.
    io: ?std.Io = null,
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
            /// Zero-based source-order index inside a fan-out callback.
            task_index: ?usize = null,
            /// Borrowed branch name inside a fan-out callback.
            branch_name: ?[]const u8 = null,
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

        /// Bounded collector passed to a mapping callback. Emitted values are
        /// owned by the fan-out node until all branch callbacks finish.
        pub const Emitter = struct {
            gpa: std.mem.Allocator,
            max_items: usize,
            items: std.ArrayList(Value) = .empty,

            /// Appends one source item or returns `FanOutLimitExceeded` before
            /// allocating beyond the graph definition's item ceiling.
            pub fn emit(self: *Emitter, value: Value) CallbackError!void {
                if (self.items.items.len >= self.max_items) return error.FanOutLimitExceeded;
                try self.items.append(self.gpa, value);
            }

            /// Returns the number of values emitted so far.
            pub fn count(self: Emitter) usize {
                return self.items.items.len;
            }
        };

        /// Produces source items for a map fan-out. The input is borrowed.
        pub const Map = struct {
            context: ?*anyopaque = null,
            run_fn: *const fn (
                context: ?*anyopaque,
                run: *Context,
                input: Value,
                output: *Emitter,
            ) CallbackError!void,
        };

        /// Selects whether a fan-out duplicates one input or maps emitted items.
        pub const FanOutMode = union(enum) {
            broadcast,
            map: Map,
        };

        /// One borrowed parallel callback. Inputs are borrowed for the call;
        /// outputs are owned by the fan-out until the join has observed them.
        pub const ParallelBranch = struct {
            name: []const u8,
            context: ?*anyopaque = null,
            run_fn: *const fn (
                context: ?*anyopaque,
                run: *Context,
                input: Value,
            ) CallbackError!Value,
        };

        /// Typed join initialized once per fork and reduced in source order.
        /// `reduce_fn` mutates the owned accumulator while borrowing each input.
        pub const Join = struct {
            context: ?*anyopaque = null,
            initial_fn: *const fn (
                context: ?*anyopaque,
                run: *Context,
                input: Value,
            ) CallbackError!Value,
            reduce_fn: *const fn (
                context: ?*anyopaque,
                run: *Context,
                accumulator: *Value,
                input: Value,
                source_index: usize,
            ) CallbackError!void,
        };

        /// Explicit map/broadcast fork with a typed join. Branches and callback
        /// contexts are borrowed for the built graph's lifetime.
        pub const FanOut = struct {
            name: []const u8,
            mode: FanOutMode,
            branches: []const ParallelBranch,
            join: Join,
            cleanup_context: ?*anyopaque = null,
            /// Optional cleanup for owned map items, branch outputs, and an
            /// accumulator abandoned by a reducer failure.
            deinit_value_fn: ?*const fn (
                context: ?*anyopaque,
                gpa: std.mem.Allocator,
                value: *Value,
            ) void = null,
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
            fan_out: FanOut,

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

            /// Registers one explicit map/broadcast fork and typed join.
            pub fn addFanOut(
                self: *Builder,
                gpa: std.mem.Allocator,
                fan_out: FanOut,
            ) BuildError!NodeId {
                if (fan_out.name.len == 0) return error.EmptyNodeName;
                if (fan_out.name.len > self.limits.max_name_bytes) return error.NodeNameTooLong;
                for (self.nodes.items) |existing| {
                    if (std.mem.eql(u8, existing.name(), fan_out.name)) return error.DuplicateNodeName;
                }
                if (fan_out.branches.len == 0) return error.MissingParallelBranch;
                if (fan_out.branches.len > self.limits.max_parallel_branches) return error.LimitExceeded;
                for (fan_out.branches, 0..) |branch_value, index| {
                    if (branch_value.name.len == 0) return error.EmptyBranchName;
                    if (branch_value.name.len > self.limits.max_name_bytes) return error.BranchNameTooLong;
                    for (fan_out.branches[0..index]) |previous| {
                        if (std.mem.eql(u8, previous.name, branch_value.name)) return error.DuplicateBranchName;
                    }
                }
                if (self.nodes.items.len >= self.limits.max_nodes) return error.LimitExceeded;
                const id = NodeId{ .index = self.nodes.items.len };
                try self.nodes.append(gpa, .{ .fan_out = fan_out });
                return id;
            }

            pub fn setEntry(self: *Builder, node: NodeId) BuildError!void {
                try self.validateNode(node);
                self.entry = node;
            }

            /// Connects a step or fan-out to exactly one following node.
            pub fn connect(
                self: *Builder,
                gpa: std.mem.Allocator,
                from: NodeId,
                to: NodeId,
            ) BuildError!void {
                try self.validateNode(from);
                try self.validateNode(to);
                switch (self.nodes.items[from.index]) {
                    .step, .fan_out => {},
                    .decision => return error.InvalidEdgeKind,
                }
                try self.addEdge(gpa, .{ .from = from, .destination = .{ .node = to } });
            }

            /// Marks a step or fan-out as the terminal producer consumed by `End`.
            pub fn finish(self: *Builder, gpa: std.mem.Allocator, from: NodeId) BuildError!void {
                try self.validateNode(from);
                switch (self.nodes.items[from.index]) {
                    .step, .fan_out => {},
                    .decision => return error.InvalidEdgeKind,
                }
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

        const ParallelTask = struct {
            gpa: std.mem.Allocator,
            state: *State,
            deps: *Deps,
            node_id: NodeId,
            step_number: usize,
            task_index: usize,
            branch: ParallelBranch,
            input: Value,
        };

        const TaskOutcome = union(enum) {
            success: struct { index: usize, value: Value },
            failure: struct { index: usize, failure: CallbackError },
        };

        const TaskSelection = union(enum) { task: TaskOutcome };

        fn runParallelTask(task: ParallelTask) TaskOutcome {
            var context = Context{
                .gpa = task.gpa,
                .state = task.state,
                .deps = task.deps,
                .node_id = task.node_id,
                .step_number = task.step_number,
                .task_index = task.task_index,
                .branch_name = task.branch.name,
            };
            const value = task.branch.run_fn(task.branch.context, &context, task.input) catch |failure|
                return .{ .failure = .{ .index = task.task_index, .failure = failure } };
            return .{ .success = .{ .index = task.task_index, .value = value } };
        }

        const LockedAllocator = struct {
            child: std.mem.Allocator,
            io: std.Io,
            mutex: std.Io.Mutex = .init,

            fn allocator(self: *LockedAllocator) std.mem.Allocator {
                return .{ .ptr = self, .vtable = &vtable };
            }

            const vtable: std.mem.Allocator.VTable = .{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            };

            fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
                const self: *LockedAllocator = @ptrCast(@alignCast(context));
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                return self.child.rawAlloc(len, alignment, return_address);
            }

            fn resize(
                context: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                new_len: usize,
                return_address: usize,
            ) bool {
                const self: *LockedAllocator = @ptrCast(@alignCast(context));
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                return self.child.rawResize(memory, alignment, new_len, return_address);
            }

            fn remap(
                context: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                new_len: usize,
                return_address: usize,
            ) ?[*]u8 {
                const self: *LockedAllocator = @ptrCast(@alignCast(context));
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                return self.child.rawRemap(memory, alignment, new_len, return_address);
            }

            fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
                const self: *LockedAllocator = @ptrCast(@alignCast(context));
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                self.child.rawFree(memory, alignment, return_address);
            }
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
            max_concurrency: usize,
            io: ?std.Io,
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
                    .fan_out => |fan_out| branch: {
                        self.value = self.executeFanOut(fan_out) catch |failure|
                            return self.fail(self.current, failure);
                        break :branch null;
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

            fn executeFanOut(self: *Run, fan_out: FanOut) RunError!Value {
                var emitter = Emitter{
                    .gpa = self.gpa,
                    .max_items = self.graph.limits.max_fan_out_items,
                };
                defer emitter.items.deinit(self.gpa);
                const mapped = fan_out.mode == .map;
                if (fan_out.mode == .map) {
                    var map_context = self.context(self.current);
                    fan_out.mode.map.run_fn(
                        fan_out.mode.map.context,
                        &map_context,
                        self.value,
                        &emitter,
                    ) catch |failure| {
                        self.cleanupValues(fan_out, emitter.items.items);
                        return failure;
                    };
                }
                defer if (mapped) self.cleanupValues(fan_out, emitter.items.items);

                const item_count: usize = if (mapped) emitter.items.items.len else 1;
                if (item_count != 0 and
                    fan_out.branches.len > self.graph.limits.max_fan_out_tasks / item_count)
                    return error.FanOutLimitExceeded;
                const task_count = item_count * fan_out.branches.len;

                const results = try self.gpa.alloc(Value, task_count);
                defer self.gpa.free(results);
                const ready = try self.gpa.alloc(bool, task_count);
                defer self.gpa.free(ready);
                @memset(ready, false);
                defer for (results, ready) |*result, is_ready| {
                    if (is_ready) self.cleanupValue(fan_out, result);
                };

                if (task_count > 1 and self.max_concurrency > 1) {
                    const io = self.io orelse return error.ParallelExecutionRequiresIo;
                    try self.executeConcurrent(fan_out, emitter.items.items, results, ready, io);
                } else {
                    for (results, 0..) |*result, index| {
                        switch (runParallelTask(self.parallelTask(fan_out, emitter.items.items, self.gpa, index))) {
                            .success => |outcome| {
                                result.* = outcome.value;
                                ready[index] = true;
                            },
                            .failure => |outcome| return outcome.failure,
                        }
                    }
                }

                var join_context = self.context(self.current);
                var accumulator = try fan_out.join.initial_fn(
                    fan_out.join.context,
                    &join_context,
                    self.value,
                );
                var keep_accumulator = false;
                defer if (!keep_accumulator) self.cleanupValue(fan_out, &accumulator);
                for (results, 0..) |result, index| {
                    try fan_out.join.reduce_fn(
                        fan_out.join.context,
                        &join_context,
                        &accumulator,
                        result,
                        index,
                    );
                }
                keep_accumulator = true;
                return accumulator;
            }

            fn executeConcurrent(
                self: *Run,
                fan_out: FanOut,
                items: []const Value,
                results: []Value,
                ready: []bool,
                io: std.Io,
            ) RunError!void {
                var locked_allocator = LockedAllocator{ .child = self.gpa, .io = io };
                const task_gpa = locked_allocator.allocator();
                const concurrency = @min(self.max_concurrency, results.len);
                const selection_buffer = try self.gpa.alloc(TaskSelection, concurrency);
                defer self.gpa.free(selection_buffer);
                var select: std.Io.Select(TaskSelection) = .init(io, selection_buffer);
                defer select.cancelDiscard();
                var launched: usize = 0;
                var running: usize = 0;
                var completed: usize = 0;
                while (completed < results.len) {
                    while (launched < results.len and running < concurrency) : (launched += 1) {
                        select.concurrent(.task, runParallelTask, .{
                            self.parallelTask(fan_out, items, task_gpa, launched),
                        }) catch {
                            cancelTasks(&select, results, ready);
                            return error.ParallelExecutionUnavailable;
                        };
                        running += 1;
                    }
                    const selection = select.await() catch {
                        cancelTasks(&select, results, ready);
                        return error.Cancelled;
                    };
                    const outcome = switch (selection) {
                        .task => |task| task,
                    };
                    running -= 1;
                    completed += 1;
                    switch (outcome) {
                        .success => |success| {
                            results[success.index] = success.value;
                            ready[success.index] = true;
                        },
                        .failure => |failure| {
                            cancelTasks(&select, results, ready);
                            return failure.failure;
                        },
                    }
                }
            }

            fn cancelTasks(
                select: *std.Io.Select(TaskSelection),
                results: []Value,
                ready: []bool,
            ) void {
                while (select.cancel()) |selection| switch (selection) {
                    .task => |task| switch (task) {
                        .success => |success| {
                            results[success.index] = success.value;
                            ready[success.index] = true;
                        },
                        .failure => {},
                    },
                };
            }

            fn parallelTask(
                self: Run,
                fan_out: FanOut,
                items: []const Value,
                task_gpa: std.mem.Allocator,
                index: usize,
            ) ParallelTask {
                const branch_index = index % fan_out.branches.len;
                const item_index = index / fan_out.branches.len;
                return .{
                    .gpa = task_gpa,
                    .state = self.state,
                    .deps = self.deps,
                    .node_id = self.current,
                    .step_number = self.step_count,
                    .task_index = index,
                    .branch = fan_out.branches[branch_index],
                    .input = if (fan_out.mode == .map) items[item_index] else self.value,
                };
            }

            fn cleanupValues(self: Run, fan_out: FanOut, values: []Value) void {
                for (values) |*value| self.cleanupValue(fan_out, value);
            }

            fn cleanupValue(self: Run, fan_out: FanOut, value: *Value) void {
                if (fan_out.deinit_value_fn) |deinit_value| {
                    deinit_value(fan_out.cleanup_context, self.gpa, value);
                }
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
            if (options.max_concurrency == 0 or self.limits.max_concurrency == 0)
                return error.InvalidRunOptions;
            const max_steps = if (options.max_steps) |requested|
                @min(requested, self.limits.max_steps)
            else
                self.limits.max_steps;
            const max_concurrency = @min(options.max_concurrency, self.limits.max_concurrency);
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
                .max_concurrency = max_concurrency,
                .io = options.io,
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

test "graph broadcast bounds concurrency and reduces in source order" {
    const Value = struct {
        scalar: u64 = 0,
        ordered: [3]u64 = .{ 0, 0, 0 },
        count: usize = 0,
    };
    const State = struct {
        active: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        maximum: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        require_overlap: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        invalid_context: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
        hold: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };
    const Workflow = Graph(State, u8, u64, Value, Value);
    const Callbacks = struct {
        fn start(_: ?*anyopaque, _: *Workflow.Context, input: u64) CallbackError!Value {
            return .{ .scalar = input };
        }

        fn branch(context: ?*anyopaque, run: *Workflow.Context, input: Value) CallbackError!Value {
            const delta: *const u64 = @ptrCast(@alignCast(context.?));
            _ = run.state.invalid_context.fetchOr(
                @intFromBool(run.task_index == null or run.branch_name == null),
                .seq_cst,
            );
            var memory = try run.gpa.alloc(u8, 8);
            if (!run.gpa.resize(memory, memory.len)) return error.StepFailed;
            memory = run.gpa.remap(memory, memory.len).?;
            run.gpa.free(memory);
            const active = run.state.active.fetchAdd(1, .seq_cst) + 1;
            _ = run.state.maximum.fetchMax(active, .seq_cst);
            defer _ = run.state.active.fetchSub(1, .seq_cst);
            if (run.state.require_overlap.load(.seq_cst)) {
                while (run.state.maximum.load(.seq_cst) < 2) std.Thread.yield() catch {};
            }
            if (run.state.hold.load(.seq_cst)) {
                while (!run.state.release.load(.seq_cst)) std.Thread.yield() catch {};
            }
            return .{ .scalar = input.scalar + delta.* };
        }

        fn initial(_: ?*anyopaque, _: *Workflow.Context, _: Value) CallbackError!Value {
            return .{};
        }

        fn reduce(
            _: ?*anyopaque,
            _: *Workflow.Context,
            accumulator: *Value,
            input: Value,
            source_index: usize,
        ) CallbackError!void {
            accumulator.ordered[source_index] = input.scalar;
            accumulator.count += 1;
        }

        fn end(_: ?*anyopaque, _: *Workflow.Context, input: Value) CallbackError!Value {
            return input;
        }

        fn runGraph(
            graph: *const Workflow,
            state: *State,
            deps: *u8,
            io: std.Io,
        ) RunError!Value {
            return graph.run(std.testing.allocator, state, deps, 30, .{
                .max_concurrency = 2,
                .io = io,
            });
        }

        fn complete(done: *std.atomic.Value(bool), value: Value) RunError!Value {
            done.store(true, .seq_cst);
            return value;
        }
    };

    var one: u64 = 1;
    var two: u64 = 2;
    var three: u64 = 3;
    const branches = [_]Workflow.ParallelBranch{
        .{ .name = "one", .context = &one, .run_fn = Callbacks.branch },
        .{ .name = "two", .context = &two, .run_fn = Callbacks.branch },
        .{ .name = "three", .context = &three, .run_fn = Callbacks.branch },
    };
    var builder: Workflow.Builder = .{};
    defer builder.deinit(std.testing.allocator);
    builder.limits.max_concurrency = 2;
    try builder.setStart(.{ .run_fn = Callbacks.start });
    try builder.setEnd(.{ .run_fn = Callbacks.end });
    const fan_out = try builder.addFanOut(std.testing.allocator, .{
        .name = "broadcast",
        .mode = .broadcast,
        .branches = &branches,
        .join = .{ .initial_fn = Callbacks.initial, .reduce_fn = Callbacks.reduce },
    });
    try builder.setEntry(fan_out);
    try builder.finish(std.testing.allocator, fan_out);
    var graph = try builder.build(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);

    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    var state: State = .{};
    var deps: u8 = 0;
    const output = try graph.run(std.testing.allocator, &state, &deps, 10, .{
        .max_concurrency = 8,
        .io = runtime.io(),
    });
    try std.testing.expectEqual(@as(usize, 2), state.maximum.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), state.active.load(.seq_cst));
    try std.testing.expectEqual(@as(u8, 0), state.invalid_context.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 3), output.count);
    try std.testing.expectEqualSlices(u64, &.{ 11, 12, 13 }, &output.ordered);

    try std.testing.expectError(error.ParallelExecutionRequiresIo, graph.run(
        std.testing.allocator,
        &state,
        &deps,
        10,
        .{ .max_concurrency = 2 },
    ));
    try std.testing.expectError(error.InvalidRunOptions, graph.run(
        std.testing.allocator,
        &state,
        &deps,
        10,
        .{ .max_concurrency = 0 },
    ));
    var invalid_definition = graph;
    invalid_definition.limits.max_concurrency = 0;
    try std.testing.expectError(error.InvalidRunOptions, invalid_definition.run(
        std.testing.allocator,
        &state,
        &deps,
        10,
        .{},
    ));

    var unavailable = std.Io.Threaded.init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer unavailable.deinit();
    try std.testing.expectError(error.ParallelExecutionUnavailable, graph.run(
        std.testing.allocator,
        &state,
        &deps,
        10,
        .{ .max_concurrency = 2, .io = unavailable.io() },
    ));

    state.require_overlap.store(false, .seq_cst);
    state.maximum.store(0, .seq_cst);
    const serial = try graph.run(std.testing.allocator, &state, &deps, 20, .{});
    try std.testing.expectEqualSlices(u64, &.{ 21, 22, 23 }, &serial.ordered);

    const CancelResult = union(enum) {
        pending,
        success: Value,
        failure: RunError,
    };
    const Cancel = struct {
        fn run(
            future: *std.Io.Future(RunError!Value),
            io: std.Io,
            requested: *std.atomic.Value(bool),
            result: *CancelResult,
        ) void {
            requested.store(true, .seq_cst);
            const value = future.cancel(io) catch |failure| {
                result.* = .{ .failure = failure };
                return;
            };
            result.* = .{ .success = value };
        }
    };
    state.hold.store(true, .seq_cst);
    state.release.store(false, .seq_cst);
    state.active.store(0, .seq_cst);
    var future = try runtime.io().concurrent(Callbacks.runGraph, .{ &graph, &state, &deps, runtime.io() });
    while (state.active.load(.seq_cst) < 2) std.Thread.yield() catch {};
    var requested = std.atomic.Value(bool).init(false);
    var cancel_result: CancelResult = .pending;
    const cancel_thread = try std.Thread.spawn(.{}, Cancel.run, .{
        &future,
        runtime.io(),
        &requested,
        &cancel_result,
    });
    while (!requested.load(.seq_cst)) std.Thread.yield() catch {};
    var spins: usize = 0;
    while (spins < 100) : (spins += 1) std.Thread.yield() catch {};
    state.release.store(true, .seq_cst);
    cancel_thread.join();
    try std.testing.expectEqual(
        @as(std.meta.Tag(CancelResult), .failure),
        std.meta.activeTag(cancel_result),
    );
    try std.testing.expectEqual(error.Cancelled, cancel_result.failure);

    var completed = std.atomic.Value(bool).init(false);
    var completed_future = try runtime.io().concurrent(Callbacks.complete, .{ &completed, Value{ .scalar = 42 } });
    while (!completed.load(.seq_cst)) std.Thread.yield() catch {};
    var completed_requested = std.atomic.Value(bool).init(false);
    var completed_result: CancelResult = .pending;
    Cancel.run(
        &completed_future,
        runtime.io(),
        &completed_requested,
        &completed_result,
    );
    try std.testing.expect(completed_requested.load(.seq_cst));
    try std.testing.expectEqual(
        @as(std.meta.Tag(CancelResult), .success),
        std.meta.activeTag(completed_result),
    );
    try std.testing.expectEqual(@as(u64, 42), completed_result.success.scalar);
}

test "graph map finalizes empty forks and cleans every failure path" {
    const OwnedValue = struct {
        number: u64 = 0,
        bytes: ?[]u8 = null,
    };
    const Mode = enum {
        success,
        expand_failure,
        branch_failure,
        many_branch_failures,
        initial_failure,
        reduce_failure,
    };
    const State = struct {
        mode: Mode = .success,
        cleaned: usize = 0,
        emitted: usize = 0,
        branch_calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    };
    const Workflow = Graph(State, u8, u64, OwnedValue, u64);
    const Callbacks = struct {
        fn make(gpa: std.mem.Allocator, number: u64) CallbackError!OwnedValue {
            const bytes = try gpa.alloc(u8, 1);
            bytes[0] = @intCast(number);
            return .{ .number = number, .bytes = bytes };
        }

        fn cleanup(context: ?*anyopaque, gpa: std.mem.Allocator, value: *OwnedValue) void {
            const state: *State = @ptrCast(@alignCast(context.?));
            if (value.bytes) |bytes| {
                gpa.free(bytes);
                value.bytes = null;
                state.cleaned += 1;
            }
        }

        fn start(_: ?*anyopaque, _: *Workflow.Context, input: u64) CallbackError!OwnedValue {
            return .{ .number = input };
        }

        fn expand(
            _: ?*anyopaque,
            run: *Workflow.Context,
            input: OwnedValue,
            output: *Workflow.Emitter,
        ) CallbackError!void {
            var index: u64 = 0;
            while (index < input.number) : (index += 1) {
                var value = try make(run.gpa, index + 1);
                output.emit(value) catch |failure| {
                    cleanup(run.state, run.gpa, &value);
                    return failure;
                };
                run.state.emitted = output.count();
                if (run.state.mode == .expand_failure) return error.StepFailed;
            }
        }

        fn branch(_: ?*anyopaque, run: *Workflow.Context, input: OwnedValue) CallbackError!OwnedValue {
            _ = run.state.branch_calls.fetchAdd(1, .seq_cst);
            if (run.state.mode == .branch_failure and input.number == 2) return error.Cancelled;
            if (run.state.mode == .many_branch_failures and input.number >= 2) return error.Cancelled;
            return make(run.gpa, input.number * 2);
        }

        fn initial(_: ?*anyopaque, run: *Workflow.Context, _: OwnedValue) CallbackError!OwnedValue {
            if (run.state.mode == .initial_failure) return error.StepFailed;
            return make(run.gpa, 0);
        }

        fn reduce(
            _: ?*anyopaque,
            run: *Workflow.Context,
            accumulator: *OwnedValue,
            input: OwnedValue,
            source_index: usize,
        ) CallbackError!void {
            if (run.state.mode == .reduce_failure and source_index == 1) return error.StepFailed;
            accumulator.number += input.number;
        }

        fn end(_: ?*anyopaque, run: *Workflow.Context, input: OwnedValue) CallbackError!u64 {
            var owned = input;
            const result = owned.number;
            cleanup(run.state, run.gpa, &owned);
            return result;
        }
    };

    const branches = [_]Workflow.ParallelBranch{
        .{ .name = "double", .run_fn = Callbacks.branch },
    };
    var state: State = .{};
    var builder: Workflow.Builder = .{};
    defer builder.deinit(std.testing.allocator);
    try builder.setStart(.{ .run_fn = Callbacks.start });
    try builder.setEnd(.{ .run_fn = Callbacks.end });
    const fan_out = try builder.addFanOut(std.testing.allocator, .{
        .name = "map",
        .mode = .{ .map = .{ .run_fn = Callbacks.expand } },
        .branches = &branches,
        .join = .{ .initial_fn = Callbacks.initial, .reduce_fn = Callbacks.reduce },
        .cleanup_context = &state,
        .deinit_value_fn = Callbacks.cleanup,
    });
    try builder.setEntry(fan_out);
    try builder.finish(std.testing.allocator, fan_out);
    var graph = try builder.build(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var deps: u8 = 0;

    try std.testing.expectEqual(@as(u64, 12), try graph.run(
        std.testing.allocator,
        &state,
        &deps,
        3,
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 7), state.cleaned);
    try std.testing.expectEqual(@as(usize, 3), state.emitted);

    state.cleaned = 0;
    state.emitted = 99;
    state.branch_calls.store(0, .seq_cst);
    try std.testing.expectEqual(@as(u64, 0), try graph.run(
        std.testing.allocator,
        &state,
        &deps,
        0,
        .{ .max_concurrency = 2 },
    ));
    try std.testing.expectEqual(@as(usize, 1), state.cleaned);
    try std.testing.expectEqual(@as(usize, 0), state.branch_calls.load(.seq_cst));

    state = .{ .mode = .expand_failure };
    try std.testing.expectError(error.StepFailed, graph.run(
        std.testing.allocator,
        &state,
        &deps,
        3,
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 1), state.cleaned);

    state = .{ .mode = .success };
    var item_limited = graph;
    item_limited.limits.max_fan_out_items = 2;
    try std.testing.expectError(error.FanOutLimitExceeded, item_limited.run(
        std.testing.allocator,
        &state,
        &deps,
        3,
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 3), state.cleaned);

    state = .{ .mode = .success };
    var task_limited = graph;
    task_limited.limits.max_fan_out_tasks = 2;
    try std.testing.expectError(error.FanOutLimitExceeded, task_limited.run(
        std.testing.allocator,
        &state,
        &deps,
        3,
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 3), state.cleaned);

    state = .{ .mode = .branch_failure };
    try std.testing.expectError(error.Cancelled, graph.run(
        std.testing.allocator,
        &state,
        &deps,
        3,
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 4), state.cleaned);
    try std.testing.expectEqual(@as(usize, 2), state.branch_calls.load(.seq_cst));

    state = .{ .mode = .initial_failure };
    try std.testing.expectError(error.StepFailed, graph.run(
        std.testing.allocator,
        &state,
        &deps,
        3,
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 6), state.cleaned);

    state = .{ .mode = .reduce_failure };
    try std.testing.expectError(error.StepFailed, graph.run(
        std.testing.allocator,
        &state,
        &deps,
        3,
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 7), state.cleaned);

    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    state = .{ .mode = .branch_failure };
    try std.testing.expectError(error.Cancelled, graph.run(
        std.testing.allocator,
        &state,
        &deps,
        3,
        .{ .max_concurrency = 2, .io = runtime.io() },
    ));
    const branch_calls = state.branch_calls.load(.seq_cst);
    // The scheduler may observe the first success before the concurrent
    // failure and admit one replacement, but it admits no work after failure.
    try std.testing.expect(branch_calls == 2 or branch_calls == 3);
    try std.testing.expectEqual(3 + branch_calls - 1, state.cleaned);

    state = .{ .mode = .many_branch_failures };
    try std.testing.expectError(error.Cancelled, graph.run(
        std.testing.allocator,
        &state,
        &deps,
        3,
        .{ .max_concurrency = 3, .io = runtime.io() },
    ));
    try std.testing.expectEqual(@as(usize, 4), state.cleaned);
    try std.testing.expectEqual(@as(usize, 3), state.branch_calls.load(.seq_cst));
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
        fn map(_: ?*anyopaque, _: *Workflow.Context, input: u8, output: *Workflow.Emitter) CallbackError!void {
            try output.emit(input);
        }
        fn initial(_: ?*anyopaque, _: *Workflow.Context, _: u8) CallbackError!u8 {
            return 0;
        }
        fn reduce(_: ?*anyopaque, _: *Workflow.Context, accumulator: *u8, input: u8, _: usize) CallbackError!void {
            accumulator.* += input;
        }
        fn end(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
    };
    const start = Workflow.Start{ .run_fn = Callbacks.start };
    const end = Workflow.End{ .run_fn = Callbacks.end };
    const step = Workflow.Step{ .name = "step", .run_fn = Callbacks.step };
    const parallel_branch = Workflow.ParallelBranch{ .name = "work", .run_fn = Callbacks.step };
    const join = Workflow.Join{ .initial_fn = Callbacks.initial, .reduce_fn = Callbacks.reduce };

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
    try std.testing.expectError(error.LimitExceeded, bounded.addFanOut(std.testing.allocator, .{
        .name = "fan",
        .mode = .broadcast,
        .branches = &.{parallel_branch},
        .join = join,
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

    var fan_out_errors: Workflow.Builder = .{ .limits = .{
        .max_name_bytes = 4,
        .max_parallel_branches = 1,
    } };
    defer fan_out_errors.deinit(std.testing.allocator);
    try std.testing.expectError(error.EmptyNodeName, fan_out_errors.addFanOut(std.testing.allocator, .{
        .name = "",
        .mode = .broadcast,
        .branches = &.{parallel_branch},
        .join = join,
    }));
    try std.testing.expectError(error.NodeNameTooLong, fan_out_errors.addFanOut(std.testing.allocator, .{
        .name = "large",
        .mode = .broadcast,
        .branches = &.{parallel_branch},
        .join = join,
    }));
    try std.testing.expectError(error.MissingParallelBranch, fan_out_errors.addFanOut(std.testing.allocator, .{
        .name = "fan",
        .mode = .broadcast,
        .branches = &.{},
        .join = join,
    }));
    try std.testing.expectError(error.LimitExceeded, fan_out_errors.addFanOut(std.testing.allocator, .{
        .name = "fan",
        .mode = .broadcast,
        .branches = &.{ parallel_branch, parallel_branch },
        .join = join,
    }));
    try std.testing.expectError(error.EmptyBranchName, fan_out_errors.addFanOut(std.testing.allocator, .{
        .name = "fan",
        .mode = .broadcast,
        .branches = &.{.{ .name = "", .run_fn = Callbacks.step }},
        .join = join,
    }));
    try std.testing.expectError(error.BranchNameTooLong, fan_out_errors.addFanOut(std.testing.allocator, .{
        .name = "fan",
        .mode = .broadcast,
        .branches = &.{.{ .name = "large", .run_fn = Callbacks.step }},
        .join = join,
    }));

    var duplicate_branches: Workflow.Builder = .{};
    defer duplicate_branches.deinit(std.testing.allocator);
    try std.testing.expectError(error.DuplicateBranchName, duplicate_branches.addFanOut(std.testing.allocator, .{
        .name = "fan",
        .mode = .broadcast,
        .branches = &.{ parallel_branch, parallel_branch },
        .join = join,
    }));
    _ = try duplicate_branches.addStep(std.testing.allocator, step);
    try std.testing.expectError(error.DuplicateNodeName, duplicate_branches.addFanOut(std.testing.allocator, .{
        .name = "step",
        .mode = .broadcast,
        .branches = &.{parallel_branch},
        .join = join,
    }));

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

    var map_builder: Workflow.Builder = .{};
    defer map_builder.deinit(std.testing.allocator);
    try map_builder.setStart(start);
    try map_builder.setEnd(end);
    const map = try map_builder.addFanOut(std.testing.allocator, .{
        .name = "map",
        .mode = .{ .map = .{ .run_fn = Callbacks.map } },
        .branches = &.{parallel_branch},
        .join = join,
    });
    try map_builder.setEntry(map);
    try map_builder.finish(std.testing.allocator, map);
    var map_graph = try map_builder.build(std.testing.allocator);
    defer map_graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 5), try map_graph.run(
        std.testing.allocator,
        &state,
        &deps,
        5,
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

fn runFanOutWithAllocator(gpa: std.mem.Allocator) !void {
    const Workflow = Graph(u8, u8, u8, u8, u8);
    const Callbacks = struct {
        fn start(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn expand(_: ?*anyopaque, _: *Workflow.Context, input: u8, output: *Workflow.Emitter) CallbackError!void {
            try output.emit(input);
            try output.emit(input + 1);
        }
        fn branch(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
        fn initial(_: ?*anyopaque, _: *Workflow.Context, _: u8) CallbackError!u8 {
            return 0;
        }
        fn reduce(_: ?*anyopaque, _: *Workflow.Context, accumulator: *u8, input: u8, _: usize) CallbackError!void {
            accumulator.* += input;
        }
        fn end(_: ?*anyopaque, _: *Workflow.Context, input: u8) CallbackError!u8 {
            return input;
        }
    };
    var builder: Workflow.Builder = .{};
    defer builder.deinit(gpa);
    try builder.setStart(.{ .run_fn = Callbacks.start });
    try builder.setEnd(.{ .run_fn = Callbacks.end });
    const fan_out = try builder.addFanOut(gpa, .{
        .name = "fan-out",
        .mode = .{ .map = .{ .run_fn = Callbacks.expand } },
        .branches = &.{.{ .name = "identity", .run_fn = Callbacks.branch }},
        .join = .{ .initial_fn = Callbacks.initial, .reduce_fn = Callbacks.reduce },
    });
    try builder.setEntry(fan_out);
    try builder.finish(gpa, fan_out);
    var graph = try builder.build(gpa);
    defer graph.deinit(gpa);
    var state: u8 = 0;
    var deps: u8 = 0;
    const output = try graph.run(gpa, &state, &deps, 1, .{});
    if (output != 3) return error.UnexpectedOutput;
}

test "graph builder cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        buildGraphWithAllocator,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runFanOutWithAllocator,
        .{},
    );
}
