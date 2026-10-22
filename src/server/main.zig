//! Wufour Maps server: the Maps-js API on zig-core (same endpoints, answers, database documents
//! and environment variables), so it can replace Maps-js behind Cloudflare Tunnel without any
//! other app noticing.
//!
//! Configuration: environment variables, else `.env.production` / `.env` (see app.Config).

const std = @import("std");
const http = @import("http");
const mongo = @import("mongo");
const env_mod = @import("env");
const geo = @import("geo");
const a_ = @import("app.zig");
const keys = @import("keys.zig");
const tiles = @import("tiles.zig");
const routing = @import("routing.zig");
const search = @import("search.zig");
const tracking = @import("tracking.zig");
const pages = @import("pages.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const env = try env_mod.Env.loadApp(arena, io, init.environ_map, "maps");
    const config = a_.Config.load(&env);

    const db = try mongo.Client.init(io, gpa, config.mongo_uri);
    defer db.deinit();
    var regions = geo.Regions.init(io, gpa, config.regions_dir);
    defer regions.deinit();
    regions.log = logGeo;
    var state: a_.App = .{
        .regions = &regions,
        .io = io,
        .gpa = gpa,
        .config = config,
        .db = db,
        .fetch = .init(io, gpa),
        .wufour = undefined,
        .started_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
    };
    defer state.fetch.deinit();
    state.wufour = .{ .fetch = &state.fetch, .host = config.auth_host };
    defer state.wufour.deinit();
    a_.app = &state;

    createIndexes(arena) catch |err| {
        std.log.err("Maps MongoDB Connection Error: {t} {s}", .{ err, db.lastError() });
        return err;
    };
    std.log.info("Maps Database Connected", .{});

    var router: http.Router = .init(gpa);
    defer router.deinit();
    try router.use(headers);
    try router.use(tracking.upgrade);
    try router.get("/healthz", healthz);
    try router.get("/tiles/:z/:x/:y", tiles.serve);
    try router.get("/", pages.mapPage);
    try router.get("/auth", pages.login);
    try router.get("/auth/callback", pages.callback);
    try router.add(null, "/auth/logout", pages.logout);
    try router.get("/api/account-menu", pages.accountMenu);
    try router.post("/api/init-session", tracking.initSession);
    try router.post("/api/tracking/batch", tracking.batch);
    try router.post("/api/tracking/end", tracking.end);
    try router.get("/api/route/valhalla", routing.valhallaProxy);
    try router.get("/api/v1/route", routing.routeV1);
    try router.get("/api/v1/search", search.search);
    try router.get("/api/v1/reverse", search.reverse);
    try router.get("/api/developer/me", pages.me);
    try router.get("/api/developer/keys", pages.listKeys);
    try router.post("/api/developer/keys/create", pages.createKey);
    try router.post("/api/developer/keys/revoke", pages.revokeKey);
    try router.get("/embed/:mode", pages.embed);
    try router.get("/sdk/style.json", pages.mapStyle);
    try router.get("/developers", pages.developers);
    router.fallback = staticFiles;

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, search.regionsLoop, .{});
    try group.concurrent(io, keys.flushLoop, .{});
    try group.concurrent(io, tracking.watchdogLoop, .{});
    try group.concurrent(io, tracking.pingLoop, .{});
    if (config.tile_proxy) try group.concurrent(io, tiles.pruneLoop, .{});

    std.log.info("Wufour Maps Engine running on http://{s}:{d}", .{ config.listen, config.port });
    try http.serve(io, gpa, .{
        .address = try .parse(config.listen, config.port),
        .router = &router,
        .trust_proxy = config.trust_proxy,
        .on_error = onError,
    });
}

fn logGeo(line: []const u8) void {
    std.log.info("{s}", .{line});
}

/// The indexes Maps-js creates; existing ones are left as they are.
fn createIndexes(arena: std.mem.Allocator) !void {
    const app = a_.app;
    _ = try app.db.command(arena, "admin", .{ .ping = 1 });
    app.collection("sessions").createIndex(arena, .{ .expiresAt = 1 }, .{ .expire_after_seconds = 0 }) catch |e| std.log.warn("TTL index: {t} {s}", .{ e, app.db.lastError() });
    app.collection("apiKeys").createIndex(arena, .{ .key = 1 }, .{}) catch |e| std.log.warn("index: {t}", .{e});
    app.collection("activeDeliveries").createIndex(arena, .{ .ownerId = 1, .deliveryId = 1 }, .{ .unique = true }) catch |e| std.log.warn("index: {t}", .{e});
    app.collection("activeDeliveries").createIndex(arena, .{ .trackId = 1, .active = 1 }, .{}) catch |e| std.log.warn("index: {t}", .{e});
    app.collection("usage").createIndex(arena, .{ .key = 1, .day = 1 }, .{ .unique = true }) catch |e| std.log.warn("index: {t}", .{e});
}

/// Security headers and CORS, before every route. The map page and embeds stay embeddable; the
/// developer console (API keys) may only be framed by Maps itself.
fn headers(ctx: *http.Context) !void {
    try ctx.setHeader("x-content-type-options", "nosniff");
    try ctx.setHeader("referrer-policy", "strict-origin-when-cross-origin");
    if (std.mem.eql(u8, ctx.path, "/developers") or std.mem.startsWith(u8, ctx.path, "/auth")) {
        try ctx.setHeader("content-security-policy", "frame-ancestors 'self'");
        try ctx.setHeader("x-frame-options", "SAMEORIGIN");
    }
    try ctx.setHeader("access-control-allow-origin", "*");
    try ctx.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");
    try ctx.setHeader("access-control-allow-headers", "Content-Type, x-maps-api-key");
    if (ctx.method == .OPTIONS) return ctx.text(.ok, "OK");
}

/// 200 when the database answers, 503 otherwise.
fn healthz(ctx: *http.Context) !void {
    try ctx.setHeader("cache-control", "no-store");
    const app = a_.app;
    _ = app.db.command(ctx.arena, "admin", .{ .ping = 1 }) catch return ctx.sendJson(.service_unavailable, .{ .ok = false, .db = "down" });
    return ctx.sendJson(.ok, .{ .ok = true, .db = "up", .uptimeS = @divFloor(a_.nowMs() - app.started_ms, 1000) });
}

/// Files under the public folder. The service worker and manifest are always revalidated, so a
/// new version reaches installed apps at once.
fn staticFiles(ctx: *http.Context) !void {
    if (ctx.method != .GET and ctx.method != .HEAD) return a_.fail(ctx, .not_found, "Not found");
    if (std.mem.eql(u8, ctx.path, "/sw.js") or std.mem.eql(u8, ctx.path, "/manifest.json")) try ctx.setHeader("cache-control", "no-cache");
    return http.serveDir(ctx, a_.app.config.public_dir, false);
}

/// Client errors keep their status; anything else is a generic 500 (details in the log).
fn onError(ctx: *http.Context, status: std.http.Status, _: anyerror) anyerror!void {
    const message = if (status == .internal_server_error) "Internal Server Error" else (status.phrase() orelse "Bad Request");
    return a_.fail(ctx, status, message);
}

test {
    _ = a_;
    _ = routing;
    _ = tiles;
    _ = tracking;
    _ = pages;
}
