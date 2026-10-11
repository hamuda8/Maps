//! The Wufour Maps developer console (/developers), a port of Maps-js's page: sign in with
//! Wufour, create, copy and revoke API keys (with their usage), and get the iframe code for
//! each embed mode, with a live preview.

const std = @import("std");
const zui = @import("zui");

pub const panic = zui.panic;
pub const boot: Msg = .boot;

comptime {
    zui.exportApp(@This());
}

const gpa = zui.allocator;
const Color = zui.Color;

const c = struct {
    const page = Color.hex("#f8fafc");
    const card = Color.hex("#ffffff");
    const ink = Color.hex("#0f172a");
    const ink_2 = Color.hex("#64748b");
    const line = Color.hex("#e2e8f0");
    const brand = Color.hex("#2563eb");
    const brand_soft = Color.hex("#e0e7ff");
    const danger = Color.hex("#ef4444");
    const code_bg = Color.hex("#0f172a");
    const code_ink = Color.hex("#e2e8f0");
};

const Mode = enum {
    full,
    picker,
    driver,
    tracking,

    fn label(m: Mode) []const u8 {
        return switch (m) {
            .full => "Full Engine",
            .picker => "Location Picker",
            .driver => "Driver Navigation",
            .tracking => "Live Tracking",
        };
    }
};

const Key = struct { app_name: []u8, key: []u8, today: u64, month: u64 };

pub const Msg = union(enum) {
    boot,
    me: zui.Response,
    keys: zui.Response,
    created: zui.Response,
    revoked: zui.Response,
    logged_out: zui.Response,
    tab: enum { credentials, docs },
    name: []const u8,
    create,
    copy_key: usize,
    revoke: usize,
    pick_key: usize,
    snippet_mode: Mode,
    sandbox_mode: Mode,
    copy_snippet,
    preview,
    login,
    logout,
    clear_note,
};

pub const State = struct {
    checked: bool = false,
    user: ?[]u8 = null,
    tab: enum { credentials, docs } = .docs,
    keys: std.ArrayList(Key) = .empty,
    keys_loaded: bool = false,
    name: [96]u8 = undefined,
    name_len: usize = 0,
    note: ?[]const u8 = null,
    note_bad: bool = false,
    note_seq: u32 = 0,
    snippet_key: usize = 0,
    snippet_mode: Mode = .full,
    sandbox_mode: Mode = .full,
};

pub fn init() State {
    return .{};
}

fn onMe(r: zui.Response) Msg {
    return .{ .me = r };
}
fn onKeys(r: zui.Response) Msg {
    return .{ .keys = r };
}
fn onCreated(r: zui.Response) Msg {
    return .{ .created = r };
}
fn onRevoked(r: zui.Response) Msg {
    return .{ .revoked = r };
}
fn onLoggedOut(r: zui.Response) Msg {
    return .{ .logged_out = r };
}
fn onName(s: []const u8) Msg {
    return .{ .name = s };
}

const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

