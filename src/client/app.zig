//! Wufour Maps client: the same code for the web, Android and iOS. A port of Maps-js's map page
//! (public/scripts/routing.js): search with suggestions, directions for five ways of travelling,
//! turn-by-turn navigation with voice, the live position, and pins dropped by tapping the map.

const std = @import("std");
const zui = @import("zui");
const map = @import("map");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const api = @import("api.zig");
const geo = @import("geo.zig");

pub const panic = zui.panic;
/// The map runs under the status and navigation bars; the panels keep clear of them.
pub const edge_to_edge = true;
pub const boot: Msg = .boot;

pub const global_locale = @embedFile("locales/global.json");
pub const locales: []const zui.i18n.Locale = &.{
    .{ .lang = "ar", .json = @embedFile("locales/ar.json") },
};

comptime {
    zui.exportApp(@This());
}

const gpa = zui.allocator;
const t = zui.i18n.t;
const LatLng = geo.LatLng;

const tile_url = api.base ++ "/tiles/{z}/{x}/{y}.png";

const Field = enum(u2) { main, start, dest };

const key_main = zui.key("main-input");
const key_start = zui.key("start-input");
const key_dest = zui.key("dest-input");

/// Text the user edits, owned by the state.
const Text = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    fn get(x: *const Text) []const u8 {
        return x.buf[0..x.len];
    }

    fn set(x: *Text, s: []const u8) void {
        var n = @min(s.len, x.buf.len);
        while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1; // whole characters
        @memcpy(x.buf[0..n], s[0..n]);
        x.len = n;
    }
};

const Suggestion = struct { label: []u8, at: LatLng };

pub const Msg = union(enum) {
    boot,
    frame,
    map: zui.Pointer,
    typed: struct { field: Field, text: []const u8 },
    focused: Field,
    blurred: struct { field: Field, seq: u32 },
    blur_seq: Field,
    search_due: u32,
    searched: zui.Response,
    picked: usize,
    picked_location,
    reversed: zui.Response,
    located: zui.Location,
    routed: zui.Response,
    live_reroute: u32,
    reroute_ready,
    back,
    swap,
    mode: api.Mode,
    start_nav,
    exit_nav,
    recenter,
    zoom_in,
    zoom_out,
    north,
    tilt,
};

const Nav = struct {
    /// Index of the next maneuver.
    step: usize = 1,
    heading: f64 = 0,
    last_raw: ?LatLng = null,
    arrived: bool = false,
    /// "In 200 metres" said for these maneuvers.
    warned: std.StaticBitSet(256) = .empty,
};

const RouteStatus = enum { none, loading, ok, failed };

pub const State = struct {
    map: map.State,
    screen: enum { search, routing } = .search,
    mode: api.Mode = .car,
    main: Text = .{},
    start_text: Text = .{},
    dest_text: Text = .{},
    /// A note in place of the start placeholder ("GPS Unavailable.").
    start_hint: ?[]const u8 = null,
    focused: ?Field = null,
    /// The field whose suggestions are open.
    list_for: ?Field = null,
    blur_seq: u32 = 0,
    suggest: enum { location_only, loading, results, empty, failed } = .location_only,
    suggestions: std.ArrayList(Suggestion) = .empty,
    search_seq: u32 = 0,
    start: ?LatLng = null,
    dest: ?LatLng = null,
    /// The start follows the live position.
    start_live: bool = false,
    live: ?LatLng = null,
    gps: enum { waiting, ok, denied, unavailable } = .waiting,
    /// A field asked for "Your Location" before the first position arrived.
    waiting_for_gps: ?Field = null,
    route: ?api.Route = null,
    route_status: RouteStatus = .none,
    route_error: Text = .{},
    route_seq: u32 = 0,
    route_from: ?LatLng = null,
    reroute_seq: u32 = 0,
    reroute_blocked: bool = false,
    reverse_seq: u32 = 0,
    nav: ?Nav = null,
    /// Opened with ?nav=1: navigation starts once the route is drawn.
    nav_after_route: bool = false,
};

pub fn init() State {
    return .{ .map = .{ .camera = .{ .center = .{ .lat = 33.5138, .lng = 36.2765 }, .zoom = 13 } } };
}

// ---- Update ------------------------------------------------------------------------------

