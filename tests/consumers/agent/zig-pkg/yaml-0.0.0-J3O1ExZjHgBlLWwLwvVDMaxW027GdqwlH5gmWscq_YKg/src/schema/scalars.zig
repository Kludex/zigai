//! Purpose: Resolve and validate YAML scalar primitive spellings.
//! Owns: Per-type scalar resolution helpers and resolved scalar payloads.
//! Does not own: General schema selection, tag-kind validation, or node construction.
//! Depends on: std only.
//! Tested by: tests/unit/schema/schema_test.zig and in-file tests.

const std = @import("std");

/// Primitive value produced by schema resolution.
pub const ResolvedScalar = union(enum) {
    null_value,
    bool_value: bool,
    int_value: i128,
    float_value: f64,
};

pub const null_scalar = struct {
    /// Returns true when the scalar resolves to a core-schema null.
    pub fn isCoreScalar(value: []const u8, is_plain: bool, tag: ?[]const u8) bool {
        if (tag) |explicit_tag| {
            return std.mem.eql(u8, explicit_tag, "tag:yaml.org,2002:null") and isCoreValue(value);
        }

        if (!is_plain) return false;
        return isCoreValue(value);
    }

    pub fn isCoreValue(value: []const u8) bool {
        return value.len == 0 or
            std.mem.eql(u8, value, "~") or
            std.mem.eql(u8, value, "null") or
            std.mem.eql(u8, value, "Null") or
            std.mem.eql(u8, value, "NULL");
    }
};

pub const bool_scalar = struct {
    pub fn parseCore(value: []const u8) ?bool {
        if (std.mem.eql(u8, value, "true") or
            std.mem.eql(u8, value, "True") or
            std.mem.eql(u8, value, "TRUE"))
        {
            return true;
        }

        if (std.mem.eql(u8, value, "false") or
            std.mem.eql(u8, value, "False") or
            std.mem.eql(u8, value, "FALSE"))
        {
            return false;
        }

        return null;
    }
};

pub const int_scalar = struct {
    pub fn parseCore(value: []const u8) ?i128 {
        if (value.len == 0) return null;

        const sign_offset: usize = if (value[0] == '-' or value[0] == '+') 1 else 0;
        if (sign_offset == value.len) return null;
        const unsigned = value[sign_offset..];

        if (std.mem.startsWith(u8, unsigned, "0o")) {
            if (!allAsciiDigitsInBase(unsigned[2..], 8)) return null;
            return parseSignedPrefixedInteger(value[0..sign_offset], unsigned[2..], 8);
        }

        if (std.mem.startsWith(u8, unsigned, "0x")) {
            if (!allAsciiDigitsInBase(unsigned[2..], 16)) return null;
            return parseSignedPrefixedInteger(value[0..sign_offset], unsigned[2..], 16);
        }

        if (!isBase10Integer(value)) return null;
        return std.fmt.parseInt(i128, value, 10) catch null;
    }

    fn parseSignedPrefixedInteger(sign: []const u8, digits: []const u8, base: u8) ?i128 {
        const magnitude = std.fmt.parseInt(u128, digits, base) catch return null;
        const max_positive: u128 = @intCast(std.math.maxInt(i128));
        if (sign.len == 0 or sign[0] == '+') {
            if (magnitude > max_positive) return null;
            return @intCast(magnitude);
        }

        if (magnitude == max_positive + 1) return std.math.minInt(i128);
        if (magnitude > max_positive) return null;
        return -@as(i128, @intCast(magnitude));
    }

    pub fn parseJson(value: []const u8) ?i128 {
        if (!isJsonInteger(value)) return null;
        return std.fmt.parseInt(i128, value, 10) catch null;
    }

    fn isBase10Integer(value: []const u8) bool {
        var index: usize = if (value[0] == '-' or value[0] == '+') 1 else 0;
        if (index == value.len) return false;

        while (index < value.len) : (index += 1) {
            if (!std.ascii.isDigit(value[index])) return false;
        }

        return true;
    }

    fn isJsonInteger(value: []const u8) bool {
        const end = jsonNumberEnd(value) orelse return false;
        return end == value.len and std.mem.indexOfAny(u8, value, ".eE") == null;
    }

    fn jsonNumberEnd(value: []const u8) ?usize {
        if (value.len == 0) return null;

        var index: usize = 0;
        if (value[index] == '-') {
            index += 1;
            if (index == value.len) return null;
        } else if (value[index] == '+') {
            return null;
        }

        if (value[index] == '0') {
            index += 1;
            if (index < value.len and std.ascii.isDigit(value[index])) return null;
        } else if (value[index] >= '1' and value[index] <= '9') {
            index += 1;
            while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
        } else {
            return null;
        }

        if (index < value.len and value[index] == '.') {
            index += 1;
            // YAML 1.2.2 JSON-schema floats allow zero digits after the dot.
            while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
        }

        if (index < value.len and (value[index] == 'e' or value[index] == 'E')) {
            index += 1;
            if (index < value.len and (value[index] == '-' or value[index] == '+')) index += 1;
            const digits_start = index;
            while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
            if (digits_start == index) return null;
        }

        return index;
    }

    fn allAsciiDigitsInBase(value: []const u8, base: u8) bool {
        if (value.len == 0) return false;

        for (value) |byte| {
            const digit = switch (byte) {
                '0'...'9' => byte - '0',
                'a'...'f' => byte - 'a' + 10,
                'A'...'F' => byte - 'A' + 10,
                else => return false,
            };
            if (digit >= base) return false;
        }

        return true;
    }
};

