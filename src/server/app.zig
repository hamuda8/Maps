//! Shared state of the Maps server and small helpers every module uses. Configuration comes from
//! the same environment variables (and .env file) as Maps-js, so either server can run on the
//! same machine without changes.

const std = @import("std");
const Io = std.Io;
const mongo = @import("mongo");
const env_mod = @import("env");
const bson = mongo.bson;

pub const Config = struct {
    port: u16,
    listen: []const u8,
    mongo_uri: []const u8,
    /// Database name; MONGO_DB overrides the one in the URI (the tests use their own).
    db_name: []const u8,
    tile_url: []const u8,
    tile_attribution: []const u8,
    tile_cache_dir: []const u8,
    tile_proxy: bool,
    valhalla_url: []const u8,
    valhalla_api_key: []const u8,
    photon_url: []const u8,
    auth_host: []const u8,
    public_url: ?[]const u8,
    trust_proxy: bool,
    /// Static files of the web pages (Maps-js `public/` until the zui pages replace them).
    public_dir: []const u8,
    /// How often counted key usage is written (tests shorten it).
    usage_flush_s: u32,

    pub fn load(e: *const env_mod.Env) Config {
        return .{
            .port = e.int(u16, "PORT", 5005),
            .listen = e.str("LISTEN", "0.0.0.0"),
            .mongo_uri = e.str("MONGO_URI", "mongodb://127.0.0.1:27017/Maps"),
            .db_name = e.str("MONGO_DB", "Maps"),
            .tile_url = e.str("MAPS_TILE_URL", "https://tile.openstreetmap.org/{z}/{x}/{y}.png"),
            .tile_attribution = e.str("MAPS_TILE_ATTRIBUTION", "&copy; <a href=\"https://www.openstreetmap.org/copyright\" target=\"_blank\" rel=\"noopener\">OpenStreetMap</a> contributors"),
            .tile_cache_dir = e.str("TILE_CACHE_DIR", "cache/tiles"),
            .tile_proxy = e.flag("MAPS_TILE_PROXY", true),
            .valhalla_url = e.str("VALHALLA_URL", "http://127.0.0.1:8002/route"),
            .valhalla_api_key = e.str("VALHALLA_API_KEY", ""),
            .photon_url = std.mem.trimEnd(u8, e.str("PHOTON_URL", "https://photon.komoot.io"), "/"),
            .auth_host = e.str("AUTH_HOST", "http://localhost:4000"),
            .public_url = if (e.get("MAPS_PUBLIC_URL")) |v| (if (v.len > 0) std.mem.trimEnd(u8, v, "/") else null) else null,
            .trust_proxy = e.flag("TRUST_PROXY", false),
            .public_dir = e.str("MAPS_PUBLIC_DIR", "public"),
            .usage_flush_s = e.int(u32, "MAPS_USAGE_FLUSH_S", 60),
        };
    }
};

pub const App = struct {
    io: Io,
    gpa: std.mem.Allocator,
    config: Config,
    db: *mongo.Client,
    /// Outgoing requests: Valhalla, Photon, tile server, Wufour sign-in.
    client: std.http.Client,
    client_lock: Io.Mutex = .init,
    started_ms: i64,

    pub fn collection(a: *App, name: []const u8) mongo.Collection {
        return a.db.database(a.config.db_name).collection(name);
    }
};

/// The one instance; set in main before serving.
pub var app: *App = undefined;

pub fn nowMs() i64 {
    return Io.Timestamp.now(app.io, .real).toMilliseconds();
}

pub fn now() bson.DateTime {
    return .{ .ms = nowMs() };
}

/// "2026-10-11" (UTC), the day key of the usage collection.
pub fn today(buf: *[10]u8) []const u8 {
    return dayOf(buf, nowMs());
}

pub fn dayOf(buf: *[10]u8, ms: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(ms, 1000)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 }) catch unreachable;
}

/// `n` random bytes as lowercase hex.
pub fn randomHex(arena: std.mem.Allocator, comptime n: usize) ![]const u8 {
    var bytes: [n]u8 = undefined;
    app.io.random(&bytes);
    return arena.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
}

pub const Upstream = struct {
    status: std.http.Status,
    content_type: []const u8,
    body: []const u8,
};

/// GET (or POST with a JSON body) to another service. Errors when it cannot be reached.
pub fn upstream(arena: std.mem.Allocator, method: std.http.Method, url: []const u8, json_body: ?[]const u8, headers: []const std.http.Header) !Upstream {
    var req = try app.client.request(method, try std.Uri.parse(url), .{
        .extra_headers = headers,
        .redirect_behavior = .unhandled,
        .keep_alive = true,
        // Bodies are passed on or parsed as they are, so ask for them uncompressed.
        .headers = .{ .accept_encoding = .omit },
    });
    defer req.deinit();
    if (json_body) |b| {
        req.transfer_encoding = .{ .content_length = b.len };
        req.headers.content_type = .{ .override = "application/json" };
        var w = try req.sendBodyUnflushed(&.{});
        try w.writer.writeAll(b);
        try w.end();
        try req.connection.?.flush();
    } else try req.sendBodiless();
    var res = try req.receiveHead(&.{});
    const content_type = try arena.dupe(u8, res.head.content_type orelse "");
    const status = res.head.status;
    var transfer: [64]u8 = undefined;
    const body = try res.reader(&transfer).allocRemaining(arena, .limited(16 << 20));
    return .{ .status = status, .content_type = content_type, .body = body };
}

/// `{"success": false, "message": ...}`, the error shape of every Maps endpoint.
pub fn fail(ctx: anytype, status: std.http.Status, message: []const u8) !void {
    return ctx.sendJson(status, .{ .success = false, .message = message });
}

/// Per-IP request budget per minute (search, routing from the map page).
pub const RateLimiter = struct {
    lock: Io.Mutex = .init,
    hits: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct { count: u32, reset_ms: i64 };

    pub fn allow(r: *RateLimiter, ip: []const u8, per_minute: u32) bool {
        r.lock.lockUncancelable(app.io);
        defer r.lock.unlock(app.io);
        const t = nowMs();
        if (r.hits.getPtr(ip)) |e| {
            if (e.reset_ms >= t) {
                e.count += 1;
                return e.count <= per_minute;
            }
            e.* = .{ .count = 1, .reset_ms = t + 60_000 };
            return true;
        }
        if (r.hits.count() > 10_000) r.clear();
        const key = app.gpa.dupe(u8, ip) catch return true;
        r.hits.put(app.gpa, key, .{ .count = 1, .reset_ms = t + 60_000 }) catch app.gpa.free(key);
        return true;
    }

    fn clear(r: *RateLimiter) void {
        var it = r.hits.keyIterator();
        while (it.next()) |k| app.gpa.free(k.*);
        r.hits.clearRetainingCapacity();
    }
};

test dayOf {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("2026-10-11", dayOf(&buf, 1_791_720_000_000));
}
