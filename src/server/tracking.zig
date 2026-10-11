//! Embed sessions, delivery tracking (batch uploads, end), the offline watchdog, and the live
//! rooms: one driver and any number of viewers per delivery, joined over WebSocket
//! (`/?room=<trackId>&role=driver|viewer[&key=]`). Only cleaned position fields are relayed, so a
//! driver cannot push arbitrary data to viewers' pages.

const std = @import("std");
const http = @import("http");
const mongo = @import("mongo");
const bson = mongo.bson;
const Io = std.Io;
const a_ = @import("app.zig");
const keys = @import("keys.zig");

fn badJson(ctx: *http.Context) !void {
    return a_.fail(ctx, .bad_request, "Invalid JSON");
}

// ---- Sessions -----------------------------------------------------------------------------

/// POST /api/init-session (x-maps-api-key)
pub fn initSession(ctx: *http.Context) !void {
    const k = ctx.header("x-maps-api-key") orelse return a_.fail(ctx, .unauthorized, "Missing Maps API Key");
    const key = (try keys.findActive(k, "session")) orelse return a_.fail(ctx, .unauthorized, "Invalid API Key");
    const body = ctx.json(struct { type: ?std.json.Value = null }) catch return badJson(ctx);
    const kind: ?[]const u8 = if (body.type) |t| (if (t == .string) t.string[0..@min(t.string.len, 32)] else null) else null;

    const token = try a_.randomHex(ctx.arena, 16);
    const now = a_.nowMs();
    _ = try a_.app.collection("sessions").insertOne(ctx.arena, .{
        .token = token,
        .appId = key.app_name,
        .type = kind,
        .createdAt = bson.DateTime{ .ms = now },
        .expiresAt = bson.DateTime{ .ms = now + 12 * 3600 * 1000 },
    });
    return ctx.sendJson(.ok, .{ .success = true, .sessionToken = token });
}

// ---- Tracking -----------------------------------------------------------------------------

/// The app that owns a delivery (by API key) is the only one that can update or end it.
fn keyOwner(ctx: *http.Context) !?[]const u8 {
    const k = ctx.header("x-maps-api-key") orelse return null;
    const key = (try keys.findActive(k, "tracking")) orelse return null;
    return try ctx.arena.dupe(u8, key.user_id);
}

fn validDeliveryId(v: ?std.json.Value) ?[]const u8 {
    const s = switch (v orelse return null) {
        .string => |s| s,
        else => return null,
    };
    return if (s.len > 0 and s.len <= 128) s else null;
}

