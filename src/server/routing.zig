//! Routing through Valhalla (Stadia's for now, our own server with the Syria map at launch; the
//! API key stays on the server). Same endpoints and answers as Maps-js.

const std = @import("std");
const http = @import("http");
const a_ = @import("app.zig");
const keys = @import("keys.zig");
const settings = @import("settings.zig");

const costing_names = [_]struct { []const u8, []const u8 }{
    .{ "car", "auto" },        .{ "walk", "pedestrian" },
    .{ "bicycle", "bicycle" }, .{ "motorcycle", "motorcycle" },
    .{ "truck", "truck" },
};

/// The same ETA adjustments the map page applies.
fn timeFactor(vehicle: []const u8) f64 {
    if (std.mem.eql(u8, vehicle, "motorcycle")) return 0.85;
    if (std.mem.eql(u8, vehicle, "truck")) return 1.2;
    return 1;
}

var page_limiter: a_.RateLimiter = .{};

const Point = struct { lat: f64, lng: f64 };

/// "lat,lng" within range.
pub fn parsePoint(s: ?[]const u8) ?Point {
    const v = s orelse return null;
    const comma = std.mem.indexOfScalar(u8, v, ',') orelse return null;
    const lat = std.fmt.parseFloat(f64, std.mem.trim(u8, v[0..comma], " ")) catch return null;
    const lng = std.fmt.parseFloat(f64, std.mem.trim(u8, v[comma + 1 ..], " ")) catch return null;
    if (!std.math.isFinite(lat) or !std.math.isFinite(lng) or @abs(lat) > 90 or @abs(lng) > 180) return null;
    return .{ .lat = lat, .lng = lng };
}

fn validKey(ctx: *http.Context) !bool {
    const k = ctx.header("x-maps-api-key") orelse ctx.queryParam("key") orelse return false;
    return (try keys.findActive(k, "route")) != null;
}

/// Browsers send Sec-Fetch-Site; "same-origin" means the request came from our own pages.
/// Older browsers (Safari before 16.4) do not, so fall back to the Referer's host.
fn fromOwnPage(ctx: *http.Context) bool {
    if (ctx.header("sec-fetch-site")) |site| return std.mem.eql(u8, site, "same-origin");
    const referer = ctx.header("referer") orelse return false;
    const host = ctx.header("host") orelse return false;
    const uri = std.Uri.parse(referer) catch return false;
    const rh = (uri.host orelse return false).percent_encoded;
    var buf: [300]u8 = undefined;
    const ref_host = if (uri.port) |p| std.fmt.bufPrint(&buf, "{s}:{d}", .{ rh, p }) catch return false else rh;
    return std.mem.eql(u8, ref_host, host);
}

fn callValhalla(arena: std.mem.Allocator, from: Point, to: Point, costing: []const u8) !a_.Upstream {
    const cfg = a_.app.config;
    const body = try std.fmt.allocPrint(arena, "{{\"locations\":[{{\"lat\":{d},\"lon\":{d}}},{{\"lat\":{d},\"lon\":{d}}}],\"costing\":\"{s}\"}}", .{ from.lat, from.lng, to.lat, to.lng, costing });
    const url = try std.fmt.allocPrint(arena, "{s}?json={s}{s}{s}", .{
        cfg.valhalla_url,
        try http.encode(arena, body),
        if (cfg.valhalla_api_key.len > 0) "&api_key=" else "",
        cfg.valhalla_api_key,
    });
    return a_.upstream(arena, .GET, url, null, &.{});
}