pub fn update(s: *State, msg: Msg, env: zui.Env, fx: zui.Fx(Msg)) void {
    s.map.setViewport(env.width, env.height);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    switch (msg) {
        .boot => {
            fx.watchLocation(onLocated);
            restoreFromLink(s, env, fx, arena);
        },
        .frame => _ = s.map.step(env.time_ms),
        .map => |p| {
            const g = s.map.handle(p);
            if (g.tap) |at| tapMap(s, at, env, fx, arena);
        },
        .typed => |e| typed(s, e.field, e.text, fx),
        .focused => |f| {
            s.focused = f;
            s.blur_seq +%= 1;
            s.list_for = f;
            if (field(s, f).len == 0) s.suggest = .location_only;
        },
        .blurred => |b| if (b.seq == s.blur_seq and s.focused == b.field) {
            s.focused = null;
            s.list_for = null;
        },
        // Hide the list a moment after the field loses focus, so a tap on a suggestion
        // (which takes the focus first) still lands.
        .blur_seq => |f| {
            s.blur_seq +%= 1;
            fx.after(200, .{ .blurred = .{ .field = f, .seq = s.blur_seq } });
        },
        .search_due => |seq| if (seq == s.search_seq) if (s.list_for) |f| {
            const near = s.map.camera.center;
            const url = api.searchUrl(arena, field(s, f), near, zui.i18n.language()) catch return;
            fx.fetch(.{ .url = url, .tag = seq }, onSearched);
        },
        .searched => |r| if (r.tag == s.search_seq) {
            clearSuggestions(s);
            const results = api.parseSearch(arena, r.body) orelse {
                s.suggest = .failed;
                return;
            };
            for (results) |p| {
                const label = gpa.dupe(u8, if (p.label.len > 0) p.label else p.name) catch break;
                s.suggestions.append(gpa, .{ .label = label, .at = .{ .lat = p.lat, .lng = p.lng } }) catch gpa.free(label);
            }
            s.suggest = if (s.suggestions.items.len > 0) .results else .empty;
        },
        .picked => |i| if (i < s.suggestions.items.len) if (s.list_for) |f| {
            const sug = s.suggestions.items[i];
            s.list_for = null;
            pickPlace(s, f, sug.label, sug.at, env, fx, arena);
        },
        .picked_location => if (s.list_for) |f| {
            s.list_for = null;
            if (s.live != null) return useLocation(s, f, env, fx, arena);
            if (s.gps == .denied or s.gps == .unavailable) return gpsUnavailable(s, f);
            s.waiting_for_gps = f;
            textOf(s, f).set(t("Locating..."));
        },
        .reversed => |r| {
            const which: Field = @enumFromInt(@as(u2, @truncate(r.tag)));
            const name = if (r.ok()) api.parseReverse(arena, r.body) else null;
            const target = textOf(s, which);
            // Only if the user has not typed something else meanwhile.
            if (std.mem.eql(u8, target.get(), t("Locating pin..."))) target.set(name orelse t("Dropped Pin"));
            updateLink(s, fx, arena);
        },
        .located => |l| located(s, l, env, fx, arena),
        .routed => |r| routed(s, r, env, fx, arena),
        .live_reroute => |seq| if (seq == s.reroute_seq and s.nav == null and s.dest != null) drawRoute(s, fx, arena, .{ .skip_fit = true }),
        .reroute_ready => s.reroute_blocked = false,
        .back => {
            clearRouting(s);
            s.main.len = 0;
            s.start_text.len = 0;
            s.dest_text.len = 0;
            s.start = null;
            s.dest = null;
            s.start_live = false;
            s.start_hint = null;
            s.screen = .search;
            updateLink(s, fx, arena);
        },
        .swap => {
            s.start_live = false;
            std.mem.swap(?LatLng, &s.start, &s.dest);
            std.mem.swap(Text, &s.start_text, &s.dest_text);
            drawRoute(s, fx, arena, .{});
        },
        .mode => |m| {
            s.mode = m;
            drawRoute(s, fx, arena, .{});
        },
        .start_nav => startNav(s, fx, arena),
        .exit_nav => {
            s.nav = null;
            s.map.easeTo(.{ .pitch = 0, .bearing = 0 }, 1000);
            drawRoute(s, fx, arena, .{});
        },
        .recenter => if (s.live) |p| s.map.flyTo(.{ .center = p, .zoom = 16, .pitch = 0 }, 1200),
        .zoom_in => s.map.easeTo(.{ .zoom = @round(s.map.camera.zoom) + 1 }, 250),
        .zoom_out => s.map.easeTo(.{ .zoom = @round(s.map.camera.zoom) - 1 }, 250),
        .north => s.map.easeTo(.{ .bearing = 0, .pitch = 0 }, 400),
        .tilt => s.map.easeTo(.{ .pitch = if (s.map.camera.pitch > 0) 0 else 55 }, 400),
    }
}

fn onLocated(l: zui.Location) Msg {
    return .{ .located = l };
}
fn onSearched(r: zui.Response) Msg {
    return .{ .searched = r };
}
fn onReversed(r: zui.Response) Msg {
    return .{ .reversed = r };
}
fn onRouted(r: zui.Response) Msg {
    return .{ .routed = r };
}
fn onMain(s: []const u8) Msg {
    return .{ .typed = .{ .field = .main, .text = s } };
}
fn onStart(s: []const u8) Msg {
    return .{ .typed = .{ .field = .start, .text = s } };
}
fn onDest(s: []const u8) Msg {
    return .{ .typed = .{ .field = .dest, .text = s } };
}
fn onMap(p: zui.Pointer) Msg {
    return .{ .map = p };
}

fn textOf(s: *State, f: Field) *Text {
    return switch (f) {
        .main => &s.main,
        .start => &s.start_text,
        .dest => &s.dest_text,
    };
}

fn field(s: *const State, f: Field) []const u8 {
    return switch (f) {
        .main => s.main.get(),
        .start => s.start_text.get(),
        .dest => s.dest_text.get(),
    };
}

fn clearSuggestions(s: *State) void {
    for (s.suggestions.items) |x| gpa.free(x.label);
    s.suggestions.clearRetainingCapacity();
}

/// Waits 300 ms after the last key before searching, as Maps-js does.
fn typed(s: *State, f: Field, text: []const u8, fx: zui.Fx(Msg)) void {
    textOf(s, f).set(text);
    s.list_for = f;
    s.search_seq +%= 1;
    if (std.mem.trim(u8, text, " ").len == 0) {
        s.suggest = .location_only;
        return;
    }
    s.suggest = .loading;
    fx.after(300, .{ .search_due = s.search_seq });
}

/// The text up to the first comma: "Umayyad Square, Damascus" → "Umayyad Square".
fn shortName(label: []const u8) []const u8 {
    return std.mem.trim(u8, label[0 .. std.mem.indexOfScalar(u8, label, ',') orelse label.len], " ");
}

fn pickPlace(s: *State, f: Field, label: []const u8, at: LatLng, env: zui.Env, fx: zui.Fx(Msg), arena: std.mem.Allocator) void {
    switch (f) {
        .main => {
            s.screen = .routing;
            s.main.set(label);
            s.dest_text.set(shortName(label));
            s.dest = at;
            startFromLive(s);
            drawRoute(s, fx, arena, .{});
            if (s.start == null) s.map.flyTo(.{ .center = at, .zoom = 16 }, 1200);
        },
        .start => {
            s.start_text.set(label);
            s.start = at;
            s.start_live = false;
            drawRoute(s, fx, arena, .{});
        },
        .dest => {
            s.dest_text.set(label);
            s.dest = at;
            drawRoute(s, fx, arena, .{});
        },
    }
    _ = env;
}

