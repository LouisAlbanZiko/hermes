const std = @import("std");
const posix = std.posix;

const Client = @This();
sock: posix.socket_t,

pub fn read(self: Client, buffer: []u8) posix.RecvFromError!usize {
    const socket_log = std.log.scoped(.SOCKET_IN);
    const res = posix.recv(self.sock, buffer, 0);
    if (res) |len| {
        socket_log.debug("{s}", .{buffer[0..len]});
        return res;
    } else |err| {
        if (err == error.WouldBlock) {
            return 0;
        } else {
            socket_log.err("Failed to read from Client({}) with Error({s})", .{ self, @errorName(err) });
            return err;
        }
    }
}
pub const Reader = std.io.Reader(Client, posix.RecvFromError, read);
pub fn reader(self: Client) Reader {
    return Reader{ .context = self };
}

pub fn write(self: Client, buffer: []const u8) posix.SendError!usize {
    const socket_log = std.log.scoped(.SOCKET_OUT);
    if (posix.send(self.sock, buffer, 0)) |count| {
        socket_log.debug("{s}", .{buffer});
        return count;
    } else |err| {
        socket_log.err("Failed to write to Client({}) with Error({s})", .{ self, @errorName(err) });
        return err;
    }
}
pub const Writer = std.io.Writer(Client, posix.SendError, write);
pub fn writer(self: Client) Writer {
    return Writer{ .context = self };
}

pub fn format(self: Client, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    try out.print("{d}", .{self.sock});
}
