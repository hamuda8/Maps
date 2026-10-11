//! Wufour Maps server (step 0 spike): serves the web build and /healthz. Step 2 replaces this
//! with the zig-core http stack (own TLS 1.3, router, WebSocket) and step 3 ports the Maps-js API.
//!
//! maps-server [--port 5105] [--web zig-out/web]

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var port: u16 = 5105;
    var web_dir: []const u8 = "zig-out/web";
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--port")) port = try std.fmt.parseUnsigned(u16, args[i + 1], 10);
        if (std.mem.eql(u8, args[i], "--web")) web_dir = args[i + 1];
    }

    const address = try Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("maps-server listening on http://127.0.0.1:{d} (web: {s})", .{ port, web_dir });

    while (true) {
        const stream = listener.accept(io) catch |err| {
            std.log.warn("accept: {t}", .{err});
            continue;
        };
        serve(io, arena, stream, web_dir) catch |err| std.log.warn("connection: {t}", .{err});
    }
}

fn serve(io: Io, arena: std.mem.Allocator, stream: Io.net.Stream, web_dir: []const u8) !void {
    defer stream.close(io);
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var http = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = http.receiveHead() catch return;
        const target = request.head.target;
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

        if (std.mem.eql(u8, path, "/healthz")) {
            try request.respond("{\"ok\":true}", .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
            continue;
        }

        const file = if (std.mem.eql(u8, path, "/")) "index.html" else path[1..];
        if (std.mem.indexOf(u8, file, "..") != null) {
            try request.respond("", .{ .status = .bad_request });
            continue;
        }
        const full = try std.fs.path.join(arena, &.{ web_dir, file });
        const body = Io.Dir.cwd().readFileAlloc(io, full, arena, .limited(32 * 1024 * 1024)) catch {
            try request.respond("not found", .{ .status = .not_found });
            continue;
        };
        try request.respond(body, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = contentType(file) },
            .{ .name = "cache-control", .value = "no-cache" },
        } });
    }
}

fn contentType(file: []const u8) []const u8 {
    const ext = std.fs.path.extension(file);
    const types = [_]struct { []const u8, []const u8 }{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".wasm", "application/wasm" },
        .{ ".json", "application/json" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
    };
    for (types) |t| if (std.mem.eql(u8, ext, t[0])) return t[1];
    return "application/octet-stream";
}

test contentType {
    try std.testing.expectEqualStrings("application/wasm", contentType("app.wasm"));
    try std.testing.expectEqualStrings("text/html; charset=utf-8", contentType("index.html"));
}