pub fn update(s: *State, msg: Msg, env: zui.Env, fx: zui.Fx(Msg)) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    switch (msg) {
        .boot => {
            // "https://maps.example.com/developers" → "https://maps.example.com"
            const link = env.link;
            const after_scheme = (std.mem.indexOf(u8, link, "://") orelse 0) + 3;
            const end = if (after_scheme < link.len) (std.mem.indexOfScalarPos(u8, link, after_scheme, '/') orelse link.len) else 0;
            origin_len = @min(end, origin_buf.len);
            @memcpy(origin_buf[0..origin_len], link[0..origin_len]);
            fx.fetch(.{ .url = "/api/developer/me" }, onMe);
        },
        .me => |r| {
            s.checked = true;
            const v = std.json.parseFromSliceLeaky(struct { user: ?struct { username: ?[]const u8 = null } = null }, arena, r.body, parse_options) catch return;
            if (v.user) |u| {
                s.user = gpa.dupe(u8, u.username orelse "") catch null;
                s.tab = .credentials;
                fx.fetch(.{ .url = "/api/developer/keys" }, onKeys);
            }
        },
        .keys => |r| {
            s.keys_loaded = true;
            const v = std.json.parseFromSliceLeaky(struct {
                keys: []const struct { appName: []const u8 = "", key: []const u8 = "", usage: ?struct { today: u64 = 0, last30Days: u64 = 0 } = null } = &.{},
            }, arena, r.body, parse_options) catch return;
            for (s.keys.items) |k| {
                gpa.free(k.app_name);
                gpa.free(k.key);
            }
            s.keys.clearRetainingCapacity();
            for (v.keys) |k| s.keys.append(gpa, .{
                .app_name = gpa.dupe(u8, k.appName) catch continue,
                .key = gpa.dupe(u8, k.key) catch continue,
                .today = if (k.usage) |u| u.today else 0,
                .month = if (k.usage) |u| u.last30Days else 0,
            }) catch {};
            if (s.snippet_key >= s.keys.items.len) s.snippet_key = 0;
        },
        .tab => |t| s.tab = switch (t) {
            .credentials => .credentials,
            .docs => .docs,
        },
        .name => |v| {
            const n = @min(v.len, s.name.len);
            @memcpy(s.name[0..n], v[0..n]);
            s.name_len = n;
        },
        .create => {
            const name = std.mem.trim(u8, s.name[0..s.name_len], " ");
            if (name.len < 2) return note(s, fx, "App name is required (2 to 80 characters)", true);
            const body = std.fmt.allocPrint(arena, "{{\"appName\":{f}}}", .{std.json.fmt(name, .{})}) catch return;
            fx.fetch(.{ .url = "/api/developer/keys/create", .method = .POST, .body = body }, onCreated);
        },
        .created => |r| {
            if (!r.ok()) return note(s, fx, message(arena, r.body) orelse "Could not create the key", true);
            s.name_len = 0;
            note(s, fx, "Key created", false);
            fx.fetch(.{ .url = "/api/developer/keys" }, onKeys);
        },
        .copy_key => |i| if (i < s.keys.items.len) {
            fx.copy(s.keys.items[i].key);
            note(s, fx, "Key copied", false);
        },
        .revoke => |i| if (i < s.keys.items.len) {
            const body = std.fmt.allocPrint(arena, "{{\"key\":{f}}}", .{std.json.fmt(s.keys.items[i].key, .{})}) catch return;
            fx.fetch(.{ .url = "/api/developer/keys/revoke", .method = .POST, .body = body }, onRevoked);
        },
        .revoked => |r| {
            if (!r.ok()) return note(s, fx, message(arena, r.body) orelse "Could not revoke the key", true);
            note(s, fx, "Key revoked", false);
            fx.fetch(.{ .url = "/api/developer/keys" }, onKeys);
        },
        .pick_key => |i| s.snippet_key = i,
        .snippet_mode => |m| s.snippet_mode = m,
        .sandbox_mode => |m| s.sandbox_mode = m,
        .copy_snippet => {
            fx.copy(snippet(s, arena, s.snippet_mode, keyFor(s)) catch return);
            note(s, fx, "Snippet copied", false);
        },
        .preview => fx.openUrl(previewUrl(arena, s.sandbox_mode) catch return, true),
        .login => fx.openUrl("/auth", false),
        .logout => fx.fetch(.{ .url = "/auth/logout", .method = .POST, .body = "{}" }, onLoggedOut),
        .logged_out => fx.openUrl("/developers", false),
        .clear_note => s.note = null,
    }
}

fn message(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(struct { message: ?[]const u8 = null }, arena, body, parse_options) catch return null;
    const m = v.message orelse return null;
    return gpa.dupe(u8, m) catch null;
}

/// A short message under the title for three seconds. (Static strings and small leaks of
/// server messages: a handful per visit.)
fn note(s: *State, fx: zui.Fx(Msg), text: []const u8, bad: bool) void {
    s.note = text;
    s.note_bad = bad;
    s.note_seq +%= 1;
    fx.after(3000, .clear_note);
}

fn keyFor(s: *const State) []const u8 {
    if (s.snippet_key < s.keys.items.len) return s.keys.items[s.snippet_key].key;
    return "YOUR_API_KEY_HERE";
}

