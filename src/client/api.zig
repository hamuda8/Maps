//! The Maps server's API from the app: request URLs and their answers.
//! On the web the page and the API share an origin; the phone apps use the server given at
//! build time (-Dserver=).

const std = @import("std");
const zui = @import("zui");
const geo = @import("geo.zig");

pub const base = if (zui.platform == .web) "" else @import("app_config").server;
/// Wufour (accounts), for the phones' in-app sign-in. The web signs in through the server (/auth).
pub const auth = if (zui.platform == .web) "" else @import("app_config").auth;

/// The Wufour account menu's data (zui.account), from this server.
pub const account_menu_url = base ++ "/api/account-menu";

/// Percent-encoding for query values (RFC 3986 unreserved characters stay).
pub fn encode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
    return out.items;
}

pub fn searchUrl(arena: std.mem.Allocator, q: []const u8, near: geo.LatLng, lang: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/api/v1/search?q={s}&limit=5&lat={d:.5}&lng={d:.5}&lang={s}", .{ base, try encode(arena, q), near.lat, near.lng, lang });
}

pub fn reverseUrl(arena: std.mem.Allocator, p: geo.LatLng, lang: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/api/v1/reverse?lat={d:.6}&lng={d:.6}&lang={s}", .{ base, p.lat, p.lng, lang });
}

pub const Mode = enum {
    car,
    motorcycle,
    truck,
    bicycle,
    walk,

    pub fn costing(m: Mode) []const u8 {
        return switch (m) {
            .car => "auto",
            .motorcycle => "motorcycle",
            .truck => "truck",
            .bicycle => "bicycle",
            .walk => "pedestrian",
        };
    }
};

/// Through the server's Valhalla proxy, so the routing provider's key stays on the server.
pub fn routeUrl(arena: std.mem.Allocator, from: geo.LatLng, to: geo.LatLng, mode: Mode) ![]const u8 {
    const body = try std.fmt.allocPrint(arena, "{{\"locations\":[{{\"lat\":{d:.6},\"lon\":{d:.6}}},{{\"lat\":{d:.6},\"lon\":{d:.6}}}],\"costing\":\"{s}\"}}", .{ from.lat, from.lng, to.lat, to.lng, mode.costing() });
    // The phone apps say who they are; the web page is recognised as same-origin.
    const client = if (zui.platform == .web) "" else "&client=app";
    return std.fmt.allocPrint(arena, "{s}/api/route/valhalla?json={s}{s}", .{ base, try encode(arena, body), client });
}

pub const Place = struct {
    name: []const u8 = "",
    street: ?[]const u8 = null,
    label: []const u8 = "",
    lat: f64 = 0,
    lng: f64 = 0,
};

const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

/// Search results, or null when the answer is not a successful search.
pub fn parseSearch(arena: std.mem.Allocator, body: []const u8) ?[]const Place {
    const r = std.json.parseFromSliceLeaky(struct { success: bool = false, results: []const Place = &.{} }, arena, body, parse_options) catch return null;
    return if (r.success) r.results else null;
}

/// The name of the place at a point: its name, else its street.
pub fn parseReverse(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const r = std.json.parseFromSliceLeaky(struct { success: bool = false, place: ?Place = null }, arena, body, parse_options) catch return null;
    const p = r.place orelse return null;
    if (p.name.len > 0) return p.name;
    return p.street;
}

pub const Maneuver = struct {
    instruction: []const u8,
    /// Valhalla's maneuver type (turn direction).
    type: u8,
    at: geo.LatLng,
};

pub const Route = struct {
    points: []geo.LatLng,
    maneuvers: []Maneuver,
    seconds: f64,
    km: f64,

    pub fn deinit(r: Route, gpa: std.mem.Allocator) void {
        for (r.maneuvers) |m| gpa.free(m.instruction);
        gpa.free(r.maneuvers);
        gpa.free(r.points);
    }
};

pub const RouteError = union(enum) {
    /// Shown to the user as is.
    message: []const u8,
    unavailable,
};

