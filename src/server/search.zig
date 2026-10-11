//! Place search and reverse geocoding. For now through Photon (OpenStreetMap data), as Maps-js
//! does; the multi-region index built from .osm.pbf files replaces it later in step 3, with
//! Photon kept as the fallback for regions without local data. Cached, and rate-limited per
//! visitor unless the request carries a valid API key.

const std = @import("std");
const http = @import("http");
const a_ = @import("app.zig");
const keys = @import("keys.zig");
const settings = @import("settings.zig");

const syria_bbox = "35.5,32.3,42.4,37.4"; // west,south,east,north
const cache_ms = 10 * 60_000;
const cache_max = 1000;

var limiter: a_.RateLimiter = .{};
var cache_lock: std.Io.Mutex = .init;
/// URL → raw Photon answer (both owned by the gpa).
var cache: std.StringHashMapUnmanaged(struct { body: []const u8, until_ms: i64 }) = .empty;

fn allowed(ctx: *http.Context, endpoint: []const u8) !bool {
    if (ctx.header("x-maps-api-key")) |k| if (try keys.findActive(k, endpoint) != null) return true;
    return limiter.allow(ctx.clientIp(), settings.get(ctx.arena).search_per_minute);
}

/// Photon's answer for `url`, from the cache when fresh. The body is copied into `arena`.
fn cached(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    const app = a_.app;
    const now = a_.nowMs();
    {
        cache_lock.lockUncancelable(app.io);
        defer cache_lock.unlock(app.io);
        if (cache.get(url)) |hit| if (hit.until_ms > now) return arena.dupe(u8, hit.body);
    }
    const res = try a_.upstream(arena, .GET, url, null, &.{.{ .name = "user-agent", .value = "WufourMaps/1.0" }});
    if (@backingInt(res.status) >= 300) return error.SearchUnavailable;

    cache_lock.lockUncancelable(app.io);
    defer cache_lock.unlock(app.io);
    if (cache.count() >= cache_max) {
        var it = cache.iterator();
        while (it.next()) |e| {
            app.gpa.free(e.key_ptr.*);
            app.gpa.free(e.value_ptr.body);
        }
        cache.clearRetainingCapacity();
    }
    const gop = try cache.getOrPut(app.gpa, url);
    if (gop.found_existing) app.gpa.free(gop.value_ptr.body) else gop.key_ptr.* = try app.gpa.dupe(u8, url);
    gop.value_ptr.* = .{ .body = try app.gpa.dupe(u8, res.body), .until_ms = now + cache_ms };
    return res.body;
}

const Feature = struct {
    geometry: ?struct { coordinates: []const f64 = &.{} } = null,
    properties: struct {
        name: ?[]const u8 = null,
        street: ?[]const u8 = null,
        housenumber: ?[]const u8 = null,
        district: ?[]const u8 = null,
        locality: ?[]const u8 = null,
        suburb: ?[]const u8 = null,
        city: ?[]const u8 = null,
        town: ?[]const u8 = null,
        village: ?[]const u8 = null,
        county: ?[]const u8 = null,
        state: ?[]const u8 = null,
        countrycode: ?[]const u8 = null,
    } = .{},
};

pub const Place = struct {
    name: []const u8,
    street: ?[]const u8,
    area: ?[]const u8,
    city: ?[]const u8,
    state: ?[]const u8,
    country: ?[]const u8,
    lat: f64,
    lng: f64,
    label: []const u8,
};

fn first(vals: []const ?[]const u8) ?[]const u8 {
    for (vals) |v| if (v) |s| if (s.len > 0) return s;
    return null;
}

/// A Photon feature in Maps' place shape.
fn place(arena: std.mem.Allocator, f: Feature) !?Place {
    const g = f.geometry orelse return null;
    if (g.coordinates.len < 2) return null;
    const p = f.properties;
    const street: ?[]const u8 = if (p.street) |s| (if (p.housenumber) |h| try std.fmt.allocPrint(arena, "{s} {s}", .{ s, h }) else s) else null;
    const area = first(&.{ p.district, p.locality, p.suburb });
    const city = first(&.{ p.city, p.town, p.village, p.county });

    // name, street, district/locality, city/town/village — empty and repeated parts dropped.
    var parts: std.ArrayList([]const u8) = .empty;
    for ([_]?[]const u8{ p.name, p.street, first(&.{ p.district, p.locality }), first(&.{ p.city, p.town, p.village }) }) |part| {
        const s = part orelse continue;
        if (s.len == 0) continue;
        const dup = for (parts.items) |x| {
            if (std.mem.eql(u8, x, s)) break true;
        } else false;
        if (!dup) try parts.append(arena, s);
    }
    return .{
        .name = first(&.{ p.name, p.street, p.city }) orelse "",
        .street = street,
        .area = area,
        .city = city,
        .state = p.state,
        .country = p.countrycode,
        .lat = g.coordinates[1],
        .lng = g.coordinates[0],
        .label = try std.mem.join(arena, ", ", parts.items),
    };
}

