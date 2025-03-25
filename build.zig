const std = @import("std");

const log = std.log.scoped(.BUILD);

pub fn build(b: *std.Build) !void {
    const WEB_DIR = b.option(std.Build.LazyPath, "web_dir", "Web Directory") orelse b.path("example_www");
    const HTTP_PORT = b.option(u16, "http_port", "Port on which to listen for HTTP Requests") orelse 80;
    const HTTPS_PORT = b.option(u16, "https_port", "Port on which to listen for HTTPS Requests") orelse 443;
    const CLIENT_TIMEOUT_S = b.option(usize, "client_timeout_s", "How long in seconds a tcp connection should stay open without communication") orelse 60;
    const SSL_PRIVATE_KEY = b.option([]const u8, "ssl_private_key", "SSL Private Key, '.key' file name.") orelse "localhost.key";
    const SSL_PUBLIC_CRT = b.option([]const u8, "ssl_public_crt", "SSL Public Certificate, '.crt' file name.") orelse "localhost.crt";

    const config = b.addOptions();
    config.addOption(u16, "http_port", HTTP_PORT);
    config.addOption(u16, "https_port", HTTPS_PORT);
    config.addOption(usize, "client_timeout_s", CLIENT_TIMEOUT_S);
    config.addOption([]const u8, "ssl_private_key", SSL_PRIVATE_KEY);
    config.addOption([]const u8, "ssl_public_crt", SSL_PUBLIC_CRT);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod_sqlite = b.addModule("sqlite", .{
        .root_source_file = b.path("sqlite/sqlite.zig"),
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    mod_sqlite.addCSourceFile(.{ .file = b.path("sqlite/sqlite3.c"), .flags = &.{"-std=c99"} });
    mod_sqlite.addIncludePath(b.path("sqlite"));

    const util = b.addModule("util", .{
        .root_source_file = b.path("util/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_http = b.addModule("http", .{
        .root_source_file = b.path("http/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_http.addImport("util", util);

    const mod_server = b.addModule("server", .{
        .root_source_file = b.path("server/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_server.addImport("sqlite", mod_sqlite);
    mod_server.addImport("http", mod_http);

    const install_www_path = "www";
    const install_www = b.addInstallDirectory(.{
        .source_dir = WEB_DIR,
        .install_subdir = install_www_path,
        .install_dir = .prefix,
    });

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var modules = std.ArrayList(*std.Build.Module).init(gpa);
    defer modules.deinit();

    var module_paths = std.ArrayList([]const u8).init(gpa);
    defer module_paths.deinit();

    const web_dir = try WEB_DIR.src_path.owner.build_root.handle.openDir(WEB_DIR.src_path.sub_path, .{ .iterate = true });

    var build_info = BuildInfo{
        .allocator = arena,
        .b = b,
        .web_dir = WEB_DIR,
        .modules = &modules,
        .module_paths = &module_paths,
    };
    try gen_resources(web_dir, "", &build_info);

    const gen_options = b.addOptions();
    gen_options.addOption([]const []const u8, "paths", module_paths.items);

    const mod_gen_structure = b.addModule("gen_structure", .{
        .root_source_file = b.path("gen_structure.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_gen_structure.addOptions("options", gen_options);

    const gen_structure_exe = b.addRunArtifact(b.addExecutable(.{
        .name = "gen_structure",
        .root_module = mod_gen_structure,
    }));
    const output = gen_structure_exe.addOutputFileArg("structure.zig");
    gen_structure_exe.has_side_effects = true;
    gen_structure_exe.step.dependOn(&install_www.step);

    const mod_structure = b.addModule("structure", .{
        .root_source_file = output,
        .target = target,
        .optimize = optimize,
    });
    for (modules.items, module_paths.items) |mod, path| {
        if (std.mem.endsWith(u8, path, ".zig")) {
            mod.addImport("server", mod_server);
        }
        mod_structure.addImport(path, mod);
    }
    mod_structure.addImport("server", mod_server);

    const mod_exe = b.addModule("server_exe", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_exe.addImport("server", mod_server);
    mod_exe.addImport("structure", mod_structure);
    mod_exe.addOptions("config", config);

    mod_exe.linkSystemLibrary("ssl", .{});

    const exe = b.addExecutable(.{
        .name = "server_exe",
        .root_module = mod_exe,
    });
    b.installArtifact(exe);

    b.getInstallStep().dependOn(&gen_structure_exe.step);
}

const BuildInfo = struct {
    allocator: std.mem.Allocator,
    b: *std.Build,
    web_dir: std.Build.LazyPath,
    modules: *std.ArrayList(*std.Build.Module),
    module_paths: *std.ArrayList([]const u8),
};

fn gen_resources(
    dir: std.fs.Dir,
    import_path: []const u8,
    build_info: *BuildInfo,
) (std.mem.Allocator.Error || std.fs.Dir.Iterator.Error || std.fs.Dir.OpenError)!void {
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        const current_name = try std.fmt.allocPrint(build_info.allocator, "{s}/{s}", .{ import_path, entry.name });
        switch (entry.kind) {
            .file => {
                const module_path = try std.fmt.allocPrint(build_info.allocator, "{s}{s}", .{ build_info.web_dir.src_path.sub_path, current_name });
                try build_info.modules.append(build_info.b.addModule(current_name, .{
                    .root_source_file = build_info.web_dir.src_path.owner.path(module_path),
                }));
                try build_info.module_paths.append(current_name);
                log.info("mod_name = '{s}', mod_path = '{s}'", .{ current_name, module_path });
            },
            .directory => {
                const child_import_path = current_name;
                defer build_info.allocator.free(child_import_path);

                var child_dir = try dir.openDir(entry.name, .{ .iterate = true });
                defer child_dir.close();

                try gen_resources(child_dir, child_import_path, build_info);
            },
            else => {
                log.err("Not a file or directory {s}:'{s}'", .{ @tagName(entry.kind), entry.name });
            },
        }
    }
}
