const std = @import("std");
const math = std.math;

pub const END_LINE = "\r\n";

pub const RespType = enum {
    // 	RESP2 	Simple 	        +
    simpleStrings,
    // 	RESP2 	Simple 	        -
    simpleErrors,
    // 	RESP2 	Simple 	        :
    int,
    // 	RESP2 	Aggregate 	$
    bulkStrings,
    // 	RESP2 	Aggregate 	*
    array,
};

pub const ParsingError = error{ NotSupported, EndLineNotFound, NotCompletedTransmission, InvalidFormat };

pub const RespParseReturn = struct { Value, RespValue, usize };

const InnerRespParseReturn = struct { RespValue, usize };

pub const ValueType = enum { string, err, int, array };

pub const Value = union(ValueType) {
    const Self = @This();

    string: []const u8,
    err: []const u8,
    int: i64,
    array: std.ArrayList(Value),

    pub fn deinit(self: Self) void {
        switch (self) {
            .array => |arr| {
                defer arr.deinit();
                for (arr.items) |a| {
                    a.deinit();
                }
            },
            else => {},
        }
    }

    pub fn parse(buffer: []const u8, alloc: std.mem.Allocator) anyerror!RespParseReturn {
        // repackage into Value Type (for simpler case handling), although both
        // array will have to be returned
        const resp = try RespValue.parse(buffer, alloc);
        const vals = try Value.convert(&resp[0], alloc);
        return .{ vals, resp[0], resp[1] };
    }

    fn convert(other: *const RespValue, alloc: std.mem.Allocator) anyerror!Value {
        switch (other.*) {
            .simpleStrings => |v| {
                return .{ .string = v };
            },
            .bulkStrings => |v| {
                return .{ .string = v };
            },
            .simpleErrors => |v| {
                return .{ .err = v };
            },
            .int => |v| {
                return .{ .int = v };
            },
            .array => |vals| {
                var arr = try std.ArrayList(Value).initCapacity(alloc, vals.items.len);
                for (vals.items) |*val| {
                    try arr.append(try Value.convert(val, alloc));
                }
                return .{ .array = arr };
            },
        }
    }
};

