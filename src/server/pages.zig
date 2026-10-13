//! The web side: embeds (/embed/:mode), the map style for the JS library (/sdk/style.json), the
//! map page and the developer console, and Wufour sign-in (the same cookies and redirects as the
//! wufour-auth library, so a user signed in on one Wufour app is signed in here too).

const std = @import("std");
const http = @import("http");
const mongo = @import("mongo");
const Io = std.Io;
const a_ = @import("app.zig");
const keys = @import("keys.zig");
const settings = @import("settings.zig");
const tiles = @import("tiles.zig");

fn publicFile(ctx: *http.Context, rel: []const u8) ![]const u8 {
    const path = try std.fs.path.join(ctx.arena, &.{ a_.app.config.public_dir, rel });
    return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(8 << 20));
}

/// GET /: the map page: the zui app (index.html of its web build), else Maps-js's page while
/// the public folder is still Maps-js's.
pub fn mapPage(ctx: *http.Context) !void {
    const html = publicFile(ctx, "index.html") catch publicFile(ctx, "markup/index.html") catch return a_.fail(ctx, .internal_server_error, "Internal Server Error");
    try ctx.setHeader("cache-control", "no-cache");
    return ctx.send(.ok, "text/html; charset=utf-8", html);
}

// ---- Embeds -------------------------------------------------------------------------------

const valid_modes = [_][]const u8{ "full", "picker", "tracking", "driver", "business" };

fn embedError(ctx: *http.Context, status: std.http.Status, message: []const u8) !void {
    const html = try std.fmt.allocPrint(ctx.arena,
        \\
        \\        <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; padding: 40px; color: #0f172a; text-align: center;">
        \\            <h2 style="color: #ef4444; margin-bottom: 10px;">{d} Error</h2>
        \\            <p style="color: #64748b; font-size: 16px;">{s}</p>
        \\        </div>
        \\
    , .{ @backingInt(status), message });
    return ctx.send(status, "text/html; charset=utf-8", html);
}

fn hostOf(url: []const u8, with_port: bool, buf: []u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    const h = (uri.host orelse return null).percent_encoded;
    if (with_port) if (uri.port) |p| return std.fmt.bufPrint(buf, "{s}:{d}", .{ h, p }) catch null;
    return h;
}

/// GET /embed/:mode?key= | ?track_id=
pub fn embed(ctx: *http.Context) !void {
    const mode = ctx.param("mode") orelse "";
    const key = ctx.queryParam("key");
    const track_id = ctx.queryParam("track_id");

    // Trust the current host, localhost and wufour.com (by host name, not substring). Demo keys
    // can be switched off from Control.
    const current_host = ctx.header("host") orelse "";
    const from = ctx.header("referer") orelse ctx.header("origin") orelse "";
    var b1: [300]u8 = undefined;
    const ref_host = hostOf(from, true, &b1) orelse "";
    var b2: [300]u8 = undefined;
    const ref_name = hostOf(from, false, &b2) orelse "";
    const trusted = std.mem.eql(u8, ref_host, current_host) or std.mem.eql(u8, ref_name, "localhost") or
        std.mem.eql(u8, ref_name, "wufour.com") or std.mem.endsWith(u8, ref_name, ".wufour.com");
    const internal_demo = settings.get(ctx.arena).demo_keys and trusted;

    const valid = for (valid_modes) |m| {
        if (std.mem.eql(u8, m, mode)) break true;
    } else false;
    if (!valid) return embedError(ctx, .bad_request, "Invalid map mode.");

    if (std.mem.eql(u8, mode, "tracking")) {
        if (track_id != null and std.mem.eql(u8, track_id.?, "DEMO_ID")) {
            if (!internal_demo) return embedError(ctx, .forbidden, "Demo ID is restricted to Wufour Documentation.");
        } else {
            const t = track_id orelse return embedError(ctx, .bad_request, "Missing track_id.");
            if (try a_.app.collection("activeDeliveries").findOne(ctx.arena, .{ .trackId = t, .active = true }, .{}) == null)
                return embedError(ctx, .forbidden, "Tracking link expired or invalid.");
        }
    } else {
        if (key != null and (std.mem.eql(u8, key.?, "DEMO_KEY") or std.mem.eql(u8, key.?, "YOUR_API_KEY_HERE"))) {
            if (!internal_demo) return embedError(ctx, .forbidden, "Demo Key is restricted to Wufour Documentation.");
        } else {
            const k = key orelse return embedError(ctx, .unauthorized, "Missing API Key.");
            if (try keys.findActive(k, "embed") == null) return embedError(ctx, .forbidden, "Invalid or revoked API Key.");
        }
    }
    return mapPage(ctx);
}

