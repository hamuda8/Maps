//! API keys: lookups cached for 30 seconds (a revoked key stops working within 30 s, at once
//! after `forget`), and usage counted in memory and written once a minute to the "usage"
//! collection, one document per key per day: { key, day: "2026-10-07", counts: { route: 12 } }.
//! The same documents Maps-js writes.

const std = @import("std");
const mongo = @import("mongo");
const bson = mongo.bson;
const a_ = @import("app.zig");

pub const Key = struct {
    user_id: []const u8,
    app_name: []const u8,
};

const cache_ms = 30_000;

const Cached = struct { key: ?Key, until_ms: i64 };

var lock: std.Io.Mutex = .init;
/// Owned by the gpa.
var cache: std.StringHashMapUnmanaged(Cached) = .empty;
/// "key|day" → endpoint → count, all owned by the gpa.
var pending: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(u32)) = .empty;

/// The active key, or null. Counts one use of `endpoint` when the key is valid.
pub fn findActive(key: []const u8, endpoint: ?[]const u8) !?Key {
    if (key.len == 0 or key.len > 200) return null;
    const app = a_.app;
    const now = a_.nowMs();

    lock.lockUncancelable(app.io);
    const hit = if (cache.get(key)) |c| (if (c.until_ms >= now) c else null) else null;
    lock.unlock(app.io);

    const found: ?Key = if (hit) |h| h.key else blk: {
        var arena = std.heap.ArenaAllocator.init(app.gpa);
        defer arena.deinit();
        const doc = try app.collection("apiKeys").findOne(arena.allocator(), .{ .key = key, .status = "active" }, .{});
        var id_buf: [24]u8 = undefined;
        const k: ?Key = if (doc) |d| .{
            .user_id = try app.gpa.dupe(u8, idString(d.get("userId"), &id_buf) orelse ""),
            .app_name = try app.gpa.dupe(u8, d.getString("appName") orelse ""),
        } else null;
        lock.lockUncancelable(app.io);
        defer lock.unlock(app.io);
        if (cache.count() > 5000) clearCache();
        const gop = try cache.getOrPut(app.gpa, key);
        if (gop.found_existing) freeKey(gop.value_ptr.key) else gop.key_ptr.* = try app.gpa.dupe(u8, key);
        gop.value_ptr.* = .{ .key = k, .until_ms = now + cache_ms };
        break :blk k;
    };
    if (found != null) if (endpoint) |e| count(key, e);
    return found;
}

/// userId may have been stored as a string or an ObjectId (hex, written into `buf`).
pub fn idString(v: ?bson.Value, buf: *[24]u8) ?[]const u8 {
    const value = v orelse return null;
    return switch (value) {
        .string => |s| s,
        .object_id => |id| blk: {
            buf.* = id.toHex();
            break :blk buf;
        },
        else => null,
    };
}

fn freeKey(k: ?Key) void {
    if (k) |key| {
        a_.app.gpa.free(key.user_id);
        a_.app.gpa.free(key.app_name);
    }
}

fn clearCache() void {
    var it = cache.iterator();
    while (it.next()) |e| {
        a_.app.gpa.free(e.key_ptr.*);
        freeKey(e.value_ptr.key);
    }
    cache.clearRetainingCapacity();
}

/// Forgets a cached key at once (after revoking it).
pub fn forget(key: []const u8) void {
    lock.lockUncancelable(a_.app.io);
    defer lock.unlock(a_.app.io);
    if (cache.fetchRemove(key)) |kv| {
        a_.app.gpa.free(kv.key);
        freeKey(kv.value.key);
    }
}

fn count(key: []const u8, endpoint: []const u8) void {
    const app = a_.app;
    var day_buf: [10]u8 = undefined;
    var id_buf: [256]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{s}|{s}", .{ key, a_.today(&day_buf) }) catch return;
    lock.lockUncancelable(app.io);
    defer lock.unlock(app.io);
    const gop = pending.getOrPut(app.gpa, id) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = app.gpa.dupe(u8, id) catch {
            _ = pending.remove(id);
            return;
        };
        gop.value_ptr.* = .empty;
    }
    const c = gop.value_ptr.getOrPut(app.gpa, endpoint) catch return;
    if (!c.found_existing) {
        c.key_ptr.* = app.gpa.dupe(u8, endpoint) catch {
            _ = gop.value_ptr.remove(endpoint);
            return;
        };
        c.value_ptr.* = 0;
    }
    c.value_ptr.* += 1;
}

/// Writes the counted uses to the usage collection.
pub fn flush() void {
    const app = a_.app;
    lock.lockUncancelable(app.io);
    var batch = pending;
    pending = .empty;
    lock.unlock(app.io);
    defer {
        var it = batch.iterator();
        while (it.next()) |e| {
            var c = e.value_ptr.iterator();
            while (c.next()) |ce| app.gpa.free(ce.key_ptr.*);
            e.value_ptr.deinit(app.gpa);
            app.gpa.free(e.key_ptr.*);
        }
        batch.deinit(app.gpa);
    }
    if (batch.count() == 0) return;

    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var stmts: std.ArrayList(mongo.Collection.UpdateStatement) = .empty;
    var it = batch.iterator();
    while (it.next()) |e| {
        const bar = std.mem.indexOfScalar(u8, e.key_ptr.*, '|') orelse continue;
        var inc = bson.Builder.init(a) catch return;
        inc.beginDoc("$inc") catch return;
        var c = e.value_ptr.iterator();
        while (c.next()) |ce| {
            const field = std.fmt.allocPrint(a, "counts.{s}", .{ce.key_ptr.*}) catch return;
            inc.int32(field, @intCast(ce.value_ptr.*)) catch return;
        }
        inc.end() catch return;
        stmts.append(a, .{
            .filter = bson.encode(a, .{ .key = e.key_ptr.*[0..bar], .day = e.key_ptr.*[bar + 1 ..] }) catch return,
            .update = inc.finish() catch return,
            .upsert = true,
        }) catch return;
    }
    app.collection("usage").bulkUpdate(a, stmts.items) catch |err| std.log.warn("usage write failed: {t}", .{err});
}

/// Flushes every minute (MAPS_USAGE_FLUSH_S). Run as its own task.
pub fn flushLoop() void {
    while (true) {
        a_.app.io.sleep(.fromSeconds(a_.app.config.usage_flush_s), .awake) catch return;
        flush();
    }
}