/// The start becomes the live position, now or when it arrives.
fn startFromLive(s: *State) void {
    if (s.live) |p| {
        s.start = p;
        s.start_live = true;
        s.start_text.set(t("Your Location"));
    } else if (s.gps == .denied or s.gps == .unavailable) {
        gpsUnavailable(s, .start);
    } else {
        s.waiting_for_gps = .start;
        s.start_text.set(t("Locating..."));
    }
}

fn gpsUnavailable(s: *State, f: Field) void {
    textOf(s, f).len = 0;
    if (f == .start) s.start_hint = t("GPS Unavailable.");
}

fn useLocation(s: *State, f: Field, env: zui.Env, fx: zui.Fx(Msg), arena: std.mem.Allocator) void {
    _ = env;
    const p = s.live orelse return;
    switch (f) {
        .main => {
            s.screen = .routing;
            s.start = p;
            s.start_live = true;
            s.start_text.set(t("Your Location"));
            s.map.flyTo(.{ .center = p, .zoom = 16 }, 1200);
            fx.focus(key_dest);
        },
        .start => {
            s.start = p;
            s.start_live = true;
            s.start_text.set(t("Your Location"));
            drawRoute(s, fx, arena, .{});
        },
        .dest => {
            s.dest = p;
            s.dest_text.set(t("Your Location"));
            drawRoute(s, fx, arena, .{});
        },
    }
}

/// A tap on the map sets the start, then the destination (Maps-js behaviour).
fn tapMap(s: *State, at: [2]f64, env: zui.Env, fx: zui.Fx(Msg), arena: std.mem.Allocator) void {
    if (s.nav != null) return;
    const v = s.map.view();
    // Taps on the live dot are not pins.
    if (s.live) |p| if (v.toScreen(p)) |dot| if (std.math.hypot(dot[0] - at[0], dot[1] - at[1]) < 40) return;
    const where = v.toMap(at[0], at[1]) orelse return;
    const target: Field = if (s.start_text.len == 0) .start else if (s.dest_text.len == 0) .dest else return;
    s.screen = .routing;
    s.list_for = null;
    if (target == .start) {
        s.start_live = false;
        s.start = where;
    } else {
        s.dest = where;
        if (s.start == null) startFromLive(s);
    }
    textOf(s, target).set(t("Locating pin..."));
    s.reverse_seq +%= 1;
    const url = api.reverseUrl(arena, where, zui.i18n.language()) catch return;
    fx.fetch(.{ .url = url, .tag = (s.reverse_seq << 2) | @intFromEnum(target) }, onReversed);
    drawRoute(s, fx, arena, .{});
    _ = env;
}

fn located(s: *State, l: zui.Location, env: zui.Env, fx: zui.Fx(Msg), arena: std.mem.Allocator) void {
    switch (l) {
        .fix => |fix| {
            const p: LatLng = .{ .lat = fix.lat, .lng = fix.lng };
            s.live = p;
            s.gps = .ok;
            if (s.waiting_for_gps) |f| {
                s.waiting_for_gps = null;
                if (f == .start and s.screen == .routing) {
                    s.start = p;
                    s.start_live = true;
                    s.start_text.set(t("Your Location"));
                    drawRoute(s, fx, arena, .{});
                } else useLocation(s, f, env, fx, arena);
                return;
            }
            if (s.nav != null) return navigate(s, p, fix.heading, fx, arena);
            if (s.start_live) {
                s.start = p;
                // Route again after real movement only: GPS jitter would spend the routing quota.
                const moved = if (s.route_from) |from| geo.distance(from, p) else std.math.inf(f64);
                if (moved > 25) {
                    s.reroute_seq +%= 1;
                    fx.after(2000, .{ .live_reroute = s.reroute_seq });
                }
            }
        },
        .denied, .unavailable => {
            s.gps = if (l == .denied) .denied else .unavailable;
            if (s.waiting_for_gps) |f| {
                s.waiting_for_gps = null;
                gpsUnavailable(s, f);
            }
        },
    }
}

const RouteOptions = struct { skip_fit: bool = false, auto: bool = false };

fn clearRouting(s: *State) void {
    if (s.route) |r| r.deinit(gpa);
    s.route = null;
    s.route_status = .none;
    s.route_seq +%= 1; // answers still on their way are dropped
    s.nav = null;
}

/// Asks for a route; only the newest request's answer is drawn.
fn drawRoute(s: *State, fx: zui.Fx(Msg), arena: std.mem.Allocator, o: RouteOptions) void {
    const from = s.start orelse return;
    const to = s.dest orelse return;
    if (from.lat == to.lat and from.lng == to.lng) {
        if (s.route) |r| r.deinit(gpa);
        s.route = null;
        s.route_status = .failed;
        s.route_error.set(t("Origin and destination cannot be the same."));
        return;
    }
    s.route_seq +%= 1;
    s.route_from = from;
    if (!o.auto) s.route_status = .loading;
    const url = api.routeUrl(arena, from, to, s.mode) catch return;
    const flags: u32 = @as(u32, @intFromBool(o.skip_fit)) | @as(u32, @intFromBool(o.auto)) << 1;
    fx.fetch(.{ .url = url, .tag = (s.route_seq << 2) | flags }, onRouted);
}

