//! Wufour Maps server. Step 2: health check and the web app on the zig-core HTTP server,
//! over plain HTTP or TLS 1.3. Step 3 ports the Maps-js API (routing, search, tiles, keys,
//! live tracking).
//!
//! maps-server [--port 5105] [--web zig-out/web]
//!             [--tls-dev]                     self-signed certificate for localhost
//!             [--cert chain.pem --key key.pem]

const std = @import("std");
const http = @import("http");

var web_dir: []const u8 = "zig-out/web";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var port: u16 = 5105;
    var tls_dev = false;
    var cert_path: ?[]const u8 = null;
    var key_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--tls-dev")) {
            tls_dev = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingValue;
        i += 1;
        if (std.mem.eql(u8, a, "--port")) port = try std.fmt.parseUnsigned(u16, args[i], 10);
        if (std.mem.eql(u8, a, "--web")) web_dir = args[i];
        if (std.mem.eql(u8, a, "--cert")) cert_path = args[i];
        if (std.mem.eql(u8, a, "--key")) key_path = args[i];
    }

    var store: ?http.CertStore = null;
    if (cert_path != null and key_path != null) {
        const cwd = std.Io.Dir.cwd();
        const chain = try cwd.readFileAlloc(io, cert_path.?, arena, .limited(1 << 20));
        const key = try cwd.readFileAlloc(io, key_path.?, arena, .limited(1 << 20));
        store = .{ .certificates = try arena.dupe(http.tls.cert.Certificate, &.{try http.tls.cert.loadPem(arena, chain, key)}) };
    } else if (tls_dev) {
        const key = http.tls.cert.KeyPair.generate(io);
        const now = std.Io.Timestamp.now(io, .real).toSeconds();
        const der = try http.tls.cert.selfSigned(io, arena, key, &.{"localhost"}, now - 3600, now + 30 * 86400);
        store = .{ .certificates = try arena.dupe(http.tls.cert.Certificate, &.{try http.tls.cert.Certificate.init(try arena.dupe([]const u8, &.{der}), key)}) };
    }

    var router: http.Router = .init(init.gpa);
    defer router.deinit();
    try router.get("/healthz", healthz);
    router.fallback = web;

    std.log.info("maps-server on {s}://localhost:{d} (web: {s})", .{ if (store != null) "https" else "http", port, web_dir });
    try http.serve(io, init.gpa, .{
        .address = try .parse("127.0.0.1", port),
        .router = &router,
        .tls = if (store) |*s| s else null,
    });
}

fn healthz(ctx: *http.Context) !void {
    try ctx.sendJson(.ok, .{ .ok = true });
}

fn web(ctx: *http.Context) !void {
    if (ctx.method != .GET and ctx.method != .HEAD) return ctx.fail(.not_found, "Not found");
    try http.serveDir(ctx, web_dir, true);
}
