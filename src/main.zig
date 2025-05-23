const std = @import("std");
const posix = std.posix;

const structure = @import("structure");
const options = @import("options");
const server = @import("server");
const util = @import("util");

const http = server.http;
const TCP_Client = server.TCP_Client;
const SSL_Client = server.SSL_Client;
const ServerResource = server.ServerResource;
const SSL_Context = server.SSL_Context;
const Config = server.Config;

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
const ClientData = struct {
    is_open: bool,
    last_commms: i128,
    ip: server.IP,
    protocol: ProtocolData,
};

const log = std.log.scoped(.SERVER);

fn custom_log(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    if (options.optimize == .Debug) {
        output_log(std.io.getStdOut().writer(), level, scope, format, args) catch @panic("Failed to log!");
    } else {
        const file = std.fs.openFileAbsolute("/var/log/" ++ options.exe_name ++ ".log", .{ .mode = .write_only }) catch |err| {
            std.debug.print("Failed to open log file with Error({s})\n", .{@errorName(err)});
            return;
        };
        file.seekFromEnd(0) catch |err| {
            std.debug.print("Failed to seek to end of file with Error({s})\n", .{@errorName(err)});
            return;
        };
        defer file.close();
        output_log(file.writer(), level, scope, format, args) catch |err| {
            std.debug.print("Failed to output to lof file with Error({s})\n", .{@errorName(err)});
            return;
        };
    }
}
fn output_log(writer: anytype, comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) !void {
    var time_buffer: [128:0]u8 = undefined;
    const timestamp_len = util.timestamp_to_iso8601(std.time.microTimestamp(), &time_buffer, time_buffer.len);
    time_buffer[timestamp_len] = 0;

    try std.fmt.format(writer, "[{s}][{s}] {s}: ", .{ time_buffer[0..timestamp_len :0], @tagName(scope), @tagName(level) });
    try std.fmt.format(writer, format, args);
    try writer.writeAll("\n");
}
pub const std_options: std.Options = .{
    .log_level = blk: {
        if (options.optimize == .Debug) {
            break :blk .debug;
        } else {
            break :blk .info;
        }
    },
    .logFn = custom_log,
};

