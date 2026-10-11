//! The map inside the Wufour Maps JS library (sdk/wufour-maps.js), which other sites load. The
//! library drives it with JSON commands (hostMessage) and hears back through fx.post: the
//! camera after every change (to place its HTML markers), clicks, and when moving starts and
//! ends. Flat and north-up, as the library always was; tiles, colours and lines as the map page.

const std = @import("std");
const zui = @import("zui");
const map = @import("map");

pub const panic = zui.panic;
pub const edge_to_edge = true;
pub const boot: Msg = .boot;

comptime {
    zui.exportApp(@This());
}

const gpa = zui.allocator;
/// The Maps server, from the library's own address (env.link): the page itself is another site.
const tile_path = "/tiles/{z}/{x}/{y}.png";

pub const Msg = union(enum) {
    boot,
    frame,
    map: zui.Pointer,
    /// A command from the library (raw JSON, valid during update).
    command: []const u8,
};

const Line = struct {
    points: []map.LatLng,
    color: zui.Color,
    width: f32,
    opacity: f32,
    dash: [2]f32,
};

pub const State = struct {
    map: map.State,
    lines: std.ArrayList(Line) = .empty,
    /// What the library last heard, to tell it only of changes.
    sent: ?map.Camera = null,
    sent_w: f32 = 0,
    sent_h: f32 = 0,
    /// A move (camera changing) is under way, and whether the user started it.
    in_move: bool = false,
    move_by_user: bool = false,
    /// What moved the map last: the user's fingers, mouse or wheel, or a command.
    last_by_user: bool = false,
    fingers_down: u8 = 0,
    server: [256]u8 = undefined,
    server_len: usize = 0,
};

pub fn init() State {
    return .{ .map = .{
        .camera = .{ .center = .{ .lat = 33.5138, .lng = 36.2765 }, .zoom = 14 },
        .can_rotate = false,
        .can_tilt = false,
    } };
}

pub fn hostMessage(json: []const u8) ?Msg {
    return .{ .command = json };
}

const Command = struct {
    cmd: []const u8 = "",
    lat: ?f64 = null,
    lng: ?f64 = null,
    zoom: ?f64 = null,
    animate: bool = true,
    duration: f64 = 700,
    delta: f64 = 0,
    points: []const [2]f64 = &.{},
    padding: f32 = 0,
    max_zoom: ?f64 = null,
    lines: []const struct {
        points: []const [2]f64 = &.{},
        color: []const u8 = "#2563eb",
        weight: f32 = 6,
        opacity: f32 = 0.8,
        dash: ?[2]f32 = null,
    } = &.{},
    pan: ?bool = null,
    zoom_enabled: ?bool = null,
};

pub fn update(s: *State, msg: Msg, env: zui.Env, fx: zui.Fx(Msg)) void {
    s.map.setViewport(env.width, env.height);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    switch (msg) {
        .boot => {
            const n = @min(env.link.len, s.server.len);
            @memcpy(s.server[0..n], env.link[0..n]);
            s.server_len = n;
        },
        .frame => _ = s.map.step(env.time_ms),
        .map => |p| {
            switch (p.kind) {
                .down => s.fingers_down +|= 1,
                .up, .cancel => s.fingers_down -|= 1,
                else => {},
            }
            s.last_by_user = true;
            const g = s.map.handle(p);
            if (g.tap) |at| if (s.map.view().toMap(at[0], at[1])) |ll| {
                fx.post(std.fmt.allocPrint(arena, "{{\"event\":\"click\",\"lat\":{d},\"lng\":{d}}}", .{ ll.lat, ll.lng }) catch return);
            };
        },
        .command => |json| command(s, json, arena),
    }
    report(s, env, fx, arena);
}

