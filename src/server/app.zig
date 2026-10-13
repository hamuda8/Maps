//! Shared state of the Maps server and small helpers every module uses. Configuration comes from
//! the same environment variables (and .env file) as Maps-js, so either server can run on the
//! same machine without changes.

const std = @import("std");
const Io = std.Io;
const mongo = @import("mongo");
const env_mod = @import("env");
const geo = @import("geo");
const fetch_mod = @import("fetch");
const wufour_mod = @import("wufour");
const http = @import("http");
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
    /// Folder of .osm.pbf files, one per region (country, continent or planet): search and
    /// reverse geocoding come from these.
    regions_dir: []const u8,
    /// A Photon-compatible geocoder for places no region covers. For development only: empty
    /// (off) unless set.
    geocoder_fallback: []const u8,
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
            .regions_dir = e.str("REGIONS_DIR", "regions"),
            .geocoder_fallback = std.mem.trimEnd(u8, e.str("GEOCODER_FALLBACK_URL", ""), "/"),
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
    fetch: fetch_mod.Client,
    wufour: wufour_mod.Verifier,
    regions: *geo.Regions,
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

/// GET (or POST with a JSON body) to another service, through zig-core's fetch: a time limit,
/// and a failed request's connection is never reused. (std.http.Client alone put a connection
/// whose send failed back in its pool and handed it out again for every later request to that
/// host: after the tile server reset an idle connection, every new tile answered 502 at once
/// until a restart.) Errors when the service cannot be reached.
pub fn upstream(arena: std.mem.Allocator, method: std.http.Method, url: []const u8, json_body: ?[]const u8, headers: []const std.http.Header) !Upstream {
    const res = try app.fetch.fetch(arena, url, .{
        .method = method,
        .headers = headers,
        .body = json_body,
        .content_type = if (json_body != null) "application/json" else null,
        .timeout_ms = 20_000,
    });
    return .{ .status = @fromBackingInt(@as(u10, @intCast(res.status))), .content_type = res.content_type, .body = res.body };
}

/// `{"success": false, "message": ...}`, the error shape of every Maps endpoint.
pub fn fail(ctx: anytype, status: std.http.Status, message: []const u8) !void {
    return ctx.sendJson(status, .{ .success = false, .message = message });
}

/// Per-IP request budget per minute (search, routing from the map page).
pub const RateLimiter = struct {
    inner: http.RateLimiter = .{ .max_keys = 10_000 },

    pub fn allow(r: *RateLimiter, ip: []const u8, per_minute: u32) bool {
        return r.inner.allow(app.io, app.gpa, ip, per_minute, 60_000, nowMs());
    }
};

test dayOf {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("2026-10-11", dayOf(&buf, 1_791_720_000_000));
}