fn routed(s: *State, r: zui.Response, env: zui.Env, fx: zui.Fx(Msg), arena: std.mem.Allocator) void {
    if (r.tag >> 2 != s.route_seq) return;
    const skip_fit = r.tag & 1 != 0;
    const auto = r.tag & 2 != 0;
    if (r.status == 0) {
        // While navigating, one failed reroute keeps the current route.
        if (auto and s.nav != null) return;
        return routeFailed(s, t("Could not reach the routing service. Check your connection."));
    }
    switch (api.parseRoute(gpa, arena, r.status, r.body, s.mode)) {
        .err => |e| {
            if (auto and s.nav != null) return;
            routeFailed(s, switch (e) {
                .message => |m| if (std.mem.startsWith(u8, m, "Route too long")) t("Route too long (max 1500 km)") else m,
                .unavailable => t("Route Unavailable"),
            });
        },
        .ok => |route| {
            if (s.route) |old| old.deinit(gpa);
            s.route = route;
            s.route_status = .ok;
            if (s.nav) |*n| {
                n.step = 1;
                n.warned = .empty;
                if (auto) fx.speak(t("Rerouting..."));
            } else if (!skip_fit) {
                s.map.fitBounds(route.points, fitPadding(env), 900);
            }
            updateLink(s, fx, arena);
            if (s.nav_after_route) {
                s.nav_after_route = false;
                startNav(s, fx, arena);
            }
        },
    }
}

fn routeFailed(s: *State, message: []const u8) void {
    if (s.route) |old| old.deinit(gpa);
    s.route = null;
    s.route_status = .failed;
    s.route_error.set(message);
}

/// Room around a route for the panels.
fn fitPadding(env: zui.Env) zui.Insets {
    if (env.width >= 768) {
        const side: f32 = 420;
        return .{ .top = env.safe.top + 60, .bottom = 80, .left = if (env.rtl) 60 else side, .right = if (env.rtl) side else 60 };
    }
    return .{ .top = env.safe.top + 60, .bottom = env.safe.bottom + 330, .left = 40, .right = 40 };
}

fn startNav(s: *State, fx: zui.Fx(Msg), arena: std.mem.Allocator) void {
    if (s.route == null) return;
    const from = s.start orelse return;
    s.nav = .{};
    s.list_for = null;
    fx.speak(zui.i18n.tf(arena, "Starting route to {name}", .{ .name = shortName(s.dest_text.get()) }));
    s.map.easeTo(.{ .center = from, .zoom = 18, .pitch = 60 }, 1500);
    updateLink(s, fx, arena);
}

/// One GPS fix while navigating (Maps-js processGPSUpdate): arrival, heading, staying on the
/// route or rerouting, the camera, and the next turn.
fn navigate(s: *State, raw: LatLng, gps_heading: ?f32, fx: zui.Fx(Msg), arena: std.mem.Allocator) void {
    const n = &(s.nav orelse return);
    if (n.arrived) return;
    const dest = s.dest orelse return;
    if (geo.distance(raw, dest) < 60) {
        n.arrived = true;
        fx.speak(t("You have arrived at your destination."));
        return;
    }
    if (n.last_raw) |last| {
        if (geo.distance(last, raw) > 1.5) n.heading = geo.bearing(last, raw);
    } else if (gps_heading) |h| n.heading = h;
    n.last_raw = raw;

    var shown = raw;
    if (s.route) |route| {
        const snap = geo.snapToRoute(raw, route.points);
        if (snap.metres > 50) {
            // A position far from the start (testing from elsewhere) does not reroute.
            if (geo.distance(raw, route.points[0]) > 50_000) return;
            if (!s.reroute_blocked) {
                s.reroute_blocked = true;
                fx.after(5000, .reroute_ready);
                s.start = raw;
                drawRoute(s, fx, arena, .{ .skip_fit = true, .auto = true });
            }
            return;
        }
        shown = snap.point;
    }
    s.start = shown;
    s.map.easeTo(.{ .center = shown, .bearing = n.heading, .pitch = 60 }, 1000);

    const route = s.route orelse return;
    if (n.step >= route.maneuvers.len) return;
    const next = route.maneuvers[n.step];
    const d = geo.distance(shown, next.at);
    if (d < 30) {
        fx.speak(next.instruction);
        n.step += 1;
    } else if (d < 250 and n.step < n.warned.capacity() and !n.warned.isSet(n.step)) {
        fx.speak(zui.i18n.tf(arena, "In 200 meters, {instruction}", .{ .instruction = next.instruction }));
        n.warned.set(n.step);
    }
}

// ---- The address (web URL) -----------------------------------------------------------------

/// ?start=lat,lng&dest=lat,lng&startName=&destName=&mode=full[&nav=1], as Maps-js keeps it.
fn updateLink(s: *State, fx: zui.Fx(Msg), arena: std.mem.Allocator) void {
    const from = s.start orelse return fx.setLink("/");
    const to = s.dest orelse return fx.setLink("/");
    const link = std.fmt.allocPrint(arena, "/?start={d:.6},{d:.6}&dest={d:.6},{d:.6}&startName={s}&destName={s}&mode=full{s}", .{
        from.lat,                                     from.lng,                                    to.lat, to.lng,
        api.encode(arena, s.start_text.get()) catch "", api.encode(arena, s.dest_text.get()) catch "", if (s.nav != null) "&nav=1" else "",
    }) catch return;
    fx.setLink(link);
}

fn query(link: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const q = link[(std.mem.indexOfScalar(u8, link, '?') orelse return null) + 1 ..];
    var it = std.mem.tokenizeScalar(u8, q, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return percentDecode(if (eq < pair.len) pair[eq + 1 ..] else "", buf);
    }
    return null;
}

fn percentDecode(s: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) : (n += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                buf[n] = b;
                i += 3;
                continue;
            } else |_| {}
        }
        buf[n] = if (s[i] == '+') ' ' else s[i];
        i += 1;
    }
    return buf[0..n];
}

