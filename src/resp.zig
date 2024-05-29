const std = @import("std");
const math = std.math;

pub const END_LINE = "\r\n";

pub const ParsingError = error{ NotSupported, EndLineNotFound, NotCompletedTransmission, InvalidFormat };

pub const RespParseReturn = struct { Value, RespValue, usize };

const InnerRespParseReturn = struct { RespValue, usize };

pub const Value = union(enum) {
    const Self = @This();

    string: RefCounterSlice(u8),
    err: RefCounterSlice(u8),
    int: i64,
    array: std.ArrayList(Value),
    nullString: void,

    pub fn deinit(self: Self) void {
        switch (self) {
            .string => |v| {
                v.deinit();
            },
            .err => |v| {
                v.deinit();
            },
            .int => {},
            .array => |arr| {
                defer arr.deinit();
                for (arr.items) |a| {
                    a.deinit();
                }
            },
            .nullString => {},
        }
    }

    pub fn parse(buffer: []const u8, alloc: std.mem.Allocator) anyerror!RespParseReturn {
        // repackage into Value Type (for simpler case handling), although both
        // array will have to be returned
        var resp = try RespValue.parse(buffer, alloc);
        const vals = try Value.convert(&resp[0], alloc);
        return .{ vals, resp[0], resp[1] };
    }

    fn convert(other: *RespValue, alloc: std.mem.Allocator) anyerror!Value {
        switch (other.*) {
            .simpleStrings => |v| {
                return .{ .string = v.clone() };
            },
            .bulkStrings => |v| {
                return .{ .string = v.clone() };
            },
            .simpleErrors => |v| {
                return .{ .err = v.clone() };
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
            .nullString => {
                return .{ .nullString = void{} };
            },
        }
    }
};

/// Helper that allows to use the hash map with these types
pub const RespValueContex = struct {
    const Self = @This();

    pub fn hash(self: Self, key: RespValue) u64 {
        const strContext = std.hash_map.StringContext{};

        var h = std.hash.Fnv1a_64.init();
        switch (key) {
            .simpleStrings => |v| {
                h.update(&Self.u64Helper(strContext.hash(v.value)));
            },
            .simpleErrors => |v| {
                h.update(&Self.u64Helper(strContext.hash(v.value)));
            },
            .int => |v| {
                h.update(&Self.u64Helper(@as(u64, @intCast(v))));
            },
            .bulkStrings => |v| {
                h.update(&Self.u64Helper(strContext.hash(v.value)));
            },
            .array => |v| {
                for (v.items) |i| {
                    h.update(&Self.u64Helper(self.hash(i)));
                }
            },
            .nullString => {
                // this should never even exist in the DB (please)
                h.update(&Self.u64Helper(~@as(u64, 0)));
            },
        }
        return h.final();
    }

    fn u64Helper(vRaw: u64) [8]u8 {
        return @bitCast(vRaw);
    }

    pub fn eql(self: Self, a: RespValue, b: RespValue) bool {
        // ugly code -.-
        const strContext = std.hash_map.StringContext{};

        switch (a) {
            .simpleStrings => |l| {
                switch (b) {
                    .simpleStrings => |r| {
                        return strContext.eql(l.value, r.value);
                    },
                    else => {},
                }
            },
            .simpleErrors => |l| {
                switch (b) {
                    .simpleErrors => |r| {
                        return strContext.eql(l.value, r.value);
                    },
                    else => {},
                }
            },
            .int => |l| {
                switch (b) {
                    .int => |r| {
                        return l == r;
                    },
                    else => {},
                }
            },
            .bulkStrings => |l| {
                switch (b) {
                    .bulkStrings => |r| {
                        return strContext.eql(l.value, r.value);
                    },
                    else => {},
                }
            },
            .array => |larr| {
                switch (b) {
                    .array => |rarr| {
                        var s = true;
                        for (larr.items, rarr.items) |l, r| {
                            s = self.eql(l, r);
                            if (!s) break;
                        }
                        return s;
                    },
                    else => {},
                }
            },
            .nullString => {
                switch (b) {
                    .nullString => {
                        return true;
                    },
                    else => {},
                }
            },
        }

        return false;
    }
};

pub const RespValue = union(enum) {
    const Self = @This();
    // 	RESP2 	Simple 	        +
    simpleStrings: RefCounterSlice(u8),
    // 	RESP2 	Simple 	        -
    simpleErrors: RefCounterSlice(u8),
    // 	RESP2 	Simple 	        :
    int: i64,
    // 	RESP2 	Aggregate 	$
    bulkStrings: RefCounterSlice(u8),
    // 	RESP2 	Aggregate 	*
    array: std.ArrayList(RespValue),
    // 	RESP2 	Aggregate 	$
    nullString: void,

    pub fn clone(self: *const Self) anyerror!Self {
        switch (self.*) {
            .simpleStrings => |v| {
                return .{ .simpleStrings = v.clone() };
            },
            .simpleErrors => |v| {
                return .{ .simpleErrors = v.clone() };
            },
            .bulkStrings => |v| {
                return .{ .bulkStrings = v.clone() };
            },
            .int => |v| {
                return .{ .int = v };
            },
            .array => |arr| {
                // TODO: fix array clone :(
                // very expensive
                const a = try arr.clone();
                // make sure the counter increments
                for (a.items) |*v| {
                    _ = try v.clone();
                }
                return .{ .array = a };
            },
            .nullString => {
                return .{ .nullString = void{} };
            },
        }
    }

    pub fn deinit(self: *const Self) void {
        switch (self.*) {
            .simpleStrings => |v| {
                v.deinit();
            },
            .simpleErrors => |v| {
                v.deinit();
            },
            .bulkStrings => |v| {
                v.deinit();
            },
            .int => {
                // has an int in there -.-
            },
            .array => |arr| {
                defer arr.deinit();
                for (arr.items) |a| {
                    a.deinit();
                }
            },
            .nullString => {
                // nothing to do
            },
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
                return RespValue.parseSimpleString(buf, alloc);
            },
            // simpleErrors
            '-' => {
                // -Some Error\r\n
                return RespValue.parseSimpleErrors(buf, alloc);
            },
            // bulkStrings
            '$' => {
                // $<length>\r\n<data>\r\n
                return RespValue.parseBulkString(buf, alloc);
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

    fn parseSimpleString(buf: []const u8, alloc: std.mem.Allocator) anyerror!InnerRespParseReturn {
        const untilRaw = findIndex(buf, END_LINE);
        const until = untilRaw orelse return ParsingError.NotCompletedTransmission;

        const res = .{
            .simpleStrings = try RefCounterSlice(u8).fromSlice(buf[0..until], alloc),
        };
        const end = 1 + until + END_LINE.len;

        return .{ res, end };
    }

    fn parseSimpleErrors(buf: []const u8, alloc: std.mem.Allocator) anyerror!InnerRespParseReturn {
        const untilRaw = findIndex(buf, END_LINE);
        const until = untilRaw orelse return ParsingError.NotCompletedTransmission;
        const res = .{
            .simpleErrors = try RefCounterSlice(u8).fromSlice(buf[0..until], alloc),
        };
        const end = 1 + until + END_LINE.len;

        return .{ res, end };
    }

    fn parseBulkString(buf: []const u8, alloc: std.mem.Allocator) anyerror!InnerRespParseReturn {
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
        const str = try RefCounterSlice(u8).fromSlice(buf[offset..][0..size], alloc);
        return .{ .{ .bulkStrings = str }, end };
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
                try buffer.appendSlice(v.value);
                try buffer.appendSlice(END_LINE);
            },
            .simpleErrors => |v| {
                try buffer.append('-');
                try buffer.appendSlice(v.value);
                try buffer.appendSlice(END_LINE);
            },
            .bulkStrings => |v| {
                try buffer.append('$');
                const size = getIntLenUsize(v.value.len);
                const b = try buffer.addManyAsSlice(size);
                _ = std.fmt.formatIntBuf(b, v.value.len, 10, std.fmt.Case.lower, .{});
                try buffer.appendSlice(END_LINE);
                try buffer.appendSlice(v.value);
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
            .nullString => {
                try buffer.appendSlice("$-1\r\n"[0..]);
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

pub fn RefCounterSlice(comptime V: type) type {
    // poor mans reference counting for a slice
    return struct {
        const Self = @This();

        /// Care must be taken to avoid data races when interacting with this field directly.
        value: []V,
        /// Don't interact with any of these
        counter: *usize,
        mutex: *std.Thread.Mutex,
        alloc: std.mem.Allocator,

        const LOWER: usize = 0;

        pub fn init(size: usize, alloc: std.mem.Allocator) anyerror!Self {
            // init and zero everything
            const value = try alloc.alloc(V, size);
            for (value) |*v| {
                v.* = std.mem.zeroes(V);
            }

            const counter = try alloc.create(usize);
            const mutex = try alloc.create(std.Thread.Mutex);
            counter.* = 1;
            mutex.* = .{};
            return .{ .value = value, .counter = counter, .alloc = alloc, .mutex = mutex };
        }

        pub fn fromSlice(slice: []const V, alloc: std.mem.Allocator) anyerror!Self {
            const s = try Self.init(slice.len, alloc);
            std.mem.copyForwards(V, s.value, slice);
            return s;
        }

        pub fn clone(self: *const Self) Self {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.counter.* += 1;
            return self.*;
        }

        pub fn deinit(self: *const Self) void {
            self.mutex.lock();
            self.counter.* -= 1;

            if (self.counter.* > Self.LOWER) {
                self.mutex.unlock();
                return;
            }

            self.mutex.unlock();
            self.alloc.free(self.value);
            self.alloc.destroy(self.counter);
            self.alloc.destroy(self.mutex);
        }
    };
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

    const pong = RespValue{ .simpleStrings = try RefCounterSlice(u8).fromSlice("PONG", tallocator) };
    defer pong.deinit();

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try pong.write(&buffer);

    try expectEqual(buffer.items.len, expected.len);
    try expectEqualSlices(u8, buffer.items, expected);
}

test "writeSimpleErrors" {
    const expected = "-Unable to Process\r\n";

    const pong = RespValue{ .simpleErrors = try RefCounterSlice(u8).fromSlice("Unable to Process", tallocator) };
    defer pong.deinit();
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
    defer res[0].deinit();

    try expectEqual(res[1], input.len);
    switch (res[0]) {
        .simpleStrings => |v| {
            try expectEqualSlices(u8, exp, v.value);
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
    defer res[0].deinit();

    try expectEqual(res[1], input.len);
    switch (res[0]) {
        .simpleErrors => |v| {
            try expectEqualSlices(u8, exp, v.value);
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
    defer res[0].deinit();

    try expectEqual(res[1], input.len);
    switch (res[0]) {
        .bulkStrings => |v| {
            try expectEqualSlices(u8, exp, v.value);
        },
        else => {
            @panic("invalid type");
        },
    }
}

test "write bulk strings" {
    const expected = "$4\r\nPING\r\n";

    const pong = RespValue{ .bulkStrings = try RefCounterSlice(u8).fromSlice("PING", tallocator) };
    defer pong.deinit();

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
    defer res[0].deinit();

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
    defer res[0].deinit();

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
    defer pong.deinit();

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

    var res = try RespValue.parse(buffer.items, tallocator);
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

    var res = try RespValue.parse(buffer.items, tallocator);
    defer res[0].deinit();

    try expectEqual(input.len, res[1]);
    switch (res[0]) {
        .array => |vals| {
            try expectEqual(exp.len, vals.items.len);
            const arr = vals.items;
            for (arr, 0..) |v, i| {
                switch (v) {
                    .bulkStrings => |inner| {
                        try expectEqualSlices(u8, exp[i], inner.value);
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

    var res = try RespValue.parse(buffer.items, tallocator);
    defer res[0].deinit();

    try expectEqual(input.len, res[1]);
    switch (res[0]) {
        .array => |vals| {
            try expectEqual(exp.len, vals.items.len);
            const arr = vals.items;
            for (arr, exp[0..]) |g, e| {
                switch (g) {
                    .bulkStrings => |inner| {
                        try expectEqualSlices(u8, e[0..], inner.value);
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

    var res = try RespValue.parse(buffer.items, tallocator);
    defer res[0].deinit();

    try expectEqual(input.len, res[1]);
    switch (res[0]) {
        .array => |vals| {
            try expectEqual(exp.len + 1, vals.items.len);
            const arr = vals.items;
            for (arr[0..2], exp[0..2]) |g, e| {
                switch (g) {
                    .bulkStrings => |inner| {
                        try expectEqualSlices(u8, e[0..], inner.value);
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

test "ref counter" {
    var ref = try RefCounterSlice(u8).init(1, tallocator);
    ref.value[0] = 5;

    try expectEqual(ref.counter.*, 1);
    try expectEqual(ref.value[0], 5);
    var vClone = ref.clone();
    try expectEqual(vClone.value[0], 5);
    vClone.value[0] = 6;
    try expectEqual(ref.value[0], 6);

    try expectEqual(ref.counter.*, 2);
    try expectEqual(vClone.counter.*, 2);

    ref.deinit();
    try expectEqual(ref.counter.*, 1);

    vClone.deinit();
}