fn number(v: ?std.json.Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string, .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// POST /api/tracking/batch { deliveryId, coordinates: [{ lat, lng, timestamp? }] }
pub fn batch(ctx: *http.Context) !void {
    const owner = (try keyOwner(ctx)) orelse return a_.fail(ctx, .unauthorized, "Missing or invalid API key");
    const body = ctx.json(std.json.Value) catch return badJson(ctx);
    const obj = if (body == .object) body.object else return a_.fail(ctx, .bad_request, "Invalid payload");
    const delivery_id = validDeliveryId(obj.get("deliveryId")) orelse return a_.fail(ctx, .bad_request, "Invalid payload");
    const coords = obj.get("coordinates") orelse return a_.fail(ctx, .bad_request, "Invalid payload");
    if (coords != .array or coords.array.items.len == 0) return a_.fail(ctx, .bad_request, "Invalid payload");

    const latest = coords.array.items[coords.array.items.len - 1];
    const lo = if (latest == .object) latest.object else return a_.fail(ctx, .bad_request, "Invalid coordinates");
    const lat = number(lo.get("lat")) orelse 999;
    const lng = number(lo.get("lng")) orelse 999;
    if (!std.math.isFinite(lat) or !std.math.isFinite(lng) or @abs(lat) > 90 or @abs(lng) > 180)
        return a_.fail(ctx, .bad_request, "Invalid coordinates");
    const ping_ms: i64 = if (number(lo.get("timestamp"))) |t| @intFromFloat(t) else a_.nowMs();

    // deliveryId is the app's own reference, unique only within that app; the public trackId
    // (tracking link, WebSocket room) is random and made here, so nobody can guess a link.
    const delivery = (try a_.app.collection("activeDeliveries").findOneAndUpdate(ctx.arena, .{ .ownerId = owner, .deliveryId = delivery_id }, .{
        .@"$set" = .{
            .active = true,
            .lastPingTime = bson.DateTime{ .ms = ping_ms },
            .lastKnownLocation = .{ .lat = lat, .lng = lng },
            .status = "ON_ROUTE",
        },
        .@"$setOnInsert" = .{ .trackId = try a_.randomHex(ctx.arena, 16), .createdAt = a_.now() },
    }, .{ .upsert = true, .return_new = true })) orelse return error.UpsertReturnedNothing;
    return ctx.sendJson(.ok, .{ .success = true, .message = "Batch processed", .trackId = delivery.getString("trackId") orelse "" });
}

/// POST /api/tracking/end { deliveryId }: the tracking link stops working, viewers are closed.
pub fn end(ctx: *http.Context) !void {
    const owner = (try keyOwner(ctx)) orelse return a_.fail(ctx, .unauthorized, "Missing or invalid API key");
    const body = ctx.json(std.json.Value) catch return badJson(ctx);
    const delivery_id = (if (body == .object) validDeliveryId(body.object.get("deliveryId")) else null) orelse return a_.fail(ctx, .bad_request, "Invalid payload");
    const delivery = (try a_.app.collection("activeDeliveries").findOneAndUpdate(ctx.arena, .{ .deliveryId = delivery_id, .ownerId = owner }, .{
        .@"$set" = .{ .active = false, .status = "ENDED", .endedAt = a_.now() },
    }, .{ .return_new = false })) orelse return a_.fail(ctx, .not_found, "Delivery not found");
    if (delivery.getString("trackId")) |t| closeRoom(t);
    return ctx.sendJson(.ok, .{ .success = true, .message = "Tracking ended" });
}

/// Every 5 minutes: deliveries silent for over two hours become CRITICAL_OFFLINE.
pub fn watchdogLoop() void {
    while (true) {
        a_.app.io.sleep(.fromSeconds(300), .awake) catch return;
        var arena = std.heap.ArenaAllocator.init(a_.app.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const deliveries = a_.app.collection("activeDeliveries");
        const two_hours_ago = bson.DateTime{ .ms = a_.nowMs() - 2 * 3600 * 1000 };
        var cursor = deliveries.find(a, .{ .status = .{ .@"$nin" = .{ "CRITICAL_OFFLINE", "ENDED" } }, .lastPingTime = .{ .@"$lt" = two_hours_ago } }, .{}) catch continue;
        while (cursor.next() catch null) |d| {
            std.log.err("CRITICAL ESCALATION: Delivery {s} offline for >2 hours.", .{d.getString("deliveryId") orelse "?"});
            _ = deliveries.updateOne(a, .{ ._id = d.get("_id").? }, .{ .@"$set" = .{ .status = "CRITICAL_OFFLINE" } }, .{}) catch {};
        }
    }
}

// ---- Live rooms ---------------------------------------------------------------------------

const Peer = struct {
    socket: *http.ws.Socket,
    alive: std.atomic.Value(bool) = .init(true),
};

const Room = struct {
    driver: ?*Peer = null,
    viewers: std.ArrayList(*Peer) = .empty,
};

var rooms_lock: Io.Mutex = .init;
/// trackId (owned) → room.
var rooms: std.StringHashMapUnmanaged(Room) = .empty;

const vehicles = [_][]const u8{ "car", "motorcycle", "truck", "bicycle", "walk" };

/// A position message with only the fields viewers need, or null if it is not one.
fn cleanPosition(arena: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
    if (v != .object) return null;
    const o = v.object;
    const lat = number(o.get("lat")) orelse return null;
    const lng = number(o.get("lng")) orelse return null;
    if (!std.math.isFinite(lat) or !std.math.isFinite(lng) or @abs(lat) > 90 or @abs(lng) > 180) return null;

    var out: std.Io.Writer.Allocating = .init(arena);
    var w: std.json.Stringify = .{ .writer = &out.writer };
    try w.beginObject();
    try w.objectField("lat");
    try w.write(lat);
    try w.objectField("lng");
    try w.write(lng);
    if (number(o.get("heading"))) |h| if (std.math.isFinite(h)) {
        try w.objectField("heading");
        try w.write(@mod(@mod(h, 360) + 360, 360));
    };
    if (number(o.get("speed"))) |s| if (std.math.isFinite(s) and s >= 0) {
        try w.objectField("speed");
        try w.write(s);
    };
    if (o.get("vehicle")) |vh| if (vh == .string) for (vehicles) |known| {
        if (std.mem.eql(u8, known, vh.string)) {
            try w.objectField("vehicle");
            try w.write(known);
        }
    };
    if (o.get("timestamp")) |t| switch (t) {
        .string, .integer, .float, .number_string => {
            try w.objectField("timestamp");
            try w.write(t);
        },
        else => {},
    };
    try w.endObject();
    return out.written();
}

/// Drivers must send the API key of the app that owns the delivery; viewers only need the
/// tracking id, and only while the delivery is active.
fn authorize(arena: std.mem.Allocator, room_id: []const u8, role: []const u8, api_key: ?[]const u8) !bool {
    const delivery = (try a_.app.collection("activeDeliveries").findOne(arena, .{ .trackId = room_id, .active = true }, .{})) orelse return false;
    if (std.mem.eql(u8, role, "viewer")) return true;
    const k = api_key orelse return false;
    const key = (try keys.findActive(k, "live")) orelse return false;
    var buf: [24]u8 = undefined;
    const owner = keys.idString(delivery.get("ownerId"), &buf) orelse return false;
    return std.mem.eql(u8, owner, key.user_id);
}

/// Middleware: takes WebSocket upgrades with ?room=&role= on any path.
pub fn upgrade(ctx: *http.Context) !void {
    if (!ctx.wantsWebSocket()) return;
    const room_id = ctx.queryParam("room") orelse return reject(ctx, .bad_request);
    const role = ctx.queryParam("role") orelse return reject(ctx, .bad_request);
    if (!std.mem.eql(u8, role, "driver") and !std.mem.eql(u8, role, "viewer")) return reject(ctx, .bad_request);
    const ok = authorize(ctx.arena, room_id, role, ctx.queryParam("key")) catch false;
    if (!ok) return reject(ctx, .forbidden);

    var socket = try ctx.webSocket();
    var peer: Peer = .{ .socket = &socket };
    const is_driver = std.mem.eql(u8, role, "driver");
    try join(room_id, &peer, is_driver);
    defer leave(room_id, &peer, is_driver);

    while (true) {
        const frame = socket.read() catch return;
        peer.alive.store(true, .release);
        if (!is_driver or frame.op != .text) continue;
        const msg = (cleanPosition(ctx.arena, frame.data) catch null) orelse continue;
        broadcast(room_id, msg);
    }
}

fn reject(ctx: *http.Context, status: std.http.Status) !void {
    ctx.responded = true;
    ctx.close_connection = true;
    try ctx.request.respond("", .{ .status = status, .keep_alive = false });
}

fn join(room_id: []const u8, peer: *Peer, is_driver: bool) !void {
    const app = a_.app;
    rooms_lock.lockUncancelable(app.io);
    defer rooms_lock.unlock(app.io);
    const gop = try rooms.getOrPut(app.gpa, room_id);
    if (!gop.found_existing) {
        gop.key_ptr.* = try app.gpa.dupe(u8, room_id);
        gop.value_ptr.* = .{};
    }
    if (is_driver) {
        // A newer driver connection replaces the old one.
        if (gop.value_ptr.driver) |old| old.socket.close(1000);
        gop.value_ptr.driver = peer;
    } else try gop.value_ptr.viewers.append(app.gpa, peer);
}

fn leave(room_id: []const u8, peer: *Peer, is_driver: bool) void {
    const app = a_.app;
    rooms_lock.lockUncancelable(app.io);
    defer rooms_lock.unlock(app.io);
    const room = rooms.getPtr(room_id) orelse return;
    if (is_driver) {
        if (room.driver == peer) {
            room.driver = null;
            for (room.viewers.items) |v| v.socket.sendText("{\"status\":\"OFFLINE\"}") catch {};
        }
    } else for (room.viewers.items, 0..) |v, i| if (v == peer) {
        _ = room.viewers.swapRemove(i);
        break;
    };
    if (room.driver == null and room.viewers.items.len == 0) {
        room.viewers.deinit(app.gpa);
        const kv = rooms.fetchRemove(room_id).?;
        app.gpa.free(kv.key);
    }
}

fn broadcast(room_id: []const u8, msg: []const u8) void {
    rooms_lock.lockUncancelable(a_.app.io);
    defer rooms_lock.unlock(a_.app.io);
    const room = rooms.getPtr(room_id) orelse return;
    for (room.viewers.items) |v| v.socket.sendText(msg) catch {};
}

/// The delivery ended: tell viewers and close every connection in the room.
pub fn closeRoom(room_id: []const u8) void {
    rooms_lock.lockUncancelable(a_.app.io);
    defer rooms_lock.unlock(a_.app.io);
    const room = rooms.getPtr(room_id) orelse return;
    for (room.viewers.items) |v| {
        v.socket.sendText("{\"status\":\"ENDED\"}") catch {};
        v.socket.close(1000);
    }
    if (room.driver) |d| d.socket.close(1000);
}

/// Every 30 s: ping everyone (Cloudflare closes connections idle for ~100 s) and drop those that
/// did not answer the previous ping. Run as its own task.
pub fn pingLoop() void {
    while (true) {
        a_.app.io.sleep(.fromSeconds(30), .awake) catch return;
        rooms_lock.lockUncancelable(a_.app.io);
        defer rooms_lock.unlock(a_.app.io);
        var it = rooms.valueIterator();
        while (it.next()) |room| {
            if (room.driver) |d| ping(d);
            for (room.viewers.items) |v| ping(v);
        }
    }
}

fn ping(p: *Peer) void {
    if (!p.alive.swap(false, .acq_rel)) return p.socket.close(1001);
    p.socket.send(.ping, "") catch {};
}

test cleanPosition {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "{\"lat\":33.52,\"lng\":36.31,\"heading\":10}",
        (try cleanPosition(a, "{\"lat\":33.52,\"lng\":36.31,\"heading\":370,\"vehicle\":\"<b>x</b>\",\"extra\":\"<script>\"}")).?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), try cleanPosition(a, "not json"));
    try std.testing.expectEqual(@as(?[]const u8, null), try cleanPosition(a, "{\"lat\":91,\"lng\":0}"));
}
