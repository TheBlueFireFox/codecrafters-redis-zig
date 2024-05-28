const std = @import("std");
const resp = @import("resp.zig");

pub const CommandType = enum {
    ping,
};

pub const FnPtr = fn ([]const resp.Value, []const resp.RespValue, std.mem.Allocator) anyerror!Commands;

pub const CommandError = error{
    NotSupported,
};

pub const Commands = union(CommandType) {
    ping: ?*const resp.RespValue,

    pub fn parse(paramsValueRaw: []const resp.Value, paramsRespRaw: []const resp.RespValue, alloc: std.mem.Allocator) anyerror!Commands {
        // * 1\r\n$4\r\nping\r\n
        const map = std.ComptimeStringMap(*const FnPtr, .{
            .{ "PING", &Commands.parsePing },
        });

        const com = paramsValueRaw[0];

        const paramsValue = paramsValueRaw[1..];
        const paramsResp = paramsRespRaw[1..];

        switch (com) {
            .string => |vRaw| {
                // COPY: because of const nature
                // upper case so that we can compare it with the map

                const v = try alloc.alloc(u8, vRaw.len);
                defer alloc.free(v);
                std.mem.copyForwards(u8, v, vRaw);
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

    fn parsePing(_: []const resp.Value, _: []const resp.RespValue, _: std.mem.Allocator) anyerror!Commands {
        // TODO: process PING / PONG values correctly
        return Commands{ .ping = null };
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
