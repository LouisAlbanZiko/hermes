const std = @import("std");

const protocol = @import("protocol.zig");

pub const Method = protocol.Method;
pub const Code = protocol.Code;
pub const ContentType = protocol.ContentType;
pub const Header = protocol.Header;

pub const Request = @import("Request.zig");
pub const Response = @import("Response.zig");

const ServerResource = @import("../ServerResource.zig");
const ClientData = @import("../ClientData.zig");
const Client = @import("../Client.zig");

pub const Context = struct {
    arena: std.mem.Allocator,
};

pub fn handle_client(
    client: Client,
    _: *ClientData,
    gpa: std.mem.Allocator,
    comptime www: []const ServerResource,
) (@TypeOf(client).ReadError || @TypeOf(client).WriteError || Request.ParseError || std.mem.Allocator.Error)!void {
    const log = std.log.scoped(.HTTP);

    const reader = client.reader();
    const writer = client.writer();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    var req = Request.parse(gpa, reader) catch |err| {
        try writer.writeAll("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n");
        return err;
    };
    defer req.deinit();

    log.info("Got Request from Client {}: {s}", .{ client, req });

    if (!std.mem.startsWith(u8, req.path, "/")) {
        const message = "Path needs to start with '/'.";
        try writer.writeAll(std.fmt.comptimePrint("HTTP/1.1 404 Not Found\r\nContent-Length: {d}\r\n\r\n{s}", .{ message.len, message }));
        return;
    }

    const ctx = Context{
        .arena = arena,
    };
    const path = req.path[1..];
    const res = try handle_dir(ctx, &req, path, www);

    try std.fmt.format(writer, "{}", .{res});
}

pub fn handle_dir(ctx: Context, req: *const Request, path: []const u8, comptime dir: []const ServerResource) std.mem.Allocator.Error!Response {
    var path_iter = std.mem.splitScalar(u8, path, '/');
    var current_path = path_iter.next() orelse return Response.not_found();
    if (current_path.len == 0) {
        current_path = "index";
    }

    inline for (dir) |resource| {
        if (std.mem.eql(u8, resource.path, current_path)) {
            switch (resource.value) {
                .directory => |child_dir| {
                    return handle_dir(ctx, req, path_iter.rest(), child_dir);
                },
                .file => |content| {
                    if (req.method == .GET) {
                        return try Response.file(ctx.arena, ContentType.from_filename(resource.path).?, content);
                    } else {
                        return Response.not_found();
                    }
                },
                .handler => |mod| {
                    switch (req.method) {
                        .GET => {
                            const fn_method = "http_" ++ @tagName(.GET);
                            if (std.meta.hasFn(mod, fn_method)) {
                                return @field(mod, fn_method)(ctx, req);
                            } else {
                                return Response.not_found();
                            }
                        },
                        .POST => {
                            const fn_method = "http_" ++ @tagName(.POST);
                            if (std.meta.hasFn(mod, fn_method)) {
                                return @field(mod, fn_method)(ctx, req);
                            } else {
                                return Response.not_found();
                            }
                        },
                        .CONNECT => {
                            const fn_method = "http_" ++ @tagName(.CONNECT);
                            if (std.meta.hasFn(mod, fn_method)) {
                                return @field(mod, fn_method)(ctx, req);
                            } else {
                                return Response.not_found();
                            }
                        },
                        .DELETE => {
                            const fn_method = "http_" ++ @tagName(.DELETE);
                            if (std.meta.hasFn(mod, fn_method)) {
                                return @field(mod, fn_method)(ctx, req);
                            } else {
                                return Response.not_found();
                            }
                        },
                        .HEAD => {
                            const fn_method = "http_" ++ @tagName(.HEAD);
                            if (std.meta.hasFn(mod, fn_method)) {
                                return @field(mod, fn_method)(ctx, req);
                            } else {
                                return Response.not_found();
                            }
                        },
                        .OPTIONS => {
                            const fn_method = "http_" ++ @tagName(.OPTIONS);
                            if (std.meta.hasFn(mod, fn_method)) {
                                return @field(mod, fn_method)(ctx, req);
                            } else {
                                return Response.not_found();
                            }
                        },
                        .PUT => {
                            const fn_method = "http_" ++ @tagName(.PUT);
                            if (std.meta.hasFn(mod, fn_method)) {
                                return @field(mod, fn_method)(ctx, req);
                            } else {
                                return Response.not_found();
                            }
                        },
                        .TRACE => {
                            const fn_method = "http_" ++ @tagName(.TRACE);
                            if (std.meta.hasFn(mod, fn_method)) {
                                return @field(mod, fn_method)(ctx, req);
                            } else {
                                return Response.not_found();
                            }
                        },
                    }
                },
            }
        }
    }
    return Response.not_found();
}