fn parsePoint(s: []const u8) ?LatLng {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse return null;
    const lat = std.fmt.parseFloat(f64, s[0..comma]) catch return null;
    const lng = std.fmt.parseFloat(f64, s[comma + 1 ..]) catch return null;
    if (!std.math.isFinite(lat) or !std.math.isFinite(lng) or @abs(lat) > 90 or @abs(lng) > 180) return null;
    return .{ .lat = lat, .lng = lng };
}

/// Opened with a route (?start=&dest=[&nav=1]), a place (?q=&lat=&lng=) or a search (?q=).
fn restoreFromLink(s: *State, env: zui.Env, fx: zui.Fx(Msg), arena: std.mem.Allocator) void {
    var a: [512]u8 = undefined;
    var b: [512]u8 = undefined;
    if (query(env.link, "vehicle", &a)) |v| if (std.meta.stringToEnum(api.Mode, v)) |m| {
        s.mode = m;
    };
    const start_s = query(env.link, "start", &a);
    const dest_s = query(env.link, "dest", &b);
    if (start_s != null and dest_s != null) {
        const from = parsePoint(start_s.?) orelse return;
        const to = parsePoint(dest_s.?) orelse return;
        s.start = from;
        s.dest = to;
        s.screen = .routing;
        s.start_text.set(query(env.link, "startName", &a) orelse t("Start"));
        s.dest_text.set(query(env.link, "destName", &b) orelse t("Destination"));
        s.nav_after_route = if (query(env.link, "nav", &a)) |v| std.mem.eql(u8, v, "1") else false;
        drawRoute(s, fx, arena, .{});
        return;
    }
    const q = query(env.link, "q", &a) orelse "";
    var lat_buf: [32]u8 = undefined;
    var lng_buf: [32]u8 = undefined;
    const lat = std.fmt.parseFloat(f64, query(env.link, "lat", &lat_buf) orelse "x") catch null;
    const lng = std.fmt.parseFloat(f64, query(env.link, "lng", &lng_buf) orelse "x") catch null;
    if (lat != null and lng != null) {
        const at: LatLng = .{ .lat = lat.?, .lng = lng.? };
        s.screen = .routing;
        s.dest = at;
        s.dest_text.set(shortName(q));
        s.map.camera.center = at;
        s.map.camera.zoom = 16;
    } else if (q.len > 0) {
        typed(s, .main, q, fx);
        fx.focus(key_main);
    }
}

// ---- View --------------------------------------------------------------------------------

pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
    const c = theme.colors(ui.env.dark);
    ui.setBackground(c.page);
    var m = s.map;
    m.setViewport(ui.env.width, ui.env.height);
    if (m.moving()) ui.requestFrame(.frame);
    const wide = ui.env.width >= 768;

    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    map.draw(Msg, ui, &m, .{
        .tile_url = tile_url,
        .on_pointer = onMap,
        .routes = routeLines(s, ui),
        .markers = markers(s, ui, c),
    });

    if (s.nav) |n| {
        navOverlay(s, n, ui, c);
    } else if (wide) {
        ui.begin(.{
            .position = .absolute,
            .inset = .{ .top = ui.env.safe.top + 20, .start = 20 },
            .width = .{ .px = 380 },
            .padding = .all(20),
            .gap = 15,
            .radius = 16,
            .background = c.panel,
            .border_width = 1,
            .border_color = c.line,
        }, .{});
        panel(s, ui, c, false);
        ui.end();
        ui.begin(.{ .position = .absolute, .inset = .{ .end = 10, .bottom = ui.env.safe.bottom + 30 }, .gap = 10, .align_items = .end }, .{});
        mapButtons(s, ui, c, true);
        ui.end();
    } else {
        // Phones: a bottom sheet, with the map buttons just above it.
        ui.begin(.{ .position = .absolute, .inset = .{ .start = 0, .end = 0, .bottom = -24 } }, .{});
        ui.begin(.{ .align_items = .end, .padding = .{ .end = 16, .bottom = 12 }, .gap = 10 }, .{});
        mapButtons(s, ui, c, false);
        ui.end();
        ui.begin(.{
            .padding = .{ .top = 24, .start = 24, .end = 24, .bottom = 24 + 24 + ui.env.safe.bottom },
            .gap = 15,
            .radius = 24,
            .background = c.panel,
            .border_width = 1,
            .border_color = c.line,
        }, .{});
        panel(s, ui, c, true);
        ui.end();
        ui.end();
    }
    ui.end();
}

fn routeLines(s: *const State, ui: *zui.Ui(Msg)) []const map.Route {
    const r = s.route orelse return &.{};
    const brand = zui.Color.hex("#2563eb");
    const line: map.Route = switch (s.mode) {
        // Walking dotted, cycling dashed, as Maps-js draws them.
        .walk => .{ .points = r.points, .color = brand, .width = 6, .dash = .{ 0.1, 10 } },
        .bicycle => .{ .points = r.points, .color = brand, .width = 6, .dash = .{ 12, 12 } },
        else => .{ .points = r.points, .color = brand, .width = 6, .opacity = if (s.nav != null) 1 else 0.8 },
    };
    const out = ui.arena().alloc(map.Route, 1) catch return &.{};
    out[0] = line;
    return out;
}

fn markers(s: *const State, ui: *zui.Ui(Msg), c: theme.Colors) []const map.Marker {
    var list: std.ArrayList(map.Marker) = .empty;
    const a = ui.arena();
    if (s.live) |p| if (s.nav == null) {
        list.append(a, .{ .at = p, .size = 14, .color = c.brand, .halo = true, .key = zui.key("live") }) catch {};
    };
    if (s.start) |p| {
        if (s.nav) |n| {
            list.append(a, .{ .at = p, .icon = icons.arrow, .size = 36, .color = zui.Color.white, .outline = c.brand, .border_width = 2, .heading = n.heading, .key = zui.key("start") }) catch {};
        } else if (!s.start_live or s.live == null) {
            list.append(a, .{ .at = p, .size = 14, .color = zui.Color.white, .border_color = c.brand, .border_width = 3, .key = zui.key("start") }) catch {};
        }
    }
    if (s.dest) |p| list.append(a, .{ .at = p, .icon = icons.pin, .size = 36, .color = c.danger, .outline = zui.Color.white, .border_width = 1.5, .anchor = .bottom, .key = zui.key("dest") }) catch {};
    return list.items;
}

