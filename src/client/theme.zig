//! Maps colors, from Maps-js `public/styles/theme.css` (brand blue #2563eb, brand dark #0f172a,
//! soft borders), with a dark variant.

const zui = @import("zui");
const Color = zui.Color;

pub const Colors = struct {
    page: Color,
    panel: Color,
    ink: Color,
    ink_2: Color,
    line: Color,
    brand: Color,
};

const light: Colors = .{
    .page = Color.hex("#f8fafc"),
    .panel = Color.hex("#ffffff"),
    .ink = Color.hex("#0f172a"),
    .ink_2 = Color.hex("#64748b"),
    .line = Color.hex("#00000014"),
    .brand = Color.hex("#2563eb"),
};

const dark: Colors = .{
    .page = Color.hex("#0b1120"),
    .panel = Color.hex("#111a2e"),
    .ink = Color.hex("#f1f5f9"),
    .ink_2 = Color.hex("#94a3b8"),
    .line = Color.hex("#ffffff1a"),
    .brand = Color.hex("#3b82f6"),
};

pub fn colors(is_dark: bool) Colors {
    return if (is_dark) dark else light;
}