fn num(s: ?[]const u8, min: f64, max: f64) ?f64 {
    const n = std.fmt.parseFloat(f64, s orelse return null) catch return null;
    return if (std.math.isFinite(n) and n >= min and n <= max) n else null;
}

/// GET /api/v1/search?q=...&lat=&lng=&limit=
pub fn search(ctx: *http.Context) !void {
    if (!try allowed(ctx, "search")) return a_.fail(ctx, .too_many_requests, "Too many searches, try again in a minute");
    // Same text, same answer: case and extra spaces do not make a new cache entry.
    var words: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, ctx.queryParam("q") orelse "", " \t\r\n");
    while (it.next()) |w| {
        if (words.items.len > 0) try words.append(ctx.arena, ' ');
        for (w) |c| try words.append(ctx.arena, std.ascii.toLower(c));
    }
    const q = words.items[0..@min(words.items.len, 100)];
    if (q.len < 2) return ctx.sendJson(.ok, .{ .success = true, .results = &[_]Place{} });
    const limit: u32 = if (num(ctx.queryParam("limit"), 1, 10)) |n| @intFromFloat(@floor(n)) else 6;

    var url: std.ArrayList(u8) = .empty;
    try url.print(ctx.arena, "{s}/api/?q={s}&limit={d}&bbox={s}", .{ a_.app.config.photon_url, try http.encode(ctx.arena, q), limit, syria_bbox });
    // The map centre only biases the ranking: rounded to about a kilometre, so panning reuses
    // cached answers.
    if (num(ctx.queryParam("lat"), -90, 90)) |lat| if (num(ctx.queryParam("lng"), -180, 180)) |lng|
        try url.print(ctx.arena, "&lat={d:.2}&lon={d:.2}", .{ lat, lng });

    const body = cached(ctx.arena, url.items) catch return a_.fail(ctx, .bad_gateway, "Search is not available right now");
    const parsed = std.json.parseFromSliceLeaky(struct { features: []const Feature = &.{} }, ctx.arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return a_.fail(ctx, .bad_gateway, "Search is not available right now");
    var results: std.ArrayList(Place) = .empty;
    for (parsed.features) |f| if (try place(ctx.arena, f)) |p| try results.append(ctx.arena, p);
    try ctx.setHeader("cache-control", "public, max-age=300");
    return ctx.sendJson(.ok, .{ .success = true, .results = results.items });
}

/// GET /api/v1/reverse?lat=&lng=
pub fn reverse(ctx: *http.Context) !void {
    if (!try allowed(ctx, "reverse")) return a_.fail(ctx, .too_many_requests, "Too many searches, try again in a minute");
    const lat = num(ctx.queryParam("lat"), -90, 90) orelse return a_.fail(ctx, .bad_request, "lat and lng are required");
    const lng = num(ctx.queryParam("lng"), -180, 180) orelse return a_.fail(ctx, .bad_request, "lat and lng are required");
    const url = try std.fmt.allocPrint(ctx.arena, "{s}/reverse?lat={d:.5}&lon={d:.5}&limit=1", .{ a_.app.config.photon_url, lat, lng });
    const body = cached(ctx.arena, url) catch return a_.fail(ctx, .bad_gateway, "Search is not available right now");
    const parsed = std.json.parseFromSliceLeaky(struct { features: []const Feature = &.{} }, ctx.arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return a_.fail(ctx, .bad_gateway, "Search is not available right now");
    const p: ?Place = if (parsed.features.len > 0) try place(ctx.arena, parsed.features[0]) else null;
    try ctx.setHeader("cache-control", "public, max-age=300");
    return ctx.sendJson(.ok, .{ .success = true, .place = p });
}