fn panel(s: *const State, ui: *zui.Ui(Msg), c: theme.Colors, phone: bool) void {
    switch (s.screen) {
        .search => {
            ui.text(t("Wufour Maps"), .{ .font_size = 24, .weight = 700, .color = c.ink });
            if (phone and s.list_for == .main) suggestionList(s, ui, c);
            fieldRow(ui, c, .{ .icon = icons.search }, s.main.get(), t("Navigate Your World..."), key_main, onMain, .main, s.focused == .main);
            if (!phone and s.list_for == .main) suggestionList(s, ui, c);
        },
        .routing => {
            const list_open = s.list_for == .start or s.list_for == .dest;
            if (phone and list_open) suggestionList(s, ui, c);
            ui.begin(.{ .direction = .row, .gap = 10, .align_items = .center }, .{});
            iconButton(ui, c, icons.back, .back, 36, false);
            ui.begin(.{ .grow = 1, .gap = 8 }, .{});
            fieldRow(ui, c, .{ .dot = .start }, s.start_text.get(), s.start_hint orelse t("Choose starting point..."), key_start, onStart, .start, s.focused == .start);
            fieldRow(ui, c, .{ .dot = .dest }, s.dest_text.get(), t("Choose destination..."), key_dest, onDest, .dest, s.focused == .dest);
            ui.end();
            iconButton(ui, c, icons.swap, .swap, 32, true);
            ui.end();
            if (!phone and list_open) suggestionList(s, ui, c);
            transportModes(s, ui, c);
            routeInfo(s, ui, c);
        },
    }
}

const Lead = union(enum) { icon: zui.Icon, dot: enum { start, dest } };

fn fieldRow(ui: *zui.Ui(Msg), c: theme.Colors, lead: Lead, value: []const u8, placeholder: []const u8, k: u64, on_change: *const fn ([]const u8) Msg, f: Field, focused: bool) void {
    ui.begin(.{
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .xy(12, 0),
        .height = .{ .px = 48 },
        .radius = 8,
        .background = c.field,
        .border_width = 1,
        .border_color = if (focused) c.brand else c.field_line,
    }, .{ .key = k +% 1 });
    switch (lead) {
        .icon => |ic| ui.icon(ic, 16, c.ink_2, .{}, 0),
        .dot => |d| {
            ui.begin(.{
                .width = .{ .px = 12 },
                .height = .{ .px = 12 },
                .radius = 6,
                .border_width = 2,
                .border_color = if (d == .start) c.ink_2 else c.danger,
                .background = if (d == .dest) c.danger else null,
            }, .{});
            ui.end();
        },
    }
    ui.input(.{
        .key = k,
        .value = value,
        .placeholder = placeholder,
        .on_change = on_change,
        .on_focus = .{ .focused = f },
        .on_blur = .{ .blur_seq = f },
        .style = .{ .grow = 1, .height = .{ .px = 46 }, .font_size = 15, .color = c.ink },
    });
    ui.end();
}

fn suggestionList(s: *const State, ui: *zui.Ui(Msg), c: theme.Colors) void {
    ui.beginScroll(.{ .max_height = 250, .radius = 12, .background = c.field, .border_width = 1, .border_color = c.line, .clip = true }, zui.key("suggestions"));
    // "Your Location", unless the other end of the route already is.
    const other_is_live = switch (s.list_for orelse .main) {
        .start => std.mem.eql(u8, s.dest_text.get(), t("Your Location")),
        .dest => s.start_live,
        .main => false,
    };
    if (!other_is_live) {
        ui.begin(.{ .direction = .row, .gap = 8, .align_items = .center, .padding = .xy(16, 14), .pressed_background = c.soft }, .{ .on_press = .picked_location, .key = zui.key("your-location") });
        ui.icon(icons.locate, 16, c.brand, .{}, 0);
        ui.text(t("Your Location"), .{ .font_size = 15, .weight = 700, .color = c.brand });
        ui.end();
    }
    switch (s.suggest) {
        .location_only => {},
        .loading => if (s.suggestions.items.len == 0) note(ui, c, t("Searching...")),
        .empty => note(ui, c, t("No locations found")),
        .failed => note(ui, c, t("Search is not available right now")),
        .results => {},
    }
    if (s.suggest == .results or s.suggest == .loading) for (s.suggestions.items, 0..) |sug, i| {
        ui.begin(.{ .padding = .xy(16, 14), .border_width = 0, .pressed_background = c.soft }, .{ .on_press = .{ .picked = i }, .key = zui.key(i + 1) });
        ui.text(sug.label, .{ .font_size = 15, .weight = 500, .color = c.ink, .max_lines = 2 });
        ui.end();
    };
    ui.end();
}

fn note(ui: *zui.Ui(Msg), c: theme.Colors, text: []const u8) void {
    ui.begin(.{ .padding = .xy(16, 14) }, .{});
    ui.text(text, .{ .font_size = 15, .color = c.ink_2 });
    ui.end();
}

fn iconButton(ui: *zui.Ui(Msg), c: theme.Colors, ic: zui.Icon, msg: Msg, size: f32, round: bool) void {
    ui.begin(.{
        .width = .{ .px = size },
        .height = .{ .px = size },
        .align_items = .center,
        .justify = .center,
        .radius = if (round) size / 2 else 6,
        .background = if (round) c.field else null,
        .border_width = if (round) 1 else 0,
        .border_color = c.line,
        .pressed_background = c.soft,
    }, .{ .on_press = msg });
    ui.icon(ic, size * 0.55, c.ink_2, .{}, 0);
    ui.end();
}

