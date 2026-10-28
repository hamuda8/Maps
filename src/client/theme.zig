//! Maps' colours: the ten TwOP roles of Wufour's `private/site/apps.js` (`maps.colors`), the
//! dark theme derived from them with the OKLCH formulas of Wufour's `style.css` (never
//! hand-picked), and the semantic tokens the screens use. Every token is a role colour or a
//! role colour with alpha: no other colours exist in the app.
//!
//! `src/developers/developers.zig` is its own module and cannot import this file; it repeats
//! the roles and formulas with this file as the source. Change both together.

const std = @import("std");
const zui = @import("zui");
const Color = zui.Color;

// The roles (apps.js). Maps defines no risky colour, so the shared signal colour is used.
pub const base = Color.hex("#ffffff");
pub const core = Color.hex("#0f172a");
pub const accent = Color.hex("#2563eb");
pub const variant = Color.hex("#0f172a");
pub const surface = Color.hex("#f8fafc");
pub const depth = Color.hex("#cbd5e1");
pub const optimal = Color.hex("#10b981");
pub const risky = Color.hex("#F0F054");
pub const fatal = Color.hex("#ef4444");
/// apps.js defines no prime for Maps; the brand is the accent until the owner adds one.
pub const prime = accent;

pub const Colors = struct {
    // The roles after the light/dark transform (--color-b, -c, -a, -v, -s, -d, -o, -r, -f, -p).
    b: Color,
    c: Color,
    a: Color,
    v: Color,
    s: Color,
    d: Color,
    o: Color,
    r: Color,
    f: Color,
    p: Color,

    /// The map page behind everything (base).
    page: Color,
    /// The search / directions panel (surface, 95% opaque as the glass panel on the web).
    panel: Color,
    /// Inputs and floating buttons (base).
    field: Color,
    /// Input borders (depth).
    field_line: Color,
    ink: Color,
    ink_2: Color,
    /// List rows and quiet backgrounds (surface).
    soft: Color,
    line: Color,
    /// The action colour (accent): route line, Start, the live dot.
    brand: Color,
    brand_soft: Color,
    danger: Color,
    /// Navigation banners (optimal).
    nav: Color,
    nav_2: Color,
    shadow: Color,
    /// Text and marks on the accent, on the navigation banners, on danger and on ink: base or
    /// core, whichever is further from the background in lightness.
    on_accent: Color,
    on_nav: Color,
    on_danger: Color,
    on_ink: Color,
    dark: bool,
};

/// `oklch(from C clamp(lo, 1 - l*l, hi) c*k h)`, with k = max(floor, 1 - l*slope): the
/// dark-mode transforms of style.css (canvas, text, border, brand, action, signal).
fn darkOf(c: Color, lo: f32, hi: f32, floor: f32, slope: f32) Color {
    var o = c.toOklch();
    const k = @max(floor, 1 - o.l * slope);
    o.l = std.math.clamp(1 - o.l * o.l, lo, hi);
    o.c *= k;
    return o.toColor();
}

fn darkCanvas(c: Color) Color {
    return darkOf(c, 0.10, 0.25, 0.5, 0);
}
fn darkText(c: Color) Color {
    return darkOf(c, 0.85, 0.95, 0.6, 0);
}
fn darkBorder(c: Color) Color {
    return darkOf(c, 0.25, 0.40, 0.4, 0);
}
fn darkBrand(c: Color) Color {
    return darkOf(c, 0.25, 0.55, 0.60, 0.40);
}
fn darkAction(c: Color) Color {
    return darkOf(c, 0.45, 0.75, 0.70, 0.30);
}
fn darkSignal(c: Color) Color {
    return darkOf(c, 0.45, 0.80, 0.75, 0.25);
}

/// Base or core, whichever is further from `bg` in OKLCH lightness.
fn readableOn(bg: Color, b: Color, c: Color) Color {
    const l = bg.toOklch().l;
    return if (@abs(b.toOklch().l - l) >= @abs(c.toOklch().l - l)) b else c;
}

pub fn colors(is_dark: bool) Colors {
    const b = if (is_dark) darkCanvas(base) else base;
    const s = if (is_dark) darkCanvas(surface) else surface;
    const c = if (is_dark) darkText(core) else core;
    const d = if (is_dark) darkBorder(depth) else depth;
    const p = if (is_dark) darkBrand(prime) else prime;
    const a = if (is_dark) darkAction(accent) else accent;
    const v = if (is_dark) darkAction(variant) else variant;
    const o = if (is_dark) darkSignal(optimal) else optimal;
    const r = if (is_dark) darkSignal(risky) else risky;
    const f = if (is_dark) darkSignal(fatal) else fatal;
    return .{
        .b = b,
        .c = c,
        .a = a,
        .v = v,
        .s = s,
        .d = d,
        .o = o,
        .r = r,
        .f = f,
        .p = p,
        .page = b,
        .panel = s.withAlpha(0.95),
        .field = b,
        .field_line = d,
        .ink = c,
        .ink_2 = c.withAlpha(0.64),
        .soft = s,
        .line = d.withAlpha(0.40),
        .brand = a,
        .brand_soft = a.withAlpha(0.12),
        .danger = f,
        .nav = o,
        .nav_2 = o,
        .shadow = c.withAlpha(if (is_dark) 0.45 else 0.10),
        .on_accent = readableOn(a, b, c),
        .on_nav = readableOn(o, b, c),
        .on_danger = readableOn(f, b, c),
        .on_ink = readableOn(c, b, c),
        .dark = is_dark,
    };
}

test "light is the palette, dark is derived" {
    const k = colors(false);
    try std.testing.expect(k.page.eql(base));
    try std.testing.expect(k.brand.eql(accent));
    try std.testing.expect(k.nav.eql(optimal));
    // Light text on the blue action colour, dark text on the white page.
    try std.testing.expect(k.on_accent.eql(base));
    try std.testing.expect(k.on_ink.eql(base));
    const dk = colors(true);
    try std.testing.expect(dk.page.toOklch().l <= 0.26);
    try std.testing.expect(dk.ink.toOklch().l >= 0.84);
    try std.testing.expect(dk.brand.toOklch().l >= 0.44);
}