/// The iframe code for a mode (Maps-js's snippets).
fn snippet(s: *const State, arena: std.mem.Allocator, mode: Mode, key: []const u8) ![]const u8 {
    _ = s;
    const src = switch (mode) {
        .tracking => "/embed/tracking?track_id=DYNAMIC_TRACK_ID_HERE&start=LAT,LNG&dest=LAT,LNG&vehicle=motorcycle",
        .driver => try std.fmt.allocPrint(arena, "/embed/driver?key={s}&start=LAT,LNG&dest=LAT,LNG", .{key}),
        else => try std.fmt.allocPrint(arena, "/embed/{t}?key={s}", .{ mode, key }),
    };
    return std.fmt.allocPrint(arena,
        \\<iframe
        \\    src="{s}{s}"
        \\    width="100%"
        \\    height="500"
        \\    style="border:0; border-radius:12px;"
        \\    allowfullscreen
        \\    allow="geolocation">
        \\</iframe>
    , .{ origin(), src });
}

/// The sandbox's demo (the demo key and track id work from this site only).
fn previewUrl(arena: std.mem.Allocator, mode: Mode) ![]const u8 {
    const start = "33.5138,36.2765";
    const dest = "33.5250,36.2900";
    return switch (mode) {
        .tracking => std.fmt.allocPrint(arena, "/embed/tracking?track_id=DEMO_ID&start={s}&dest={s}&vehicle=motorcycle", .{ start, dest }),
        .driver => std.fmt.allocPrint(arena, "/embed/driver?key=DEMO_KEY&start={s}&dest={s}", .{ start, dest }),
        else => std.fmt.allocPrint(arena, "/embed/{t}?key=DEMO_KEY", .{mode}),
    };
}

/// The page's own address: snippets point at this server.
var origin_buf: [256]u8 = undefined;
var origin_len: usize = 0;
fn origin() []const u8 {
    return if (origin_len > 0) origin_buf[0..origin_len] else "https://YOUR-MAPS-HOST";
}

fn mask(arena: std.mem.Allocator, key: []const u8) []const u8 {
    if (key.len < 20) return key;
    return std.fmt.allocPrint(arena, "{s}••••••••••••••••{s}", .{ key[0..16], key[key.len - 4 ..] }) catch key;
}

// ---- View --------------------------------------------------------------------------------

pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
    ui.setBackground(c.page);
    ui.beginScroll(.{ .width = .fill, .height = .fill }, zui.key("page"));
    // Top bar.
    ui.begin(.{ .direction = .row, .align_items = .center, .justify = .space_between, .padding = .xy(24, 14), .background = c.card, .border_width = 1, .border_color = c.line }, .{});
    ui.text("Wufour Maps Platform", .{ .font_size = 18, .weight = 700, .color = c.ink });
    if (s.user) |name| {
        ui.begin(.{ .direction = .row, .gap = 12, .align_items = .center }, .{});
        ui.text(name, .{ .font_size = 14, .weight = 500, .color = c.ink_2 });
        button(ui, "Logout", .logout, false);
        ui.end();
    } else if (s.checked) button(ui, "Log in via Wufour", .login, true);
    ui.end();

    if (s.user != null) {
        ui.begin(.{ .direction = .row, .gap = 4, .padding = .xy(24, 8), .background = c.card, .border_width = 1, .border_color = c.line }, .{});
        tabButton(ui, "API Credentials", .{ .tab = .credentials }, s.tab == .credentials);
        tabButton(ui, "Embed API Setup", .{ .tab = .docs }, s.tab == .docs);
        ui.end();
    }

    ui.begin(.{ .align_items = .center, .padding = .all(24) }, .{});
    ui.begin(.{ .width = .fill, .max_width = 900, .gap = 20 }, .{});
    if (s.note) |n| ui.text(n, .{ .font_size = 14, .weight = 600, .color = if (s.note_bad) c.danger else Color.hex("#16a34a") });
    if (s.tab == .credentials and s.user != null) credentials(s, ui) else docs(s, ui);
    ui.end();
    ui.end();
    ui.end();
}

