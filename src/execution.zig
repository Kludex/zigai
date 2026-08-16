//! Explicit filesystem, command, remote-sandbox, audit, and workspace contracts.
//!
//! Local workspaces are rooted directory handles. Paths are always relative and
//! validated before I/O. Remote backends implement the same owned result API.

const std = @import("std");
const builtin = @import("builtin");
const model_types = @import("model.zig");

/// Backend enforcement guarantees.
pub const Profile = struct {
    filesystem: bool = true,
    shell: bool = true,
    network_isolated: bool = false,
    disposable: bool = false,
};

/// Network access required by one command.
pub const NetworkAccess = enum {
    denied,
    unrestricted,
};

/// One command environment variable. Sensitive values never enter audit events.
pub const EnvironmentVariable = struct {
    name: []const u8,
    value: []const u8,
    sensitive: bool = false,
};

/// Explicit command and process policy.
pub const CommandPolicy = struct {
    allowed_executables: []const []const u8 = &.{},
    network: NetworkAccess = .denied,
    allow_sensitive_environment: bool = false,
    redact_sensitive_output: bool = true,
    max_arguments: usize = 128,
    max_environment_variables: usize = 128,
    max_output_bytes: usize = 1024 * 1024,
};

/// Filesystem operation policy.
pub const FilesystemPolicy = struct {
    read_only: bool = false,
    max_file_bytes: usize = 16 * 1024 * 1024,
};

/// One bounded command request.
pub const Command = struct {
    argv: []const []const u8,
    cwd: []const u8 = ".",
    environment: []const EnvironmentVariable = &.{},
    network: NetworkAccess = .denied,
    timeout_ms: ?u64 = null,
    cancellation: ?*const model_types.CancellationToken = null,
};

