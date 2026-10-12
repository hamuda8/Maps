const std = @import("std");
const core = @import("zig_core");

pub fn build(b: *std.Build) void {
    // Where the phone apps reach the Maps server. For development over USB:
    //   adb reverse tcp:5106 tcp:5106  and  zig build android -Dserver=http://127.0.0.1:5106
    const options = b.addOptions();
    options.addOption([]const u8, "server", b.option([]const u8, "server", "Maps server for the phone apps") orelse "https://maps.wreseal.com");

    core.addApp(b, b.dependency("zig_core", .{}), .{
        .client_config = options.createModule(),
        .name = "maps",
        .client = b.path("src/client/app.zig"),
        .server = b.path("src/server/main.zig"),
        .web = b.path("shells/web"),
        .android_manifest = b.path("shells/android/AndroidManifest.xml"),
        .ios_info_plist = b.path("shells/ios/Info.plist"),
        .android_res = b.path("shells/android/res"),
        .android_res_files = &.{"mipmap-xxxhdpi/ic_launcher.png"},
        // The map of the JS library other sites load (/sdk/wufour-maps.js).
        .web_extra = &.{
            .{ .name = "sdk", .root = b.path("src/sdk/sdk.zig") },
            // The developer console (/developers): API keys and embed snippets.
            .{ .name = "developers", .root = b.path("src/developers/developers.zig") },
        },
        .optimize = b.standardOptimizeOption(.{}),
    });
}
