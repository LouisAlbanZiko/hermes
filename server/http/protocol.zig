const std = @import("std");

pub const Version = enum {
    @"HTTP/1.0",
    @"HTTP/1.1",
    @"HTTP/2",
    @"HTTP/3",
};

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

pub const Code = enum {
    @"101 Switching Protocols",
    @"200 Ok",
    @"300 Multiple Choices",
    @"301 Moved Permanently",
    @"302 Found",
    @"400 Bad Request",
    @"401 Unauthorized",
    @"403 Forbidden",
    @"404 Not Found",
    @"405 Method Not Allowed",
    @"415 Unsupported Media Type",
    @"500 Internal Server Error",
};

pub const ContentType = enum {
    @"application/x-www-form-urlencoded",
    @"application/json",
    @"application/xml",
    @"application/pdf",
    @"application/zip",

    @"image/gif",
    @"image/jpeg",
    @"image/png",
    @"image/tiff",
    @"image/vnd.microsoft.icon",
    @"image/svg+xml",

    @"text/css",
    @"text/csv",
    @"text/html",
    @"text/javascript",
    @"text/plain",
    @"text/xml",

    pub fn from_filename(filename: []const u8) ?ContentType {
        const extension = std.fs.path.extension(filename);
        if (std.mem.eql(u8, extension, ".css")) {
            return .@"text/css";
        } else if (std.mem.eql(u8, extension, ".csv")) {
            return .@"text/csv";
        } else if (std.mem.eql(u8, extension, ".html")) {
            return .@"text/html";
        } else if (std.mem.eql(u8, extension, ".js")) {
            return .@"text/javascript";
        } else if (std.mem.eql(u8, extension, ".txt")) {
            return .@"text/plain";
        } else if (std.mem.eql(u8, extension, ".xml")) {
            return .@"text/xml";
        } else if (std.mem.eql(u8, extension, ".gif")) {
            return .@"image/gif";
        } else if (std.mem.eql(u8, extension, ".jpeg")) {
            return .@"image/jpeg";
        } else if (std.mem.eql(u8, extension, ".png")) {
            return .@"image/png";
        } else if (std.mem.eql(u8, extension, ".tiff")) {
            return .@"image/tiff";
        } else if (std.mem.eql(u8, extension, ".svg")) {
            return .@"image/svg+xml";
        } else if (std.mem.eql(u8, extension, ".ico")) {
            return .@"image/vnd.microsoft.icon";
        } else if (std.mem.eql(u8, extension, ".pdf")) {
            return .@"application/pdf";
        } else if (std.mem.eql(u8, extension, ".zip")) {
            return .@"application/zip";
        } else {
            return null;
        }
    }
};

pub const Header = struct { []const u8, []const u8 };
