const std = @import("std");
const core = @import("zig_core");

pub fn build(b: *std.Build) void {
    core.addApp(b, b.dependency("zig_core", .{}), .{
        .name = "maps",
        .client = b.path("src/client/app.zig"),
        .server = b.path("src/server/main.zig"),
        .web = b.path("shells/web"),
        .android_manifest = b.path("shells/android/AndroidManifest.xml"),
        .ios_info_plist = b.path("shells/ios/Info.plist"),
        .optimize = b.standardOptimizeOption(.{}),
    });
}
