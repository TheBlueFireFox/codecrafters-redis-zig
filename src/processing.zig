const std = @import("std");
const request = @import("request.zig");
const resp = @import("resp.zig");

pub fn process(req: *const request.Commands, _: std.mem.Allocator) anyerror!resp.RespValue {
    switch (req.*) {
        .ping => |v| {
            return ping(v);
        },
        .echo => |v| {
            return echo(v);
        },
    }
}

fn ping(payload: ?*const resp.RespValue) resp.RespValue {
    if (payload) |p| {
        return p.*;
    }

    return resp.RespValue{ .simpleStrings = "PONG" };
}

fn echo(payload: *const resp.RespValue) resp.RespValue {
    return payload.*;
}
