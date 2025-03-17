const std = @import("std");

const log = std.log.scoped(.BUILD);

const WEB_DIR = "www";

pub fn build(b: *std.Build) !void {
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

    const gen_structure = b.addExecutable(.{
        .name = "gen_structure",
        .root_source_file = b.path("gen_structure.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gen_structure_exe = b.addRunArtifact(gen_structure);
    const output = gen_structure_exe.addOutputFileArg("structure.zig");
    gen_structure_exe.addArg(WEB_DIR);
    gen_structure_exe.has_side_effects = true;

    const mod_structure = b.addModule("structure", .{
        .root_source_file = output,
        .target = target,
        .optimize = optimize,
    });
    mod_structure.addImport("server", mod_server);

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();

    const gpa = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    var dirs = std.ArrayList([]const u8).init(gpa);
    try dirs.append(WEB_DIR);
    defer {
        for (1..dirs.items.len) |index| {
            gpa.free(dirs.items[index]);
        }
        dirs.deinit();
    }

    var dir_index: usize = 0;
    while (dir_index < dirs.items.len) {
        var dir = try std.fs.cwd().openDir(dirs.items[dir_index], .{ .iterate = true });
        defer dir.close();

        log.info("Going through dir '{s}'", .{dirs.items[dir_index]});

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            switch (entry.kind) {
                .directory => {
                    const new_dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dirs.items[dir_index], entry.name });
                    try dirs.append(new_dir);
                    log.info("Added dir '{s}' to list", .{new_dir});
                },
                .file => {
                    const mod_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dirs.items[dir_index], entry.name });
                    const mod_name = mod_path[WEB_DIR.len..];

                    const extension = std.fs.path.extension(entry.name);
                    if (std.mem.eql(u8, extension, ".zig")) {
                        const mod = b.addModule(mod_name, .{
                            .root_source_file = b.path(mod_path),
                            .target = target,
                            .optimize = optimize,
                        });
                        mod.addImport("http", mod_http);
                        mod.addImport("server", mod_server);
                        //mod.addImport("ws", mod_ws);
                        mod_structure.addImport(mod_name, mod);
                        log.info("Added file '{s}' as a handler.", .{mod_path});
                    } else {
                        mod_structure.addAnonymousImport(mod_name, .{
                            .root_source_file = b.path(mod_path),
                        });
                        log.info("Added file '{s}' as an embed.", .{mod_path});
                    }
                },
                else => {
                    log.warn("Not a file or directory {s}:'{s}'", .{ @tagName(entry.kind), entry.name });
                },
            }
        }

        dir_index += 1;
    }
    const mod_exe = b.addModule("server_exe", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_exe.addImport("server", mod_server);
    mod_exe.addImport("structure", mod_structure);

    mod_exe.linkSystemLibrary("ssl", .{});

    const exe = b.addExecutable(.{
        .name = "server_exe",
        .root_module = mod_exe,
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(&gen_structure_exe.step);
    b.getInstallStep().dependOn(&gen_structure_exe.step);

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
