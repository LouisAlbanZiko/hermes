const std = @import("std");
const posix = std.posix;

const structure = @import("structure");
const config = @import("config");
const server = @import("server");
const http = server.http;

const DB = server.DB;
const TCP_Client = server.TCP_Client;
const SSL_Client = server.SSL_Client;
const ServerResource = server.ServerResource;
const SSL_Context = server.SSL_Context;

const Protocol = enum { http, tls, https };
const ProtocolData = union(Protocol) {
    http: struct {
        client: TCP_Client,
    },
    tls: struct {
        client: SSL_Client,
    },
    https: struct {
        client: SSL_Client,
    },
};

const log = std.log.scoped(.SERVER);

const PORTS = [_]u16{ config.http_port, config.https_port };
const DEFAULT_PROTOCOL = [_]Protocol{ .http, .tls };
const CLIENT_TIMEOUT_S = 60;

pub fn main() std.mem.Allocator.Error!void {
    const client_poll_offset = PORTS.len;

    const server_start = std.time.nanoTimestamp();

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();

    const gpa = gpa_state.allocator();

    var db = DB.init("db.sqlite") catch |err| {
        log.err("Failed to initialize Database with Error({s})", .{@errorName(err)});
        return;
    };
    defer db.deinit();

    var ssl_ctx = SSL_Context.init("localhost.crt", "localhost.key") catch |err| {
        log.err("Failed to initialize SSL_Context with Error({s})", .{@errorName(err)});
        return;
    };
    defer ssl_ctx.deinit();

    var pollfds = std.ArrayList(posix.pollfd).init(gpa);
    defer {
        for (pollfds.items) |pollfd| {
            posix.close(pollfd.fd);
        }
        pollfds.deinit();
    }

    const ClientData = struct {
        is_open: bool,
        last_commms: i128,
        ip: server.IP,
        protocol: ProtocolData,
    };
    var clients_data = std.ArrayList(ClientData).init(gpa);
    defer clients_data.deinit();

    const www = comptime http.gen_resources(structure.www);

    var server_socks: [PORTS.len]posix.socket_t = undefined;
    for (0..PORTS.len) |port_index| {
        const port = PORTS[port_index];

        const server_sock = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch |err| {
            log.err("Failed to open Server Socket at port({d}) with Error({s})", .{ port, @errorName(err) });
            return;
        };

        const on: [4]u8 = .{ 0, 0, 0, 1 };
        posix.setsockopt(server_sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &on) catch |err| {
            log.err("Failed to make Server Socket at port({d}) Non Blocking with Error({s})", .{ port, @errorName(err) });
            return;
        };

        var address = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = ((port & 0xFF00) >> 8) | ((port & 0x00FF) << 8),
            .addr = 0,
        };
        posix.bind(server_sock, @ptrCast(&address), @sizeOf(@TypeOf(address))) catch |err| {
            log.err("Failed to bind Server Socket at port({d}) with Error({s})", .{ port, @errorName(err) });
            return;
        };
        posix.listen(server_sock, 32) catch |err| {
            log.err("Failed to make Server Socket listen on port({d}) with Error({s})", .{ port, @errorName(err) });
            return;
        };

        try pollfds.append(posix.pollfd{ .events = posix.POLL.IN, .fd = server_sock, .revents = 0 });

        log.info("Listening on port {d}.", .{port});
        server_socks[port_index] = server_sock;
    }
    defer {
        for (server_socks) |server_sock| {
            posix.close(server_sock);
        }
    }

    const running = true;
    while (running) {
        {
            log.info("POLLING Server and {d} Clients", .{pollfds.items.len - 1});
            const ready_count = posix.poll(pollfds.items, 2 * 1000) catch |err| {
                log.err("Polling failed with Error({s})", .{@errorName(err)});
                continue;
            };
            var handled_count: usize = 0;
            log.info("POLLED! {d} socks are ready.", .{ready_count});

            for (0..server_socks.len) |server_sock_index| {
                const server_sock = server_socks[server_sock_index];
                if (pollfds.items[server_sock_index].revents & posix.POLL.IN != 0) {
                    var addr: posix.sockaddr.in = undefined;
                    var addr_len: u32 = @sizeOf(@TypeOf(addr));
                    const client_sock = posix.accept(server_sock, @ptrCast(&addr), &addr_len, posix.SOCK.NONBLOCK) catch |err| {
                        log.err("Failed to accept client on port({d}) with Error({s})", .{ PORTS[server_sock_index], @errorName(err) });
                        continue;
                    };

                    var protocol_data: ProtocolData = undefined;
                    if (DEFAULT_PROTOCOL[server_sock_index] == .http) {
                        protocol_data = .{ .http = .{ .client = .{ .sock = client_sock } } };
                    } else {
                        const client = ssl_ctx.client_new(client_sock) catch |err| {
                            log.err("Failed to initialize SSL for new client with Error({s})", .{@errorName(err)});
                            posix.close(client_sock);
                            continue;
                        };
                        protocol_data = .{ .tls = .{ .client = client } };
                    }

                    try pollfds.append(posix.pollfd{ .events = posix.POLL.IN, .fd = client_sock, .revents = 0 });
                    try clients_data.append(ClientData{
                        .is_open = true,
                        .last_commms = std.time.nanoTimestamp() - server_start,
                        .ip = .{ .v4 = @bitCast(addr.addr) },
                        .protocol = protocol_data,
                    });

                    log.info("ACCEPTED Client({d}) with IP({})", .{ client_sock, clients_data.getLast().ip });

                    handled_count += 1;
                }
            }

            var poll_index: usize = client_poll_offset;
            while (handled_count < ready_count and poll_index < pollfds.items.len) {
                const pollfd = pollfds.items[poll_index];
                if (pollfd.revents & posix.POLL.IN != 0) {
                    switch (clients_data.items[poll_index - client_poll_offset].protocol) {
                        .http => |*http_data| {
                            const client = http_data.client;
                            if (http.Request.parse(gpa, client.reader())) |const_req| {
                                var req = const_req;
                                defer req.deinit();

                                var res = try http.Response.init(gpa);
                                defer res.deinit();

                                if (std.mem.startsWith(u8, req.path, "/")) {
                                    if (http.find_resource(req.path[1..], www)) |resource| {
                                        switch (resource) {
                                            .directory => |_| {
                                                res.code = ._404_NOT_FOUND;
                                                log.debug("Found directory at '{s}'", .{req.path});
                                            },
                                            .file => |content| {
                                                res.code = ._200_OK;
                                                _ = try res.write_body(content);
                                                log.debug("Found static file at '{s}'", .{req.path});
                                            },
                                            .template => |_| {
                                                res.code = ._404_NOT_FOUND;
                                                log.debug("Found template at '{s}'", .{req.path});
                                            },
                                            .handler => |*handler| {
                                                if (handler.*[@intFromEnum(req.method)]) |callback| {
                                                    var context = http.Context{ .db = db };
                                                    callback(&context, &req, &res) catch |err| {
                                                        res.code = ._500_INTERNAL_SERVER_ERROR;
                                                        log.err("Callback on path '{s}' failed with Error({s})", .{ req.path, @errorName(err) });
                                                    };
                                                } else {
                                                    res.code = ._404_NOT_FOUND;
                                                    log.debug("Found null callback at '{s}'", .{req.path});
                                                }
                                            },
                                        }
                                    } else {
                                        res.code = ._404_NOT_FOUND;
                                        log.debug("No resource found at '{s}'", .{req.path});
                                    }
                                } else {
                                    res.code = ._404_NOT_FOUND;
                                    log.debug("Request path '{s}' doesn't start with '/'.", .{req.path});
                                }

                                res.output_to(client.writer()) catch |err| {
                                    log.err("Failed to send response to Client({}) with Error({s})", .{ client, @errorName(err) });
                                    clients_data.items[poll_index - client_poll_offset].is_open = false;
                                };
                            } else |err| {
                                switch (err) {
                                    http.Request.ParseError.StreamEmpty => {
                                        log.info("CLOSING {d}. Reason: Stream Empty", .{pollfd.fd});
                                        clients_data.items[poll_index - client_poll_offset].is_open = false;
                                    },
                                    else => {
                                        log.err("CLOSING {d}. Reason: Error({s})", .{ pollfd.fd, @errorName(err) });
                                        clients_data.items[poll_index - client_poll_offset].is_open = false;
                                    },
                                }
                            }
                        },
                        .https => |*https_data| {
                            const client = https_data.client;
                            if (http.Request.parse(gpa, client.reader())) |const_req| {
                                var req = const_req;
                                defer req.deinit();

                                var res = try http.Response.init(gpa);
                                defer res.deinit();

                                if (std.mem.startsWith(u8, req.path, "/")) {
                                    if (http.find_resource(req.path[1..], www)) |resource| {
                                        switch (resource) {
                                            .directory => |_| {
                                                res.code = ._404_NOT_FOUND;
                                                log.debug("Found directory at '{s}'", .{req.path});
                                            },
                                            .file => |content| {
                                                res.code = ._200_OK;
                                                _ = try res.write_body(content);
                                                log.debug("Found static file at '{s}'", .{req.path});
                                            },
                                            .template => |_| {
                                                res.code = ._404_NOT_FOUND;
                                                log.debug("Found template at '{s}'", .{req.path});
                                            },
                                            .handler => |*handler| {
                                                if (handler.*[@intFromEnum(req.method)]) |callback| {
                                                    var context = http.Context{ .db = db };
                                                    callback(&context, &req, &res) catch |err| {
                                                        res.code = ._500_INTERNAL_SERVER_ERROR;
                                                        log.err("Callback on path '{s}' failed with Error({s})", .{ req.path, @errorName(err) });
                                                    };
                                                } else {
                                                    res.code = ._404_NOT_FOUND;
                                                    log.debug("Found null callback at '{s}'", .{req.path});
                                                }
                                            },
                                        }
                                    } else {
                                        res.code = ._404_NOT_FOUND;
                                        log.debug("No resource found at '{s}'", .{req.path});
                                    }
                                } else {
                                    res.code = ._404_NOT_FOUND;
                                    log.debug("Request path '{s}' doesn't start with '/'.", .{req.path});
                                }

                                res.output_to(client.writer()) catch |err| {
                                    log.err("Failed to send response to Client({}) with Error({s})", .{ client, @errorName(err) });
                                    clients_data.items[poll_index - client_poll_offset].is_open = false;
                                };
                            } else |err| {
                                switch (err) {
                                    http.Request.ParseError.StreamEmpty => {
                                        log.info("CLOSING {d}. Reason: Stream Empty", .{pollfd.fd});
                                        clients_data.items[poll_index - client_poll_offset].is_open = false;
                                    },
                                    else => {
                                        log.err("CLOSING {d}. Reason: Error({s})", .{ pollfd.fd, @errorName(err) });
                                        clients_data.items[poll_index - client_poll_offset].is_open = false;
                                    },
                                }
                            }
                        },
                        .tls => |*tls_data| {
                            if (tls_data.client.accept_step()) |is_accepted| {
                                if (is_accepted) {
                                    clients_data.items[poll_index - client_poll_offset].protocol = .{ .https = .{ .client = tls_data.client } };
                                }
                            } else |err| {
                                log.err("CLOSING {d}. Reason: SSL handshake failed with Error({s})", .{ pollfd.fd, @errorName(err) });
                                clients_data.items[poll_index - client_poll_offset].is_open = false;
                            }
                        },
                    }
                    clients_data.items[poll_index - client_poll_offset].last_commms = std.time.nanoTimestamp() - server_start;

                    handled_count += 1;
                }
                poll_index += 1;
            }
        }
        {
            const now = std.time.nanoTimestamp() - server_start;
            var client_index: usize = 0;
            while (client_index < clients_data.items.len) {
                if (clients_data.items[client_index].last_commms + CLIENT_TIMEOUT_S * std.time.ns_per_s < now) {
                    clients_data.items[client_index].is_open = false;
                }
                client_index += 1;
            }
        }
        {
            var client_index: usize = 0;
            while (client_index < clients_data.items.len) {
                if (clients_data.items[client_index].is_open) {
                    client_index += 1;
                } else {
                    const poll_index = client_index + client_poll_offset;
                    posix.close(pollfds.items[poll_index].fd);
                    switch (clients_data.items[client_index].protocol) {
                        .https => |*https_data| {
                            ssl_ctx.client_free(https_data.client);
                        },
                        .tls => |*tls_data| {
                            ssl_ctx.client_free(tls_data.client);
                        },
                        .http => |_| {},
                    }
                    const pollfd = pollfds.swapRemove(poll_index);
                    _ = clients_data.swapRemove(client_index);
                    log.info("CLOSED {d}", .{pollfd.fd});
                }
            }
        }
    }
}