pub const float_scalar = struct {
    pub const Resolution = enum {
        explicit,
        implicit,
    };

    pub fn parseCore(value: []const u8, resolution: Resolution) ?f64 {
        if (parseCoreSpecial(value)) |float_value| return float_value;

        if (!isCoreFloatNumber(value, resolution == .implicit)) return null;
        return std.fmt.parseFloat(f64, value) catch null;
    }

    pub fn parseJson(value: []const u8) ?f64 {
        if (!isJsonFloat(value)) return null;
        return std.fmt.parseFloat(f64, value) catch null;
    }

    fn parseCoreSpecial(value: []const u8) ?f64 {
        var sign: f64 = 1;
        var signed = false;
        var rest = value;
        if (std.mem.startsWith(u8, rest, "-")) {
            sign = -1;
            signed = true;
            rest = rest[1..];
        } else if (std.mem.startsWith(u8, rest, "+")) {
            signed = true;
            rest = rest[1..];
        }

        if (std.mem.eql(u8, rest, ".inf") or
            std.mem.eql(u8, rest, ".Inf") or
            std.mem.eql(u8, rest, ".INF"))
        {
            return sign * std.math.inf(f64);
        }

        if (!signed and
            (std.mem.eql(u8, rest, ".nan") or
                std.mem.eql(u8, rest, ".NaN") or
                std.mem.eql(u8, rest, ".NAN")))
        {
            return std.math.nan(f64);
        }

        return null;
    }

    fn isCoreFloatNumber(value: []const u8, require_float_marker: bool) bool {
        if (value.len == 0) return false;

        var index: usize = 0;
        if (value[index] == '-' or value[index] == '+') {
            index += 1;
            if (index == value.len) return false;
        }

        var saw_dot = false;
        var saw_exponent = false;

        if (value[index] == '.') {
            saw_dot = true;
            index += 1;
            const digits_start = index;
            while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
            if (digits_start == index) return false;
        } else if (std.ascii.isDigit(value[index])) {
            while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
            if (index < value.len and value[index] == '.') {
                saw_dot = true;
                index += 1;
                while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
            }
        } else {
            return false;
        }

        if (index < value.len and (value[index] == 'e' or value[index] == 'E')) {
            saw_exponent = true;
            index += 1;
            if (index < value.len and (value[index] == '-' or value[index] == '+')) index += 1;
            const digits_start = index;
            while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
            if (digits_start == index) return false;
        }

        if (index != value.len) return false;
        if (require_float_marker and !saw_dot and !saw_exponent) return false;
        return true;
    }

    fn isJsonFloat(value: []const u8) bool {
        const end = jsonNumberEnd(value) orelse return false;
        return end == value.len and std.mem.indexOfAny(u8, value, ".eE") != null;
    }

    fn jsonNumberEnd(value: []const u8) ?usize {
        if (value.len == 0) return null;

        var index: usize = 0;
        if (value[index] == '-') {
            index += 1;
            if (index == value.len) return null;
        } else if (value[index] == '+') {
            return null;
        }

        if (value[index] == '0') {
            index += 1;
            if (index < value.len and std.ascii.isDigit(value[index])) return null;
        } else if (value[index] >= '1' and value[index] <= '9') {
            index += 1;
            while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
        } else {
            return null;
        }

        if (index < value.len and value[index] == '.') {
            index += 1;
            // YAML 1.2.2 JSON-schema floats allow zero digits after the dot.
            while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
        }

        if (index < value.len and (value[index] == 'e' or value[index] == 'E')) {
            index += 1;
            if (index < value.len and (value[index] == '-' or value[index] == '+')) index += 1;
            const digits_start = index;
            while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
            if (digits_start == index) return null;
        }

        return index;
    }
};

