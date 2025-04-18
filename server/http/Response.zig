const std = @import("std");

const http = @import("protocol.zig");

const Response = @This();
code: http.Code,
headers: []const http.Header,
body: []const u8,

pub fn file(arena: std.mem.Allocator, content_type: http.ContentType, content: []const u8) std.mem.Allocator.Error!Response {
    var headers = std.ArrayList(http.Header).init(arena);
    try headers.append(.{ "Content-Type", @tagName(content_type) });

    return Response{
        .code = .@"200 Ok",
        .headers = try headers.toOwnedSlice(),
        .body = content,
    };
}

pub fn redirect(arena: std.mem.Allocator, location: []const u8) std.mem.Allocator.Error!Response {
    var headers = std.ArrayList(http.Header).init(arena);
    try headers.append(.{ "Location", location });
    return Response{
        .code = .@"302 Found",
        .headers = try headers.toOwnedSlice(),
        .body = "",
    };
}

pub fn not_found() Response {
    return Response{
        .code = .@"404 Not Found",
        .headers = &[_]http.Header{},
        .body = "",
    };
}

pub fn server_error() Response {
    return Response{
        .code = .@"500 Internal Server Error",
        .headers = &[_]http.Header{},
        .body = "",
    };
}

pub fn format(
    self: *const @This(),
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try std.fmt.format(writer, "{s} {s}\r\n", .{ @tagName(http.Version.@"HTTP/1.1"), @tagName(self.code) });
    for (self.headers) |header| {
        try std.fmt.format(writer, "{s}: {s}\r\n", .{ header.@"0", header.@"1" });
    }
    try std.fmt.format(writer, "Content-Length: {d}\r\n", .{self.body.len});
    try std.fmt.format(writer, "\r\n{s}", .{self.body});
}
