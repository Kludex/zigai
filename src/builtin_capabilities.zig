//! Reviewed built-in capability catalog with optional application backends.
//!
//! Native search/fetch use provider tools. Browser, image, skill, and repository
//! capabilities are local tool contracts and import no vendor SDK.

const std = @import("std");
const builtin = @import("builtin");
const agent_spec = @import("agent_spec.zig");
const agent_types = @import("agent.zig");
const execution = @import("execution.zig");
const json_limits = @import("json.zig");
const model_types = @import("model.zig");
const security = @import("security.zig");

/// Shared content bounds for optional local backends.
pub const Limits = struct {
    max_input_bytes: usize = 1024 * 1024,
    max_output_bytes: usize = 8 * 1024 * 1024,
    max_image_bytes: usize = 16 * 1024 * 1024,
};

/// Browser/navigation backend supplied by an application or optional package.
pub const BrowserBackend = struct {
    context: *anyopaque,
    open_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator, url: []const u8) anyerror![]u8,

    pub fn open(self: BrowserBackend, gpa: std.mem.Allocator, url: []const u8) ![]u8 {
        return self.open_fn(self.context, gpa, url);
    }
};

/// Owned image bytes returned by an image-generation backend.
pub const GeneratedImage = struct {
    bytes: []u8,
    media_type: []const u8,
};

/// Image backend supplied by an application or optional vendor adapter.
pub const ImageBackend = struct {
    context: *anyopaque,
    generate_fn: *const fn (
        context: *anyopaque,
        gpa: std.mem.Allocator,
        prompt: []const u8,
    ) anyerror!GeneratedImage,

    pub fn generate(self: ImageBackend, gpa: std.mem.Allocator, prompt: []const u8) !GeneratedImage {
        return self.generate_fn(self.context, gpa, prompt);
    }
};

/// Skill source. Names are validated before this callback runs.
pub const SkillStore = struct {
    context: *anyopaque,
    load_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator, name: []const u8) anyerror![]u8,

    pub fn load(self: SkillStore, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        return self.load_fn(self.context, gpa, name);
    }
};

/// Optional repository search implementation. File reads use `Environment`.
pub const RepositorySearch = struct {
    context: *anyopaque,
    search_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator, query: []const u8) anyerror![]u8,

    pub fn search(self: RepositorySearch, gpa: std.mem.Allocator, query: []const u8) ![]u8 {
        return self.search_fn(self.context, gpa, query);
    }
};

