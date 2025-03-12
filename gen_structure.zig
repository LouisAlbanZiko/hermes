const std = @import("std");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();

    const gpa = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    _ = arena_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len != 2) fatal("Expected 2 arguments. Got {d}.", .{args.len});

    const output_file_path = args[1];

    var output_file = std.fs.cwd().createFile(output_file_path, .{}) catch |err| {
        fatal("Unable to open output file '{s}' with Error({s})", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close();

    const w = output_file.writer();

    try std.fmt.format(w,
        \\const ServerResource = @import("server").ServerResource; 
        \\pub const {s} = &[_]ServerResource{{
    , .{"www"});
    try traverse_directory(".", gpa, w);
    try std.fmt.format(w,
        \\}};
    , .{});
}

fn traverse_directory(
    dir_path: []const u8,
    allocator: std.mem.Allocator,
    w: anytype,
) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const extension = std.fs.path.extension(entry.name);
                if (std.mem.eql(u8, extension, ".zig")) {
                    try std.fmt.format(
                        w,
                        \\.{{.path="{s}",.value=.{{.handler=@import("{s}/{s}")}}}},
                    ,
                        .{ std.fs.path.stem(entry.name), dir_path[1..], entry.name },
                    );
                } else if (std.mem.eql(u8, extension, ".template")) {
                    try std.fmt.format(
                        w,
                        \\.{{.path="{s}",.value=.{{.template=@embedFile("{s}/{s}")}}}},
                    ,
                        .{ entry.name, dir_path[1..], entry.name },
                    );
                } else {
                    try std.fmt.format(
                        w,
                        \\.{{.path="{s}",.value=.{{.file=@embedFile("{s}/{s}")}}}},
                    ,
                        .{ entry.name, dir_path[1..], entry.name },
                    );
                }
            },
            .directory => {
                try std.fmt.format(
                    w,
                    \\.{{.path="{s}",.value=.{{.directory=&[_]ServerResource{{
                ,
                    .{entry.name},
                );
                const child_dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
                defer allocator.free(child_dir_path);

                try traverse_directory(child_dir_path, allocator, w);
                try std.fmt.format(w,
                    \\}}}}}},
                , .{});
            },
            else => {},
        }
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format ++ "\n", args);
    std.process.exit(1);
}