/// Arena-owned command result with secret-redacted output.
pub const CommandResult = struct {
    arena: std.heap.ArenaAllocator,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: ?u8,

    pub fn deinit(self: *CommandResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Borrowed audit event. Secret values are represented only by variable names.
pub const AuditEvent = struct {
    operation: Operation,
    path: ?[]const u8 = null,
    executable: ?[]const u8 = null,
    sensitive_environment_names: []const []const u8 = &.{},
    success: bool,
    failure_name: ?[]const u8 = null,

    pub const Operation = enum { read, write, remove, command, dispose };
};

/// Infallible audit sink. Copy borrowed fields before retaining them.
pub const AuditSink = struct {
    context: ?*anyopaque = null,
    event_fn: *const fn (context: ?*anyopaque, event: AuditEvent) void,

    pub fn emit(self: AuditSink, event: AuditEvent) void {
        self.event_fn(self.context, event);
    }
};

/// Provider-neutral execution environment vtable.
pub const Environment = struct {
    context: *anyopaque,
    profile: Profile,
    read_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]u8,
    write_fn: *const fn (context: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void,
    remove_fn: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
    execute_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator, command: Command) anyerror!CommandResult,
    dispose_fn: ?*const fn (context: *anyopaque) anyerror!void = null,

    pub fn read(self: Environment, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.read_fn(self.context, gpa, path);
    }

    pub fn write(self: Environment, path: []const u8, bytes: []const u8) !void {
        return self.write_fn(self.context, path, bytes);
    }

    pub fn remove(self: Environment, path: []const u8) !void {
        return self.remove_fn(self.context, path);
    }

    pub fn execute(self: Environment, gpa: std.mem.Allocator, command: Command) !CommandResult {
        return self.execute_fn(self.context, gpa, command);
    }

    pub fn dispose(self: Environment) !void {
        const dispose_fn = self.dispose_fn orelse return error.WorkspaceNotDisposable;
        return dispose_fn(self.context);
    }
};

/// Application-owned remote sandbox API using the common environment contract.
pub const RemoteSandbox = struct {
    environment: Environment,
    sandbox_id: []const u8,
};

/// Local rooted workspace. `root` is borrowed unless `owns_root` is true.
pub const LocalWorkspace = struct {
    io: std.Io,
    root: std.Io.Dir,
    filesystem_policy: FilesystemPolicy = .{},
    command_policy: CommandPolicy = .{},
    audit: ?AuditSink = null,
    owns_root: bool = false,
    disposal_parent: ?std.Io.Dir = null,
    /// Borrowed path that must outlive this disposable workspace.
    disposal_path: ?[]const u8 = null,
    disposed: bool = false,

    pub fn init(io: std.Io, root: std.Io.Dir) LocalWorkspace {
        return .{ .io = io, .root = root };
    }

    pub fn initDisposable(
        io: std.Io,
        parent: std.Io.Dir,
        relative_path: []const u8,
    ) !LocalWorkspace {
        try validatePath(relative_path);
        try parent.createDirPath(io, relative_path);
        const root = try parent.openDir(io, relative_path, .{});
        return .{
            .io = io,
            .root = root,
            .owns_root = true,
            .disposal_parent = parent,
            .disposal_path = relative_path,
        };
    }

    pub fn deinit(self: *LocalWorkspace) void {
        if (self.owns_root and !self.disposed) {
            self.root.close(self.io);
            self.disposed = true;
            if (self.disposal_parent) |parent| parent.deleteTree(self.io, self.disposal_path.?) catch |failure| {
                self.auditFailure(.dispose, self.disposal_path, null, failure);
            };
        }
        self.* = undefined;
    }

    pub fn environment(self: *LocalWorkspace) Environment {
        return .{
            .context = self,
            .profile = .{
                .network_isolated = false,
                .disposable = self.owns_root,
            },
            .read_fn = read,
            .write_fn = write,
            .remove_fn = remove,
            .execute_fn = execute,
            .dispose_fn = if (self.owns_root) dispose else null,
        };
    }

    fn read(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *LocalWorkspace = @ptrCast(@alignCast(context));
        validatePath(path) catch |failure| {
            self.auditFailure(.read, path, null, failure);
            return failure;
        };
        var file = self.root.openFile(self.io, path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |failure| {
            self.auditFailure(.read, path, null, failure);
            return failure;
        };
        defer file.close(self.io);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        const bytes = reader.interface.allocRemaining(
            gpa,
            .limited(self.filesystem_policy.max_file_bytes),
        ) catch |failure| {
            self.auditFailure(.read, path, null, failure);
            return failure;
        };
        self.auditSuccess(.read, path, null, &.{});
        return bytes;
    }

    fn write(context: *anyopaque, path: []const u8, bytes: []const u8) !void {
        const self: *LocalWorkspace = @ptrCast(@alignCast(context));
        validatePath(path) catch |failure| {
            self.auditFailure(.write, path, null, failure);
            return failure;
        };
        if (self.filesystem_policy.read_only) return error.ReadOnlyWorkspace;
        if (bytes.len > self.filesystem_policy.max_file_bytes) return error.ExecutionFileTooLarge;
        var file = self.root.createFile(self.io, path, .{ .resolve_beneath = true }) catch |failure| {
            self.auditFailure(.write, path, null, failure);
            return failure;
        };
        defer file.close(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(self.io, &buffer);
        writer.interface.writeAll(bytes) catch |failure| { // kcov-ignore: requires an OS write failure after open
            self.auditFailure(.write, path, null, failure); // kcov-ignore: write failure audit
            return failure; // kcov-ignore: write failure propagation
        };
        try writer.interface.flush();
        self.auditSuccess(.write, path, null, &.{});
    }

    fn remove(context: *anyopaque, path: []const u8) !void {
        const self: *LocalWorkspace = @ptrCast(@alignCast(context));
        try validatePath(path);
        if (self.filesystem_policy.read_only) return error.ReadOnlyWorkspace;
        self.root.deleteFile(self.io, path) catch |failure| {
            self.auditFailure(.remove, path, null, failure);
            return failure;
        };
        self.auditSuccess(.remove, path, null, &.{});
    }

    fn execute(context: *anyopaque, gpa: std.mem.Allocator, command: Command) !CommandResult {
        const self: *LocalWorkspace = @ptrCast(@alignCast(context));
        const sensitive_names = try validateCommand(gpa, command, self.command_policy, false);
        defer gpa.free(sensitive_names);
        var environ = std.process.Environ.Map.init(gpa);
        defer environ.deinit();
        for (command.environment) |variable| try environ.put(variable.name, variable.value);
        var cwd: ?std.Io.Dir = if (std.mem.eql(u8, command.cwd, ".")) null else try self.root.openDir(
            self.io,
            command.cwd,
            .{},
        );
        defer if (cwd) |*directory| directory.close(self.io);
        const control = try model_types.RunControl.init(self.io, command.cancellation, command.timeout_ms);
        const raw = control.invoke(std.process.RunResult, runProcess, .{
            gpa,
            self.io,
            command.argv,
            if (cwd) |directory| directory else self.root,
            &environ,
            self.command_policy.max_output_bytes,
        }) catch |failure| {
            self.auditFailure(.command, null, command.argv[0], failure);
            return failure;
        };
        defer gpa.free(raw.stdout);
        defer gpa.free(raw.stderr);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const stdout = try redactOutput(arena.allocator(), raw.stdout, command.environment, self.command_policy);
        const stderr = try redactOutput(arena.allocator(), raw.stderr, command.environment, self.command_policy);
        self.auditSuccess(.command, null, command.argv[0], sensitive_names);
        return .{
            .arena = arena,
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = switch (raw.term) {
                .exited => |code| code,
                else => null,
            },
        };
    }

    fn dispose(context: *anyopaque) !void {
        const self: *LocalWorkspace = @ptrCast(@alignCast(context));
        if (self.disposed) return;
        self.root.close(self.io);
        self.disposed = true;
        if (self.disposal_parent) |parent| parent.deleteTree(self.io, self.disposal_path.?) catch |failure| { // kcov-ignore: requires an OS deletion failure
            self.auditFailure(.dispose, self.disposal_path, null, failure); // kcov-ignore: deletion failure audit
            return failure; // kcov-ignore: deletion failure propagation
        };
        self.auditSuccess(.dispose, self.disposal_path, null, &.{});
    }

    fn auditSuccess(
        self: LocalWorkspace,
        operation: AuditEvent.Operation,
        path: ?[]const u8,
        executable: ?[]const u8,
        sensitive_names: []const []const u8,
    ) void {
        if (self.audit) |sink| sink.emit(.{
            .operation = operation,
            .path = path,
            .executable = executable,
            .sensitive_environment_names = sensitive_names,
            .success = true,
        });
    }

    fn auditFailure(
        self: LocalWorkspace,
        operation: AuditEvent.Operation,
        path: ?[]const u8,
        executable: ?[]const u8,
        failure: anyerror,
    ) void {
        if (self.audit) |sink| sink.emit(.{
            .operation = operation,
            .path = path,
            .executable = executable,
            .success = false,
            .failure_name = @errorName(failure),
        });
    }
};

fn runProcess(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: std.Io.Dir,
    environ: *const std.process.Environ.Map,
    max_output_bytes: usize,
) !std.process.RunResult {
    return std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .environ_map = environ,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    });
}

fn validateCommand(
    gpa: std.mem.Allocator,
    command: Command,
    policy: CommandPolicy,
    network_isolated: bool,
) ![]const []const u8 {
    if (command.argv.len == 0 or command.argv.len > policy.max_arguments or command.argv[0].len == 0)
        return error.InvalidExecutionCommand;
    try validatePath(command.cwd);
    if (policy.allowed_executables.len > 0) {
        var allowed = false;
        for (policy.allowed_executables) |executable| {
            if (std.mem.eql(u8, executable, command.argv[0])) allowed = true;
        }
        if (!allowed) return error.ExecutionCommandDenied;
    }
    if (command.network != policy.network) return error.ExecutionNetworkDenied;
    if (command.network == .denied and !network_isolated) return error.NetworkIsolationUnavailable;
    if (command.environment.len > policy.max_environment_variables) return error.TooManyExecutionEnvironmentVariables;
    var sensitive_count: usize = 0;
    for (command.environment) |variable| {
        try validateEnvironmentName(variable.name);
        if (variable.sensitive and !policy.allow_sensitive_environment)
            return error.SensitiveEnvironmentDenied;
        sensitive_count += @intFromBool(variable.sensitive);
    }
    const sensitive_names = try gpa.alloc([]const u8, sensitive_count);
    var index: usize = 0;
    for (command.environment) |variable| if (variable.sensitive) {
        sensitive_names[index] = variable.name;
        index += 1;
    };
    return sensitive_names;
}

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidExecutionPath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, "..")) return error.InvalidExecutionPath;
    }
}