fn docs(s: *const State, ui: *zui.Ui(Msg)) void {
    ui.text("Maps Embed API", .{ .font_size = 28, .weight = 800, .color = c.ink });
    ui.text("The Wufour Maps Embed API lets you place an interactive map, location picker, or real-time tracking interface on your website with a simple HTML iframe.", .{ .font_size = 15, .color = c.ink_2 });
    card(ui, "Live Sandbox", "Select a mode below to see how it looks and get the template code.");
    modeChooser(ui, s.sandbox_mode, .sandbox);
    code(ui, snippet(s, ui.arena(), s.sandbox_mode, "YOUR_API_KEY_HERE") catch "");
    button(ui, "Open the live preview", .preview, true);
    ui.end();
}

fn credentials(s: *const State, ui: *zui.Ui(Msg)) void {
    ui.text("API Credentials", .{ .font_size = 28, .weight = 800, .color = c.ink });

    card(ui, "Generate New Key", null);
    ui.begin(.{ .direction = .row, .gap = 10, .align_items = .center }, .{});
    ui.begin(.{ .grow = 1, .padding = .xy(12, 0), .height = .{ .px = 44 }, .radius = 8, .border_width = 1, .border_color = c.line, .background = c.card, .justify = .center }, .{ .key = zui.key("name-row") });
    ui.input(.{ .key = zui.key("name"), .value = s.name[0..s.name_len], .placeholder = "e.g., Turf Logistics Production", .on_change = onName, .on_submit = .create, .style = .{ .height = .{ .px = 42 }, .font_size = 15, .color = c.ink } });
    ui.end();
    button(ui, "Create Key", .create, true);
    ui.end();
    ui.end();

    card(ui, "Active Keys", null);
    if (s.keys_loaded and s.keys.items.len == 0) ui.text("No active keys found.", .{ .font_size = 15, .color = c.ink_2 });
    for (s.keys.items, 0..) |k, i| {
        ui.begin(.{ .direction = .row, .align_items = .center, .justify = .space_between, .gap = 12, .padding = .xy(0, 12), .border_width = 0 }, .{ .key = zui.key(k.key) });
        ui.begin(.{ .grow = 1, .gap = 4 }, .{});
        ui.text(k.app_name, .{ .font_size = 15, .weight = 700, .color = c.ink });
        ui.text(mask(ui.arena(), k.key), .{ .font_size = 13, .mono = true, .color = c.ink_2 });
        ui.text(ui.tf("{today} calls today · {month} in the last 30 days", .{ .today = k.today, .month = k.month }), .{ .font_size = 13, .color = c.ink_2 });
        ui.end();
        button(ui, "Copy Key", .{ .copy_key = i }, true);
        button(ui, "Revoke", .{ .revoke = i }, false);
        ui.end();
    }
    ui.end();

    card(ui, "Personalized Snippet Generator", "Configure your map mode below to generate the exact HTML iframe code with your API key.");
    if (s.keys.items.len > 0) {
        ui.text("Key", .{ .font_size = 13, .weight = 600, .color = c.ink_2 });
        ui.begin(.{ .direction = .row, .gap = 6 }, .{});
        for (s.keys.items, 0..) |k, i| chip(ui, k.app_name, .{ .pick_key = i }, i == s.snippet_key, zui.key(i + 100));
        ui.end();
    }
    modeChooser(ui, s.snippet_mode, .snippet);
    code(ui, snippet(s, ui.arena(), s.snippet_mode, keyFor(s)) catch "");
    button(ui, "Copy Snippet to Clipboard", .copy_snippet, true);
    ui.end();
}

/// A white card with a title; the caller adds content and closes it with ui.end().
fn card(ui: *zui.Ui(Msg), title: []const u8, desc: ?[]const u8) void {
    ui.begin(.{ .padding = .all(24), .gap = 12, .radius = 12, .background = c.card, .border_width = 1, .border_color = c.line }, .{});
    ui.text(title, .{ .font_size = 18, .weight = 700, .color = c.ink });
    if (desc) |d| ui.text(d, .{ .font_size = 14, .color = c.ink_2 });
}

