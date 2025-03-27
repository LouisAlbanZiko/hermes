const std = @import("std");

const log = std.log.scoped(.CONFIG);

const Config = @This();
client_timeout_s: usize,
poll_timeout_s: usize,
http: struct {
    port: u16,
},
https: struct {
    port: u16,
    cert: []const u8,
    key: []const u8,
},

pub fn default() Config {
    return Config {
        .client_timeout_s = 60,
        .poll_timeout_s = 25,
        .http = .{
            .port = 80,
        },
        .https = .{
            .port = 443,
            .cert = "localhost.crt",
            .key = "localhost.key",
        },
    };
}

pub fn load(arena: std.mem.Allocator, path: []const u8) Config {
    const config_file = std.fs.cwd().openFile(path, std.fs.File.OpenFlags{.mode = .read_only}) catch |err| {
        log.warn("Failed to open file at '{s}' with Error({s})", .{path, @errorName(err)});
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
        log.warn("Failed to read config file '{s}' with Error({s})", .{path, @errorName(err)});
        log.info("Loading defaults.", .{});
        return Config.default();
    };
    defer arena.free(content);

    const config = std.zon.parse.fromSlice(Config, arena, content, null, .{}) catch |err| {
        log.warn("Failed to parse config file at '{s}' with Error({s})", .{path, @errorName(err)});
        log.info("Loading defaults.", .{});
        return Config.default();
    };
    
    return config;
}

