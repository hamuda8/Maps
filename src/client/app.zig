//! Wufour Maps client. The same code is compiled for the web, Android and iOS.
//!
//! Step 1: a demo screen that exercises every zui primitive (boxes, text, presses, input,
//! scrolling, translation and right-to-left). The real map screens replace it in step 3.

const std = @import("std");
const zui = @import("zui");
const theme = @import("theme.zig");

pub const Msg = union(enum) {
    press,
    toggle_language,
    query: []const u8,
};

pub const State = struct {
    presses: u32 = 0,
    query_buf: [128]u8 = undefined,
    query_len: usize = 0,

    fn query(s: *const State) []const u8 {
        return s.query_buf[0..s.query_len];
    }
};

/// Crash messages go to the platform log (logcat, device log, browser console).
pub const panic = zui.panic;

pub const global_locale = @embedFile("locales/global.json");
pub const locales: []const zui.i18n.Locale = &.{
    .{ .lang = "ar", .json = @embedFile("locales/ar.json") },
};

comptime {
    zui.exportApp(@This());
}

pub fn init() State {
    return .{};
}

pub fn update(s: *State, msg: Msg) void {
    switch (msg) {
        .press => s.presses += 1,
        .toggle_language => zui.i18n.setLanguage(if (zui.i18n.isRtl()) "en" else "ar"),
        .query => |q| {
            s.query_len = @min(q.len, s.query_buf.len);
            @memcpy(s.query_buf[0..s.query_len], q[0..s.query_len]);
        },
    }
}

fn onQuery(q: []const u8) Msg {
    return .{ .query = q };
}

pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
    const c = theme.colors(ui.env.dark);
    ui.setBackground(c.page);

    ui.begin(.{ .padding = .xy(20, 16), .gap = 16, .height = .fill }, .{});
    {
        // Header: title and the language switch.
        ui.begin(.{ .direction = .row, .align_items = .center, .justify = .space_between }, .{});
        ui.text(ui.t("Wufour Maps"), .{ .font_size = 24, .weight = 700, .color = c.ink });
        button(ui, c, if (zui.i18n.isRtl()) "English" else "عربي", .toggle_language, false);
        ui.end();

        ui.text(ui.t("One codebase, real native views on the web, Android and iOS."), .{ .font_size = 15, .color = c.ink_2, .line_height = 1.5 });

        // Search box.
        ui.begin(.{ .direction = .row, .align_items = .center, .padding = .xy(14, 0), .height = .{ .px = 48 }, .background = c.panel, .radius = 12, .border_width = 1, .border_color = c.line }, .{});
        ui.input(.{
            .value = s.query(),
            .placeholder = ui.t("Search places"),
            .on_change = onQuery,
            .style = .{ .width = .fill, .font_size = 15, .color = c.ink },
        });
        ui.end();
        if (s.query_len > 0) ui.text(ui.tf("You typed: {q}", .{ .q = s.query() }), .{ .color = c.ink_2 });

        button(ui, c, ui.tf("Pressed {n} times", .{ .n = s.presses }), .press, true);

        // A list long enough to scroll.
        ui.beginScroll(.{ .height = .fill, .gap = 8, .background = c.panel, .radius = 12, .padding = .all(12) }, 0);
        for (1..31) |i| {
            ui.begin(.{ .direction = .row, .justify = .space_between, .align_items = .center, .padding = .xy(12, 10), .radius = 10, .background = c.page }, .{ .key = zui.key(i) });
            ui.text(ui.tf("Place {n}", .{ .n = i }), .{ .color = c.ink, .weight = 600 });
            ui.text(ui.tf("{n} km", .{ .n = i * 3 }), .{ .color = c.ink_2, .font_size = 13 });
            ui.end();
        }
        ui.end();
    }
    ui.end();
}

fn button(ui: *zui.Ui(Msg), c: theme.Colors, label: []const u8, msg: Msg, primary: bool) void {
    ui.begin(.{
        .padding = .xy(16, 10),
        .radius = 10,
        .align_items = .center,
        .background = if (primary) c.brand else c.panel,
        .border_width = if (primary) 0 else 1,
        .border_color = c.line,
        .pressed_opacity = 0.7,
    }, .{ .on_press = msg });
    ui.text(label, .{ .font_size = 15, .weight = 600, .color = if (primary) zui.Color.white else c.ink });
    ui.end();
}

test "pressing the button counts, and the language switch flips to right-to-left" {
    const D = zui.host.Driver(@This());
    D.start(360, 640);
    defer D.reset();
    try std.testing.expect(D.findText("Pressed 0 times") != 0);
    try D.press("Pressed 0 times");
    try std.testing.expect(D.findText("Pressed 1 times") != 0);

    const title = D.findText("Wufour Maps");
    try std.testing.expectEqual(@as(f32, 20), D.absoluteFrame(title).x);
    try D.press("عربي");
    try std.testing.expect(zui.i18n.isRtl());
    const title_ar = D.findText("خرائط وفور");
    try std.testing.expect(title_ar != 0);
    // Right-to-left: the title now ends at the right padding.
    const f = D.absoluteFrame(title_ar);
    try std.testing.expectEqual(@as(f32, 360 - 20), f.x + f.w);
    try D.press("English");
}

test "typing shows the text" {
    const D = zui.host.Driver(@This());
    D.start(360, 640);
    defer D.reset();
    try D.typeInto("Search places", "Kuala Lumpur");
    try std.testing.expect(D.findText("You typed: Kuala Lumpur") != 0);
}