pub const timestamp_scalar = struct {
    pub fn isValid(value: []const u8) bool {
        var index: usize = 0;

        const year = parseFixedDigits(value, &index, 4) orelse return false;
        if (!consume(value, &index, '-')) return false;
        const month = parseFixedDigits(value, &index, 2) orelse return false;
        if (!consume(value, &index, '-')) return false;
        const day = parseFixedDigits(value, &index, 2) orelse return false;
        if (!validDate(year, month, day)) return false;

        if (index == value.len) return true;
        if (!consumeTimestampSeparator(value, &index)) return false;

        const hour = parseFixedDigits(value, &index, 2) orelse return false;
        if (!consume(value, &index, ':')) return false;
        const minute = parseFixedDigits(value, &index, 2) orelse return false;
        if (!consume(value, &index, ':')) return false;
        const second = parseFixedDigits(value, &index, 2) orelse return false;
        if (hour > 23 or minute > 59 or second > 59) return false;

        if (index < value.len and value[index] == '.') {
            index += 1;
            const fraction_start = index;
            while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
            if (index == fraction_start) return false;
        }

        if (index == value.len) return true;
        if (isBlank(value[index])) {
            while (index < value.len and isBlank(value[index])) : (index += 1) {}
            if (index == value.len) return false;
        }

        if (value[index] == 'Z') return index + 1 == value.len;
        if (value[index] != '+' and value[index] != '-') return false;
        index += 1;

        const zone_hour = parseOneOrTwoDigits(value, &index) orelse return false;
        var zone_minute: u16 = 0;
        if (index < value.len and value[index] == ':') {
            index += 1;
            zone_minute = parseFixedDigits(value, &index, 2) orelse return false;
        }

        return index == value.len and zone_hour <= 23 and zone_minute <= 59;
    }

    fn consume(value: []const u8, index: *usize, expected: u8) bool {
        if (index.* >= value.len or value[index.*] != expected) return false;
        index.* += 1;
        return true;
    }

    fn consumeTimestampSeparator(value: []const u8, index: *usize) bool {
        if (index.* >= value.len) return false;
        if (value[index.*] == 'T' or value[index.*] == 't') {
            index.* += 1;
            return true;
        }
        if (!isBlank(value[index.*])) return false;
        while (index.* < value.len and isBlank(value[index.*])) : (index.* += 1) {}
        return true;
    }

    fn parseOneOrTwoDigits(value: []const u8, index: *usize) ?u16 {
        const start = index.*;
        while (index.* < value.len and index.* - start < 2 and std.ascii.isDigit(value[index.*])) : (index.* += 1) {}
        if (index.* == start) return null;
        return std.fmt.parseInt(u16, value[start..index.*], 10) catch null;
    }

    fn parseFixedDigits(value: []const u8, index: *usize, count: usize) ?u16 {
        if (value.len - index.* < count) return null;
        const start = index.*;
        const end = start + count;
        for (value[start..end]) |byte| {
            if (!std.ascii.isDigit(byte)) return null;
        }
        index.* = end;
        return std.fmt.parseInt(u16, value[start..end], 10) catch null;
    }

    fn validDate(year: u16, month: u16, day: u16) bool {
        if (month < 1 or month > 12) return false;
        const max_day: u16 = switch (month) {
            2 => if (isLeapYear(year)) 29 else 28,
            4, 6, 9, 11 => 30,
            else => 31,
        };
        return day >= 1 and day <= max_day;
    }

    fn isLeapYear(year: u16) bool {
        return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    }

    fn isBlank(byte: u8) bool {
        return byte == ' ' or byte == '\t';
    }
};

