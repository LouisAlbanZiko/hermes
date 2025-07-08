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

pub const PrivResourceType = enum { directory, file };
pub const PrivResource = struct {
    path: []const u8,
    value: union(PrivResourceType) {
        directory: PrivDirectory,
        file: [:0]const u8,
    },
};
pub const PrivDirectory = struct {
    resources: []const PrivResource,
    pub fn init(gpa: std.mem.Allocator, comptime www: []const ServerResource) !PrivDirectory {
        var resources: []PrivResource = try gpa.alloc(PrivResource, count_priv(www));
        var res_index: usize = 0;
        inline for (www) |res| {
            switch (res.value) {
                .priv => |content| {
                    resources[res_index] = PrivResource{ .path = res.path, .value = .{ .file = content } };
                    res_index += 1;
                },
                .directory => |dir| {
                    resources[res_index] = PrivResource{ .path = res.path, .value = .{ .directory = try init(gpa, dir)} };
                    res_index += 1;
                },
                else => {},
            }
        }
        return .{ .resources = resources };
    }
    pub fn deinit(self: PrivDirectory, gpa: std.mem.Allocator) void {
        for (self.resources) |res| {
            switch (res.value) {
                .directory => |dir| {
                    dir.deinit(gpa);
                },
                else => {},
            }
        }
        gpa.free(self.resources);
    }
    pub fn lookup(self: PrivDirectory, path: []const u8) ?PrivResource {
        var path_iter = std.mem.splitScalar(u8, path, '/');
        const current = path_iter.next() orelse "";
        std.debug.print("\\\\ current={s}\n", .{current});
        for (self.resources) |res| {
            std.debug.print("\\\\ checking={s}\n", .{res.path});
            if (std.mem.eql(u8, current, res.path)) {
                std.debug.print("\\\\ found={s}\n", .{res.path});
                switch (res.value) {
                    .file => |_| {
                        if (path_iter.peek()) |next| {
                            std.debug.print("found file, next is '{s}'\n", .{next});
                            return null;
                        } else {
                            std.debug.print("found file\n", .{});
                            return res;
                        }
                    },
                    .directory => |dir| {
                        if (path_iter.peek()) |next| {
                            std.debug.print("Found dir, next is '{s}'\n", .{next});
                            return dir.lookup(path_iter.rest());
                        } else {
                            std.debug.print("Found dir but no next\n", .{});
                            //return null;
                            return res;
                        }
                    },
                }
            }
        }
        unreachable;
    }
};

fn count_priv(comptime www: []const ServerResource) usize {
    var count: usize = 0;
    inline for (www) |res| {
        switch (res.value) {
            .priv => {
                count += 1;
            },
            .directory => {
                count += 1;
            },
            else => {},
        }
    } 
    return count;
}

pub const Context = struct {
    arena: std.mem.Allocator,
    resources: PrivDirectory,
};

pub fn handle_client(
    client: Client,
    _: *ClientData,
    gpa: std.mem.Allocator,
    comptime www: []const ServerResource,
    priv_dir: PrivDirectory,
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
        .resources = priv_dir,
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
                .priv => |_| {
                    return Response.not_found();
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


