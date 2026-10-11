//! Geometry for routes and navigation: distances, bearings, Valhalla's route shape, and where a
//! GPS fix lies on the route.

const std = @import("std");
const map = @import("map");

pub const LatLng = map.LatLng;

/// Metres between two points (haversine).
pub fn distance(a: LatLng, b: LatLng) f64 {
    const r = 6_371_000.0;
    const p1 = std.math.degreesToRadians(a.lat);
    const p2 = std.math.degreesToRadians(b.lat);
    const dp = std.math.degreesToRadians(b.lat - a.lat);
    const dl = std.math.degreesToRadians(b.lng - a.lng);
    const h = @sin(dp / 2) * @sin(dp / 2) + @cos(p1) * @cos(p2) * @sin(dl / 2) * @sin(dl / 2);
    return r * 2 * std.math.atan2(@sqrt(h), @sqrt(1 - h));
}

/// Degrees clockwise from north, from `a` towards `b`.
pub fn bearing(a: LatLng, b: LatLng) f64 {
    const p1 = std.math.degreesToRadians(a.lat);
    const p2 = std.math.degreesToRadians(b.lat);
    const dl = std.math.degreesToRadians(b.lng - a.lng);
    const y = @sin(dl) * @cos(p2);
    const x = @cos(p1) * @sin(p2) - @sin(p1) * @cos(p2) * @cos(dl);
    return @mod(std.math.radiansToDegrees(std.math.atan2(y, x)) + 360, 360);
}

/// Valhalla's encoded polyline (6 decimal places) as points.
pub fn decodePolyline6(gpa: std.mem.Allocator, s: []const u8) ![]LatLng {
    var out: std.ArrayList(LatLng) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var lat: i64 = 0;
    var lng: i64 = 0;
    while (i < s.len) {
        lat += try value(s, &i);
        lng += try value(s, &i);
        try out.append(gpa, .{ .lat = @as(f64, @floatFromInt(lat)) / 1e6, .lng = @as(f64, @floatFromInt(lng)) / 1e6 });
    }
    return out.toOwnedSlice(gpa);
}

fn value(s: []const u8, i: *usize) !i64 {
    var result: i64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (i.* >= s.len) return error.BadPolyline;
        const b = @as(i64, s[i.*]) - 63;
        i.* += 1;
        if (b < 0) return error.BadPolyline;
        result |= (b & 0x1f) << shift;
        if (b < 0x20) break;
        shift += 5;
        if (shift > 60) return error.BadPolyline;
    }
    return if (result & 1 != 0) ~(result >> 1) else result >> 1;
}

pub const Snap = struct { point: LatLng, metres: f64 };

/// The point of the route nearest to `p`, and how far `p` is from it.
pub fn snapToRoute(p: LatLng, route: []const LatLng) Snap {
    if (route.len < 2) return .{ .point = p, .metres = 0 };
    var best: Snap = .{ .point = p, .metres = std.math.inf(f64) };
    for (route[0 .. route.len - 1], route[1..]) |a, b| {
        const dx = b.lng - a.lng;
        const dy = b.lat - a.lat;
        const len = dx * dx + dy * dy;
        const t = if (len == 0) 0 else std.math.clamp(((p.lng - a.lng) * dx + (p.lat - a.lat) * dy) / len, 0, 1);
        const q: LatLng = .{ .lat = a.lat + dy * t, .lng = a.lng + dx * t };
        const d = distance(p, q);
        if (d < best.metres) best = .{ .point = q, .metres = d };
    }
    return best;
}

const testing = std.testing;

test decodePolyline6 {
    // Encoded at 6 digits with Node (the encoder Maps-js decodes): [[33.513844,36.276511],[33.5,36.3]].
    const pts = try decodePolyline6(testing.allocator, "gvo|~@}pcedAf`Za{l@");
    defer testing.allocator.free(pts);
    try testing.expectEqual(@as(usize, 2), pts.len);
    try testing.expectApproxEqAbs(@as(f64, 33.513844), pts[0].lat, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 36.276511), pts[0].lng, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 33.5), pts[1].lat, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 36.3), pts[1].lng, 1e-9);
    try testing.expectError(error.BadPolyline, decodePolyline6(testing.allocator, "o"));
}

test "distance, bearing, snap" {
    const a: LatLng = .{ .lat = 33.5, .lng = 36.3 };
    const b: LatLng = .{ .lat = 33.51, .lng = 36.3 };
    try testing.expectApproxEqAbs(@as(f64, 1112), distance(a, b), 2);
    try testing.expectApproxEqAbs(@as(f64, 0), bearing(a, b), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 90), bearing(a, .{ .lat = 33.5, .lng = 36.31 }), 0.01);
    const s = snapToRoute(.{ .lat = 33.505, .lng = 36.301 }, &.{ a, b });
    try testing.expectApproxEqAbs(@as(f64, 33.505), s.point.lat, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 36.3), s.point.lng, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 92.7), s.metres, 1);
}
