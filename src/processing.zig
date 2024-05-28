const std = @import("std");
const request = @import("request.zig");
const resp = @import("resp.zig");
const db = @import("db.zig");

pub fn process(req: request.Commands, alloc: std.mem.Allocator, database: *db.DataMap) anyerror!resp.RespValue {
    switch (req) {
        .ping => |v| {
            return ping(v, alloc);
        },
        .echo => |v| {
            return echo(v);
        },
        .set => |v| {
            return set(v, database, alloc);
        },
        .get => |v| {
            return get(v, database, alloc);
        },
    }
}

fn ping(payload: ?resp.RespValue, alloc: std.mem.Allocator) anyerror!resp.RespValue {
    if (payload) |p| {
        return p.clone();
    }

    return resp.RespValue{ .simpleStrings = try resp.RefCounterSlice(u8).fromSlice("PONG", alloc) };
}

fn echo(payload: resp.RespValue) anyerror!resp.RespValue {
    return payload.clone();
}

fn get(key: resp.RespValue, database: *db.DataMap, alloc: std.mem.Allocator) anyerror!resp.RespValue {
    const value = try database.get(&key);
    return value orelse return errorHandler("missing key", alloc);
}

fn set(com: request.SetCommand, database: *db.DataMap, alloc: std.mem.Allocator) anyerror!resp.RespValue {
    const value = try database.set(com.key, com.value);
    if (value) |old| old.deinit();
    return resp.RespValue{ .simpleStrings = try refFromSlice("OK", alloc) };
}

fn errorHandler(str: []const u8, alloc: std.mem.Allocator) anyerror!resp.RespValue {
    return .{ .simpleErrors = try refFromSlice(str, alloc) };
}

fn refFromSlice(str: []const u8, alloc: std.mem.Allocator) anyerror!resp.RefCounterSlice(u8) {
    return resp.RefCounterSlice(u8).fromSlice(str, alloc);
}
