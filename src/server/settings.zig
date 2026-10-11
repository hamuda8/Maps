//! Service settings managed from Control (settings collection, _id "platform"): rate limits, the
//! tile server, and whether demo keys work. Re-read every 15 seconds; the env file gives the
//! defaults. Never fails: the last good value (or the defaults) is used when the database is
//! unreachable.

const std = @import("std");
const mongo = @import("mongo");
const a_ = @import("app.zig");

pub const Settings = struct {
    search_per_minute: u32 = 120,
    route_per_minute: u32 = 120,
    tile_url: []const u8,
    tile_attribution: []const u8,
    demo_keys: bool = true,
};

const ttl_ms = 15_000;

var lock: std.Io.Mutex = .init;
var current: ?Settings = null;
var fetched_ms: i64 = 0;
/// Holds the strings of `current`; replaced on every refresh.
var strings: ?std.heap.ArenaAllocator = null;

/// The current settings, with the strings copied into `arena` (the request's) while the lock is
/// held, because a later refresh frees the previous ones.
pub fn get(arena: std.mem.Allocator) Settings {
    const app = a_.app;
    lock.lockUncancelable(app.io);
    defer lock.unlock(app.io);
    const now = a_.nowMs();
    if (current == null or now - fetched_ms >= ttl_ms) refresh(now);
    var s = current.?;
    s.tile_url = arena.dupe(u8, s.tile_url) catch app.config.tile_url;
    s.tile_attribution = arena.dupe(u8, s.tile_attribution) catch app.config.tile_attribution;
    return s;
}

/// Called with the lock held.
fn refresh(now: i64) void {
    const app = a_.app;
    fetched_ms = now;
    const defaults: Settings = .{ .tile_url = app.config.tile_url, .tile_attribution = app.config.tile_attribution };
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    const doc = app.collection("settings").findOne(arena.allocator(), .{ ._id = "platform" }, .{}) catch {
        arena.deinit();
        if (current == null) current = defaults;
        return;
    };
    var s = defaults;
    if (doc) |d| {
        if (positive(d.getPath("limits.searchPerMinute"))) |v| s.search_per_minute = v;
        if (positive(d.getPath("limits.routePerMinute"))) |v| s.route_per_minute = v;
        if (nonEmpty(d.getPath("tiles.url"))) |v| s.tile_url = v;
        if (nonEmpty(d.getPath("tiles.attribution"))) |v| s.tile_attribution = v;
        if (d.get("demoKeys")) |v| if (v == .boolean) {
            s.demo_keys = v.boolean;
        };
    }
    if (strings) |*old| old.deinit();
    strings = arena;
    current = s;
}

fn positive(v: ?mongo.bson.Value) ?u32 {
    const n = (v orelse return null).asInt() orelse return null;
    return if (n > 0 and n <= std.math.maxInt(u32)) @intCast(n) else null;
}

fn nonEmpty(v: ?mongo.bson.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| if (std.mem.trim(u8, s, " \t").len > 0) std.mem.trim(u8, s, " \t") else null,
        else => null,
    };
}