/// Stable catalog configuration. Call `resolver` only after this value reaches
/// its final address, and keep it alive as long as resolved capabilities.
pub const Catalog = struct {
    browser: ?BrowserBackend = null,
    image: ?ImageBackend = null,
    skills: ?SkillStore = null,
    repository: ?execution.Environment = null,
    repository_search: ?RepositorySearch = null,
    url_policy: security.UrlPolicy = .{},
    limits: Limits = .{},
    web_search: model_types.BuiltinTool.WebSearch = .{},
    web_search_tools: [1]model_types.BuiltinTool = undefined,
    web_fetch_tools: [1]model_types.BuiltinTool = undefined,
    browser_tools: [1]model_types.Tool = undefined,
    image_tools: [1]model_types.Tool = undefined,
    skill_tools: [1]model_types.Tool = undefined,
    repository_tools: [2]model_types.Tool = undefined,

    pub fn resolver(self: *Catalog) agent_spec.CapabilityResolver {
        return .{ .context = self, .getFn = get };
    }

    pub fn capability(self: *Catalog, id: []const u8) ?agent_types.Capability {
        self.bindTools();
        if (std.mem.eql(u8, id, "web_search")) return .{
            .id = "web_search",
            .description = "Search the public web with the model provider.",
            .builtin_tools = &self.web_search_tools,
        };
        if (std.mem.eql(u8, id, "web_fetch")) return .{
            .id = "web_fetch",
            .description = "Fetch a public web page with the model provider.",
            .builtin_tools = &self.web_fetch_tools,
        };
        if (std.mem.eql(u8, id, "browser") and self.browser != null) return .{
            .id = "browser",
            .description = "Open a policy-approved public URL in an application browser backend.",
            .tools = &self.browser_tools,
        };
        if (std.mem.eql(u8, id, "image_generation") and self.image != null) return .{
            .id = "image_generation",
            .description = "Generate an image with an application-selected backend.",
            .tools = &self.image_tools,
        };
        if (std.mem.eql(u8, id, "skills") and self.skills != null) return .{
            .id = "skills",
            .description = "Load reviewed instructions by stable skill name.",
            .tools = &self.skill_tools,
        };
        if (std.mem.eql(u8, id, "repository_context") and self.repository != null) return .{
            .id = "repository_context",
            .description = "Read and search files inside the configured repository root.",
            .tools = if (self.repository_search != null) &self.repository_tools else self.repository_tools[0..1],
        };
        return null;
    }

    fn get(context: *anyopaque, id: []const u8) ?agent_types.Capability {
        const self: *Catalog = @ptrCast(@alignCast(context));
        return self.capability(id);
    }

    fn bindTools(self: *Catalog) void {
        self.web_search_tools[0] = .{ .web_search = self.web_search };
        self.web_fetch_tools[0] = .{ .web_fetch = .{} };
        self.browser_tools[0] = .{ .definition = .{
            .name = "browser_open",
            .description = "Open one public URL and return bounded page text.",
            .parameters_json_schema =
            \\{"type":"object","properties":{"url":{"type":"string"}},"required":["url"],"additionalProperties":false}
            ,
        }, .context = self, .executeFn = executeBrowser };
        self.image_tools[0] = .{ .definition = .{
            .name = "generate_image",
            .description = "Generate one image from a bounded prompt.",
            .parameters_json_schema =
            \\{"type":"object","properties":{"prompt":{"type":"string"}},"required":["prompt"],"additionalProperties":false}
            ,
        }, .context = self, .executeFn = executeImage };
        self.skill_tools[0] = .{ .definition = .{
            .name = "load_skill",
            .description = "Load reviewed skill instructions by name.",
            .parameters_json_schema =
            \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}
            ,
        }, .context = self, .executeFn = executeSkill };
        self.repository_tools[0] = .{ .definition = .{
            .name = "read_repository_file",
            .description = "Read one file relative to the configured repository root.",
            .parameters_json_schema =
            \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}
            ,
        }, .context = self, .executeFn = executeRepositoryRead };
        self.repository_tools[1] = .{ .definition = .{
            .name = "search_repository",
            .description = "Search repository context with the configured backend.",
            .parameters_json_schema =
            \\{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}
            ,
        }, .context = self, .executeFn = executeRepositorySearch };
    }
};

fn executeBrowser(context: *anyopaque, gpa: std.mem.Allocator, arguments_json: []const u8) ![]const u8 {
    const self: *Catalog = @ptrCast(@alignCast(context));
    const arguments = try parseArgument(gpa, arguments_json, "url", self.limits.max_input_bytes);
    defer gpa.free(arguments);
    try self.url_policy.validate(arguments);
    const output = try self.browser.?.open(gpa, arguments);
    errdefer gpa.free(output);
    try validateOutput(output, self.limits.max_output_bytes);
    return output;
}

fn executeImage(context: *anyopaque, gpa: std.mem.Allocator, arguments_json: []const u8) ![]const u8 {
    const self: *Catalog = @ptrCast(@alignCast(context));
    const prompt = try parseArgument(gpa, arguments_json, "prompt", self.limits.max_input_bytes);
    defer gpa.free(prompt);
    const image = try self.image.?.generate(gpa, prompt);
    defer gpa.free(image.bytes);
    if (image.bytes.len == 0 or image.bytes.len > self.limits.max_image_bytes or
        image.media_type.len == 0 or !std.mem.startsWith(u8, image.media_type, "image/"))
        return error.InvalidGeneratedImage;
    const encoded = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(image.bytes.len));
    defer gpa.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    return std.json.Stringify.valueAlloc(gpa, .{
        .media_type = image.media_type,
        .data_base64 = encoded,
    }, .{});
}

