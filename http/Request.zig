const std = @import("std");

const ReadBuffer = @import("util").ReadBuffer;

pub const Method = enum {
    OPTIONS,
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    TRACE,
    CONNECT,
};

const Request = @This();
_buffer: [8192]u8,
_raw: []const u8,
method: Method,
path: []const u8,
url_params: std.StringHashMap([]const u8),
version: []const u8,
headers: std.StringHashMap([]const u8),
cookies: std.StringHashMap([]const u8),
body: []const u8,

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Request {
    var req: Request = undefined;

    req.url_params = std.StringHashMap([]const u8).init(allocator);
    req.headers = std.StringHashMap([]const u8).init(allocator);
    req.cookies = std.StringHashMap([]const u8).init(allocator);

    return req;
}
pub fn deinit(self: *Request) void {
    self.url_params.deinit();
    self.headers.deinit();
    self.cookies.deinit();
}

pub const ParseError = error{
    StreamEmpty,
    StreamTooLong,
    ParseContentLengthFailed,
    WrongContentLength,
    UnknownMethod,
} || ReadBuffer.Error;
pub fn parse(allocator: std.mem.Allocator, reader: anytype) (ParseError || std.mem.Allocator.Error || @TypeOf(reader).Error)!Request {
    var req = try init(allocator);
    errdefer req.deinit();

    const read_len = try reader.read(&req._buffer);
    req._raw = req._buffer[0..read_len];

    //std.debug.print("_raw='{s}'\n", .{req._raw});

    if (req._raw.len == 0) {
        return ParseError.StreamEmpty;
    }

    var rb = ReadBuffer.init(req._raw);

    const method_str = try rb.read_bytes_until(' ');
    //std.debug.print("method='{s}'\n", .{method_str});
    if (std.mem.eql(u8, method_str, @tagName(Method.OPTIONS))) {
        req.method = Method.OPTIONS;
    } else if (std.mem.eql(u8, method_str, @tagName(Method.GET))) {
        req.method = Method.GET;
    } else if (std.mem.eql(u8, method_str, @tagName(Method.HEAD))) {
        req.method = Method.HEAD;
    } else if (std.mem.eql(u8, method_str, @tagName(Method.POST))) {
        req.method = Method.POST;
    } else if (std.mem.eql(u8, method_str, @tagName(Method.PUT))) {
        req.method = Method.PUT;
    } else if (std.mem.eql(u8, method_str, @tagName(Method.DELETE))) {
        req.method = Method.DELETE;
    } else if (std.mem.eql(u8, method_str, @tagName(Method.TRACE))) {
        req.method = Method.TRACE;
    } else if (std.mem.eql(u8, method_str, @tagName(Method.CONNECT))) {
        req.method = Method.CONNECT;
    } else {
        return error.UnknownMethod;
    }

    _ = try rb.read(u8); // skip space

    req.path = try rb.read_bytes_until_either(" ?");
    //std.debug.print("path='{s}'\n", .{req.path});

    if (try rb.read(u8) == '?') {
        while (true) {
            const url_param_name = try rb.read_bytes_until_either("=");
            _ = try rb.read(u8);
            const url_param_value = try rb.read_bytes_until_either("& ");
            if (try rb.read(u8) == ' ') {
                break;
            }
            try req.url_params.put(url_param_name, url_param_value);
        }
    }

    req.version = try rb.read_bytes_until_either("\r");

    if (try rb.read(u8) == '\r') {
        _ = try rb.read(u8);
    }

    var content_length: usize = 0;
    while (true) {
        if (rb.peek() == '\r') {
            _ = try rb.read_bytes(2); // \r\n
            break;
        }

        const header_name = try rb.read_bytes_until_either(":");
        _ = try rb.read(u8);

        if (rb.peek() == ' ') {
            _ = try rb.read(u8);
        }

        const header_value = try rb.read_bytes_until_either(&[_]u8{'\r'});
        _ = try rb.read_bytes(2); // \r\n

        try req.headers.put(header_name, header_value);

        if (std.mem.eql(u8, header_name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, header_value, 10) catch return ParseError.ParseContentLengthFailed;
        } else if (std.mem.eql(u8, header_name, "Cookies")) {
            var crb = ReadBuffer.init(header_value);

            while (true) {
                const cookie_name = try crb.read_bytes_until('=');
                _ = try crb.read(u8);

                const cookie_value = crb.read_bytes_until(';') catch crb.data[crb.read_index..];
                try req.cookies.put(cookie_name, cookie_value);

                if (crb.peek() == ';') {
                    _ = try crb.read(u8);
                    if (crb.read_index == crb.data.len) {
                        break;
                    }
                } else {
                    break;
                }
            }
        }
    }

    if (content_length != 0) {
        req.body = try rb.read_bytes(content_length);
    } else {
        req.body = "";
    }

    return req;
}

pub fn is_websocket(self: *const Request) bool {
    if (self.headers.get("Connection")) |connection| {
        if (std.mem.containsAtLeast(u8, connection, 1, "Upgrade")) {
            if (self.headers.get("Upgrade")) |upgrade| {
                if (std.mem.eql(u8, upgrade, "websocket")) {
                    return true;
                }
            }
        }
    }
    return false;
}

pub fn parse_body_form(self: *const Request, allocator: std.mem.Allocator) (ReadBuffer.Error || std.mem.Allocator.Error)!std.StringHashMap([]const u8) {
    var form = std.StringHashMap([]const u8).init(allocator);
    var rb = ReadBuffer.init(self.body);

    while (true) {
        const name = try rb.read_bytes_until('=');
        _ = try rb.read(u8);

        if (rb.peek() == '&') {
            continue;
        }

        const value = rb.read_bytes_until('&') catch rb.data[rb.read_index..];

        try form.put(name, value);

        if (rb.peek() == '&') {
            break;
        }
    }
    return form;
}