pub fn main() std.mem.Allocator.Error!void {
    const server_start = std.time.nanoTimestamp();

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();

    const gpa = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const args = std.process.argsAlloc(gpa) catch |err| {
        log.err("Failed to retrieve cmd arguments with Error({s})", .{@errorName(err)});
        return;
    };
    defer std.process.argsFree(gpa, args);

    var config_file_path: []const u8 = "config.zon";
    if (args.len >= 2) {
        config_file_path = args[1];
    }

    const config = Config.load(arena, config_file_path);

    var client_poll_offset: usize = 0;
    var server_socks = std.ArrayList(ServerSock).init(gpa);
    defer server_socks.deinit();

    var pollfds = std.ArrayList(posix.pollfd).init(gpa);
    defer {
        for (pollfds.items) |pollfd| {
            posix.close(pollfd.fd);
        }
        pollfds.deinit();
    }

    const http_sock = open_server_sock(config.http.port, .http) catch {
        return;
    };
    try server_socks.append(http_sock);
    try pollfds.append(posix.pollfd{ .fd = http_sock.sock, .events = posix.POLL.IN, .revents = 0 });
    client_poll_offset += 1;

    const ssl_public_crt = try gpa.dupeZ(u8, config.https.cert);
    defer gpa.free(ssl_public_crt);
    const ssl_private_key = try gpa.dupeZ(u8, config.https.key);
    defer gpa.free(ssl_private_key);

    var has_https: ?struct {
        sock: ServerSock,
        ssl: SSL_Context,
    } = null;
    if (SSL_Context.init(ssl_public_crt, ssl_private_key)) |ssl| {
        if (open_server_sock(config.https.port, .tls)) |https_sock| {
            try server_socks.append(https_sock);
            try pollfds.append(posix.pollfd{ .fd = https_sock.sock, .events = posix.POLL.IN, .revents = 0 });
            has_https = .{ .sock = https_sock, .ssl = ssl };
            client_poll_offset += 1;
        } else |err| {
            log.err("Failed to open HTTPS socket with Error({s})", .{@errorName(err)});
        }
    } else |err| {
        log.err("Failed to initialize SSL_Context with Error({s}).", .{@errorName(err)});
    }
    defer {
        if (has_https) |*https| {
            https.ssl.deinit();
        }
    }

    var clients_data = std.ArrayList(ClientData).init(gpa);
    defer clients_data.deinit();

    var http_server_data = http.ServerData.init(structure.www);

    inline for (structure.modules) |mod| {
        if (std.meta.hasFn(mod, "init")) {
            mod.init(gpa) catch |err| {
                log.err("Failed to initialize module with Error({s})", .{@errorName(err)});
                return;
            };
        }
    }

    const running = true;
    while (running) {
        {
            log.debug("POLLING Server and {d} Clients", .{pollfds.items.len - 1});
            const ready_count = posix.poll(pollfds.items, @intCast(config.poll_timeout_s * std.time.ms_per_s)) catch |err| {
                log.err("Polling failed with Error({s})", .{@errorName(err)});
                continue;
            };
            var handled_count: usize = 0;
            log.debug("POLLED! {d} socks are ready.", .{ready_count});

            // check http port
            {
                if (pollfds.items[0].revents & posix.POLL.IN != 0) {
                    var addr: posix.sockaddr.in = undefined;
                    var addr_len: u32 = @sizeOf(@TypeOf(addr));
                    const client_sock = posix.accept(http_sock.sock, @ptrCast(&addr), &addr_len, posix.SOCK.NONBLOCK) catch |err| {
                        log.err("Failed to accept client on port({d}) with Error({s})", .{ http_sock.port, @errorName(err) });
                        continue;
                    };

                    try pollfds.append(posix.pollfd{ .events = posix.POLL.IN, .fd = client_sock, .revents = 0 });
                    try clients_data.append(ClientData{
                        .is_open = true,
                        .last_commms = std.time.nanoTimestamp() - server_start,
                        .ip = .{ .v4 = @bitCast(addr.addr) },
                        .protocol = ProtocolData{ .http = .{ .client = .{ .sock = client_sock } } },
                    });

                    log.info("ACCEPTED HTTP Client({d}) with IP({})", .{ client_sock, clients_data.getLast().ip });

                    handled_count += 1;
                }
            }
            if (has_https) |*https| {
                if (pollfds.items[1].revents & posix.POLL.IN != 0) {
                    var addr: posix.sockaddr.in = undefined;
                    var addr_len: u32 = @sizeOf(@TypeOf(addr));
                    const client_sock = posix.accept(https.sock.sock, @ptrCast(&addr), &addr_len, posix.SOCK.NONBLOCK) catch |err| {
                        log.err("Failed to accept client on port({d}) with Error({s})", .{ https.sock.port, @errorName(err) });
                        continue;
                    };

                    const ssl_client = https.ssl.client_new(client_sock) catch |err| {
                        log.err("Failed to initialize SSL for new client with Error({s})", .{@errorName(err)});
                        posix.close(client_sock);
                        continue;
                    };

                    try pollfds.append(posix.pollfd{ .events = posix.POLL.IN, .fd = client_sock, .revents = 0 });
                    try clients_data.append(ClientData{
                        .is_open = true,
                        .last_commms = std.time.nanoTimestamp() - server_start,
                        .ip = .{ .v4 = @bitCast(addr.addr) },
                        .protocol = ProtocolData{ .tls = .{ .client = ssl_client } },
                    });

                    log.info("ACCEPTED TLS Client({d}) with IP({})", .{ client_sock, clients_data.getLast().ip });

                    handled_count += 1;
                }
            }

            var poll_index: usize = client_poll_offset;
            while (handled_count < ready_count and poll_index < pollfds.items.len) {
                const pollfd = pollfds.items[poll_index];
                if (pollfd.revents & posix.POLL.IN != 0) {
                    var client_data = &clients_data.items[poll_index - client_poll_offset];
                    switch (clients_data.items[poll_index - client_poll_offset].protocol) {
                        .http => |*http_data| {
                            const client = http_data.client;
                            handle_http_data(
                                client,
                                client_data,
                                gpa,
                                &config,
                                &http_server_data,
                            ) catch |err| {
                                client_data.is_open = false;
                                log.info("CLOSING {d}. Reason: Error({s})", .{ client.sock, @errorName(err) });
                            };
                        },
                        .https => |*https_data| {
                            const client = https_data.client;
                            handle_http_data(
                                client,
                                client_data,
                                gpa,
                                &config,
                                &http_server_data,
                            ) catch |err| {
                                client_data.is_open = false;
                                log.info("CLOSING {d}. Reason: Error({s})", .{ client.sock, @errorName(err) });
                            };
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
                if (clients_data.items[client_index].last_commms + config.client_timeout_s * std.time.ns_per_s < now) {
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
                            const https = &(has_https orelse unreachable);
                            https.ssl.client_free(https_data.client);
                        },
                        .tls => |*tls_data| {
                            const https = &(has_https orelse unreachable);
                            https.ssl.client_free(tls_data.client);
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

const ServerSock = struct {
    port: u16,
    sock: i32,
    prot: Protocol,
};

fn open_server_sock(port: u16, prot: Protocol) !ServerSock {
    const server_sock = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch |err| {
        log.err("Failed to open Server Socket at port({d}) with Error({s})", .{ port, @errorName(err) });
        return err;
    };

    const on: [4]u8 = .{ 0, 0, 0, 1 };
    posix.setsockopt(server_sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &on) catch |err| {
        log.err("Failed to make Server Socket at port({d}) Non Blocking with Error({s})", .{ port, @errorName(err) });
        return err;
    };

    var address = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = ((port & 0xFF00) >> 8) | ((port & 0x00FF) << 8),
        .addr = 0,
    };
    posix.bind(server_sock, @ptrCast(&address), @sizeOf(@TypeOf(address))) catch |err| {
        log.err("Failed to bind Server Socket at port({d}) with Error({s})", .{ port, @errorName(err) });
        return err;
    };
    posix.listen(server_sock, 32) catch |err| {
        log.err("Failed to make Server Socket listen on port({d}) with Error({s})", .{ port, @errorName(err) });
        return err;
    };

    //try pollfds.append(posix.pollfd{ .events = posix.POLL.IN, .fd = server_sock, .revents = 0 });

    log.info("Listening on port {d}.", .{port});

    return ServerSock{
        .sock = server_sock,
        .port = port,
        .prot = prot,
    };
}

fn handle_http_data(
    client: anytype,
    _: *ClientData,
    gpa: std.mem.Allocator,
    config: *const Config,
    http_server_data: *http.ServerData,
) (@TypeOf(client).ReadError || @TypeOf(client).WriteError || http.Request.ParseError || std.mem.Allocator.Error)!void {
    const reader = client.reader();
    const writer = client.writer();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    var req = http.Request.parse(gpa, reader) catch |err| {
        try writer.writeAll("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n");
        return err;
    };
    defer req.deinit();

    log.info("Got Request from Client {d}: {s}", .{ client.sock, req });

    if (!std.mem.startsWith(u8, req.path, "/")) {
        const message = "Path needs to start with '/'.";
        try writer.writeAll(std.fmt.comptimePrint("HTTP/1.1 404 Not Found\r\nContent-Length: {d}\r\n\r\n{s}", .{ message.len, message }));
        return;
    }

    const path = req.path[1..];
    const res = blk_handle: {
        if (http_server_data.root_dir.find_resource(path)) |resource_tuple| {
            const resource = resource_tuple.@"1";
            const current_dir = resource_tuple.@"0";
            switch (resource) {
                .directory => |_| {
                    // add index lookup
                    log.debug("Found directory at '{s}'", .{req.path});
                    break :blk_handle http.Response.not_found();
                },
                .file => |content| {
                    log.debug("Found static file at '{s}'", .{req.path});
                    break :blk_handle try http.Response.file(arena, http.ContentType.from_filename(path).?, content);
                },
                .handler => |*handler| {
                    if (handler.*[@intFromEnum(req.method)]) |callback| {
                        const ctx = http.Context{
                            .arena = arena,
                            .root_dir = http_server_data.root_dir,
                            .current_dir = current_dir,
                        };
                        if (callback(ctx, &req)) |res| {
                            break :blk_handle res;
                        } else |err| {
                            log.err("Callback on path '{s}' failed with Error({s})", .{ req.path, @errorName(err) });
                            break :blk_handle http.Response.server_error();
                        }
                    } else {
                        log.debug("Found null callback at '{s}'", .{req.path});
                        break :blk_handle http.Response.not_found();
                    }
                },
            }
        } else if (config.data_dir) |data_dir| {
            var dir = std.fs.cwd().openDir(data_dir, .{}) catch |err| {
                log.info("Could not open data dir with Error({s})", .{@errorName(err)});
                break :blk_handle http.Response.not_found();
            };
            defer dir.close();

            const file = dir.openFile(path, .{}) catch |err| {
                log.info("Could not open file at path '{s}' with Error({s})", .{ path, @errorName(err) });
                break :blk_handle http.Response.not_found();
            };
            defer file.close();

            const content = file.readToEndAlloc(arena, 1024 * 256) catch |err| {
                log.err("Could not read file at path '{s}' with Error({s})", .{ path, @errorName(err) });
                break :blk_handle http.Response.server_error();
            };
            break :blk_handle try http.Response.file(arena, http.ContentType.from_filename(path).?, content);
        } else {
            break :blk_handle http.Response.not_found();
        }
    };

    try std.fmt.format(writer, "{}", .{res});
}