fn modeChooser(ui: *zui.Ui(Msg), current: Mode, which: enum { sandbox, snippet }) void {
    ui.text("Map Mode", .{ .font_size = 13, .weight = 600, .color = c.ink_2 });
    ui.begin(.{ .direction = .row, .gap = 6 }, .{});
    inline for (comptime std.enums.values(Mode)) |m| {
        const msg: Msg = if (which == .sandbox) .{ .sandbox_mode = m } else .{ .snippet_mode = m };
        chip(ui, m.label(), msg, current == m, zui.key(@as(u64, @intFromEnum(m)) + 10));
    }
    ui.end();
}

fn chip(ui: *zui.Ui(Msg), label: []const u8, msg: Msg, on: bool, k: u64) void {
    ui.begin(.{ .padding = .xy(12, 8), .radius = 16, .background = if (on) c.brand_soft else c.page, .border_width = 1, .border_color = if (on) c.brand else c.line, .pressed_opacity = 0.8 }, .{ .on_press = msg, .key = k });
    ui.text(label, .{ .font_size = 13, .weight = 600, .color = if (on) c.brand else c.ink_2 });
    ui.end();
}

fn code(ui: *zui.Ui(Msg), text: []const u8) void {
    ui.begin(.{ .padding = .all(16), .radius = 8, .background = c.code_bg }, .{});
    ui.text(text, .{ .font_size = 13, .mono = true, .color = c.code_ink });
    ui.end();
}

fn button(ui: *zui.Ui(Msg), label: []const u8, msg: Msg, primary: bool) void {
    ui.begin(.{
        .padding = .xy(20, 10),
        .radius = 22,
        .align_items = .center,
        .background = if (primary) c.brand else c.card,
        .border_width = if (primary) 0 else 1,
        .border_color = if (primary) c.brand else c.danger,
        .pressed_opacity = 0.85,
    }, .{ .on_press = msg });
    ui.text(label, .{ .font_size = 14, .weight = 600, .color = if (primary) Color.white else c.danger });
    ui.end();
}

fn tabButton(ui: *zui.Ui(Msg), label: []const u8, msg: Msg, on: bool) void {
    ui.begin(.{ .padding = .xy(16, 10), .radius = 8, .background = if (on) c.brand_soft else null, .pressed_opacity = 0.8 }, .{ .on_press = msg });
    ui.text(label, .{ .font_size = 14, .weight = 600, .color = if (on) c.brand else c.ink_2 });
    ui.end();
}

const D = zui.host.Driver(@This());
const testing = std.testing;

test "signed in: lists keys, creates one, copies the snippet with the chosen key" {
    D.startWith(1000, 800, "https://maps.example.com/developers");
    defer D.reset();
    try testing.expect(D.respond("/api/developer/me", 200, "{\"success\":true,\"user\":{\"username\":\"tarek\"}}"));
    try testing.expect(D.findText("tarek") != 0);
    try testing.expect(D.respond("/api/developer/keys", 200,
        \\{"success":true,"keys":[{"appName":"Turf","key":"wf_maps_live_0123456789abcdef0123","usage":{"today":3,"last30Days":40}}]}
    ));
    try testing.expect(D.findText("wf_maps_live_012••••••••••••••••0123") != 0);
    try testing.expect(D.findText("3 calls today · 40 in the last 30 days") != 0);
    try D.typeInto("e.g., Turf Logistics Production", "Shop");
    try D.press("Create Key");
    const req = D.pending("/api/developer/keys/create").?;
    _ = req;
    try D.press("Location Picker");
    try D.press("Copy Snippet to Clipboard");
    try testing.expect(std.mem.indexOf(u8, zui.host.clipboard.items, "src=\"https://maps.example.com/embed/picker?key=wf_maps_live_0123456789abcdef0123\"") != null);
}

test "signed out: the docs and a sign-in button" {
    D.start(1000, 800);
    defer D.reset();
    try testing.expect(D.respond("/api/developer/me", 200, "{\"success\":true,\"user\":null}"));
    try testing.expect(D.findText("Maps Embed API") != 0);
    try D.press("Log in via Wufour");
    try testing.expectEqualStrings("/auth", zui.host.opened.items);
}