fn command(s: *State, json: []const u8, arena: std.mem.Allocator) void {
    const c = std.json.parseFromSliceLeaky(Command, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return;
    const target: ?map.LatLng = if (c.lat != null and c.lng != null) .{ .lat = c.lat.?, .lng = c.lng.? } else null;
    const is = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;
    s.last_by_user = false;
    if (is(c.cmd, "view")) {
        const to: map.CameraTarget = .{ .center = target, .zoom = c.zoom };
        if (c.animate) s.map.easeTo(to, c.duration) else {
            s.map.animation = null;
            if (target) |t| s.map.camera.center = t;
            if (c.zoom) |z| s.map.camera.zoom = std.math.clamp(z, s.map.minZoom(), map.max_zoom);
        }
    } else if (is(c.cmd, "fly")) {
        if (c.duration <= 0) {
            if (target) |t| s.map.camera.center = t;
            if (c.zoom) |z| s.map.camera.zoom = z;
        } else s.map.flyTo(.{ .center = target, .zoom = c.zoom }, c.duration);
    } else if (is(c.cmd, "zoomBy")) {
        s.map.easeTo(.{ .zoom = s.map.camera.zoom + c.delta }, if (c.animate) 250 else 1);
    } else if (is(c.cmd, "fit")) {
        const pts = arena.alloc(map.LatLng, c.points.len) catch return;
        for (c.points, pts) |p, *o| o.* = .{ .lat = p[0], .lng = p[1] };
        s.map.fitBounds(pts, .{ .top = c.padding, .bottom = c.padding, .left = c.padding, .right = c.padding }, if (c.animate) 700 else 1);
        if (c.max_zoom) |mz| if (s.map.animation) |*a| {
            a.to.zoom = @min(a.to.zoom, mz);
            a.arc = 0;
        };
    } else if (is(c.cmd, "lines")) {
        for (s.lines.items) |l| gpa.free(l.points);
        s.lines.clearRetainingCapacity();
        for (c.lines) |l| {
            const pts = gpa.alloc(map.LatLng, l.points.len) catch continue;
            for (l.points, pts) |p, *o| o.* = .{ .lat = p[0], .lng = p[1] };
            // MapLibre's dash lengths are in line widths.
            const dash: [2]f32 = if (l.dash) |d| .{ @max(0.1, d[0] * l.weight), d[1] * l.weight } else .{ 0, 0 };
            s.lines.append(gpa, .{
                .points = pts,
                .color = zui.Color.parseHex(l.color) catch zui.Color.hex("#2563eb"),
                .width = l.weight,
                .opacity = l.opacity,
                .dash = dash,
            }) catch gpa.free(pts);
        }
    } else if (is(c.cmd, "interactive")) {
        if (c.pan) |v| s.map.can_pan = v;
        if (c.zoom_enabled) |v| s.map.can_zoom = v;
    }
}

/// Tells the library what changed: the camera (it places its markers with it), and when a
/// move starts and ends (Taazur's picker listens for those).
fn report(s: *State, env: zui.Env, fx: zui.Fx(Msg), arena: std.mem.Allocator) void {
    const c = s.map.camera;
    const changed = s.sent == null or !std.meta.eql(s.sent.?, c) or s.sent_w != env.width or s.sent_h != env.height;
    const camera_moved = s.sent != null and !std.meta.eql(s.sent.?, c);
    // A move starts when the camera changes (a tap or a still press is not one) ...
    if (camera_moved and !s.in_move) {
        s.in_move = true;
        s.move_by_user = s.last_by_user;
        fx.post(std.fmt.allocPrint(arena, "{{\"event\":\"movestart\",\"user\":{}}}", .{s.move_by_user}) catch return);
    }
    if (changed) {
        s.sent = c;
        s.sent_w = env.width;
        s.sent_h = env.height;
        fx.post(std.fmt.allocPrint(arena, "{{\"event\":\"camera\",\"lat\":{d},\"lng\":{d},\"zoom\":{d},\"width\":{d},\"height\":{d}}}", .{ c.center.lat, c.center.lng, c.zoom, env.width, env.height }) catch return);
    }
    // ... and ends when it rests: no animation, no finger down.
    if (s.in_move and !s.map.moving() and s.fingers_down == 0) {
        s.in_move = false;
        fx.post(std.fmt.allocPrint(arena, "{{\"event\":\"moveend\",\"user\":{}}}", .{s.move_by_user}) catch return);
    }
}

fn onMap(p: zui.Pointer) Msg {
    return .{ .map = p };
}

pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
    var m = s.map;
    m.setViewport(ui.env.width, ui.env.height);
    if (m.moving()) ui.requestFrame(.frame);
    var routes: std.ArrayList(map.Route) = .empty;
    for (s.lines.items) |l| routes.append(ui.arena(), .{ .points = l.points, .color = l.color, .width = l.width, .opacity = l.opacity, .dash = l.dash }) catch {};
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    const tiles = std.fmt.allocPrint(ui.arena(), "{s}{s}", .{ s.server[0..s.server_len], tile_path }) catch return;
    map.draw(Msg, ui, &m, .{ .tile_url = tiles, .on_pointer = onMap, .routes = routes.items });
    ui.end();
}

