const std = @import("std");

const server = @import("server");
const http = server.http;

pub fn http_GET(ctx: *http.Context, req: *const http.Request) std.mem.Allocator.Error!http.Response {
    var body = std.ArrayList(u8).init(ctx.arena());
    try std.fmt.format(
        body.writer(),
        \\<p>VERSION: '{s}'</p>
        \\<p>METHOD: '{s}'</p>
        \\<p>PATH: '{s}'</p>
    ,
        .{
            @tagName(req.version),
            @tagName(req.method),
            req.path,
        },
    );

    var iter_query = req.query.iterator();
    _ = try body.writer().write("<p>QUERY:</p><ul>");
    while (iter_query.next()) |e| {
        try std.fmt.format(body.writer(), "<li>{s}={s}</li>", .{ e.key_ptr.*, e.value_ptr.* });
    }
    _ = try body.writer().write("</ul>");

    var iter_headers = req.headers.iterator();
    _ = try body.writer().write("<p>HEADERS:</p><ul>");
    while (iter_headers.next()) |e| {
        try std.fmt.format(body.writer(), "<li>{s}: {s}</li>", .{ e.key_ptr.*, e.value_ptr.* });
    }
    _ = try body.writer().write("</ul>");

    var headers = try ctx.arena().alloc(http.Response.Header, 1);
    headers[0] = .{ "Content-Type", @tagName(.@"text/html") };

    return http.Response{
        .code = .@"200 Ok",
        .headers = headers,
        .body = body.items,
    };
}
