//! Map tile proxy with a disk cache: GET /tiles/:z/:x/:y.png. Every map loads tiles from here.
//! Each tile is fetched upstream at most once per 30 days, then served from disk; behind
//! Cloudflare the long Cache-Control lets the edge serve most requests. The cache layout and
//! source ids are the same as Maps-js, so the two share one cache folder.

const std = @import("std");
const http = @import("http");
const Io = std.Io;
const a_ = @import("app.zig");
const settings = @import("settings.zig");

const cache_days = 30;
const prune_days = 90;
const max_zoom = 19;

/// At most this many requests to the tile server at once.
var upstream_slots: Io.Semaphore = .{ .permits = 6 };

/// Short id of the upstream URL (first 10 hex digits of its SHA-1): part of the tile URL and the
/// cache folder, so changing the tile server never serves the old server's tiles.
pub fn sourceId(url: []const u8) [10]u8 {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(url, &digest, .{});
    return std.fmt.bytesToHex(digest[0..5].*, .lower);
}

fn typeOf(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".jpg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    return "image/png";
}

fn extOf(content_type: []const u8) []const u8 {
    if (std.mem.indexOf(u8, content_type, "jpeg") != null) return ".jpg";
    if (std.mem.indexOf(u8, content_type, "webp") != null) return ".webp";
    return ".png";
}

const Cached = struct { path: []const u8, fresh: bool };

fn readCached(arena: std.mem.Allocator, base: []const u8) ?Cached {
    const io = a_.app.io;
    for ([_][]const u8{ ".png", ".jpg", ".webp" }) |ext| {
        const path = std.mem.concat(arena, u8, &.{ base, ext }) catch return null;
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        const age_ms = a_.nowMs() - st.mtime.toMilliseconds();
        return .{ .path = path, .fresh = age_ms < cache_days * 86_400_000 };
    }
    return null;
}

/// GET /tiles/:z/:x/:yfile ("2.png")
pub fn serve(ctx: *http.Context) !void {
    const z = std.fmt.parseUnsigned(u32, ctx.param("z") orelse "", 10) catch return notFound(ctx);
    const x = std.fmt.parseUnsigned(u32, ctx.param("x") orelse "", 10) catch return notFound(ctx);
    const yfile = ctx.param("y") orelse "";
    if (!std.mem.endsWith(u8, yfile, ".png")) return notFound(ctx);
    const y = std.fmt.parseUnsigned(u32, yfile[0 .. yfile.len - 4], 10) catch return notFound(ctx);
    if (z > max_zoom or x >= (@as(u32, 1) << @intCast(z)) or y >= (@as(u32, 1) << @intCast(z))) return notFound(ctx);

    const s = settings.get(ctx.arena);
    const id = sourceId(s.tile_url);
    const base = try std.fs.path.join(ctx.arena, &.{ a_.app.config.tile_cache_dir, &id, try std.fmt.allocPrint(ctx.arena, "{d}", .{z}), try std.fmt.allocPrint(ctx.arena, "{d}", .{x}), try std.fmt.allocPrint(ctx.arena, "{d}", .{y}) });
    const cwd = Io.Dir.cwd();
    const io = a_.app.io;

    const cached = readCached(ctx.arena, base);
    if (cached) |c| if (c.fresh) {
        if (cwd.readFileAlloc(io, c.path, ctx.arena, .limited(4 << 20))) |body| return send(ctx, body, typeOf(c.path)) else |_| {}
    };

    var url = s.tile_url;
    inline for (.{ .{ "{z}", z }, .{ "{x}", x }, .{ "{y}", y } }) |r| {
        url = try std.mem.replaceOwned(u8, ctx.arena, url, r[0], try std.fmt.allocPrint(ctx.arena, "{d}", .{r[1]}));
    }
    url = try std.mem.replaceOwned(u8, ctx.arena, url, "{s}", "a");

    upstream_slots.waitUncancelable(io);
    const res = a_.upstream(ctx.arena, .GET, url, null, &.{.{ .name = "user-agent", .value = "WufourMaps/1.0 tile cache (+https://wufour.com)" }});
    upstream_slots.post(io);

    if (res) |tile| {
        if (@backingInt(tile.status) < 300) {
            const ct = if (tile.content_type.len > 0) tile.content_type else "image/png";
            if (std.fs.path.dirname(base)) |dir| cwd.createDirPath(io, dir) catch {};
            cwd.writeFile(io, .{ .sub_path = try std.mem.concat(ctx.arena, u8, &.{ base, extOf(ct) }), .data = tile.body }) catch |err| std.log.warn("tile cache write: {t}", .{err});
            return send(ctx, tile.body, ct);
        }
        if (tile.status == .not_found and cached == null) return notFound(ctx);
    } else |_| {}

    // Tile server down or slow: an old copy beats a hole in the map.
    if (cached) |c| if (cwd.readFileAlloc(io, c.path, ctx.arena, .limited(4 << 20))) |body| return send(ctx, body, typeOf(c.path)) else |_| {};
    ctx.responded = true;
    try ctx.request.respond("", .{ .status = .bad_gateway, .extra_headers = ctx.response_headers.items });
}

fn send(ctx: *http.Context, body: []const u8, content_type: []const u8) !void {
    try ctx.setHeader("cache-control", "public, max-age=604800");
    return ctx.send(.ok, content_type, body);
}

fn notFound(ctx: *http.Context) !void {
    ctx.responded = true;
    try ctx.request.respond("", .{ .status = .not_found, .extra_headers = ctx.response_headers.items });
}

/// Daily: deletes tiles nobody has needed for 90 days, so the cache only holds areas people look
/// at. Run as its own task.
pub fn pruneLoop() void {
    while (true) {
        a_.app.io.sleep(.fromSeconds(86400), .awake) catch return;
        prune();
    }
}

fn prune() void {
    const app = a_.app;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    var dir = Io.Dir.cwd().openDir(app.io, app.config.tile_cache_dir, .{ .iterate = true }) catch return;
    defer dir.close(app.io);
    var walker = dir.walk(arena.allocator()) catch return;
    defer walker.deinit();
    const cutoff = a_.nowMs() - prune_days * 86_400_000;
    while (walker.next(app.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const st = entry.dir.statFile(app.io, entry.basename, .{}) catch continue;
        if (st.mtime.toMilliseconds() < cutoff) entry.dir.deleteFile(app.io, entry.basename) catch {};
    }
}

test sourceId {
    // Same id as Maps-js: crypto.createHash('sha1').update(url).digest('hex').slice(0, 10)
    try std.testing.expectEqualStrings("72ce51dfa6", &sourceId("https://tile.openstreetmap.org/{z}/{x}/{y}.png"));
}