pub const RespValue = union(RespType) {
    const Self = @This();
    // 	RESP2 	Simple 	        +
    simpleStrings: []const u8,
    // 	RESP2 	Simple 	        -
    simpleErrors: []const u8,
    // 	RESP2 	Simple 	        :
    int: i64,
    // 	RESP2 	Aggregate 	$
    bulkStrings: []const u8,
    // 	RESP2 	Aggregate 	*
    array: std.ArrayList(RespValue),

    pub fn deinit(self: Self) void {
        switch (self) {
            .array => |arr| {
                defer arr.deinit();
                for (arr.items) |a| {
                    a.deinit();
                }
            },
            else => {},
        }
    }

    pub fn parse(buffer: []const u8, alloc: std.mem.Allocator) anyerror!InnerRespParseReturn {
        // command + \n\r
        if (buffer.len <= 3) return ParsingError.NotCompletedTransmission;

        var buf = buffer;
        const command = buf[0];
        buf = buf[1..];
        switch (command) {
            // simpleStrings
            '+' => {
                // +PING\r\n
                return RespValue.parseSimpleString(buf);
            },
            // simpleErrors
            '-' => {
                // -Some Error\r\n
                return RespValue.parseSimpleErrors(buf);
            },
            // bulkStrings
            '$' => {
                // $<length>\r\n<data>\r\n
                return RespValue.parseBulkString(buf);
            },
            // int
            // :[<+|->]<value>\r\n
            ':' => {
                return RespValue.parseInt(buf);
            },
            // array
            // *0\r\n
            // *2\r\n$5\r\nhello\r\n$5\r\nworld\r\n
            '*' => {
                return RespValue.parseArray(buf, alloc);
            },
            else => {
                return ParsingError.NotSupported;
            },
        }
    }

    fn parseSimpleString(buf: []const u8) anyerror!InnerRespParseReturn {
        const untilRaw = findIndex(buf, END_LINE);
        const until = untilRaw orelse return ParsingError.NotCompletedTransmission;
        const res = .{
            .simpleStrings = buf[0..until],
        };
        const end = 1 + until + END_LINE.len;

        return .{ res, end };
    }

    fn parseSimpleErrors(buf: []const u8) anyerror!InnerRespParseReturn {
        const untilRaw = findIndex(buf, END_LINE);
        const until = untilRaw orelse return ParsingError.NotCompletedTransmission;
        const res = .{
            .simpleErrors = buf[0..until],
        };
        const end = 1 + until + END_LINE.len;

        return .{ res, end };
    }

    fn parseBulkString(buf: []const u8) anyerror!InnerRespParseReturn {
        // no $ at the beginning
        // $4\r\nPING\r\n

        // $4
        const endOfSize = findIndex(buf, END_LINE) orelse return ParsingError.NotCompletedTransmission;

        // 4\r\n
        const offset = endOfSize + 2;
        if (buf.len <= offset) return ParsingError.NotCompletedTransmission;

        const size = std.fmt.parseInt(usize, buf[0..endOfSize], 10) catch {
            return ParsingError.InvalidFormat;
        };

        // $4\r\nPING\r\n
        // add $ to the end offset
        const end = offset + size + 2 + 1;
        if (buf.len <= offset) return ParsingError.NotCompletedTransmission;
        return .{ .{ .bulkStrings = buf[offset..][0..size] }, end };
    }

    fn parseInt(buf: []const u8) anyerror!InnerRespParseReturn {

        // :[< +|- >]<value>\r\n
        const endOfInt = findIndex(buf, END_LINE) orelse return ParsingError.NotCompletedTransmission;

        var offset: usize = 0;
        var pos: i64 = 1;
        if (buf[0] == '+') {
            pos = 1;
            offset = 1;
        } else if (buf[0] == '-') {
            pos = -1;
            offset = 1;
        }

        const val = std.fmt.parseInt(i64, buf[offset..endOfInt], 10) catch {
            return ParsingError.InvalidFormat;
        };
        const res = .{ .int = val * pos };
        // +1 because of prefix + 2 for end
        const end = 1 + offset + (endOfInt - offset) + 2;
        return .{ res, end };
    }

    fn parseArray(buf: []const u8, alloc: std.mem.Allocator) anyerror!InnerRespParseReturn {
        // *0\r\n
        // *2\r\n$5\r\nhello\r\n$5\r\nworld\r\n

        var offset: usize = 0;

        const endOfInt = findIndex(buf, END_LINE) orelse return ParsingError.NotCompletedTransmission;

        const val = std.fmt.parseInt(usize, buf[offset..endOfInt], 10) catch {
            return ParsingError.InvalidFormat;
        };

        offset += endOfInt + 2;

        var arr = try std.ArrayList(RespValue).initCapacity(alloc, val);

        for (0..val) |_| {
            // recuse and append to array
            const curr = try RespValue.parse(buf[offset..], alloc);
            offset += curr[1];

            try arr.append(curr[0]);
        }

        const res = .{ .array = arr };
        return .{ res, offset + 1 };
    }

    pub fn write(self: *const RespValue, buffer: *std.ArrayList(u8)) anyerror!void {
        switch (self.*) {
            .simpleStrings => |v| {
                try buffer.append('+');
                try buffer.appendSlice(v);
                try buffer.appendSlice(END_LINE);
            },
            .simpleErrors => |v| {
                try buffer.append('-');
                try buffer.appendSlice(v);
                try buffer.appendSlice(END_LINE);
            },
            .bulkStrings => |v| {
                try buffer.append('$');
                const size = getIntLenUsize(v.len);
                const b = try buffer.addManyAsSlice(size);
                _ = std.fmt.formatIntBuf(b, v.len, 10, std.fmt.Case.lower, .{});
                try buffer.appendSlice(END_LINE);
                try buffer.appendSlice(v);
                try buffer.appendSlice(END_LINE);
            },
            .int => |v| {
                try buffer.append(':');
                const neg = v < 0;
                const size = getIntLenI64(v) + @intFromBool(neg);
                const b = try buffer.addManyAsSlice(size);
                _ = std.fmt.formatIntBuf(b, v, 10, std.fmt.Case.lower, .{});
                try buffer.appendSlice(END_LINE);
            },
            .array => |arr| {
                try buffer.append('*');
                const size = getIntLenUsize(arr.items.len);
                const b = try buffer.addManyAsSlice(size);
                _ = std.fmt.formatIntBuf(b, arr.items.len, 10, std.fmt.Case.lower, .{});
                try buffer.appendSlice(END_LINE);
                for (arr.items) |v| {
                    try v.write(buffer);
                }
            },
        }
    }
};

fn getIntLenUsize(val: usize) usize {
    if (val == 0) return 1;
    return math.log10_int(val) + 1;
}

fn getIntLenI64(val: i64) usize {
    if (val == 0) return 1;
    return math.log10_int(@abs(val)) + 1;
}