// ---- Map style ----------------------------------------------------------------------------

/// Our public address for absolute tile URLs (MAPS_PUBLIC_URL, else from the request).
fn publicOrigin(ctx: *http.Context) ![]const u8 {
    if (a_.app.config.public_url) |u| return u;
    const proto = if (a_.app.config.trust_proxy) (ctx.header("x-forwarded-proto") orelse "http") else "http";
    return std.fmt.allocPrint(ctx.arena, "{s}://{s}", .{ proto, ctx.header("host") orelse "localhost" });
}

/// GET /sdk/style.json
pub fn mapStyle(ctx: *http.Context) !void {
    const s = settings.get(ctx.arena);
    const tile_url = if (a_.app.config.tile_proxy)
        try std.fmt.allocPrint(ctx.arena, "{s}/tiles/{{z}}/{{x}}/{{y}}.png?s={s}", .{ try publicOrigin(ctx), &tiles.sourceId(s.tile_url) })
    else
        s.tile_url;
    try ctx.setHeader("cache-control", "public, max-age=60");
    return ctx.sendJson(.ok, .{
        .version = 8,
        .sources = .{ .osm = .{ .type = "raster", .tiles = &[_][]const u8{tile_url}, .tileSize = 256, .attribution = s.tile_attribution } },
        .layers = &[_]struct { id: []const u8, type: []const u8, source: []const u8, minzoom: u8, maxzoom: u8 }{.{ .id = "osm-tiles", .type = "raster", .source = "osm", .minzoom = 0, .maxzoom = 19 }},
    });
}

// ---- Wufour sign-in -----------------------------------------------------------------------

pub const User = struct {
    userId: ?[]const u8,
    email: ?[]const u8,
    username: ?[]const u8,
    role: []const u8,
};

fn tokenOf(ctx: *http.Context) ?[]const u8 {
    return ctx.cookie("wufour_token") orelse ctx.cookie("auth_token") orelse ctx.cookie("wufour_session");
}

/// Asks Wufour whether `token` is a live session (zig-core's wufour.Verifier, cached 30 s).
fn verify(arena: std.mem.Allocator, token: []const u8) ?User {
    const u = a_.app.wufour.verify(arena, token, a_.nowMs()) orelse return null;
    const id = idText(arena, u.get("userId")) orelse idText(arena, u.get("id"));
    return .{ .userId = id, .email = u.s("email") orelse u.s("username"), .username = u.s("username"), .role = u.s("role") orelse "user" };
}

fn idText(arena: std.mem.Allocator, v: mongo.val.Val) ?[]const u8 {
    return switch (v) {
        .str => |s| s,
        .num => |n| if (std.math.isFinite(n)) std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))}) catch null else null,
        else => null,
    };
}

pub fn currentUser(ctx: *http.Context) ?User {
    return verify(ctx.arena, tokenOf(ctx) orelse return null);
}

fn clearCookies(ctx: *http.Context) !void {
    for ([_][]const u8{ "auth_token", "wufour_token", "wufour_session" }) |n| try ctx.setCookie(n, "", 0);
}

