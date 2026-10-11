//! Wufour Maps client. The same code is compiled for the web, Android and iOS.
//!
//! Step 3: the map engine (tiles through the Maps server's tile proxy, pan, pinch-zoom, rotate,
//! two-finger tilt, glide, wheel zoom), a route line, markers and the map controls. Search and
//! routing from the server come with the client's networking next.

const std = @import("std");
const zui = @import("zui");
const map = @import("map");
const theme = @import("theme.zig");

pub const panic = zui.panic;

pub const Msg = union(enum) {
    map: zui.Pointer,
    glide,
    zoom_in,
    zoom_out,
    north,
    tilt,
    toggle_language,
};

pub const State = struct {
    map: map.State,
    /// Whether the glide after a quick pan is running (it asks for frames).
    gliding: bool = false,
};

pub const global_locale = @embedFile("locales/global.json");
pub const locales: []const zui.i18n.Locale = &.{
    .{ .lang = "ar", .json = @embedFile("locales/ar.json") },
};

comptime {
    zui.exportApp(@This());
}

/// Tiles through the Maps server's cached proxy: same origin on the web; on the phones, the
/// server given at build time (-Dserver=).
const tile_url = if (zui.platform == .web) "/tiles/{z}/{x}/{y}.png" else @import("app_config").server ++ "/tiles/{z}/{x}/{y}.png";

const damascus: map.LatLng = .{ .lat = 33.5138, .lng = 36.2765 };

/// A sample route through central Damascus (from the Maps server's /api/v1/route).
const sample_route = [_]map.LatLng{
    .{ .lat = 33.513844, .lng = 36.276511 }, .{ .lat = 33.5129, .lng = 36.2812 }, .{ .lat = 33.5119, .lng = 36.2866 },
    .{ .lat = 33.5107, .lng = 36.2920 },     .{ .lat = 33.5086, .lng = 36.2958 }, .{ .lat = 33.5052, .lng = 36.2985 },
    .{ .lat = 33.5000, .lng = 36.3000 },
};

pub fn init() State {
    return .{ .map = .{ .camera = .{ .center = .{ .lat = 33.5075, .lng = 36.2890 }, .zoom = 14 } } };
}

pub fn update(s: *State, msg: Msg, env: zui.Env) void {
    s.map.setViewport(env.width, env.height);
    switch (msg) {
        .map => |p| {
            if (s.map.handle(p)) s.gliding = true;
        },
        .glide => s.gliding = s.map.glide(),
        .zoom_in => s.map.zoomAround(env.width / 2, env.height / 2, @round(s.map.camera.zoom) + 1),
        .zoom_out => s.map.zoomAround(env.width / 2, env.height / 2, @round(s.map.camera.zoom) - 1),
        .north => {
            s.map.camera.bearing = 0;
            s.map.camera.pitch = 0;
        },
        .tilt => s.map.camera.pitch = if (s.map.camera.pitch > 0) 0 else 55,
        .toggle_language => zui.i18n.setLanguage(if (zui.i18n.isRtl()) "en" else "ar"),
    }
}

fn onMap(p: zui.Pointer) Msg {
    return .{ .map = p };
}

pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
    const c = theme.colors(ui.env.dark);
    ui.setBackground(c.page);
    var m = s.map;
    m.setViewport(ui.env.width, ui.env.height);
    if (s.gliding) ui.requestFrame(.glide);

    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    map.draw(Msg, ui, &m, .{
        .tile_url = tile_url,
        .on_pointer = onMap,
        .routes = &.{.{ .points = &sample_route, .color = c.brand }},
        .markers = &.{
            .{ .at = sample_route[0], .color = zui.Color.hex("#16a34a") },
            .{ .at = sample_route[sample_route.len - 1], .color = zui.Color.hex("#dc2626") },
            .{ .at = damascus, .size = 14 },
        },
    });

    // Title card (top) and controls (bottom end), floating over the map.
    ui.begin(.{
        .position = .absolute,
        .inset = .{ .top = ui.env.safe.top + 12, .start = 12, .end = 12 },
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
        .padding = .xy(16, 10),
        .radius = 14,
        .background = c.panel,
        .border_width = 1,
        .border_color = c.line,
    }, .{});
    ui.text(ui.t("Wufour Maps"), .{ .font_size = 20, .weight = 700, .color = c.ink });
    button(ui, c, if (zui.i18n.isRtl()) "English" else "عربي", .toggle_language);
    ui.end();

    ui.begin(.{ .position = .absolute, .inset = .{ .end = 12, .bottom = ui.env.safe.bottom + 24 }, .gap = 8 }, .{});
    button(ui, c, "+", .zoom_in);
    button(ui, c, "−", .zoom_out);
    button(ui, c, if (s.map.camera.pitch > 0) "2D" else "3D", .tilt);
    button(ui, c, "N", .north);
    ui.end();
    ui.end();
}

fn button(ui: *zui.Ui(Msg), c: theme.Colors, label: []const u8, msg: Msg) void {
    ui.begin(.{
        .padding = .xy(12, 8),
        .min_width = 44,
        .radius = 10,
        .align_items = .center,
        .background = c.panel,
        .border_width = 1,
        .border_color = c.line,
        .pressed_opacity = 0.7,
    }, .{ .on_press = msg });
    ui.text(label, .{ .font_size = 16, .weight = 600, .color = c.ink });
    ui.end();
}

test "the map loads tiles around Damascus, pans with a drag, zooms with +" {
    const D = zui.host.Driver(@This());
    D.start(400, 800);
    defer D.reset();
    try std.testing.expect(D.countImages() > 6);
    const before = D.R.appState().map.camera.center;
    D.pointer(.{ .kind = .down, .id = 1, .x = 200, .y = 400 });
    D.pointer(.{ .kind = .move, .id = 1, .x = 100, .y = 400, .time_ms = 16 });
    D.pointer(.{ .kind = .up, .id = 1, .x = 100, .y = 400, .time_ms = 200 });
    try std.testing.expect(D.R.appState().map.camera.center.lng > before.lng); // dragged left: east comes into view
    try D.press("+");
    try std.testing.expectApproxEqAbs(@as(f64, 15), D.R.appState().map.camera.zoom, 1e-9);
}
