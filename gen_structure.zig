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

    const args_count = 3;
    if (args.len != args_count) fatal("Expected {d} arguments. Got {d}.", .{ args_count, args.len });

    const output_file_path = args[1];
    const scan_dir = args[2];

    var dir = std.fs.cwd().openDir(scan_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            fatal("Directory '{s}' doesn't exist.", .{scan_dir});
        },
        else => {
            fatal("Failed to open directory '{s}' with Error({s}).", .{ scan_dir, @errorName(err) });
        },
    };
    defer dir.close();

    var output_file = std.fs.cwd().createFile(output_file_path, .{}) catch |err| {
        fatal("Unable to open output file '{s}' with Error({s})", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close();

    const w = output_file.writer();

    try std.fmt.format(w,
        \\const ServerResource = @import("server").ServerResource; 
        \\pub const {s} = &[_]ServerResource{{
    , .{scan_dir});
    try traverse_directory(&dir, "", gpa, w);
    try std.fmt.format(w,
        \\}};
    , .{});
}

fn traverse_directory(
    dir: *std.fs.Dir,
    current_path: []const u8,
    allocator: std.mem.Allocator,
    w: anytype,
) !void {
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
                        .{ std.fs.path.stem(entry.name), current_path, entry.name },
                    );
                } else if (std.mem.eql(u8, extension, ".template")) {
                    try std.fmt.format(
                        w,
                        \\.{{.path="{s}",.value=.{{.template=@embedFile("{s}/{s}")}}}},
                    ,
                        .{ entry.name, current_path, entry.name },
                    );
                } else {
                    try std.fmt.format(
                        w,
                        \\.{{.path="{s}",.value=.{{.file=@embedFile("{s}/{s}")}}}},
                    ,
                        .{ entry.name, current_path, entry.name },
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
                const new_current_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_path, entry.name });
                defer allocator.free(new_current_path);

                var new_dir = try dir.openDir(entry.name, .{ .iterate = true });
                defer new_dir.close();

                try traverse_directory(&new_dir, new_current_path, allocator, w);
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