fn transportModes(s: *const State, ui: *zui.Ui(Msg), c: theme.Colors) void {
    ui.begin(.{ .direction = .row, .gap = 5, .padding = .{ .bottom = 12 } }, .{});
    inline for (.{ .{ api.Mode.car, icons.car }, .{ api.Mode.motorcycle, icons.motorcycle }, .{ api.Mode.truck, icons.truck }, .{ api.Mode.bicycle, icons.bicycle }, .{ api.Mode.walk, icons.walk } }) |entry| {
        const active = s.mode == entry[0];
        ui.begin(.{
            .grow = 1,
            .align_items = .center,
            .padding = .all(8),
            .radius = 8,
            .background = if (active) c.brand_soft else null,
            .pressed_background = c.soft,
        }, .{ .on_press = .{ .mode = entry[0] } });
        ui.icon(entry[1], 20, if (active) c.brand else c.ink.withAlpha(0.45), .{}, 0);
        ui.end();
    }
    ui.end();
}

fn routeInfo(s: *const State, ui: *zui.Ui(Msg), c: theme.Colors) void {
    if (s.route_status == .none) return;
    ui.begin(.{ .padding = .all(16), .radius = 12, .background = c.soft, .border_width = 1, .border_color = c.line, .gap = 12 }, .{});
    switch (s.route_status) {
        .none => {},
        .loading => ui.text(t("Calculating route..."), .{ .font_size = 18, .weight = 700, .color = c.ink, .text_align = .center }),
        .failed => ui.text(s.route_error.get(), .{ .font_size = 15, .color = c.danger, .text_align = .center }),
        .ok => if (s.route) |r| {
            ui.begin(.{ .direction = .row, .justify = .center, .align_items = .center, .gap = 6 }, .{});
            ui.text(duration(ui, r.seconds), .{ .font_size = 18, .weight = 700, .color = c.ink });
            ui.text(ui.tf("({n} km)", .{ .n = km(ui, r.km) }), .{ .font_size = 18, .color = c.ink_2 });
            ui.end();
            if (s.start_live) {
                ui.begin(.{ .align_items = .center, .padding = .xy(20, 12), .radius = 24, .background = c.brand, .pressed_opacity = 0.85 }, .{ .on_press = .start_nav });
                ui.text(t("Start"), .{ .font_size = 15, .weight = 600, .color = zui.Color.white });
                ui.end();
            }
        },
    }
    ui.end();
}

fn mapButtons(s: *const State, ui: *zui.Ui(Msg), c: theme.Colors, wide: bool) void {
    const turned = s.map.camera.bearing != 0 or s.map.camera.pitch != 0;
    if (turned) squareButton(ui, c, .north, null, "N");
    squareButton(ui, c, .tilt, null, if (s.map.camera.pitch > 0) "2D" else "3D");
    if (wide) {
        squareButton(ui, c, .zoom_in, null, "+");
        squareButton(ui, c, .zoom_out, null, "−");
    }
    squareButton(ui, c, .recenter, icons.locate, "");
}

fn squareButton(ui: *zui.Ui(Msg), c: theme.Colors, msg: Msg, ic: ?zui.Icon, label: []const u8) void {
    ui.begin(.{
        .width = .{ .px = 44 },
        .height = .{ .px = 44 },
        .align_items = .center,
        .justify = .center,
        .radius = 8,
        .background = c.field,
        .border_width = 1,
        .border_color = c.line,
        .pressed_background = c.soft,
    }, .{ .on_press = msg });
    if (ic) |i| ui.icon(i, 22, c.ink_2, .{}, 0) else ui.text(label, .{ .font_size = 15, .weight = 700, .color = c.ink_2 });
    ui.end();
}

fn navOverlay(s: *const State, n: Nav, ui: *zui.Ui(Msg), c: theme.Colors) void {
    const white = zui.Color.white;
    // The next turn, at the top.
    ui.begin(.{ .position = .absolute, .inset = .{ .top = ui.env.safe.top + 10, .start = 20, .end = 20 }, .align_items = .center }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 16, .padding = .xy(20, 16), .radius = 12, .background = c.nav, .max_width = 400, .width = .fill }, .{});
    var dist_text: []const u8 = "-- m";
    var instruction: []const u8 = t("Head straight");
    var ic = icons.straight;
    if (n.arrived) {
        dist_text = ui.tf("{n} m", .{ .n = 0 });
        instruction = t("You have arrived");
        ic = icons.arrived;
    } else if (s.route) |r| if (n.step < r.maneuvers.len) {
        const next = r.maneuvers[n.step];
        if (s.start) |here| dist_text = metres(ui, geo.distance(here, next.at));
        instruction = next.instruction;
        ic = switch (api.turn(next.type)) {
            .left => icons.turn_left,
            .right => icons.turn_right,
            .arrive => icons.arrived,
            .straight => icons.straight,
        };
    };
    ui.icon(ic, 28, white, .{}, 0);
    ui.begin(.{ .grow = 1, .gap = 4 }, .{});
    ui.text(dist_text, .{ .font_size = 24, .weight = 700, .color = white });
    ui.text(instruction, .{ .font_size = 16, .weight = 500, .color = white, .line_height = 1.2 });
    ui.end();
    ui.end();
    ui.end();

    // Time, distance and Exit at the bottom.
    ui.begin(.{ .position = .absolute, .inset = .{ .bottom = ui.env.safe.bottom + 20, .start = 20, .end = 20 }, .direction = .row, .justify = .space_between, .align_items = .end, .gap = 10 }, .{});
    ui.begin(.{ .direction = .row, .gap = 12, .align_items = .end, .padding = .xy(24, 12), .radius = 12, .background = c.nav_2 }, .{});
    if (s.route) |r| {
        ui.text(duration(ui, r.seconds), .{ .font_size = 24, .weight = 700, .color = white });
        ui.text(ui.tf("{n} km", .{ .n = km(ui, r.km) }), .{ .font_size = 16, .weight = 500, .color = white.withAlpha(0.9) });
    }
    ui.end();
    ui.begin(.{ .padding = .xy(24, 12), .radius = 24, .background = c.danger, .pressed_opacity = 0.85 }, .{ .on_press = .exit_nav });
    ui.text(t("Exit"), .{ .font_size = 16, .weight = 700, .color = white });
    ui.end();
    ui.end();
}