fn executeSkill(context: *anyopaque, gpa: std.mem.Allocator, arguments_json: []const u8) ![]const u8 {
    const self: *Catalog = @ptrCast(@alignCast(context));
    const name = try parseArgument(gpa, arguments_json, "name", 128);
    defer gpa.free(name);
    try validateName(name);
    const output = try self.skills.?.load(gpa, name);
    errdefer gpa.free(output);
    try validateOutput(output, self.limits.max_output_bytes);
    return output;
}

fn executeRepositoryRead(context: *anyopaque, gpa: std.mem.Allocator, arguments_json: []const u8) ![]const u8 {
    const self: *Catalog = @ptrCast(@alignCast(context));
    const path = try parseArgument(gpa, arguments_json, "path", self.limits.max_input_bytes);
    defer gpa.free(path);
    const output = try self.repository.?.read(gpa, path);
    errdefer gpa.free(output);
    try validateOutput(output, self.limits.max_output_bytes);
    return output;
}

fn executeRepositorySearch(context: *anyopaque, gpa: std.mem.Allocator, arguments_json: []const u8) ![]const u8 {
    const self: *Catalog = @ptrCast(@alignCast(context));
    const query = try parseArgument(gpa, arguments_json, "query", self.limits.max_input_bytes);
    defer gpa.free(query);
    const output = try self.repository_search.?.search(gpa, query);
    errdefer gpa.free(output);
    try validateOutput(output, self.limits.max_output_bytes);
    return output;
}

fn parseArgument(
    gpa: std.mem.Allocator,
    arguments_json: []const u8,
    field: []const u8,
    maximum: usize,
) ![]u8 {
    const parsed = try json_limits.parse(
        std.json.Value,
        gpa,
        arguments_json,
        json_limits.defaults.tool_payload,
        .{ .allocate = .alloc_always },
        error.InvalidBuiltinCapabilityArguments,
    );
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 1)
        return error.InvalidBuiltinCapabilityArguments;
    const value = parsed.value.object.get(field) orelse return error.InvalidBuiltinCapabilityArguments;
    if (value != .string or value.string.len == 0 or value.string.len > maximum)
        return error.InvalidBuiltinCapabilityArguments;
    return gpa.dupe(u8, value.string);
}

fn validateName(name: []const u8) !void {
    for (name) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.'))
        return error.InvalidBuiltinCapabilityArguments;
}

fn validateOutput(output: []const u8, maximum: usize) !void {
    if (output.len > maximum) return error.BuiltinCapabilityOutputTooLarge;
}