fn currentDomain(ctx: *http.Context) ![]const u8 {
    const proto = if (a_.app.config.trust_proxy) (ctx.header("x-forwarded-proto") orelse "http") else "http";
    return std.fmt.allocPrint(ctx.arena, "{s}://{s}", .{ proto, ctx.header("host") orelse "localhost" });
}

fn redirectToLogin(ctx: *http.Context, next: []const u8) !void {
    const callback_url = try std.fmt.allocPrint(ctx.arena, "{s}/auth/callback?next={s}", .{ try currentDomain(ctx), try http.encode(ctx.arena, next) });
    return ctx.redirect(try std.fmt.allocPrint(ctx.arena, "{s}/auth?returnTo={s}", .{ a_.app.config.auth_host, try http.encode(ctx.arena, callback_url) }));
}

/// GET /auth: sign in, then the developer console.
pub fn login(ctx: *http.Context) !void {
    const token = ctx.cookie("wufour_token") orelse ctx.cookie("auth_token") orelse return redirectToLogin(ctx, "/auth");
    if (verify(ctx.arena, token) == null) {
        try clearCookies(ctx);
        return redirectToLogin(ctx, "/auth");
    }
    return ctx.redirect("/developers");
}

/// Only our own pages may be the destination after sign-in (no open redirect).
fn safeNext(next: []const u8) bool {
    return next.len > 0 and next[0] == '/' and !std.mem.startsWith(u8, next, "//") and !std.mem.startsWith(u8, next, "/\\");
}

/// GET /auth/callback?token=&next=
pub fn callback(ctx: *http.Context) !void {
    const next = ctx.queryParam("next");
    const token = ctx.queryParam("token") orelse "";
    if (next != null and !safeNext(next.?)) {
        return ctx.redirect(try std.fmt.allocPrint(ctx.arena, "/auth/callback?token={s}&next=%2Fdevelopers", .{try http.encode(ctx.arena, token)}));
    }
    if (token.len == 0) return ctx.redirect("/");
    if (verify(ctx.arena, token) == null) {
        try clearCookies(ctx);
        return ctx.redirect("/?auth=failed");
    }
    for ([_][]const u8{ "auth_token", "wufour_token" }) |n| try ctx.setCookie(n, token, 24 * 3600);
    return ctx.redirect(next orelse "/");
}

/// GET|POST /auth/logout
pub fn logout(ctx: *http.Context) !void {
    if (ctx.cookie("auth_token") orelse ctx.cookie("wufour_token")) |token| {
        a_.app.wufour.logout(ctx.arena, token);
    }
    try clearCookies(ctx);
    const wants_json = (if (ctx.header("x-requested-with")) |x| std.ascii.eqlIgnoreCase(x, "xmlhttprequest") else false) or
        (if (ctx.header("accept")) |acc| std.mem.indexOf(u8, acc, "json") != null else false);
    if (wants_json) return ctx.sendJson(.ok, .{ .ok = true });
    return ctx.redirect("/");
}

/// GET /developers: the console page with the signed-in user (or null) injected.
pub fn developers(ctx: *http.Context) !void {
    // The zui console (developers.html of the web build), else Maps-js's page.
    var html = publicFile(ctx, "developers.html") catch publicFile(ctx, "markup/developers.html") catch return ctx.text(.internal_server_error, "Internal Server Error");
    try ctx.setHeader("cache-control", "no-cache");
    var injected: ?struct { userId: ?[]const u8, username: ?[]const u8, role: []const u8 } = null;
    if (tokenOf(ctx)) |token| {
        if (verify(ctx.arena, token)) |u| {
            injected = .{ .userId = u.userId, .username = u.username orelse u.email, .role = u.role };
        } else try clearCookies(ctx);
    }
    var json: std.Io.Writer.Allocating = .init(ctx.arena);
    try std.json.Stringify.value(injected, .{}, &json.writer);
    // Safe inside <script>: no "</script>" can close the tag early.
    const safe = try std.mem.replaceOwned(u8, ctx.arena, json.written(), "</", "<\\/");
    const script = try std.fmt.allocPrint(ctx.arena, "<script>window.__USER__ = {s};</script>\n", .{safe});
    if (std.mem.indexOf(u8, html, "</head>")) |i| {
        html = try std.mem.concat(ctx.arena, u8, &.{ html[0..i], script, html[i..] });
    } else html = try std.mem.concat(ctx.arena, u8, &.{ script, html });
    return ctx.send(.ok, "text/html; charset=utf-8", html);
}