test "null scalar" {
    try std.testing.expect(null_scalar.isCoreScalar("", true, null));
    try std.testing.expect(null_scalar.isCoreScalar("~", true, null));
    try std.testing.expect(null_scalar.isCoreScalar("null", true, null));
    try std.testing.expect(null_scalar.isCoreScalar("Null", true, null));
    try std.testing.expect(null_scalar.isCoreScalar("NULL", true, null));
    try std.testing.expect(!null_scalar.isCoreScalar("", false, null));
    try std.testing.expect(null_scalar.isCoreScalar("~", false, "tag:yaml.org,2002:null"));
    try std.testing.expect(null_scalar.isCoreScalar("NULL", false, "tag:yaml.org,2002:null"));
    try std.testing.expect(!null_scalar.isCoreScalar("not-null", true, "tag:yaml.org,2002:null"));
    try std.testing.expect(!null_scalar.isCoreScalar("null ", true, null));
    try std.testing.expect(!null_scalar.isCoreScalar("~", true, "tag:yaml.org,2002:str"));
}

test "bool scalar" {
    try std.testing.expectEqual(true, bool_scalar.parseCore("true").?);
    try std.testing.expectEqual(true, bool_scalar.parseCore("True").?);
    try std.testing.expectEqual(true, bool_scalar.parseCore("TRUE").?);
    try std.testing.expectEqual(false, bool_scalar.parseCore("false").?);
    try std.testing.expectEqual(false, bool_scalar.parseCore("False").?);
    try std.testing.expectEqual(false, bool_scalar.parseCore("FALSE").?);
    try std.testing.expect(bool_scalar.parseCore("yes") == null);
    try std.testing.expect(bool_scalar.parseCore("FALSE ") == null);
    try std.testing.expect(bool_scalar.parseCore("") == null);
}

test "schema bool: core rejects YAML 1.1 and keyword-like spellings" {
    try std.testing.expect(bool_scalar.parseCore("yes") == null);
    try std.testing.expect(bool_scalar.parseCore("Yes") == null);
    try std.testing.expect(bool_scalar.parseCore("NO") == null);
    try std.testing.expect(bool_scalar.parseCore("on") == null);
    try std.testing.expect(bool_scalar.parseCore("Off") == null);

    try std.testing.expect(bool_scalar.parseCore("truth") == null);
    try std.testing.expect(bool_scalar.parseCore("falsehood") == null);
    try std.testing.expect(bool_scalar.parseCore("truefalse") == null);
}

test "int scalar" {
    try std.testing.expectEqual(@as(i128, 42), int_scalar.parseCore("42").?);
    try std.testing.expectEqual(@as(i128, -19), int_scalar.parseCore("-19").?);
    try std.testing.expectEqual(@as(i128, 7), int_scalar.parseCore("0o7").?);
    try std.testing.expectEqual(@as(i128, -7), int_scalar.parseCore("-0o7").?);
    try std.testing.expectEqual(@as(i128, 7), int_scalar.parseCore("+0o7").?);
    try std.testing.expectEqual(@as(i128, 58), int_scalar.parseCore("0x3A").?);
    try std.testing.expectEqual(@as(i128, -58), int_scalar.parseCore("-0x3A").?);
    try std.testing.expectEqual(@as(i128, 58), int_scalar.parseCore("+0x3A").?);
    try std.testing.expect(int_scalar.parseCore("0o-7") == null);
    try std.testing.expect(int_scalar.parseCore("0x+3A") == null);
    try std.testing.expect(int_scalar.parseCore("12.3") == null);
}

