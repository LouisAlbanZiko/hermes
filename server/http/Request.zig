const std = @import("std");
const http = @import("protocol.zig");

const ReadBuffer = @import("util").ReadBuffer;

const Request = @This();
_buffer: [8192]u8,
_raw: []const u8,

version: http.Version,
method: http.Method,
path: []const u8,
query: std.StringHashMap([]const u8),
headers: std.StringHashMap([]const u8),
cookies: std.StringHashMap([]const u8),
body: []const u8,

@"Content-Type": ?http.ContentType,
@"Content-Length": usize,

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Request {
    var req: Request = undefined;

    req.query = std.StringHashMap([]const u8).init(allocator);
    req.headers = std.StringHashMap([]const u8).init(allocator);
    req.cookies = std.StringHashMap([]const u8).init(allocator);

    return req;
}
pub fn deinit(self: *Request) void {
    self.query.deinit();
    self.headers.deinit();
    self.cookies.deinit();
}

pub const ParseError = error{
    StreamEmpty,
    StreamTooLong,
    ParseContentLengthFailed,
    WrongContentLength,
    UnknownMethod,
    UnknownVersion,
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
    if (std.mem.eql(u8, method_str, @tagName(http.Method.OPTIONS))) {
        req.method = http.Method.OPTIONS;
    } else if (std.mem.eql(u8, method_str, @tagName(http.Method.GET))) {
        req.method = http.Method.GET;
    } else if (std.mem.eql(u8, method_str, @tagName(http.Method.HEAD))) {
        req.method = http.Method.HEAD;
    } else if (std.mem.eql(u8, method_str, @tagName(http.Method.POST))) {
        req.method = http.Method.POST;
    } else if (std.mem.eql(u8, method_str, @tagName(http.Method.PUT))) {
        req.method = http.Method.PUT;
    } else if (std.mem.eql(u8, method_str, @tagName(http.Method.DELETE))) {
        req.method = http.Method.DELETE;
    } else if (std.mem.eql(u8, method_str, @tagName(http.Method.TRACE))) {
        req.method = http.Method.TRACE;
    } else if (std.mem.eql(u8, method_str, @tagName(http.Method.CONNECT))) {
        req.method = http.Method.CONNECT;
    } else {
        return error.UnknownMethod;
    }

    _ = try rb.read(u8); // skip space

    req.path = try rb.read_bytes_until_either(" ?");

    if (try rb.read(u8) == '?') {
        while (true) {
            const url_param_name = try rb.read_bytes_until_either("=");
            _ = try rb.read(u8);
            const url_param_value = try rb.read_bytes_until_either("& ");
            try req.query.put(url_param_name, url_param_value);
            if (try rb.read(u8) == ' ') {
                break;
            }
        }
    }

    const version_str = try rb.read_bytes_until_either("\r");
    if (std.mem.eql(u8, version_str, @tagName(http.Version.@"HTTP/1.0"))) {
        req.version = .@"HTTP/1.0";
    } else if (std.mem.eql(u8, version_str, @tagName(http.Version.@"HTTP/1.1"))) {
        req.version = .@"HTTP/1.1";
    } else if (std.mem.eql(u8, version_str, @tagName(http.Version.@"HTTP/2"))) {
        req.version = .@"HTTP/2";
    } else if (std.mem.eql(u8, version_str, @tagName(http.Version.@"HTTP/3"))) {
        req.version = .@"HTTP/3";
    } else {
        return error.UnknownVersion;
    }

    if (try rb.read(u8) == '\r') {
        _ = try rb.read(u8);
    }

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
    }

    if (req.headers.get("Content-Length")) |content_length_str| {
        req.@"Content-Length" = std.fmt.parseInt(usize, content_length_str, 10) catch return ParseError.ParseContentLengthFailed;
    } else {
        req.@"Content-Length" = 0;
    }

    if (req.headers.get("Content-Type")) |content_type_str| {
        req.@"Content-Type" = enumFromStr(http.ContentType, content_type_str);
    } else {
        req.@"Content-Type" = null;
    }

    if (req.headers.get("Cookie")) |cookie_str| {
        var crb = ReadBuffer.init(cookie_str);

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

    if (req.@"Content-Length" != 0) {
        req.body = try rb.read_bytes(req.@"Content-Length");
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
        const name = rb.read_bytes_until_either("=") catch break;
        _ = try rb.read(u8);
        const value = rb.read_bytes_until_either("& ") catch rb.data[rb.read_index..];
        try form.put(name, value);
        if (try rb.read(u8) == ' ') {
            break;
        }
    }
    return form;
}

pub fn format(
    self: @This(),
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try std.fmt.format(writer, "{s} {s}", .{ @tagName(self.method), self.path });
}

pub fn enumFromStr(E: type, str: []const u8) ?E {
    comptime {
        if (@typeInfo(E) != .@"enum") {
            @compileError(std.fmt.comptimePrint("Expected enum, found {s}", .{@tagName(@typeInfo(E))}));
        }
    }
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (std.mem.eql(u8, field.name, str)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}