// ---- Developer console API ----------------------------------------------------------------

/// GET /api/developer/keys: the user's active keys with today's and 30 days' usage.
/// GET /api/developer/me: the signed-in Wufour user, or null.
pub fn me(ctx: *http.Context) !void {
    try ctx.setHeader("cache-control", "no-store");
    const u = currentUser(ctx) orelse return ctx.sendJson(.ok, .{ .success = true, .user = @as(?u8, null) });
    return ctx.sendJson(.ok, .{ .success = true, .user = .{ .username = u.username orelse u.email, .role = u.role } });
}

pub fn listKeys(ctx: *http.Context) !void {
    const user = currentUser(ctx) orelse return a_.fail(ctx, .unauthorized, "Not authenticated");
    const user_id = user.userId orelse return a_.fail(ctx, .unauthorized, "Not authenticated");
    const a = ctx.arena;
    var cursor = try a_.app.collection("apiKeys").find(a, .{ .userId = user_id, .status = "active" }, .{
        .projection = try mongo.bson.encode(a, .{ .key = 1, .appName = 1, .createdAt = 1 }),
        .sort = try mongo.bson.encode(a, .{ .createdAt = -1 }),
    });
    const docs = try cursor.all();

    var day_buf: [10]u8 = undefined;
    const today = try a.dupe(u8, a_.today(&day_buf));
    var since_buf: [10]u8 = undefined;
    const since = a_.dayOf(&since_buf, a_.nowMs() - 29 * 86_400_000);

    var key_list: std.ArrayList([]const u8) = .empty;
    for (docs) |d| try key_list.append(a, d.getString("key") orelse "");
    var usage_rows: []mongo.bson.Doc = &.{};
    if (key_list.items.len > 0) {
        var uc = try a_.app.collection("usage").find(a, .{ .key = .{ .@"$in" = key_list.items }, .day = .{ .@"$gte" = since } }, .{});
        usage_rows = try uc.all();
    }

    var out: std.Io.Writer.Allocating = .init(a);
    var w: std.json.Stringify = .{ .writer = &out.writer };
    try w.beginObject();
    try w.objectField("success");
    try w.write(true);
    try w.objectField("keys");
    try w.beginArray();
    for (docs) |d| {
        const k = d.getString("key") orelse "";
        try w.beginObject();
        try w.objectField("_id");
        try writeValue(&w, d.get("_id"));
        try w.objectField("key");
        try w.write(k);
        try w.objectField("appName");
        try w.write(d.getString("appName"));
        try w.objectField("createdAt");
        try writeValue(&w, d.get("createdAt"));

        var today_n: i64 = 0;
        var total: i64 = 0;
        var by: std.StringArrayHashMapUnmanaged(i64) = .empty;
        for (usage_rows) |row| {
            if (!std.mem.eql(u8, row.getString("key") orelse "", k)) continue;
            const counts = row.getDoc("counts") orelse continue;
            var it = counts.iterator();
            while (try it.next()) |e| {
                const n = e.value.asInt() orelse continue;
                total += n;
                if (std.mem.eql(u8, row.getString("day") orelse "", today)) today_n += n;
                const gop = try by.getOrPut(a, e.key);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += n;
            }
        }
        try w.objectField("usage");
        try w.beginObject();
        try w.objectField("today");
        try w.write(today_n);
        try w.objectField("last30Days");
        try w.write(total);
        try w.objectField("byEndpoint");
        try w.beginObject();
        var bi = by.iterator();
        while (bi.next()) |e| {
            try w.objectField(e.key_ptr.*);
            try w.write(e.value_ptr.*);
        }
        try w.endObject();
        try w.endObject();
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
    return ctx.send(.ok, "application/json", out.written());
}

/// ObjectIds as hex strings and dates as ISO text, the way Express sends them.
fn writeValue(w: *std.json.Stringify, v: ?mongo.bson.Value) !void {
    const value = v orelse return w.write(null);
    switch (value) {
        .object_id => |id| try w.write(&id.toHex()),
        .datetime => |d| {
            var buf: [24]u8 = undefined;
            try w.write(isoTime(&buf, d.ms));
        },
        .string => |s| try w.write(s),
        else => try w.write(null),
    }
}

/// "2026-10-11T12:00:00.000Z"
pub fn isoTime(buf: *[24]u8, ms: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(ms, 1000)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), @as(u64, @intCast(@mod(ms, 1000))),
    }) catch unreachable;
}