pub fn findIndex(haystack: []const u8, needle: []const u8) ?usize {
    for (0..haystack.len - needle.len + 1) |i| {
        const section = haystack[i..][0..needle.len];
        if (std.mem.eql(u8, section, needle)) return i;
    }
    return null;
}

const tallocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "len of int" {
    const exp = "1234";
    const input = 1234;
    try expectEqual(exp.len, getIntLenUsize(input));
}

test "find needle in haystack" {
    const expected = 2;
    const needle = "cd";
    const input = "abcd";
    const res = findIndex(input, needle);
    try expectEqual(res, expected);
}

test "find needle in haystack in middle" {
    const expected = 1;
    const needle = "bc";
    const input = "abcd";
    const res = findIndex(input, needle);
    try expectEqual(res, expected);
}

test "don't find needle in haystack" {
    const expected = null;
    const needle = "cd";
    const input = "abcc";
    const res = findIndex(input, needle);
    try expectEqual(res, expected);
}

test "writeSimpleString" {
    const expected = "+PONG\r\n";

    const pong = RespValue{ .simpleStrings = "PONG" };

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try pong.write(&buffer);

    try expectEqual(buffer.items.len, expected.len);
    try expectEqualSlices(u8, buffer.items, expected);
}

test "writeSimpleErrors" {
    const expected = "-Unable to Process\r\n";

    const pong = RespValue{ .simpleErrors = "Unable to Process" };
    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try pong.write(&buffer);

    try expectEqual(buffer.items.len, expected.len);
    try expectEqualSlices(u8, buffer.items, expected);
}

test "parseSimpleString" {
    const exp = "PING";
    const input = "+PING\r\n";

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try buffer.appendSlice(input);

    const res = try RespValue.parse(buffer.items, tallocator);

    try expectEqual(res[1], input.len);
    switch (res[0]) {
        .simpleStrings => |v| {
            try expectEqualSlices(u8, exp, v);
        },
        else => {
            try expect(false);
        },
    }
}

test "parse simple error" {
    const exp = "Some Error";
    const input = "-Some Error\r\n";

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try buffer.appendSlice(input);

    const res = try RespValue.parse(buffer.items, tallocator);

    try expectEqual(res[1], input.len);
    switch (res[0]) {
        .simpleErrors => |v| {
            try expectEqualSlices(u8, exp, v);
        },
        else => {
            @panic("invalid type");
        },
    }
}

test "parse bulk string" {
    const exp = "PING";
    const input = "$4\r\nPING\r\n";

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try buffer.appendSlice(input);

    const res = try RespValue.parse(buffer.items, tallocator);

    try expectEqual(res[1], input.len);
    switch (res[0]) {
        .bulkStrings => |v| {
            try expectEqualSlices(u8, exp, v);
        },
        else => {
            @panic("invalid type");
        },
    }
}

test "write bulk strings" {
    const expected = "$4\r\nPING\r\n";

    const pong = RespValue{ .bulkStrings = "PING" };
    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try pong.write(&buffer);

    try expectEqual(buffer.items.len, expected.len);
    try expectEqualSlices(u8, buffer.items, expected);
}

test "parse int positive" {
    const exp = 4;
    const input = ":4\r\n";

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try buffer.appendSlice(input);

    const res = try RespValue.parse(buffer.items, tallocator);

    try expectEqual(input.len, res[1]);
    switch (res[0]) {
        .int => |v| {
            try expectEqual(exp, v);
        },
        else => {
            @panic("invalid type");
        },
    }
}

test "parse int positive with sing" {
    const exp = 4;
    const input = ":+4\r\n";

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try buffer.appendSlice(input);

    const res = try RespValue.parse(buffer.items, tallocator);

    try expectEqual(input.len, res[1]);
    switch (res[0]) {
        .int => |v| {
            try expectEqual(exp, v);
        },
        else => {
            @panic("invalid type");
        },
    }
}

test "parse int negative" {
    const exp = -4;
    const input = ":-4\r\n";

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try buffer.appendSlice(input);

    const res = try RespValue.parse(buffer.items, tallocator);

    try expectEqual(input.len, res[1]);
    switch (res[0]) {
        .int => |v| {
            try expectEqual(exp, v);
        },
        else => {
            @panic("invalid type");
        },
    }
}

test "write int values positive no sign" {
    const expected = ":4\r\n";

    const pong = RespValue{ .int = 4 };
    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try pong.write(&buffer);

    try expectEqual(buffer.items.len, expected.len);
    try expectEqualSlices(u8, buffer.items, expected);
}

