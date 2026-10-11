//! Wufour Maps client. The same code is compiled for the web, Android and iOS.

const std = @import("std");
const zui = @import("zui");

pub const app: zui.App = .{
    .name = "Wufour Maps",
    .start = start,
};

comptime {
    zui.exportApp(app);
}

fn start(ui: *zui.Ui) void {
    ui.text("Wufour Maps · خرائط وفور");
}

test "start shows the app name" {
    var ctx: zui.host.Context = .{};
    var ui: zui.Ui = .{ .ctx = &ctx };
    start(&ui);
    try std.testing.expectEqualStrings("Wufour Maps · خرائط وفور", ctx.shown);
}