const D = zui.host.Driver(@This());
const testing = std.testing;

test "commands move the map and the library hears the camera, clicks and moves" {
    D.start(400, 300);
    defer D.reset();
    D.R.hostMessage("{\"cmd\":\"view\",\"lat\":3.15,\"lng\":101.7,\"zoom\":15,\"animate\":false}");
    try testing.expect(std.mem.indexOf(u8, zui.host.posted.items, "\"event\":\"camera\",\"lat\":3.15,\"lng\":101.7,\"zoom\":15") != null);
    D.R.hostMessage("{\"cmd\":\"lines\",\"lines\":[{\"points\":[[3.15,101.7],[3.16,101.71]],\"color\":\"#ff0000\",\"weight\":4,\"dash\":[2,2]}]}");
    try testing.expectEqual(@as(usize, 1), D.R.appState().lines.items.len);
    try testing.expectEqual([2]f32{ 8, 8 }, D.R.appState().lines.items[0].dash);
    // A tap is a click at that point (the centre here), and not a move.
    zui.host.posted.clearRetainingCapacity();
    D.pointer(.{ .kind = .down, .id = 1, .x = 200, .y = 150, .time_ms = 0 });
    D.pointer(.{ .kind = .up, .id = 1, .x = 200, .y = 150, .time_ms = 100 });
    try testing.expect(std.mem.indexOf(u8, zui.host.posted.items, "\"event\":\"click\",\"lat\":3.15") != null);
    try testing.expect(std.mem.indexOf(u8, zui.host.posted.items, "move") == null);
    // A user drag: movestart and moveend say so.
    D.pointer(.{ .kind = .down, .id = 1, .x = 200, .y = 150, .time_ms = 1000 });
    D.pointer(.{ .kind = .move, .id = 1, .x = 150, .y = 150, .time_ms = 1300 });
    D.pointer(.{ .kind = .up, .id = 1, .x = 150, .y = 150, .time_ms = 1600 });
    while (D.frame()) {}
    try testing.expect(std.mem.indexOf(u8, zui.host.posted.items, "\"event\":\"moveend\",\"user\":true") != null);
    // Interaction off: a drag no longer moves it.
    D.R.hostMessage("{\"cmd\":\"interactive\",\"pan\":false,\"zoom_enabled\":false}");
    const before = D.R.appState().map.camera.center;
    D.pointer(.{ .kind = .down, .id = 1, .x = 200, .y = 150, .time_ms = 3000 });
    D.pointer(.{ .kind = .move, .id = 1, .x = 100, .y = 150, .time_ms = 3100 });
    D.pointer(.{ .kind = .up, .id = 1, .x = 100, .y = 150, .time_ms = 3200 });
    try testing.expectEqual(before, D.R.appState().map.camera.center);
}