/// GET /api/route/valhalla?json=... : the raw Valhalla answer, for the map page itself.
pub fn valhallaProxy(ctx: *http.Context) !void {
    if (!try validKey(ctx)) {
        if (!fromOwnPage(ctx)) return a_.fail(ctx, .unauthorized, "Missing or invalid API key");
        if (!page_limiter.allow(ctx.clientIp(), settings.get(ctx.arena).route_per_minute))
            return a_.fail(ctx, .too_many_requests, "Too many route requests, try again in a minute");
    }

    const Req = struct { locations: []const struct { lat: ?f64 = null, lon: ?f64 = null }, costing: []const u8 };
    const raw = ctx.queryParam("json") orelse "";
    const r = std.json.parseFromSliceLeaky(Req, ctx.arena, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return a_.fail(ctx, .bad_request, "Invalid route request");
    const costing_ok = for (costing_names) |c| {
        if (std.mem.eql(u8, c[1], r.costing)) break true;
    } else false;
    if (r.locations.len < 2 or !costing_ok) return a_.fail(ctx, .bad_request, "Invalid route request");
    var pts: [2]Point = undefined;
    for (r.locations[0..2], &pts) |l, *p| {
        p.* = parsePoint(try std.fmt.allocPrint(ctx.arena, "{d},{d}", .{ l.lat orelse 999, l.lon orelse 999 })) orelse
            return a_.fail(ctx, .bad_request, "Invalid route request");
    }

    const res = callValhalla(ctx.arena, pts[0], pts[1], r.costing) catch
        return ctx.sendJson(.bad_gateway, .{ .@"error" = "Routing service unreachable" });
    // Valhalla's own status and JSON, as Maps-js passes them on.
    if (res.body.len == 0) return ctx.sendJson(res.status, .{ .@"error" = "Route Unavailable" });
    return ctx.send(res.status, "application/json; charset=utf-8", res.body);
}

/// Valhalla maneuver types → { type, modifier } in the OSRM vocabulary.
fn maneuver(t: i64) ?struct { []const u8, ?[]const u8 } {
    return switch (t) {
        1 => .{ "depart", "straight" },
        2 => .{ "depart", "right" },
        3 => .{ "depart", "left" },
        4 => .{ "arrive", null },
        5 => .{ "arrive", "right" },
        6 => .{ "arrive", "left" },
        7 => .{ "new name", "straight" },
        8 => .{ "continue", "straight" },
        9 => .{ "turn", "slight right" },
        10 => .{ "turn", "right" },
        11 => .{ "turn", "sharp right" },
        12, 13 => .{ "turn", "uturn" },
        14 => .{ "turn", "sharp left" },
        15 => .{ "turn", "left" },
        16 => .{ "turn", "slight left" },
        17 => .{ "on ramp", "straight" },
        18 => .{ "on ramp", "slight right" },
        19 => .{ "on ramp", "slight left" },
        20 => .{ "off ramp", "slight right" },
        21 => .{ "off ramp", "slight left" },
        22 => .{ "fork", "straight" },
        23 => .{ "fork", "slight right" },
        24 => .{ "fork", "slight left" },
        25 => .{ "merge", "straight" },
        26 => .{ "roundabout", null },
        28, 29 => .{ "continue", "straight" },
        37 => .{ "merge", "slight right" },
        38 => .{ "merge", "slight left" },
        else => null,
    };
}

/// Valhalla's encoded shape (polyline, 6 decimal places) as [lat, lng] pairs.
pub fn decodePolyline6(arena: std.mem.Allocator, s: []const u8) ![][2]f64 {
    var out: std.ArrayList([2]f64) = .empty;
    var i: usize = 0;
    var lat: i64 = 0;
    var lng: i64 = 0;
    while (i < s.len) {
        inline for (.{ &lat, &lng }) |coord| {
            var result: i64 = 0;
            var shift: u6 = 0;
            while (true) {
                if (i >= s.len) return error.BadPolyline;
                const b: i64 = @as(i64, s[i]) - 63;
                i += 1;
                result |= (b & 0x1f) << shift;
                shift += 5;
                if (b < 0x20) break;
                if (shift > 60) return error.BadPolyline;
            }
            coord.* += if (result & 1 != 0) ~(result >> 1) else result >> 1;
        }
        try out.append(arena, .{ @as(f64, @floatFromInt(lat)) / 1e6, @as(f64, @floatFromInt(lng)) / 1e6 });
    }
    return out.items;
}

const Step = struct {
    type: []const u8,
    modifier: ?[]const u8,
    exit: ?i64,
    name: ?[]const u8,
    distanceM: i64,
    durationS: i64,
    location: [2]f64,
};

/// GET /api/v1/route?from=lat,lng&to=lat,lng&vehicle=car : for other apps (needs an API key).
pub fn routeV1(ctx: *http.Context) !void {
    if (!try validKey(ctx)) return a_.fail(ctx, .unauthorized, "Missing or invalid API key");
    const from = parsePoint(ctx.queryParam("from"));
    const to = parsePoint(ctx.queryParam("to"));
    const asked = ctx.queryParam("vehicle") orelse "car";
    const vehicle = for (costing_names) |c| {
        if (std.mem.eql(u8, c[0], asked)) break c;
    } else costing_names[0];
    if (from == null or to == null) return a_.fail(ctx, .bad_request, "from and to must be \"lat,lng\"");

    const res = callValhalla(ctx.arena, from.?, to.?, vehicle[1]) catch
        return a_.fail(ctx, .bad_gateway, "Routing service unreachable");

    const Leg = struct {
        shape: []const u8,
        maneuvers: []const struct {
            type: i64,
            length: f64 = 0,
            time: f64 = 0,
            street_names: ?[]const []const u8 = null,
            begin_shape_index: usize = 0,
            roundabout_exit_count: ?i64 = null,
        } = &.{},
    };
    const Reply = struct {
        trip: ?struct { legs: []const Leg = &.{}, summary: struct { length: f64 = 0, time: f64 = 0 } = .{} } = null,
        @"error": ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSliceLeaky(Reply, ctx.arena, res.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch Reply{};
    const trip = parsed.trip orelse return noRoute(ctx, res.status, parsed.@"error");
    if (trip.legs.len == 0) return noRoute(ctx, res.status, parsed.@"error");
    const leg = trip.legs[0];

    const factor = timeFactor(vehicle[0]);
    const geometry = try decodePolyline6(ctx.arena, leg.shape);
    var steps: std.ArrayList(Step) = .empty;
    for (leg.maneuvers) |m| {
        const mapped = maneuver(m.type) orelse continue; // "exit the roundabout": covered by the roundabout step
        try steps.append(ctx.arena, .{
            .type = mapped[0],
            .modifier = mapped[1],
            .exit = if (m.type == 26) m.roundabout_exit_count else null,
            .name = if (m.street_names) |n| (if (n.len > 0) n[0] else null) else null,
            .distanceM = @intFromFloat(@round(m.length * 1000)),
            .durationS = @intFromFloat(@round(m.time * factor)),
            .location = if (m.begin_shape_index < geometry.len) geometry[m.begin_shape_index] else if (geometry.len > 0) geometry[geometry.len - 1] else .{ 0, 0 },
        });
    }
    return ctx.sendJson(.ok, .{
        .success = true,
        .route = .{
            .vehicle = vehicle[0],
            .distanceM = @as(i64, @intFromFloat(@round(trip.summary.length * 1000))),
            .durationS = @as(i64, @intFromFloat(@round(trip.summary.time * factor))),
            .geometry = geometry,
            .steps = steps.items,
        },
    });
}

fn noRoute(ctx: *http.Context, status: std.http.Status, message: ?[]const u8) !void {
    const code = @backingInt(status);
    const s: std.http.Status = if (code >= 400 and code < 500) .unprocessable_entity else .bad_gateway;
    return a_.fail(ctx, s, message orelse "No route found");
}

test decodePolyline6 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // (38.5, -120.2) then (40.7, -120.95), encoded by an independent implementation.
    const pts = try decodePolyline6(arena.allocator(), "_izlhA~rlgdF_{geC~ywl@");
    try std.testing.expectEqual(@as(usize, 2), pts.len);
    try std.testing.expectApproxEqAbs(@as(f64, 38.5), pts[0][0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -120.2), pts[0][1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 40.7), pts[1][0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -120.95), pts[1][1], 1e-9);
}

test parsePoint {
    try std.testing.expectEqual(Point{ .lat = 33.5, .lng = 36.3 }, parsePoint("33.5,36.3").?);
    try std.testing.expectEqual(@as(?Point, null), parsePoint("95,1"));
    try std.testing.expectEqual(@as(?Point, null), parsePoint("x"));
}