test "built-in catalog exposes native and optional capability families safely" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const State = struct {
        browser_calls: usize = 0,
        image_calls: usize = 0,
        skill_calls: usize = 0,
        search_calls: usize = 0,

        fn browser(context: *anyopaque, gpa: std.mem.Allocator, url: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("https://example.com/", url);
            self.browser_calls += 1;
            return gpa.dupe(u8, "page");
        }
        fn image(context: *anyopaque, gpa: std.mem.Allocator, prompt: []const u8) !GeneratedImage {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("draw", prompt);
            self.image_calls += 1;
            return .{ .bytes = try gpa.dupe(u8, "png"), .media_type = "image/png" };
        }
        fn skill(context: *anyopaque, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("review", name);
            self.skill_calls += 1;
            return gpa.dupe(u8, "instructions");
        }
        fn search(context: *anyopaque, gpa: std.mem.Allocator, query: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("needle", query);
            self.search_calls += 1;
            return gpa.dupe(u8, "match.zig:1");
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "README.md", .data = "repository" });
    var workspace = execution.LocalWorkspace.init(std.testing.io, temporary.dir);
    defer workspace.deinit();
    var state: State = .{};
    var catalog = Catalog{
        .browser = .{ .context = &state, .open_fn = State.browser },
        .image = .{ .context = &state, .generate_fn = State.image },
        .skills = .{ .context = &state, .load_fn = State.skill },
        .repository = workspace.environment(),
        .repository_search = .{ .context = &state, .search_fn = State.search },
    };
    const resolver = catalog.resolver();
    try std.testing.expectEqual(model_types.BuiltinToolKind.web_search, resolver.get("web_search").?.builtin_tools[0].kind());
    try std.testing.expectEqual(model_types.BuiltinToolKind.web_fetch, resolver.get("web_fetch").?.builtin_tools[0].kind());
    try std.testing.expect(resolver.get("unknown") == null);

    const browser = resolver.get("browser").?.tools[0];
    const page = try browser.execute(std.testing.allocator, "{\"url\":\"https://example.com/\"}");
    defer std.testing.allocator.free(page);
    try std.testing.expectEqualStrings("page", page);
    try std.testing.expectError(
        error.LocalNetworkUrlForbidden,
        browser.execute(std.testing.allocator, "{\"url\":\"https://127.0.0.1/\"}"),
    );

    const image = try resolver.get("image_generation").?.tools[0].execute(
        std.testing.allocator,
        "{\"prompt\":\"draw\"}",
    );
    defer std.testing.allocator.free(image);
    try std.testing.expect(std.mem.indexOf(u8, image, "cG5n") != null);
    const skill = try resolver.get("skills").?.tools[0].execute(
        std.testing.allocator,
        "{\"name\":\"review\"}",
    );
    defer std.testing.allocator.free(skill);
    try std.testing.expectEqualStrings("instructions", skill);
    try std.testing.expectError(
        error.InvalidBuiltinCapabilityArguments,
        resolver.get("skills").?.tools[0].execute(std.testing.allocator, "{\"name\":\"../bad\"}"),
    );
    const repository = resolver.get("repository_context").?;
    const file = try repository.tools[0].execute(std.testing.allocator, "{\"path\":\"README.md\"}");
    defer std.testing.allocator.free(file);
    try std.testing.expectEqualStrings("repository", file);
    const matches = try repository.tools[1].execute(std.testing.allocator, "{\"query\":\"needle\"}");
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqualStrings("match.zig:1", matches);
    try std.testing.expectEqual(@as(usize, 1), state.browser_calls);
    try std.testing.expectEqual(@as(usize, 1), state.image_calls);
    try std.testing.expectEqual(@as(usize, 1), state.skill_calls);
    try std.testing.expectEqual(@as(usize, 1), state.search_calls);

    catalog.limits.max_output_bytes = 1;
    try std.testing.expectError(
        error.BuiltinCapabilityOutputTooLarge,
        browser.execute(std.testing.allocator, "{\"url\":\"https://example.com/\"}"),
    );
    try std.testing.expectError(
        error.BuiltinCapabilityOutputTooLarge,
        catalog.skill_tools[0].execute(std.testing.allocator, "{\"name\":\"review\"}"),
    );
    try std.testing.expectError(
        error.BuiltinCapabilityOutputTooLarge,
        catalog.repository_tools[0].execute(std.testing.allocator, "{\"path\":\"README.md\"}"),
    );
    try std.testing.expectError(
        error.BuiltinCapabilityOutputTooLarge,
        catalog.repository_tools[1].execute(std.testing.allocator, "{\"query\":\"needle\"}"),
    );
    catalog.limits.max_image_bytes = 1;
    try std.testing.expectError(
        error.InvalidGeneratedImage,
        catalog.image_tools[0].execute(std.testing.allocator, "{\"prompt\":\"draw\"}"),
    );
    try std.testing.expectError(
        error.InvalidBuiltinCapabilityArguments,
        browser.execute(std.testing.allocator, "{}"),
    );
    try std.testing.expectError(
        error.InvalidBuiltinCapabilityArguments,
        browser.execute(std.testing.allocator, "{\"url\":1}"),
    );
}

fn runCatalogWithAllocator(gpa: std.mem.Allocator) !void {
    const State = struct {
        fn browser(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]u8 {
            return allocator.dupe(u8, "page");
        }
    };
    var marker: u8 = 0;
    var catalog = Catalog{ .browser = .{ .context = &marker, .open_fn = State.browser } };
    const resolver = catalog.resolver();
    const output = try resolver.get("browser").?.tools[0].execute(
        gpa,
        "{\"url\":\"https://example.com/\"}",
    );
    defer gpa.free(output);
}

test "built-in capability ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runCatalogWithAllocator,
        .{},
    );
}