fn validateEnvironmentName(name: []const u8) !void {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_'))
        return error.InvalidExecutionEnvironment;
    for (name[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_'))
        return error.InvalidExecutionEnvironment;
}

fn redactOutput(
    arena: std.mem.Allocator,
    source: []const u8,
    environment: []const EnvironmentVariable,
    policy: CommandPolicy,
) ![]const u8 {
    var output = try arena.dupe(u8, source);
    if (!policy.redact_sensitive_output) return output;
    for (environment) |variable| {
        if (!variable.sensitive or variable.value.len == 0) continue;
        while (std.mem.indexOf(u8, output, variable.value)) |index| {
            const replacement = "[REDACTED]";
            const next = try arena.alloc(u8, output.len - variable.value.len + replacement.len);
            @memcpy(next[0..index], output[0..index]);
            @memcpy(next[index .. index + replacement.len], replacement);
            @memcpy(next[index + replacement.len ..], output[index + variable.value.len ..]);
            output = next;
        }
    }
    return output;
}

test "local execution stays rooted redacts secrets and audits operations" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Capture = struct {
        events: usize = 0,
        saw_secret_name: bool = false,
        fn audit(context: ?*anyopaque, event: AuditEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.events += 1;
            for (event.sensitive_environment_names) |name| {
                if (std.mem.eql(u8, name, "SECRET")) self.saw_secret_name = true;
            }
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var capture: Capture = .{};
    var workspace = LocalWorkspace.init(std.testing.io, temporary.dir);
    defer workspace.deinit();
    workspace.audit = .{ .context = &capture, .event_fn = Capture.audit };
    workspace.command_policy = .{
        .allowed_executables = &.{"/usr/bin/env"},
        .network = .unrestricted,
        .allow_sensitive_environment = true,
    };
    const environment = workspace.environment();
    try environment.write("note.txt", "hello");
    const note = try environment.read(std.testing.allocator, "note.txt");
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings("hello", note);
    var result = try environment.execute(std.testing.allocator, .{
        .argv = &.{"/usr/bin/env"},
        .network = .unrestricted,
        .environment = &.{.{ .name = "SECRET", .value = "private-value", .sensitive = true }},
    });
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "private-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "[REDACTED]") != null);
    try std.testing.expectEqual(@as(?u8, 0), result.exit_code);
    try environment.remove("note.txt");
    try std.testing.expect(capture.events >= 4);
    try std.testing.expect(capture.saw_secret_name);
    try std.testing.expectError(error.InvalidExecutionPath, environment.read(std.testing.allocator, "../outside"));
    try std.testing.expectError(error.InvalidExecutionPath, environment.read(std.testing.allocator, "/absolute"));
    try std.testing.expectError(error.FileNotFound, environment.read(std.testing.allocator, "missing"));
    try std.testing.expectError(error.InvalidExecutionPath, environment.write("../outside", "x"));
    try std.testing.expectError(error.FileNotFound, environment.write("missing/file", "x"));
    try std.testing.expectError(error.FileNotFound, environment.remove("missing"));
    try std.testing.expectError(error.InvalidExecutionCommand, environment.execute(std.testing.allocator, .{
        .argv = &.{},
        .network = .unrestricted,
    }));
    try std.testing.expectError(error.ExecutionCommandDenied, environment.execute(std.testing.allocator, .{
        .argv = &.{"/bin/echo"},
        .network = .unrestricted,
    }));
    workspace.command_policy.network = .denied;
    try std.testing.expectError(error.NetworkIsolationUnavailable, environment.execute(std.testing.allocator, .{
        .argv = &.{"/usr/bin/env"},
        .network = .denied,
    }));
}

test "local shell enforces cancellation output environment and network policy" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    var workspace = LocalWorkspace.init(runtime.io(), temporary.dir);
    defer workspace.deinit();
    workspace.command_policy = .{
        .allowed_executables = &.{ "/bin/sh", "/bin/echo" },
        .network = .unrestricted,
        .max_output_bytes = 1,
    };
    const environment = workspace.environment();
    try std.testing.expectError(error.StreamTooLong, environment.execute(std.testing.allocator, .{
        .argv = &.{ "/bin/echo", "long" },
        .network = .unrestricted,
    }));
    workspace.command_policy.max_output_bytes = 1024;
    try temporary.dir.createDirPath(runtime.io(), "child");
    var child_result = try environment.execute(std.testing.allocator, .{
        .argv = &.{ "/bin/echo", "child" },
        .cwd = "child",
        .network = .unrestricted,
    });
    child_result.deinit();
    try std.testing.expectError(error.RunTimedOut, environment.execute(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 10" },
        .network = .unrestricted,
        .timeout_ms = 1,
    }));
    try std.testing.expectError(error.SensitiveEnvironmentDenied, environment.execute(std.testing.allocator, .{
        .argv = &.{ "/bin/echo", "x" },
        .network = .unrestricted,
        .environment = &.{.{ .name = "SECRET", .value = "value", .sensitive = true }},
    }));
    workspace.command_policy.max_environment_variables = 0;
    try std.testing.expectError(error.TooManyExecutionEnvironmentVariables, environment.execute(
        std.testing.allocator,
        .{
            .argv = &.{ "/bin/echo", "x" },
            .network = .unrestricted,
            .environment = &.{.{ .name = "VALUE", .value = "x" }},
        },
    ));
}

test "disposable local and remote workspace contracts clean up" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var workspace = try LocalWorkspace.initDisposable(std.testing.io, temporary.dir, "workspace");
    defer workspace.deinit();
    const environment = workspace.environment();
    try environment.write("artifact.txt", "owned");
    try environment.dispose();
    try environment.dispose();
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.openDir(std.testing.io, "workspace", .{}),
    );
    var abandoned = try LocalWorkspace.initDisposable(std.testing.io, temporary.dir, "abandoned");
    abandoned.deinit();
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.openDir(std.testing.io, "abandoned", .{}),
    );
    const Remote = struct {
        disposed: bool = false,
        fn read(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8) ![]u8 {
            return gpa.dupe(u8, "remote");
        }
        fn write(_: *anyopaque, _: []const u8, _: []const u8) !void {}
        fn remove(_: *anyopaque, _: []const u8) !void {}
        fn execute(_: *anyopaque, gpa: std.mem.Allocator, _: Command) !CommandResult {
            var arena = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const stdout = try arena.allocator().dupe(u8, "remote command");
            return .{ .arena = arena, .stdout = stdout, .stderr = "", .exit_code = 0 };
        }
        fn dispose(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.disposed = true;
        }
    };
    var remote_state: Remote = .{};
    const remote = RemoteSandbox{
        .sandbox_id = "sandbox-1",
        .environment = .{
            .context = &remote_state,
            .profile = .{ .network_isolated = true, .disposable = true },
            .read_fn = Remote.read,
            .write_fn = Remote.write,
            .remove_fn = Remote.remove,
            .execute_fn = Remote.execute,
            .dispose_fn = Remote.dispose,
        },
    };
    const bytes = try remote.environment.read(std.testing.allocator, "file");
    defer std.testing.allocator.free(bytes);
    try remote.environment.write("file", "value");
    try remote.environment.remove("file");
    var command = try remote.environment.execute(std.testing.allocator, .{ .argv = &.{"remote"} });
    command.deinit();
    try remote.environment.dispose();
    try std.testing.expect(remote_state.disposed);

    const Allocation = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var state: Remote = .{};
            const remote_environment = Environment{
                .context = &state,
                .profile = .{ .network_isolated = true, .disposable = true },
                .read_fn = Remote.read,
                .write_fn = Remote.write,
                .remove_fn = Remote.remove,
                .execute_fn = Remote.execute,
                .dispose_fn = Remote.dispose,
            };
            var result = try remote_environment.execute(gpa, .{ .argv = &.{"remote"} });
            result.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Allocation.run, .{});
}

fn runLocalWithAllocator(gpa: std.mem.Allocator) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = "content" });
    var workspace = LocalWorkspace.init(std.testing.io, temporary.dir);
    defer workspace.deinit();
    const bytes = try workspace.environment().read(gpa, "file");
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("content", bytes);
}

fn runCommandWithAllocator(gpa: std.mem.Allocator) !void {
    if (builtin.os.tag == .windows) return;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var workspace = LocalWorkspace.init(std.testing.io, temporary.dir);
    defer workspace.deinit();
    workspace.command_policy = .{
        .allowed_executables = &.{"/bin/echo"},
        .network = .unrestricted,
    };
    var result = try workspace.environment().execute(gpa, .{
        .argv = &.{ "/bin/echo", "output" },
        .network = .unrestricted,
    });
    result.deinit();
}

test "execution environment ownership survives every allocation failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runLocalWithAllocator,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runCommandWithAllocator,
        .{},
    );
}
