const std = @import("std");

const Request = @import("Request.zig");
const Response = @import("Response.zig");

const log = std.log.scoped(.HTTP);

pub const Context = struct {
    //db: DB,
    //client_data: *const ClientData,
    //client_index: usize,
};
const Callback = *const fn (*Context, *const Request, *Response) std.mem.Allocator.Error!void;
const ResourceType = enum { directory, handler, template, file };
const Directory = std.StaticStringMap(Resource);
const Resource = union(ResourceType) {
    directory: Directory,
    handler: [@typeInfo(Request.Method).@"enum".fields.len]?Callback,
    template: []const u8,
    file: []const u8,
};

const Self = @This();
www: Directory,

pub fn init(root_dir: Directory) std.mem.Allocator.Error!Self {
    return .{
        .www = root_dir,
    };
}

pub fn deinit(_: *Self) void {}

const PathIterator = std.mem.SplitIterator(u8, .scalar);
pub fn find_resource(current_path: []const u8, path_iter: PathIterator, dir: *const Directory) ?Resource {
    if (dir.get(current_path)) |res| {
        if (path_iter.next()) |child_path| {
            switch (res) {
                .directory => |*child_dir| {
                    return find_resource(child_path, path_iter, child_dir);
                },
                else => {
                    return null;
                },
            }
        } else {
            return res;
        }
    } else {
        return null;
    }
}

pub fn handle_data(self: *Self, allocator: std.mem.Allocator, client: anytype) (@TypeOf(client).ReadError || @TypeOf(client).WriteError || Request.ParseError || std.mem.Allocator.Error)!void {
    const writer = client.writer();
    const reader = client.reader();

    const req = try Request.parse(allocator, reader);
    defer req.deinit();

    var res = try Response.init(allocator);
    defer res.deinit();

    var path_iter = std.mem.splitScalar(u8, req.path, '/');
    if (path_iter.next()) |current_path| {
        if (find_resource(current_path, path_iter, self.www)) |resource| {
            switch (resource) {
                .directory => |_| {
                    res.code = ._404_NOT_FOUND;
                },
                .file => |*content| {
                    res.code = ._200_OK;
                    _ = try res.write_body(content.*);
                },
                .template => |_| {
                    res.code = ._404_NOT_FOUND;
                },
                .handler => |*handler| {
                    const callback = handler.*[@intFromEnum(req.method)];
                    var ctx = Context{};
                    callback(&ctx, &req, &res) catch |err| {
                        res.code = ._500_INTERNAL_SERVER_ERROR;
                        log.err("Callback on path '{s}' failed with Error({s})", .{ req.path, @errorName(err) });
                    };
                },
            }
        } else {
            res.code = ._404_NOT_FOUND;
        }
    } else {
        res.code = ._404_NOT_FOUND;
    }

    try res.output_to(writer);
}

pub fn respond_websocket(res: *Response, req: *const Request) std.mem.Allocator.Error!void {
    const websocket_key = req.headers.get("Sec-WebSocket-Key") orelse {
        res.code = ._400_BAD_REQUEST;
        _ = try res.write_body("Missing 'Sec-WebSocket-Key' for WS request.");
        return;
    };
    if (websocket_key.len != 24) {
        res.code = ._400_BAD_REQUEST;
        _ = try res.write_body("'Sec-WebSocket-Key' is the wrong length. Expected 24 bytes.");
        return;
    }
    const websocket_version = req.headers.get("Sec-WebSocket-Version") orelse {
        res.code = ._400_BAD_REQUEST;
        _ = try res.write_body("Missing 'Sec-WebSocket-Version' for WS request.");
        return;
    };
    if (!std.mem.eql(u8, websocket_version, "13")) {
        res.code = ._400_BAD_REQUEST;
        try res.write_body_fmt("Expected 'Sec-WebSocket-Version: 13' but got '{s}'.", .{websocket_version});
        return;
    }
    res.code = ._101_SWITCHING_PROTOCOLS;
    try res.header("Upgrade", "websocket");
    try res.header("Connection", "Upgrade");

    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const concat: [24 + magic.len]u8 = undefined;
    std.mem.copyForwards(u8, concat[0..websocket_key.len], websocket_key);
    std.mem.copyForwards(u8, concat[websocket_key.len .. websocket_key.len + magic.len], magic);

    var sha1_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(concat, &sha1_hash, .{});

    var base64_buffer: [std.base64.standard.Encoder.calcSize(sha1_hash.len)]u8 = undefined;
    const base64_slice = std.base64.standard.Encoder.encode(&base64_buffer, &sha1_hash);

    try res.header("Sec-WebSocket-Accept", base64_slice);
}
