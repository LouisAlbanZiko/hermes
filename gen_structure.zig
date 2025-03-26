const std = @import("std");

const options = @import("options");

const log = std.log.scoped(.GEN_STRUCTURE);

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();

    const gpa = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const args_count = 2;
    if (args.len != args_count) fatal("Expected {d} arguments. Got {d}.", .{ args_count, args.len });

    const output_file_path = args[1];

    var output_file = std.fs.cwd().createFile(output_file_path, .{}) catch |err| {
        fatal("Unable to open output file '{s}' with Error({s})", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close();

    const w = output_file.writer();

    log.info("Outputing structure to file '{s}'", .{output_file_path});

    var root_dir = BuildResourceDir.init(gpa);
    defer root_dir.deinit();

    for (options.paths) |path| {
        log.debug("Generating path '{s}'\n", .{path});

        var current_dir = &root_dir;
        var iter = std.mem.splitScalar(u8, path, std.fs.path.sep);
        if (iter.peek()) |first| {
            if (first.len == 0) {
                _ = iter.next();
            }
        }
        while (iter.next()) |entry| {
            var has_br: ?*BuildResource = null;
            for (current_dir.items) |*br| {
                if (std.mem.eql(u8, br.path, entry)) {
                    has_br = br;
                }
            }

            if (iter.peek()) |_| {
                if (has_br) |br| {
                    switch (br.value) {
                        .directory => |_| {
                            current_dir = &br.value.directory;
                        },
                        else => {
                            log.err("Path is not a dir '{s}','{s}'", .{ path, entry });
                            break;
                        },
                    }
                } else {
                    const br = BuildResource{
                        .path = entry,
                        .value = .{
                            .directory = BuildResourceDir.init(arena),
                        },
                    };
                    try current_dir.append(br);
                    current_dir = &current_dir.items[current_dir.items.len - 1].value.directory;
                    log.info("Added dir '{s}'", .{entry});
                }
            } else {
                const br = BuildResource{
                    .path = entry,
                    .value = .{ .file = path },
                };
                try current_dir.append(br);
                log.info("Added file at '{s}'", .{path});
            }
        }
    }

    try std.fmt.format(w,
        \\const ServerResource = @import("server").ServerResource; 
        \\pub const www = &[_]ServerResource{{
    , .{});
    for (root_dir.items) |br| {
        try br.write_zig(w);
    }
    try std.fmt.format(w,
        \\}};
    , .{});
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.process.exit(1);
}

const BuildResourceType = enum { file, directory };
const BuildResourceDir = std.ArrayList(BuildResource);
const BuildResource = struct {
    path: []const u8,
    value: union(BuildResourceType) {
        file: []const u8,
        directory: BuildResourceDir,
    },
    pub fn write_zig(
        self: @This(),
        writer: anytype,
    ) !void {
        switch (self.value) {
            .file => |full_path| {
                var resource_type: []const u8 = undefined;
                var function: []const u8 = undefined;
                var name: []const u8 = undefined;
                if (std.mem.endsWith(u8, full_path, ".zig")) {
                    resource_type = "handler";
                    function = "import";
                    name = self.path[0 .. self.path.len - ".zig".len];
                } else {
                    resource_type = "file";
                    function = "embedFile";
                    name = self.path;
                }
                try std.fmt.format(
                    writer,
                    \\.{{ .path="{s}",.value=.{{.{s}=@{s}("{s}")}}}},
                ,
                    .{ name, resource_type, function, full_path },
                );
            },
            .directory => |dir| {
                try std.fmt.format(
                    writer,
                    \\.{{.path="{s}",.value=.{{.directory=&[_]ServerResource{{
                ,
                    .{self.path},
                );
                for (dir.items) |br| {
                    try br.write_zig(writer);
                }
                try writer.writeAll("}}}\n");
            },
        }
    }
};