/// POST /api/developer/keys/create { appName }
pub fn createKey(ctx: *http.Context) !void {
    const user = currentUser(ctx) orelse return a_.fail(ctx, .unauthorized, "Not authenticated");
    const user_id = user.userId orelse return a_.fail(ctx, .unauthorized, "Not authenticated");
    const body = ctx.json(struct { appName: ?std.json.Value = null }) catch return a_.fail(ctx, .bad_request, "Invalid JSON");
    const name_raw = if (body.appName) |v| (if (v == .string) v.string else "") else "";
    const name = std.mem.trim(u8, name_raw, " \t\r\n");
    if (name.len < 2 or name.len > 80) return a_.fail(ctx, .bad_request, "App name is required (2 to 80 characters)");

    const key = try std.fmt.allocPrint(ctx.arena, "wf_maps_live_{s}", .{try a_.randomHex(ctx.arena, 32)});
    const created = a_.nowMs();
    const id = try a_.app.collection("apiKeys").insertOne(ctx.arena, .{
        .userId = user_id,
        .appName = name,
        .key = key,
        .status = "active",
        .createdAt = mongo.bson.DateTime{ .ms = created },
    });
    var buf: [24]u8 = undefined;
    return ctx.sendJson(.ok, .{ .success = true, .key = .{
        .userId = user_id,
        .appName = name,
        .key = key,
        .status = "active",
        .createdAt = isoTime(&buf, created),
        ._id = &id.object_id.toHex(),
    } });
}

/// POST /api/developer/keys/revoke { key }
pub fn revokeKey(ctx: *http.Context) !void {
    const user = currentUser(ctx) orelse return a_.fail(ctx, .unauthorized, "Not authenticated");
    const user_id = user.userId orelse return a_.fail(ctx, .unauthorized, "Not authenticated");
    const body = ctx.json(struct { key: ?std.json.Value = null }) catch return a_.fail(ctx, .bad_request, "Invalid JSON");
    const key = if (body.key) |v| (if (v == .string and v.string.len > 0) v.string else null) else null;
    const k = key orelse return a_.fail(ctx, .bad_request, "Key string required");
    const r = try a_.app.collection("apiKeys").updateOne(ctx.arena, .{ .userId = user_id, .key = k }, .{
        .@"$set" = .{ .status = "revoked", .revokedAt = a_.now() },
    }, .{});
    if (r.modified > 0) {
        keys.forget(k); // stop it working now, not when the cache expires
        return ctx.sendJson(.ok, .{ .success = true, .message = "Key revoked successfully" });
    }
    return a_.fail(ctx, .not_found, "Key not found or already revoked");
}

test isoTime {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("2026-10-11T12:00:00.000Z", isoTime(&buf, 1_791_720_000_000));
}
