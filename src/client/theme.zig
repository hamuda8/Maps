//! Maps colors, from Maps-js `public/styles/theme.css` (brand blue #2563eb, brand dark #0f172a,
//! soft borders, the green navigation banner and red exit), with a dark variant.

const zui = @import("zui");
const Color = zui.Color;

pub const Colors = struct {
    page: Color,
    /// The search / directions panel (95% opaque, as the glass panel on the web).
    panel: Color,
    field: Color,
    field_line: Color,
    ink: Color,
    ink_2: Color,
    /// List rows and quiet backgrounds.
    soft: Color,
    line: Color,
    brand: Color,
    brand_soft: Color,
    danger: Color,
    nav: Color,
    nav_2: Color,
    shadow: Color,
};

const light: Colors = .{
    .page = Color.hex("#f8fafc"),
    .panel = Color.hex("#fffffff2"),
    .field = Color.hex("#ffffff"),
    .field_line = Color.hex("#cbd5e1"),
    .ink = Color.hex("#0f172a"),
    .ink_2 = Color.hex("#64748b"),
    .soft = Color.hex("#f8fafc"),
    .line = Color.hex("#00000014"),
    .brand = Color.hex("#2563eb"),
    .brand_soft = Color.hex("#e0e7ff"),
    .danger = Color.hex("#ef4444"),
    .nav = Color.hex("#0f9d58"),
    .nav_2 = Color.hex("#10b981"),
    .shadow = Color.hex("#0000001a"),
};

const dark: Colors = .{
    .page = Color.hex("#0b1120"),
    .panel = Color.hex("#111a2ef2"),
    .field = Color.hex("#0b1120"),
    .field_line = Color.hex("#334155"),
    .ink = Color.hex("#f1f5f9"),
    .ink_2 = Color.hex("#94a3b8"),
    .soft = Color.hex("#1e293b"),
    .line = Color.hex("#ffffff1a"),
    .brand = Color.hex("#3b82f6"),
    .brand_soft = Color.hex("#1e3a8a"),
    .danger = Color.hex("#ef4444"),
    .nav = Color.hex("#0f9d58"),
    .nav_2 = Color.hex("#10b981"),
    .shadow = Color.hex("#00000066"),
};

pub fn colors(is_dark: bool) Colors {
    return if (is_dark) dark else light;
}