test "schema int: signed prefixed magnitudes respect i128 bounds" {
    try std.testing.expectEqual(std.math.minInt(i128), int_scalar.parseCore("-0x80000000000000000000000000000000").?);
    try std.testing.expect(int_scalar.parseCore("+0x80000000000000000000000000000000") == null);
    try std.testing.expect(int_scalar.parseCore("-0x80000000000000000000000000000001") == null);

    try std.testing.expectEqual(std.math.minInt(i128), int_scalar.parseCore("-0o2000000000000000000000000000000000000000000").?);
    try std.testing.expect(int_scalar.parseCore("+0o2000000000000000000000000000000000000000000") == null);
    try std.testing.expect(int_scalar.parseCore("-0o2000000000000000000000000000000000000000001") == null);
}

test "float scalar" {
    try std.testing.expectEqual(@as(f64, 0.278), float_scalar.parseCore("0.278", .implicit).?);
    try std.testing.expectEqual(@as(f64, 0.5), float_scalar.parseCore(".5", .implicit).?);
    try std.testing.expectEqual(@as(f64, -0.5), float_scalar.parseCore("-.5", .implicit).?);
    try std.testing.expectEqual(@as(f64, 12), float_scalar.parseCore("12.", .implicit).?);
    try std.testing.expectEqual(@as(f64, 1000), float_scalar.parseCore("1e3", .implicit).?);
    try std.testing.expectEqual(@as(f64, -1200), float_scalar.parseCore("-1.2E+3", .implicit).?);
    try std.testing.expect(std.math.isPositiveInf(float_scalar.parseCore("+.INF", .implicit).?));
    try std.testing.expect(std.math.isNegativeInf(float_scalar.parseCore("-.Inf", .implicit).?));
    try std.testing.expect(std.math.isNan(float_scalar.parseCore(".NaN", .implicit).?));
    try std.testing.expect(float_scalar.parseCore("42", .implicit) == null);
    try std.testing.expectEqual(@as(f64, 42), float_scalar.parseCore("42", .explicit).?);
    try std.testing.expect(float_scalar.parseCore("+.NaN", .implicit) == null);
    try std.testing.expect(float_scalar.parseCore("1_2.3", .implicit) == null);
    try std.testing.expect(float_scalar.parseCore("1_2.3", .explicit) == null);
    try std.testing.expect(float_scalar.parseCore("0x1.0p0", .implicit) == null);
    try std.testing.expect(float_scalar.parseCore("0x1.0p0", .explicit) == null);
}

test "schema float: core exponent and decimal boundaries" {
    try std.testing.expectEqual(@as(f64, 1000), float_scalar.parseCore("+1e3", .implicit).?);
    try std.testing.expectEqual(@as(f64, -0.0), float_scalar.parseCore("-0e0", .implicit).?);
    try std.testing.expectEqual(@as(f64, 1), float_scalar.parseCore("1.", .implicit).?);
    try std.testing.expectEqual(@as(f64, 0.25), float_scalar.parseCore(".25", .implicit).?);
    try std.testing.expectEqual(@as(f64, 7), float_scalar.parseCore("7", .explicit).?);

    try std.testing.expect(float_scalar.parseCore(".", .implicit) == null);
    try std.testing.expect(float_scalar.parseCore("1e", .implicit) == null);
    try std.testing.expect(float_scalar.parseCore("1e+", .implicit) == null);
    try std.testing.expect(float_scalar.parseCore("+", .explicit) == null);
    try std.testing.expect(float_scalar.parseCore("7", .implicit) == null);
}

test "schema float: core special value spelling boundaries" {
    try std.testing.expect(std.math.isPositiveInf(float_scalar.parseCore(".inf", .implicit).?));
    try std.testing.expect(std.math.isPositiveInf(float_scalar.parseCore(".Inf", .implicit).?));
    try std.testing.expect(std.math.isPositiveInf(float_scalar.parseCore(".INF", .implicit).?));
    try std.testing.expect(std.math.isPositiveInf(float_scalar.parseCore("+.inf", .implicit).?));
    try std.testing.expect(std.math.isNegativeInf(float_scalar.parseCore("-.INF", .implicit).?));

    try std.testing.expect(std.math.isNan(float_scalar.parseCore(".nan", .implicit).?));
    try std.testing.expect(std.math.isNan(float_scalar.parseCore(".NaN", .implicit).?));
    try std.testing.expect(std.math.isNan(float_scalar.parseCore(".NAN", .implicit).?));

    try std.testing.expect(float_scalar.parseCore("+.nan", .implicit) == null);
    try std.testing.expect(float_scalar.parseCore("-.NaN", .implicit) == null);
    try std.testing.expect(float_scalar.parseCore(".infinity", .implicit) == null);
    try std.testing.expect(float_scalar.parseCore(".nan.", .implicit) == null);
}

