const std = @import("std");

const server = @import("server");
const http = server.http;

pub fn http_GET(_: *http.Context, req: *const http.Request, res: *http.Response) std.mem.Allocator.Error!void {
    res.code = ._200_OK;
    try res.write_body_fmt("<p>METHOD: '{s}'</p>", .{@tagName(req.method)});
    try res.write_body_fmt("<p>PATH: '{s}'</p>", .{req.path});
    try res.write_body_fmt("<p>VERSION: '{s}'</p>", .{req.version});

    try res.write_body_fmt("</br>", .{});

    var iter_url_params = req.url_params.iterator();
    try res.write_body_fmt("<p>URL_PARAMS:</p>", .{});
    while (iter_url_params.next()) |e| {
        try res.write_body_fmt("<p>\t'{s}': '{s}'</p>", .{ e.key_ptr.*, e.value_ptr.* });
    }

    try res.write_body_fmt("</br>", .{});

    var iter_headers = req.headers.iterator();
    try res.write_body_fmt("<p>HEADERS:</p>", .{});
    while (iter_headers.next()) |e| {
        try res.write_body_fmt("<p>\t'{s}': '{s}'</p>", .{ e.key_ptr.*, e.value_ptr.* });
    }
}
