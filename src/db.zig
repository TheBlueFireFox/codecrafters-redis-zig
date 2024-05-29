const std = @import("std");
const resp = @import("resp.zig");

const ValueLayout = struct { initTime: i64, livesFor: ?i64, payload: resp.RespValue };

pub const DataMap = struct {
    const Self = @This();
    const HM = std.HashMap(resp.RespValue, ValueLayout, resp.RespValueContex, std.hash_map.default_max_load_percentage);

    mutex: std.Thread.Mutex,
    db: HM,

    fn getCurrentTime() i64 {
        return std.time.milliTimestamp();
    }

    pub fn init(allocator: std.mem.Allocator) Self {
        const mutex = std.Thread.Mutex{};
        const db = HM.init(allocator);
        return .{ .mutex = mutex, .db = db };
    }

    pub fn deinit(self: *Self) void {
        self.db.deinit();
    }

    pub fn set(self: *Self, key: resp.RespValue, value: resp.RespValue, livesFor: ?i64) anyerror!?resp.RespValue {
        self.mutex.lock();
        defer self.mutex.unlock();
        const v = .{ .initTime = Self.getCurrentTime(), .livesFor = livesFor, .payload = value };

        const old = try self.db.fetchPut(key, v);
        if (old) |o| return Self.validateData(o.value);
        return null;
    }

    fn validateData(data: ValueLayout) ?resp.RespValue {
        const currentTime = Self.getCurrentTime();
        const livesFor = data.livesFor orelse return data.payload;
        const initTime = data.initTime;

        const delta = currentTime - initTime;

        if (delta - livesFor > 0) return null;
        return data.payload;
    }

    pub fn get(self: *Self, key: *const resp.RespValue) anyerror!?resp.RespValue {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.db.get(key.*)) |val| {
            if (Self.validateData(val)) |v| return v;
            // data invalid
            self.db.fetchRemove(key.*).?.value.payload.deinit();
        }
        return null;
    }
};
