const std = @import("std");

const net = std.net;

const resp = @import("resp.zig");
const req = @import("request.zig");
const processing = @import("processing.zig");
const db = @import("db.zig");

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

    var dmap = db.DataMap.init(allocator);
    defer dmap.deinit();

    var threads = [_]std.Thread{};
    var pool = std.Thread.Pool{ .allocator = allocator, .threads = &threads };
    try pool.init(.{ .allocator = allocator, .n_jobs = 8 });
    defer pool.deinit();

    while (true) {
        const connection = try listener.accept();

        // SAFETY: this ptr is safe at it will live for as long as the program does
        try pool.spawn(processConnection, .{ConnectionOptions{ .conn = connection, .alloc = allocator, .db = &dmap }});
    }
}

const ConnectionOptions = struct { conn: net.Server.Connection, alloc: std.mem.Allocator, db: *db.DataMap };

fn processConnection(co: ConnectionOptions) void {
    innerProcessConnection(co) catch {
        // we cannot do anything about the error anymore
        @panic("An error happend");
    };
}
fn innerProcessConnection(co: ConnectionOptions) anyerror!void {
    const conn = co.conn;
    const alloc = co.alloc;
    const database = co.db;

    defer conn.stream.close();
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

        _ = process(connectionBuffer.items, &resultBuffer, alloc, database) catch |err| {
            if (err != resp.ParsingError.NotCompletedTransmission) return err;
            // we need to loop and process everything now
            continue;
        };

        try conn.stream.writeAll(resultBuffer.items);
    }
}

fn process(buf: []const u8, outBuf: *std.ArrayList(u8), alloc: std.mem.Allocator, database: *db.DataMap) anyerror!usize {
    // struct { std.ArrayList(Value), std.ArrayList(RespValue), usize }
    var val = resp.Value.parse(buf, alloc) catch |err| {
        return try errorHandler(outBuf, err, alloc);
    };

    defer val[0].deinit();
    defer val[1].deinit();

    const fVal = try fixValue(&val[0], alloc);
    defer fVal.deinit();

    const fRVal = try fixRValue(&val[1], alloc);
    defer fRVal.deinit();

    const request = req.Commands.parse(fVal.arr.items, fRVal.arr.items, alloc) catch |err| {
        return try errorHandler(outBuf, err, alloc);
    };

    // process command
    const result = processing.process(request, alloc, database) catch |err| {
        return try errorHandler(outBuf, err, alloc);
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

fn errorHandler(outBuf: *std.ArrayList(u8), err: anyerror, alloc: std.mem.Allocator) anyerror!usize {
    if (err == resp.ParsingError.NotSupported) {
        return errorHandlerHelper("Not Supported Type during inital Text Parsing", outBuf, alloc);
    } else if (err == req.CommandError.NotSupported) {
        return errorHandlerHelper("Not Supported Type during request Command Parsing", outBuf, alloc);
    } else if (err == resp.ParsingError.InvalidFormat) {
        return errorHandlerHelper("Invalid Format", outBuf, alloc);
    } else if (err == req.CommandError.InvalidFormat) {
        return errorHandlerHelper("Invalid Format", outBuf, alloc);
    }
    return err;
}

fn errorHandlerHelper(str: []const u8, outBuf: *std.ArrayList(u8), alloc: std.mem.Allocator) anyerror!usize {
    var e = resp.RespValue{ .simpleErrors = try resp.RefCounterSlice(u8).fromSlice(str, alloc) };
    defer e.deinit();
    try e.write(outBuf);
    return outBuf.items.len;
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
    var database = db.DataMap.init(talloc);
    defer database.deinit();

    const resultSize = try process(input[0..], &outBuf, talloc, &database);
    try expectEqual(resultSize, expect.len);
    try expectEqualSlices(u8, expect, outBuf.items);
}

test "test full ping bulk string" {
    const input = "$4\r\nPING\r\n";
    const expect = "+PONG\r\n";
    var outBuf = std.ArrayList(u8).init(talloc);
    defer outBuf.deinit();
    var database = db.DataMap.init(talloc);
    defer database.deinit();

    const resultSize = try process(input[0..], &outBuf, talloc, &database);
    try expectEqual(resultSize, expect.len);
    try expectEqualSlices(u8, expect, outBuf.items);
}