test "JSON float scalar" {
    try std.testing.expectEqual(@as(f64, 1), float_scalar.parseJson("1.").?);
    try std.testing.expectEqual(@as(f64, -0.25), float_scalar.parseJson("-0.25").?);
    try std.testing.expectEqual(@as(f64, 1200), float_scalar.parseJson("1.2e+3").?);
    try std.testing.expect(float_scalar.parseJson("1") == null);
    try std.testing.expect(float_scalar.parseJson("+1.0") == null);
    try std.testing.expect(float_scalar.parseJson("01.0") == null);
    try std.testing.expect(float_scalar.parseJson(".5") == null);
    try std.testing.expect(float_scalar.parseJson("1.e") == null);
    try std.testing.expect(float_scalar.parseJson(".inf") == null);
}

test "schema float: JSON exponent and decimal boundaries" {
    try std.testing.expectEqual(@as(f64, 1000), float_scalar.parseJson("1e3").?);
    try std.testing.expectEqual(@as(f64, 0), float_scalar.parseJson("-0e-0").?);
    try std.testing.expectEqual(@as(f64, 1), float_scalar.parseJson("1.E+0").?);

    try std.testing.expect(float_scalar.parseJson("0") == null);
    try std.testing.expect(float_scalar.parseJson("+1e0") == null);
    try std.testing.expect(float_scalar.parseJson("01e0") == null);
    try std.testing.expect(float_scalar.parseJson("1e") == null);
    try std.testing.expect(float_scalar.parseJson("1e+") == null);
    try std.testing.expect(float_scalar.parseJson(".") == null);
}

test "timestamp scalar" {
    try std.testing.expect(timestamp_scalar.isValid("2001-12-15"));
    try std.testing.expect(timestamp_scalar.isValid("2000-02-29"));
    try std.testing.expect(timestamp_scalar.isValid("2400-02-29"));
    try std.testing.expect(timestamp_scalar.isValid("2001-12-15T02:59:43.1Z"));
    try std.testing.expect(timestamp_scalar.isValid("2001-12-15T02:59:43.001Z"));
    try std.testing.expect(timestamp_scalar.isValid("2001-12-15 02:59:43 -5:00"));
    try std.testing.expect(timestamp_scalar.isValid("2001-12-15t02:59:43+05"));
    try std.testing.expect(timestamp_scalar.isValid("2001-12-15T02:59:43+23:59"));
    try std.testing.expect(timestamp_scalar.isValid("2001-12-15T02:59:43-0:00"));
    try std.testing.expect(timestamp_scalar.isValid("2001-12-15T02:59:43 Z"));
    try std.testing.expect(timestamp_scalar.isValid("2001-12-15\t02:59:43\t-5"));
    try std.testing.expect(timestamp_scalar.isValid("2001-12-15 02:59:43 +5"));
    try std.testing.expect(timestamp_scalar.isValid("2001-12-15 02:59:43 +05"));

    try std.testing.expect(!timestamp_scalar.isValid("not-a-date"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-1-15"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-5"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-13-15"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-02-29"));
    try std.testing.expect(!timestamp_scalar.isValid("1900-02-29"));
    try std.testing.expect(!timestamp_scalar.isValid("2100-02-29"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-32"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-15T2:59:43Z"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-15T02:59"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-15T02:59:43 "));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-15T02:59:43.Z"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-15T24:00:00"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-15T02:60:00"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-15T02:59:43+24:00"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-15T02:59:43+23:60"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-15T02:59:43+5:0"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-15T02:59:43+5:"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-15T02:59:43\t"));
    try std.testing.expect(!timestamp_scalar.isValid("2001-12-15T02:59:43\t+"));
}
