const std = @import("std");
const zigai = @import("zigai");

const LocalEmbeddings = struct {
    fn model(self: *LocalEmbeddings) zigai.embeddings.Model {
        return .{
            .context = self,
            .provider_name = "local",
            .model_name = "keyword-demo",
            .max_batch_size = 8,
            .max_dimensions = 3,
            .embed_fn = embed,
        };
    }

    fn embed(
        _: *anyopaque,
        gpa: std.mem.Allocator,
        request: zigai.embeddings.Request,
    ) !zigai.embeddings.BatchResult {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const vectors = try arena.allocator().alloc([]const f32, request.inputs.len);
        for (request.inputs, vectors) |input, *vector| {
            const values = try arena.allocator().alloc(f32, 3);
            values[0] = if (contains(input, "zig")) 1 else 0;
            values[1] = if (contains(input, "python")) 1 else 0;
            values[2] = if (contains(input, "http")) 1 else 0;
            vector.* = values;
        }
        return .{ .arena = arena, .vectors = vectors };
    }

    fn contains(input: []const u8, needle: []const u8) bool {
        return std.ascii.indexOfIgnoreCase(input, needle) != null;
    }
};

pub fn main(init: std.process.Init) !void {
    const documents = [_][]const u8{
        "Zig gives you explicit memory control.",
        "Python has a large machine learning ecosystem.",
        "HTTP carries requests and responses between services.",
    };
    var local: LocalEmbeddings = .{};
    const embedder = zigai.embeddings.Embedder{ .model = local.model() };
    var indexed = try embedder.embedDocuments(init.gpa, &documents, .{});
    defer indexed.deinit();
    var query = try embedder.embedQuery(init.gpa, "How does Zig manage memory?", .{});
    defer query.deinit();

    var best_index: usize = 0;
    var best_score = -std.math.inf(f64);
    for (indexed.vectors, 0..) |vector, index| {
        const score = try zigai.embeddings.cosineSimilarity(query.vectors[0], vector);
        if (score > best_score) {
            best_score = score;
            best_index = index;
        }
    }
    std.debug.print("{s}\n", .{indexed.inputs[best_index]});
}
