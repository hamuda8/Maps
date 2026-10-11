//! Wufour Maps server. Step 2: health check and the web app on the zig-core HTTP server.
//! Step 3 ports the Maps-js API (routing, search, tiles, keys, live tracking).
//!
//! maps-server [--port 5105] [--web zig-out/web]

const std = @import("std");
const http = @import("http");

var web_dir: []const u8 = "zig-out/web";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var port: u16 = 5105;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--port")) port = try std.fmt.parseUnsigned(u16, args[i + 1], 10);
        if (std.mem.eql(u8, args[i], "--web")) web_dir = args[i + 1];
    }

    var router: http.Router = .init(init.gpa);
    defer router.deinit();
    try router.get("/healthz", healthz);
    router.fallback = web;

    std.log.info("maps-server on http://127.0.0.1:{d} (web: {s})", .{ port, web_dir });
    try http.serve(init.io, init.gpa, .{ .address = try .parse("127.0.0.1", port), .router = &router });
}

fn healthz(ctx: *http.Context) !void {
    try ctx.sendJson(.ok, .{ .ok = true });
}

fn web(ctx: *http.Context) !void {
    if (ctx.method != .GET and ctx.method != .HEAD) return ctx.fail(.not_found, "Not found");
    try http.serveDir(ctx, web_dir, true);
}
