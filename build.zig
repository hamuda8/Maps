const std = @import("std");
const core = @import("zig_core");

pub fn build(b: *std.Build) void {
    // Where the phone apps reach the Maps server. For development over USB:
    //   adb reverse tcp:5106 tcp:5106  and  zig build android -Dserver=http://127.0.0.1:5106
    const options = b.addOptions();
    options.addOption([]const u8, "server", b.option([]const u8, "server", "Maps server for the phone apps") orelse "https://maps.wreseal.com");
    // Wufour (accounts): the phones' in-app sign-in from the account menu.
    options.addOption([]const u8, "auth", b.option([]const u8, "auth", "Wufour (accounts) for sign-in") orelse "https://www.wreseal.com");

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
    // The npm scripts of the Node version, one command each (tools/run.ps1 does the builds):
    //   zig build local        this machine, with ../Maps-js/.env.local, in this window
    //   zig build staging      maps.wreseal.com, with ../Maps-js/.env.staging, in the background
    //   zig build production   the Linux server and pages for Proxmox, in zig-out/production
    for ([_][2][]const u8{
        .{ "local", "Build and run on this machine (like npm run local)" },
        .{ "staging", "Build and start staging in the background (like npm run staging)" },
        .{ "production", "Build the Linux server and pages for Proxmox into zig-out/production" },
    }) |m| {
        const run = b.addSystemCommand(&.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" });
        run.addFileArg(b.path("tools/run.ps1"));
        run.addArgs(&.{ "-Mode", m[0], "-Zig", b.graph.zig_exe });
        run.has_side_effects = true;
        b.step(m[0], m[1]).dependOn(&run.step);
    }
    b.step("dev", "Same as zig build local (like npm run dev)").dependOn(&b.top_level_steps.get("local").?.step);
}