fn duration(ui: *zui.Ui(Msg), seconds: f64) []const u8 {
    const mins: u64 = @intFromFloat(@ceil(@max(0, seconds) / 60));
    if (mins < 60) return ui.tf("{n} min", .{ .n = mins });
    return ui.tf("{h} hr {m} min", .{ .h = mins / 60, .m = mins % 60 });
}

fn km(ui: *zui.Ui(Msg), v: f64) []const u8 {
    return std.fmt.allocPrint(ui.arena(), "{d:.1}", .{v}) catch "";
}

fn metres(ui: *zui.Ui(Msg), m: f64) []const u8 {
    if (m > 1000) return ui.tf("{n} km", .{ .n = km(ui, m / 1000) });
    return ui.tf("{n} m", .{ .n = @as(u64, @intFromFloat(@round(m))) });
}

// ---- Tests -------------------------------------------------------------------------------

const D = zui.host.Driver(@This());
const testing = std.testing;

test "search, pick a place, route from the live position, navigate" {
    D.start(400, 800);
    defer D.reset();
    try testing.expect(zui.host.location_on); // live position asked for at start
    try testing.expect(D.countImages() > 6);
    D.locate(33.5138, 36.2765);

    try D.typeInto("Navigate Your World...", "umayyad");
    try testing.expect(D.pending("/api/v1/search") == null); // waits for typing to pause
    D.runTimers();
    const url = D.pending("/api/v1/search").?;
    try testing.expect(std.mem.indexOf(u8, url, "q=umayyad") != null);
    try testing.expect(D.respond("/api/v1/search", 200,
        \\{"success":true,"results":[{"name":"Umayyad Square","label":"Umayyad Square, Damascus","lat":33.5138,"lng":36.2765},
        \\{"name":"Umayyad Mosque","label":"Umayyad Mosque, Damascus","lat":33.5115,"lng":36.3066}]}
    ));
    try testing.expect(D.findText("Umayyad Mosque, Damascus") != 0);
    try D.press("Umayyad Mosque, Damascus");

    // Routing view: the destination is the place, the start is the live position.
    const route_url = D.pending("/api/route/valhalla").?;
    try testing.expect(std.mem.indexOf(u8, route_url, "auto") != null);
    try testing.expect(D.respond("/api/route/valhalla", 200,
        \\{"trip":{"summary":{"time":600,"length":4.2},"legs":[{"shape":"gvo|~@}pcedAf`Za{l@","maneuvers":[
        \\{"instruction":"Drive south.","type":1,"begin_shape_index":0},
        \\{"instruction":"Turn right onto Baghdad Street.","type":10,"begin_shape_index":1}]}]}}
    ));
    try testing.expect(D.findText("10 min") != 0);
    try testing.expect(D.findText("(4.2 km)") != 0);
    try testing.expect(std.mem.indexOf(u8, zui.host.link.items, "start=33.513800,36.276500") != null);

    try D.press("Start");
    try testing.expect(D.findText("Exit") != 0);
    try testing.expect(std.mem.startsWith(u8, zui.host.spoken.items, "Starting route to Umayyad Mosque"));
    // Near the turn: the banner shows it and the voice warns.
    D.locate(33.50097, 36.29836); // on the route, about 190 m before the turn
    try testing.expect(D.findText("Turn right onto Baghdad Street.") != 0);
    try testing.expect(std.mem.startsWith(u8, zui.host.spoken.items, "In 200 meters, Turn right"));
    try D.press("Exit");
    try testing.expect(D.findText("Exit") == 0);
}

test "a slow answer for an old route does not replace the new one" {
    D.start(400, 800);
    defer D.reset();
    D.locate(33.5138, 36.2765);
    D.R.dispatch(.{ .located = .{ .fix = .{ .lat = 33.5138, .lng = 36.2765 } } });
    try D.typeInto("Navigate Your World...", "x");
    D.runTimers();
    try testing.expect(D.respond("/api/v1/search", 200, "{\"success\":true,\"results\":[{\"name\":\"X\",\"label\":\"X\",\"lat\":33.6,\"lng\":36.3}]}"));
    try D.press("X");
    // Change the mode before the first answer arrives: the first answer is ignored.
    D.R.dispatch(.{ .mode = .walk });
    try testing.expect(D.respond("auto", 200, "{\"trip\":{\"summary\":{\"time\":60,\"length\":1},\"legs\":[{\"shape\":\"gvo|~@}pcedAf`Za{l@\",\"maneuvers\":[]}]}}"));
    try testing.expect(D.findText("1 min") == 0);
    try testing.expect(D.respond("pedestrian", 200, "{\"trip\":{\"summary\":{\"time\":1800,\"length\":2.5},\"legs\":[{\"shape\":\"gvo|~@}pcedAf`Za{l@\",\"maneuvers\":[]}]}}"));
    try testing.expect(D.findText("30 min") != 0);
}

test "opened with a route link" {
    D.startWith(400, 800, "/?start=33.5,36.27&dest=33.52,36.31&startName=Home&destName=Work");
    defer D.reset();
    try testing.expect(D.pending("/api/route/valhalla") != null);
    try testing.expect(D.findText("Calculating route...") != 0);
}

test {
    _ = api;
    _ = geo;
}
