const std = @import("std");
const TCP_Client = @import("TCP_Client.zig");
const SSL_Client = @import("SSL_Client.zig");

const ClientType = enum { tcp, ssl };
const Client = @This();
id: i32,
value: union(ClientType) {
    tcp: TCP_Client,
    ssl: SSL_Client,
},

pub fn read(self: Client, bytes: []u8) ReadError!usize {
    switch(self.value) {
        .ssl => |ssl_client| {
            return ssl_client.read(bytes);
        },
        .tcp => |tcp_client| {
            return tcp_client.read(bytes);
        },
    }
}
pub const ReadError = TCP_Client.ReadError || SSL_Client.ReadError;
pub const Reader = std.io.Reader(Client, ReadError, read);
pub fn reader(self: Client) Reader {
    return Reader{ .context = self };
}

pub fn write(self: Client, bytes: []const u8) !usize {
    switch (self.value) {
        .ssl => |ssl_client| {
            return ssl_client.write(bytes);
        },
        .tcp => |tcp_client| {
            return tcp_client.write(bytes);
        },
    }
}
pub const WriteError = TCP_Client.WriteError || SSL_Client.WriteError;
pub const Writer = std.io.Writer(Client, WriteError, write);
pub fn writer(self: Client) Writer {
    return Writer{ .context = self };
}

pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    try out.print("{d}", .{self.id});
}



