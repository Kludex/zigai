pub const packages = struct {
    pub const @"../../.." = struct {
        pub const build_root = "/Users/marcelotryle/dev/personal/zigai/tests/consumers/providers/../../..";
        pub const build_zig = @import("../../..");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "yaml", "yaml-0.0.0-J3O1ExZjHgBlLWwLwvVDMaxW027GdqwlH5gmWscq_YKg" },
        };
    };
    pub const @"yaml-0.0.0-J3O1ExZjHgBlLWwLwvVDMaxW027GdqwlH5gmWscq_YKg" = struct {
        pub const build_root = "/Users/marcelotryle/dev/personal/zigai/tests/consumers/providers/zig-pkg/yaml-0.0.0-J3O1ExZjHgBlLWwLwvVDMaxW027GdqwlH5gmWscq_YKg";
        pub const build_zig = @import("yaml-0.0.0-J3O1ExZjHgBlLWwLwvVDMaxW027GdqwlH5gmWscq_YKg");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "zigai", "../../.." },
};
