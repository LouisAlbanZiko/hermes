const std = @import("std");

pub const Headers = std.StringHashMapUnmanaged([]const u8);

pub const Code = enum {
    _101_SWITCHING_PROTOCOLS,
    _200_OK,
    _300_MULTIPLE_CHOICES,
    _301_MOVED_PERMANENTLY,
    _302_FOUND,
    _400_BAD_REQUEST,
    _401_UNAUTHORIZED,
    _403_FORBIDDEN,
    _404_NOT_FOUND,
    _405_METHOD_NOT_ALLOWED,
    _500_INTERNAL_SERVER_ERROR,
    pub fn message(self: Code) []const u8 {
        switch (self) {
            ._101_SWITCHING_PROTOCOLS => return "101 Switching Protocols",
            ._200_OK => return "200 OK",
            ._300_MULTIPLE_CHOICES => return "300 Multiple Choices",
            ._301_MOVED_PERMANENTLY => return "301 Moved Permanently",
            ._302_FOUND => return "302 Found",
            ._400_BAD_REQUEST => return "400 Bad Request",
            ._401_UNAUTHORIZED => return "401 Unauthorized",
            ._403_FORBIDDEN => return "403 Forbidden",
            ._404_NOT_FOUND => return "404 NOT FOUND",
            ._405_METHOD_NOT_ALLOWED => return "405 Method Not Allowed",
            ._500_INTERNAL_SERVER_ERROR => return "500 Internal Server Error",
        }
    }
};

const Response = @This();
allocator: std.mem.Allocator,
code: Code,
headers: Headers,
body_buf: []u8,
body_len: usize,

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Response {
    var res: Response = undefined;
    res.allocator = allocator;
    res.code = ._404_NOT_FOUND;
    res.headers = Headers{};
    res.body_len = 0;
    res.body_buf = try res.allocator.alloc(u8, 1024);
    return res;
}
pub fn deinit(self: *Response) void {
    self.allocator.free(self.body_buf);
    self.headers.deinit(self.allocator);
}

pub fn header(self: *Response, key: []const u8, value: []const u8) std.mem.Allocator.Error!void {
    const copy_key = try self.allocator.dupe(u8, key);
    const copy_value = try self.allocator.dupe(u8, value);
    try self.headers.put(self.allocator, copy_key, copy_value);
}

const Writer = std.io.Writer(*Response, std.mem.Allocator.Error, write_body);
pub fn body_writer(self: *Response) Writer {
    return Writer{ .context = self };
}

pub fn write_body(self: *Response, value: []const u8) std.mem.Allocator.Error!usize {
    while (self.body_len + value.len >= self.body_buf.len) {
        self.body_buf = try self.allocator.realloc(self.body_buf, self.body_buf.len * 2);
    }
    std.mem.copyForwards(u8, self.body_buf[self.body_len .. self.body_len + value.len], value);
    self.body_len += value.len;
    return value.len;
}

pub fn write_body_fmt(self: *Response, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
    const writer = Writer{ .context = self };
    try std.fmt.format(writer, fmt, args);
}

// output
pub fn body(self: *const Response) []const u8 {
    return self.body_buf[0..self.body_len];
}

pub fn output_to(self: *const Response, w: anytype) (@TypeOf(w).Error || std.mem.Allocator.Error)!void {
    const format = std.fmt.format;
    try format(w, "HTTP/1.1 {s}\r\n", .{self.code.message()});
    var iter = self.headers.iterator();
    while (iter.next()) |e| {
        try format(w, "{s}: {s}\r\n", .{ e.key_ptr.*, e.value_ptr.* });
    }

    try format(w, "{s}: {d}\r\n", .{ "Content-Length", self.body_len });
    if (self.body_len > 0) {
        try format(w, "\r\n{s}", .{self.body()});
    } else {
        try format(w, "\r\n", .{});
    }
}
