const std = @import("std");
const resp = @import("resp.zig");

pub const CommandType = enum {
    ping,
    echo,
    get,
    set,
};

pub const FnPtr = fn ([]const resp.Value, []const resp.RespValue, std.mem.Allocator) anyerror!Commands;

pub const CommandError = error{ NotSupported, InvalidFormat };

pub const SetCommand = struct {
    key: resp.RespValue,
    value: resp.RespValue,
    lives: ?i64,
};

pub const Commands = union(CommandType) {
    ping: ?resp.RespValue,
    echo: resp.RespValue,
    get: resp.RespValue,
    set: SetCommand,

    pub fn parse(paramsValueRaw: []const resp.Value, paramsRespRaw: []const resp.RespValue, alloc: std.mem.Allocator) anyerror!Commands {
        // * 1\r\n$4\r\nping\r\n
        const map = std.ComptimeStringMap(*const FnPtr, .{
            .{ "PING", &Commands.parsePing },
            .{ "ECHO", &Commands.parseEcho },
            .{ "GET", &Commands.parseGet },
            .{ "SET", &Commands.parseSet },
        });

        const com = paramsValueRaw[0];

        const paramsValue = paramsValueRaw[1..];
        const paramsResp = paramsRespRaw[1..];

        switch (com) {
            .string => |vRaw| {
                // COPY: because of otherwise a unwanted mutation occures
                // upper case so that we can compare it with the map

                const v = try alloc.alloc(u8, vRaw.value.len);
                defer alloc.free(v);
                std.mem.copyForwards(u8, v, vRaw.value);
                toUpper(v);

                const fnPtr = map.get(v) orelse return CommandError.NotSupported;
                const res = try fnPtr(paramsValue, paramsResp, alloc);

                return res;
            },
            else => {
                return CommandError.NotSupported;
            },
        }
    }

    fn parsePing(_: []const resp.Value, r: []const resp.RespValue, _: std.mem.Allocator) anyerror!Commands {
        if (r.len == 0) return Commands{ .ping = null };
        return Commands{ .ping = try r[0].clone() };
    }

    fn parseEcho(_: []const resp.Value, r: []const resp.RespValue, _: std.mem.Allocator) anyerror!Commands {
        if (r.len == 0) return CommandError.InvalidFormat;
        return Commands{ .ping = try r[0].clone() };
    }

    fn parseSet(valsParsed: []const resp.Value, vals: []const resp.RespValue, alloc: std.mem.Allocator) anyerror!Commands {
        if (vals.len < 2) return CommandError.InvalidFormat;
        var res = SetCommand{ .key = try vals[0].clone(), .value = try vals[1].clone(), .lives = null };
        if (vals.len == 2) {
            return .{ .set = res };
        }
        var comRaw: []u8 = &[0]u8{};
        switch (valsParsed[2]) {
            .string => |v| {
                comRaw = v.value;
            },
            else => {
                return CommandError.InvalidFormat;
            },
        }
        var livesFor: i64 = 0;
        switch (valsParsed[3]) {
            .int => |v| {
                livesFor = v;
            },
            .string => |v| {
                const val = std.fmt.parseInt(i64, v.value, 10) catch {
                    return CommandError.InvalidFormat;
                };
                livesFor = val;
            },
            else => {
                return CommandError.InvalidFormat;
            },
        }

        // COPY: to make my life easier
        const com = try alloc.alloc(u8, comRaw.len);
        defer alloc.free(com);
        std.mem.copyForwards(u8, com, comRaw);
        toUpper(com);

        if (std.mem.eql(u8, com, "EX")) {
            // from seconds to milliseconds
            livesFor *= 1000;
        } else if (!std.mem.eql(u8, com, "PX")) {
            // not supported
            return CommandError.NotSupported;
        }
        res.lives = livesFor;

        return .{ .set = res };
    }

    fn parseGet(_: []const resp.Value, vals: []const resp.RespValue, _: std.mem.Allocator) anyerror!Commands {
        if (vals.len < 1) return CommandError.InvalidFormat;
        return .{ .get = try vals[0].clone() };
    }
};

fn toUpper(buf: []u8) void {
    for (buf) |*val| {
        const v = val.*;
        if (v >= 'a' and v <= 'z') {
            val.* = v - 'a' + 'A';
        }
    }
}

const tallocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "to upper simple" {
    const exp = "ABC";
    const input = "abc";

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try buffer.appendSlice(input);

    toUpper(buffer.items);

    try expectEqualSlices(u8, buffer.items, exp);
}

test "to upper complex" {
    const exp = "!ABüC12";
    const input = "!abüc12";

    var buffer = std.ArrayList(u8).init(tallocator);
    defer buffer.deinit();
    try buffer.appendSlice(input);

    toUpper(buffer.items);

    try expectEqualSlices(u8, buffer.items, exp);
}
