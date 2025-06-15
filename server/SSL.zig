const std = @import("std");
const openssl = @cImport({
    @cInclude("openssl/ssl.h");
});
const SSL_Client = @import("SSL_Client.zig");

const log = std.log.scoped(.SSL);

const SSL_Context = @This();
ssl_ctx: ?*openssl.SSL_CTX,

pub const InitError = error{
    ContextCreateError,
    LoadCrtError,
    LoadPrivError,
};
pub fn init(file_crt: [:0]const u8, file_key: [:0]const u8) InitError!SSL_Context {
    const ssl_method = openssl.TLS_server_method();
    const ssl_ctx: ?*openssl.SSL_CTX = openssl.SSL_CTX_new(ssl_method);
    if (ssl_ctx == null) {
        log.err("Failed to create SSL context", .{});
        return InitError.ContextCreateError;
    }

    if (openssl.SSL_CTX_use_certificate_file(ssl_ctx, file_crt, openssl.SSL_FILETYPE_PEM) <= 0) {
        log.err("Failed to load crt file.", .{});
        return error.LoadCrtError;
    }
    if (openssl.SSL_CTX_use_PrivateKey_file(ssl_ctx, file_key, openssl.SSL_FILETYPE_PEM) <= 0) {
        log.err("Failed to load private key file.", .{});
        return error.LoadPrivError;
    }

    return .{ .ssl_ctx = ssl_ctx };
}

pub fn deinit(self: *SSL_Context) void {
    openssl.SSL_CTX_free(self.ssl_ctx);
}

pub const ClientInitError = error{
    SSL_new_Failed,
    SSL_set_fd_Failed,
};
pub fn client_new(self: *SSL_Context, client_sock: std.posix.socket_t) !SSL_Client {
    const ssl = openssl.SSL_new(self.ssl_ctx);
    if (ssl == null) {
        log.err("Failed to create SSL Client.", .{});
        return ClientInitError.SSL_new_Failed;
    }
    errdefer openssl.SSL_free(ssl);

    const builtin = @import("builtin");
    const sock32bit: c_int = if (builtin.os.tag == .windows) @intCast(@intFromPtr(client_sock)) else client_sock;
    if (openssl.SSL_set_fd(ssl, sock32bit) <= 0) {
        log.err("Failed to set fd of SSL_Client", .{});
        return ClientInitError.SSL_set_fd_Failed;
    }
    return SSL_Client{ .ssl = ssl, .sock = client_sock };
}

pub fn client_free(_: *const SSL_Context, client: SSL_Client) void {
    openssl.SSL_free(client.ssl);
}
