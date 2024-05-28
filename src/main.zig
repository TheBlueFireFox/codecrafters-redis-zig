const std = @import("std");

const net = std.net;

const resp = @import("resp.zig");
const req = @import("request.zig");
const processing = @import("processing.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const allocator = std.heap.page_allocator;

    // You can use print statements as follows for debugging, they'll be visible when running tests.
    try stdout.print("Logs from your program will appear here!\n", .{});

    // Uncomment this block to pass the first stage

    const address = try net.Address.resolveIp("127.0.0.1", 6379);

    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    while (true) {
        const connection = try listener.accept();
        defer connection.stream.close();
        try processConnection(connection, allocator);
    }
}

fn processConnection(conn: net.Server.Connection, alloc: std.mem.Allocator) anyerror!void {
    const stdout = std.io.getStdOut().writer();

    // setup buffers (no reuse for now)
    var connectionBuffer = try std.ArrayList(u8).initCapacity(alloc, 1024);
    defer connectionBuffer.deinit();

    var resultBuffer = try std.ArrayList(u8).initCapacity(alloc, 1024);
    defer resultBuffer.deinit();

    // load data from stream
    var reader = conn.stream.reader();

    try stdout.print("accepted new connection\n", .{});

    while (true) {
        connectionBuffer.clearRetainingCapacity();
        resultBuffer.clearRetainingCapacity();
        // read connection
        // to check for stream end => read all bytes

        var innerBuffer = std.mem.zeroes([1024]u8);
        const loaded = try reader.read(&innerBuffer);

        // write back to main buffer
        try connectionBuffer.appendSlice(innerBuffer[0..loaded]);

        _ = process(connectionBuffer.items, &resultBuffer, alloc) catch |err| {
            if (err != resp.ParsingError.NotCompletedTransmission) return err;
            // we need to loop and process everything now
            continue;
        };

        try conn.stream.writeAll(resultBuffer.items);
    }
}

fn process(buf: []const u8, outBuf: *std.ArrayList(u8), alloc: std.mem.Allocator) anyerror!usize {
    // struct { std.ArrayList(Value), std.ArrayList(RespValue), usize }
    const val = resp.Value.parse(buf, alloc) catch |err| {
        return try errorHandler(outBuf, err);
    };

    defer val[0].deinit();
    defer val[1].deinit();

    const fVal = try fixValue(&val[0], alloc);
    defer fVal.deinit();

    const fRVal = try fixRValue(&val[1], alloc);
    defer fRVal.deinit();

    const request = req.Commands.parse(fVal.arr.items, fRVal.arr.items, alloc) catch |err| {
        return try errorHandler(outBuf, err);
    };

    // process command
    const result = processing.process(&request, alloc) catch |err| {
        return try errorHandler(outBuf, err);
    };

    try result.write(outBuf);

    return outBuf.items.len;
}

fn Fix(comptime T: type) type {
    return struct {
        const Self = @This();

        clean: bool,
        arr: std.ArrayList(T),

        pub fn init(clean: bool, arr: std.ArrayList(T)) Self {
            return .{
                .clean = clean,
                .arr = arr,
            };
        }

        pub fn deinit(self: Self) void {
            if (self.clean)
                self.arr.deinit();
        }
    };
}

fn fixValue(vals: *const resp.Value, alloc: std.mem.Allocator) anyerror!Fix(resp.Value) {
    var arr = std.ArrayList(resp.Value).init(alloc);
    const fix = Fix(resp.Value);
    switch (vals.*) {
        .array => |v| {
            return fix.init(false, v);
        },
        else => |_| {
            try arr.append(vals.*);
            return fix.init(true, arr);
        },
    }
}

fn fixRValue(vals: *const resp.RespValue, alloc: std.mem.Allocator) anyerror!Fix(resp.RespValue) {
    var arr = std.ArrayList(resp.RespValue).init(alloc);
    const fix = Fix(resp.RespValue);
    switch (vals.*) {
        .array => |v| {
            return fix.init(false, v);
        },
        else => |_| {
            try arr.append(vals.*);
            return fix.init(true, arr);
        },
    }
}

fn errorHandler(out_buf: *std.ArrayList(u8), err: anyerror) anyerror!usize {
    if (err == resp.ParsingError.NotSupported) {
        var e = resp.RespValue{ .simpleErrors = "Not Supported Type during inital Text Parsing" };
        try e.write(out_buf);
        return out_buf.items.len;
    } else if (err == req.CommandError.NotSupported) {
        var e = resp.RespValue{ .simpleErrors = "Not Supported Type during request Command Parsing" };
        try e.write(out_buf);
        return out_buf.items.len;
    } else if (err == resp.ParsingError.InvalidFormat) {
        var e = resp.RespValue{ .simpleErrors = "Invalid Format" };
        try e.write(out_buf);
        return out_buf.items.len;
    }
    return err;
}

// hack so that all tests are run
test {
    _ = resp;
    _ = req;
    _ = processing;
}
const talloc = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "test full ping simple string" {
    const input = "+PING\r\n";
    const expect = "+PONG\r\n";
    var outBuf = std.ArrayList(u8).init(talloc);
    defer outBuf.deinit();

    const resultSize = try process(input[0..], &outBuf, talloc);
    try expectEqual(resultSize, expect.len);
    try expectEqualSlices(u8, expect, outBuf.items);
}

test "test full ping bulk string" {
    const input = "$4\r\nPING\r\n";
    const expect = "+PONG\r\n";
    var outBuf = std.ArrayList(u8).init(talloc);
    defer outBuf.deinit();

    const resultSize = try process(input[0..], &outBuf, talloc);
    try expectEqual(resultSize, expect.len);
    try expectEqualSlices(u8, expect, outBuf.items);
}