test "write int values negative" {
    const expected = ":-4\r\n";

    const pong = RespValue{ .int = -4 };
    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try pong.write(&buffer);

    try expectEqual(buffer.items.len, expected.len);
    try expectEqualSlices(u8, buffer.items, expected);
}

test "parse array empty" {
    // *2\r\n$5\r\nhello\r\n$5\r\nworld\r\n
    const input = "*0\r\n";

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try buffer.appendSlice(input);

    const res = try RespValue.parse(buffer.items, tallocator);
    defer res[0].deinit();

    try expectEqual(input.len, res[1]);
    switch (res[0]) {
        .array => |v| {
            try expectEqual(0, v.items.len);
        },
        else => {
            @panic("invalid type");
        },
    }
}

test "parse array single element" {
    // *2\r\n$5\r\nhello\r\n$5\r\nworld\r\n
    const input = "*1\r\n$5\r\nhello\r\n";
    const exp = [_][]const u8{"hello"};

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try buffer.appendSlice(input);

    const res = try RespValue.parse(buffer.items, tallocator);
    defer res[0].deinit();

    try expectEqual(input.len, res[1]);
    switch (res[0]) {
        .array => |vals| {
            try expectEqual(exp.len, vals.items.len);
            const arr = vals.items;
            for (arr, 0..) |v, i| {
                switch (v) {
                    .bulkStrings => |inner| {
                        try expectEqualSlices(u8, inner, exp[i]);
                    },
                    else => {
                        @panic("invalid type");
                    },
                }
            }
        },
        else => {
            @panic("invalid type");
        },
    }
}

test "parse array multiple element" {
    // *2\r\n$5\r\nhello\r\n$5\r\nworld\r\n
    const input = "*2\r\n$5\r\nhello\r\n$5\r\nworld\r\n";
    const exp = [_][]const u8{ "hello", "world" };

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try buffer.appendSlice(input);

    const res = try RespValue.parse(buffer.items, tallocator);
    defer res[0].deinit();

    try expectEqual(input.len, res[1]);
    switch (res[0]) {
        .array => |vals| {
            try expectEqual(exp.len, vals.items.len);
            const arr = vals.items;
            for (arr, exp[0..]) |g, e| {
                switch (g) {
                    .bulkStrings => |inner| {
                        try expectEqualSlices(u8, inner, e[0..]);
                    },
                    else => {
                        @panic("invalid type");
                    },
                }
            }
        },
        else => {
            @panic("invalid type");
        },
    }
}

test "parse array multiple element different types" {
    // *2\r\n$5\r\nhello\r\n$5\r\nworld\r\n
    const input = "*3\r\n$5\r\nhello\r\n$5\r\nworld\r\n:3\r\n";
    const exp = [_][]const u8{ "hello", "world" };
    const expInt = 3;

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try buffer.appendSlice(input);

    const res = try RespValue.parse(buffer.items, tallocator);
    defer res[0].deinit();

    try expectEqual(input.len, res[1]);
    switch (res[0]) {
        .array => |vals| {
            try expectEqual(exp.len + 1, vals.items.len);
            const arr = vals.items;
            for (arr[0..2], exp[0..2]) |g, e| {
                switch (g) {
                    .bulkStrings => |inner| {
                        try expectEqualSlices(u8, inner, e[0..]);
                    },
                    else => {
                        @panic("invalid type");
                    },
                }
            }
            switch (arr[2]) {
                .int => |v| {
                    try expectEqual(expInt, v);
                },
                else => {
                    @panic("invalid type");
                },
            }
        },
        else => {
            @panic("invalid type");
        },
    }
}

test "write array empty" {
    const expected = "*0\r\n";

    const abuffer = std.ArrayList(RespValue).init(tallocator);
    defer abuffer.deinit();

    const pong = RespValue{ .array = abuffer };
    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try pong.write(&buffer);

    try expectEqual(buffer.items.len, expected.len);
    try expectEqualSlices(u8, buffer.items, expected);
}

test "write array single " {
    const expected = "*1\r\n:33\r\n";

    var abuffer = std.ArrayList(RespValue).init(tallocator);
    defer abuffer.deinit();
    try abuffer.append(.{ .int = 33 });

    const pong = RespValue{ .array = abuffer };
    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try pong.write(&buffer);

    try expectEqual(buffer.items.len, expected.len);
    try expectEqualSlices(u8, buffer.items, expected);
}
