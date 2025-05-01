const std = @import("std");

const log = std.log.scoped(.CONFIG);

const Config = @This();
client_timeout_s: usize = 60,
poll_timeout_s: usize = 25,
data_dir: ?[]const u8 = null,
http: struct {
    port: u16 = 8080,
} = .{},
https: struct {
    port: u16 = 8443,
    cert: []const u8 = "localhost.crt",
    key: []const u8 = "localhost.key",
} = .{},

pub fn default() Config {
    return Config{};
}

pub fn load(arena: std.mem.Allocator, path: []const u8) Config {
    const config_file = std.fs.cwd().openFile(path, std.fs.File.OpenFlags{ .mode = .read_only }) catch |err| {
        log.warn("Failed to open file at '{s}' with Error({s})", .{ path, @errorName(err) });
        log.info("Loading defaults.", .{});
        return Config.default();
    };
    defer config_file.close();
    const content = config_file.readToEndAllocOptions(
        arena,
        8096,
        null,
        8,
        0,
    ) catch |err| {
        log.warn("Failed to read config file '{s}' with Error({s})", .{ path, @errorName(err) });
        log.info("Loading defaults.", .{});
        return Config.default();
    };
    defer arena.free(content);

    const config = std.zon.parse.fromSlice(Config, arena, content, null, .{}) catch |err| {
        log.warn("Failed to parse config file at '{s}' with Error({s})", .{ path, @errorName(err) });
        log.info("Loading defaults.", .{});
        return Config.default();
    };

    return config;
}
