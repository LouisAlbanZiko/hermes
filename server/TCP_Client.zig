const std = @import("std");
const posix = std.posix;

const TCP_Client = @This();
sock: posix.socket_t,

pub const ReadError = posix.RecvFromError;
pub fn read(self: TCP_Client, buffer: []u8) ReadError!usize {
    const socket_log = std.log.scoped(.SOCKET_IN);
    const res = posix.recv(self.sock, buffer, 0);
    if (res) |len| {
        //socket_log.debug("{s}", .{buffer[0..len]});
        return len;
    } else |err| {
        if (err == error.WouldBlock) {
            return 0;
        } else {
            socket_log.err("Failed to read from TCP_Client({}) with Error({s})", .{ self, @errorName(err) });
            return err;
        }
    }
}
pub const Reader = std.io.Reader(TCP_Client, ReadError, read);
pub fn reader(self: TCP_Client) Reader {
    return Reader{ .context = self };
}

pub const WriteError = posix.SendError;
pub fn write(self: TCP_Client, buffer: []const u8) WriteError!usize {
    const socket_log = std.log.scoped(.SOCKET_OUT);
    if (posix.send(self.sock, buffer, 0)) |count| {
        //socket_log.debug("{s}", .{buffer});
        return count;
    } else |err| {
        socket_log.err("Failed to write to TCP_Client({}) with Error({s})", .{ self, @errorName(err) });
        return err;
    }
}
pub const Writer = std.io.Writer(TCP_Client, WriteError, write);
pub fn writer(self: TCP_Client) Writer {
    return Writer{ .context = self };
}

pub fn format(self: TCP_Client, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    try out.print("{d}", .{self.sock});
}
