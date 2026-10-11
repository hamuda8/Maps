//! Wufour Maps server. Step 2: health check and the web app on the zig-core HTTP server,
//! over plain HTTP or TLS 1.3. Step 3 ports the Maps-js API (routing, search, tiles, keys,
//! live tracking).
//!
//! maps-server [--port 5105] [--web zig-out/web]
//!             [--tls-dev]                     self-signed certificate for localhost
//!             [--cert chain.pem --key key.pem]
//!             [--acme maps.example.com[,www.maps.example.com] --acme-dir DIR
//!              [--acme-email you@example.com] [--acme-staging] [--http-port 80]]
//!
//! With --acme the server answers Let's Encrypt on --http-port (redirecting everything else to
//! HTTPS), keeps a certificate in --acme-dir, renews it, and serves HTTPS on --port.

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
    var acme_names: ?[]const u8 = null;
    var acme_dir: []const u8 = "acme";
    var acme_email: ?[]const u8 = null;
    var acme_staging = false;
    var http_port: u16 = 80;
    var listen_host: []const u8 = "127.0.0.1";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--tls-dev")) {
            tls_dev = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--acme-staging")) {
            acme_staging = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingValue;
        i += 1;
        if (std.mem.eql(u8, a, "--port")) port = try std.fmt.parseUnsigned(u16, args[i], 10);
        if (std.mem.eql(u8, a, "--web")) web_dir = args[i];
        if (std.mem.eql(u8, a, "--cert")) cert_path = args[i];
        if (std.mem.eql(u8, a, "--key")) key_path = args[i];
        if (std.mem.eql(u8, a, "--acme")) acme_names = args[i];
        if (std.mem.eql(u8, a, "--acme-dir")) acme_dir = args[i];
        if (std.mem.eql(u8, a, "--acme-email")) acme_email = args[i];
        if (std.mem.eql(u8, a, "--http-port")) http_port = try std.fmt.parseUnsigned(u16, args[i], 10);
        if (std.mem.eql(u8, a, "--listen")) listen_host = args[i];
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

    // Let's Encrypt: port 80 answers challenges first, then the certificate is loaded or obtained.
    var challenges: http.tls.acme.Challenges = .{ .gpa = init.gpa };
    var acme_store: http.CertStore = .{ .certificates = &.{} };
    var manager: http.tls.acme.Manager = undefined;
    var plain_router: http.Router = .init(init.gpa);
    defer plain_router.deinit();
    var plain_server: ?std.Io.Future(anyerror!void) = null;
    defer if (plain_server) |*f| {
        _ = f.cancel(io) catch {};
    };
    var renewals: ?std.Io.Future(void) = null;
    defer if (renewals) |*f| f.cancel(io);
    if (acme_names) |list| {
        var names: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |n| try names.append(arena, n);
        http.acme_challenges = &challenges;
        plain_router.fallback = http.redirectToHttps;
        plain_server = try io.concurrent(servePlain, .{ io, init.gpa, &plain_router, listen_host, http_port });
        manager = .{
            .io = io,
            .gpa = init.gpa,
            .dir = acme_dir,
            .names = names.items,
            .directory_url = if (acme_staging) http.tls.acme.lets_encrypt_staging else http.tls.acme.lets_encrypt,
            .contact_email = acme_email,
            .challenges = &challenges,
            .store = &acme_store,
        };
        try manager.ensure();
        renewals = try io.concurrent(http.tls.acme.Manager.renewLoop, .{&manager});
        store = acme_store;
        if (port == 5105) port = 443;
    }

    var router: http.Router = .init(init.gpa);
    defer router.deinit();
    try router.get("/healthz", healthz);
    router.fallback = web;

    std.log.info("maps-server on {s}://localhost:{d} (web: {s})", .{ if (store != null) "https" else "http", port, web_dir });
    try http.serve(io, init.gpa, .{
        .address = try .parse(listen_host, port),
        .router = &router,
        .tls = if (acme_names != null) &acme_store else if (store) |*s| s else null,
    });
}

fn servePlain(io: std.Io, gpa: std.mem.Allocator, router: *const http.Router, host: []const u8, port: u16) anyerror!void {
    try http.serve(io, gpa, .{ .address = try .parse(host, port), .router = router });
}

fn healthz(ctx: *http.Context) !void {
    try ctx.sendJson(.ok, .{ .ok = true });
}

fn web(ctx: *http.Context) !void {
    if (ctx.method != .GET and ctx.method != .HEAD) return ctx.fail(.not_found, "Not found");
    try http.serveDir(ctx, web_dir, true);
}