/// A Valhalla answer as a route owned by `gpa`, or what went wrong.
pub fn parseRoute(gpa: std.mem.Allocator, arena: std.mem.Allocator, status: u16, body: []const u8, mode: Mode) union(enum) { ok: Route, err: RouteError } {
    if (status < 200 or status >= 300) {
        // Our server could not reach the routing service (502 and the other gateway answers):
        // the translated "Route Unavailable", not the server's English sentence.
        if (status >= 502 and status <= 504) return .{ .err = .unavailable };
        const e = std.json.parseFromSliceLeaky(struct { error_code: ?i64 = null, @"error": ?[]const u8 = null, message: ?[]const u8 = null }, arena, body, parse_options) catch return .{ .err = .unavailable };
        if (e.error_code == 154) return .{ .err = .{ .message = "Route too long (max 1500 km)" } };
        if (e.@"error" orelse e.message) |m| return .{ .err = .{ .message = m } };
        return .{ .err = .unavailable };
    }
    const T = struct {
        trip: ?struct {
            summary: struct { time: f64 = 0, length: f64 = 0 } = .{},
            legs: []const struct {
                shape: []const u8 = "",
                maneuvers: []const struct { instruction: []const u8 = "", type: u8 = 0, begin_shape_index: usize = 0 } = &.{},
            } = &.{},
        } = null,
    };
    const r = std.json.parseFromSliceLeaky(T, arena, body, parse_options) catch return .{ .err = .unavailable };
    const trip = r.trip orelse return .{ .err = .unavailable };
    if (trip.legs.len == 0) return .{ .err = .unavailable };
    const leg = trip.legs[0];
    const points = geo.decodePolyline6(gpa, leg.shape) catch return .{ .err = .unavailable };
    if (points.len < 2) {
        gpa.free(points);
        return .{ .err = .unavailable };
    }
    const maneuvers = gpa.alloc(Maneuver, leg.maneuvers.len) catch {
        gpa.free(points);
        return .{ .err = .unavailable };
    };
    var n: usize = 0;
    for (leg.maneuvers) |m| {
        maneuvers[n] = .{
            .instruction = gpa.dupe(u8, m.instruction) catch break,
            .type = m.type,
            .at = points[@min(m.begin_shape_index, points.len - 1)],
        };
        n += 1;
    }
    // Motorcycles filter through traffic; trucks are slower (as Maps-js estimates).
    const factor: f64 = switch (mode) {
        .motorcycle => 0.85,
        .truck => 1.2,
        else => 1,
    };
    return .{ .ok = .{ .points = points, .maneuvers = maneuvers[0..n], .seconds = trip.summary.time * factor, .km = trip.summary.length } };
}

/// Which way a maneuver turns, for its arrow.
pub fn turn(maneuver_type: u8) enum { straight, left, right, arrive } {
    return switch (maneuver_type) {
        4, 5, 6 => .arrive,
        2, 9, 10, 11, 12, 18, 20, 23, 37 => .right,
        3, 13, 14, 15, 16, 19, 21, 24, 38 => .left,
        else => .straight,
    };
}

const testing = std.testing;

test "route answers become routes, errors become messages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ok =
        \\{"trip":{"summary":{"time":600,"length":4.2},"legs":[{"shape":"gvo|~@}pcedAf`Za{l@","maneuvers":[
        \\{"instruction":"Drive south.","type":1,"begin_shape_index":0},
        \\{"instruction":"Turn right onto Baghdad Street.","type":10,"begin_shape_index":1}]}]}}
    ;
    const r = parseRoute(testing.allocator, arena.allocator(), 200, ok, .motorcycle).ok;
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), r.points.len);
    try testing.expectApproxEqAbs(@as(f64, 510), r.seconds, 1e-9);
    try testing.expectEqualStrings("Turn right onto Baghdad Street.", r.maneuvers[1].instruction);
    try testing.expectEqual(.right, turn(r.maneuvers[1].type));
    try testing.expectApproxEqAbs(@as(f64, 33.5), r.maneuvers[1].at.lat, 1e-9);

    const too_long = parseRoute(testing.allocator, arena.allocator(), 400, "{\"error_code\":154,\"error\":\"Path distance exceeds the max distance limit\"}", .car);
    try testing.expectEqualStrings("Route too long (max 1500 km)", too_long.err.message);
    try testing.expectEqual(RouteError.unavailable, parseRoute(testing.allocator, arena.allocator(), 502, "<html>", .car).err);
}

test "urls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("%D8%AF%D9%85%D8%B4%D9%82%20x", try encode(a, "دمشق x"));
    const u = try routeUrl(a, .{ .lat = 1, .lng = 2 }, .{ .lat = 3, .lng = 4 }, .walk);
    try testing.expect(std.mem.indexOf(u8, u, "pedestrian") != null);
}
