const std = @import("std");
const resp = @import("resp.zig");

pub const DataMap = struct {
    const Self = @This();
    const HM = std.HashMap(resp.RespValue, resp.RespValue, resp.RespValueContex, std.hash_map.default_max_load_percentage);

    mutex: std.Thread.Mutex,
    db: HM,

    pub fn init(allocator: std.mem.Allocator) Self {
        const mutex = std.Thread.Mutex{};
        const db = HM.init(allocator);
        return .{ .mutex = mutex, .db = db };
    }

    pub fn deinit(self: *Self) void {
        self.db.deinit();
    }

    pub fn set(self: *Self, key: resp.RespValue, value: resp.RespValue) anyerror!?resp.RespValue {
        self.mutex.lock();
        defer self.mutex.unlock();

        const old = try self.db.fetchPut(key, value);
        if (old) |o| return o.value;
        return null;
    }

    pub fn get(self: *Self, key: *const resp.RespValue) anyerror!?resp.RespValue {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.db.get(key.*)) |val| return try val.clone();
        return null;
    }
};
