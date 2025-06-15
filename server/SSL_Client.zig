const std = @import("std");
const openssl = @cImport({
    @cInclude("openssl/ssl.h");
});

const SSL_Client = @This();
ssl: ?*openssl.SSL,
sock: std.posix.socket_t,

pub const ReadError = error{SSL_Read_Error};
pub fn read(self: SSL_Client, buffer: []u8) ReadError!usize {
    const socket_log = std.log.scoped(.SSL_IN);
    var len: usize = undefined;
    const res = openssl.SSL_read_ex(self.ssl, buffer.ptr, buffer.len, &len);
    if (res > 0) {
        //socket_log.debug("{s}", .{buffer[0..len]});
        return len;
    } else {
        socket_log.err("Failed to read from SSL_Client with Error: {X:0>4}", .{openssl.SSL_get_error(self.ssl, res)});
        return error.SSL_Read_Error;
    }
}
pub const Reader = std.io.Reader(SSL_Client, ReadError, read);
pub fn reader(self: SSL_Client) Reader {
    return Reader{ .context = self };
}

pub const WriteError = error{SSL_Write_Error};
pub fn write(self: SSL_Client, buffer: []const u8) WriteError!usize {
    const socket_log = std.log.scoped(.SSL_OUT);
    var len: usize = undefined;
    const res = openssl.SSL_write_ex(self.ssl, buffer.ptr, buffer.len, &len);
    if (res > 0) {
        //socket_log.debug("{s}", .{buffer});
        return len;
    } else {
        socket_log.err("Failed to write to SSL_Client with Error: {X:0>4}", .{openssl.SSL_get_error(self.ssl, res)});
        return error.SSL_Write_Error;
    }
}
pub const Writer = std.io.Writer(SSL_Client, WriteError, write);
pub fn writer(self: SSL_Client) Writer {
    return Writer{ .context = self };
}

pub const AcceptError = error{FailedToAcceptClient};
pub fn accept_step(self: SSL_Client) AcceptError!bool {
    const ret_code = openssl.SSL_accept(self.ssl);
    if (ret_code == 0) {
        return false;
    } else if (ret_code == 1) {
        return true;
    } else {
        const err_code = openssl.SSL_get_error(self.ssl, ret_code);
        if (err_code == openssl.SSL_ERROR_WANT_READ or err_code == openssl.SSL_ERROR_WANT_WRITE) {
            return false;
        } else {
            return AcceptError.FailedToAcceptClient;
        }
    }
}
