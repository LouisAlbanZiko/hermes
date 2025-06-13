const std = @import("std");
const IP = @import("IP.zig");
const Client = @import("Client.zig");

is_open: bool,
last_commms: i128,
ip: IP,
protocol: ProtocolData,
client: Client,

pub const Protocol = enum { http, tls, ws };
pub const ProtocolData = union(Protocol) {
    http: struct {},
    tls: struct {},
    ws: struct {},
};

pub fn switch_to_ws(self: @This()) void {
    std.debug.assert(self.protocol == .http);
    self.protocol = .{ .ws = .{} };
}

pub fn switch_to_http(self: @This()) void {
    std.debug.assert(self.protocol == .tls);
    self.protocol = .{ .http = .{} };
}

