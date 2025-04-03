const std = @import("std");

const log = std.log.scoped(.BUILD);

pub fn build(b: *std.Build) !void {
    const WEB_DIR = b.option(std.Build.LazyPath, "web_dir", "Web Directory") orelse b.path("example_www");
    const MOD_DIR = b.option(std.Build.LazyPath, "mod_dir", "Directory containing handlers used by the handlers");
    const EXE_NAME = b.option([]const u8, "exe_name", "Name of the executable produced") orelse "server_exe";

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

    const mod_util = b.addModule("util", .{
        .root_source_file = b.path("util/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_util.addCSourceFile(.{ .file = b.path("util/time_fmt.c"), .flags = &.{"-std=c99"} });
    mod_util.addIncludePath(b.path("util"));

    const mod_http = b.addModule("http", .{
        .root_source_file = b.path("http/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_http.addImport("util", mod_util);

    const mod_server = b.addModule("server", .{
        .root_source_file = b.path("server/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_server.addImport("util", mod_util);
    mod_server.addImport("sqlite", mod_sqlite);
    mod_server.addImport("http", mod_http);

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var modules = std.ArrayList(Dependency).init(gpa);
    defer modules.deinit();

    if (MOD_DIR) |mod_dir_path| {
        var build_info = BuildInfo{
            .allocator = arena,
            .b = b,
            .dir_path = mod_dir_path,
            .target = target,
            .optimize = optimize,
        };
        var mod_dir = try mod_dir_path.src_path.owner.build_root.handle.openDir(mod_dir_path.src_path.sub_path, .{ .iterate = true });
        defer mod_dir.close();

        try gen_modules(mod_dir, "", &build_info, &modules);
    }

    var handlers = std.ArrayList(Dependency).init(gpa);
    defer handlers.deinit();

    var static_files = std.ArrayList(Dependency).init(gpa);
    defer static_files.deinit();

    var build_info = BuildInfo{
        .allocator = arena,
        .b = b,
        .dir_path = WEB_DIR,
        .target = target,
        .optimize = optimize,
    };
    var web_dir = try WEB_DIR.src_path.owner.build_root.handle.openDir(WEB_DIR.src_path.sub_path, .{ .iterate = true });
    defer web_dir.close();
    try gen_resources(
        web_dir,
        "",
        &build_info,
        modules.items,
        &handlers,
        &static_files,
    );

    var handler_paths = std.ArrayList([]const u8).init(gpa);
    defer handler_paths.deinit();

    for (handlers.items) |dep| {
        try handler_paths.append(dep.name);
    }
    for (static_files.items) |dep| {
        try handler_paths.append(dep.name);
    }

    var mod_paths = std.ArrayList([]const u8).init(gpa);
    defer mod_paths.deinit();

    for (modules.items) |dep| {
        try mod_paths.append(dep.name);
    }

    const gen_options = b.addOptions();
    gen_options.addOption([]const []const u8, "paths", handler_paths.items);
    gen_options.addOption([]const []const u8, "mods", mod_paths.items);

    const mod_gen_structure = b.addModule("gen_structure", .{
        .root_source_file = b.path("gen_structure.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_gen_structure.addOptions("options", gen_options);

    const gen_structure_exe = b.addExecutable(.{
        .name = "gen_structure_exe",
        .root_module = mod_gen_structure,
    });
    const gen_structure_artifact = b.addRunArtifact(gen_structure_exe);
    const output = gen_structure_artifact.addOutputFileArg("structure.zig");
    gen_structure_artifact.has_side_effects = true;

    std.debug.print("Added gen_structure_exe\n", .{});

    const mod_structure = b.addModule("structure", .{
        .root_source_file = output,
        .target = target,
        .optimize = optimize,
    });
    for (handlers.items) |dep| {
        dep.mod.addImport("server", mod_server);
        for (modules.items) |imp| {
            dep.mod.addImport(imp.name, imp.mod);
        }
        mod_structure.addImport(dep.name, dep.mod);
    }
    for (static_files.items) |dep| {
        mod_structure.addImport(dep.name, dep.mod);
    }
    for (modules.items) |dep| {
        dep.mod.addImport("server", mod_server);
        mod_structure.addImport(dep.name, dep.mod);
    }
    mod_structure.addImport("server", mod_server);

    var options = b.addOptions();
    options.addOption(std.builtin.OptimizeMode, "optimize", optimize);
    options.addOption([]const u8, "exe_name", EXE_NAME);

    const mod_exe = b.addModule(EXE_NAME, .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_exe.addImport("server", mod_server);
    mod_exe.addImport("structure", mod_structure);
    mod_exe.addImport("util", mod_util);
    mod_exe.addOptions("options", options);

    mod_exe.linkSystemLibrary("ssl", .{});

    const exe = b.addExecutable(.{
        .name = EXE_NAME,
        .root_module = mod_exe,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}

const BuildInfo = struct {
    allocator: std.mem.Allocator,
    b: *std.Build,
    dir_path: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

const Dependency = struct {
    name: []const u8,
    mod: *std.Build.Module,
};

fn gen_modules(
    dir: std.fs.Dir,
    import_path: []const u8,
    build_info: *BuildInfo,
    modules: *std.ArrayList(Dependency),
) !void {
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        const current_name = try std.fmt.allocPrint(build_info.allocator, "{s}/{s}", .{ import_path, entry.name });
        switch (entry.kind) {
            .file => {
                const module_path = try std.fmt.allocPrint(build_info.allocator, "{s}{s}", .{ build_info.dir_path.src_path.sub_path, current_name });
                const mod = build_info.b.addModule(current_name, .{
                    .root_source_file = build_info.dir_path.src_path.owner.path(module_path),
                    .target = build_info.target,
                    .optimize = build_info.optimize,
                });
                try modules.append(.{
                    .name = current_name,
                    .mod = mod,
                });
                log.info("Added module at '{s}'.", .{current_name});
            },
            .directory => {
                const child_import_path = current_name;
                defer build_info.allocator.free(child_import_path);

                var child_dir = try dir.openDir(entry.name, .{ .iterate = true });
                defer child_dir.close();

                try gen_modules(child_dir, child_import_path, build_info, modules);
            },
            else => {
                log.err("Not a file or directory {s}:'{s}'", .{ @tagName(entry.kind), entry.name });
            },
        }
    }
}

fn gen_resources(
    dir: std.fs.Dir,
    import_path: []const u8,
    build_info: *BuildInfo,
    modules: []const Dependency,
    handlers: *std.ArrayList(Dependency),
    static_files: *std.ArrayList(Dependency),
) (std.mem.Allocator.Error || std.fs.Dir.Iterator.Error || std.fs.Dir.OpenError)!void {
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        const current_name = try std.fmt.allocPrint(build_info.allocator, "{s}/{s}", .{ import_path, entry.name });
        switch (entry.kind) {
            .file => {
                const module_path = try std.fmt.allocPrint(build_info.allocator, "{s}{s}", .{ build_info.dir_path.src_path.sub_path, current_name });
                if (std.mem.endsWith(u8, current_name, ".zig")) {
                    const mod = build_info.b.addModule(current_name, .{
                        .root_source_file = build_info.dir_path.src_path.owner.path(module_path),
                        .target = build_info.target,
                        .optimize = build_info.optimize,
                    });
                    for (modules) |dep| {
                        mod.addImport(dep.name, dep.mod);
                    }
                    try handlers.append(.{
                        .name = current_name,
                        .mod = mod,
                    });
                    log.info("Added handler at '{s}'.", .{current_name});
                } else if (std.mem.endsWith(u8, current_name, ".template")) {
                    log.info("Found template at '{s}'. Skipping!", .{current_name});
                } else {
                    const mod = build_info.b.addModule(current_name, .{
                        .root_source_file = build_info.dir_path.src_path.owner.path(module_path),
                    });
                    try static_files.append(.{
                        .name = current_name,
                        .mod = mod,
                    });
                    log.info("Added static file at '{s}'.", .{current_name});
                }
            },
            .directory => {
                const child_import_path = current_name;
                defer build_info.allocator.free(child_import_path);

                var child_dir = try dir.openDir(entry.name, .{ .iterate = true });
                defer child_dir.close();

                try gen_resources(child_dir, child_import_path, build_info, modules, handlers, static_files);
            },
            else => {
                log.err("Not a file or directory {s}:'{s}'", .{ @tagName(entry.kind), entry.name });
            },
        }
    }
}
