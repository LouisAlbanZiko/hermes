const std = @import("std");
const posix = std.posix;

const structure = @import("structure");
const server = @import("server");
const http = server.http;

const DB = server.DB;
const Client = server.Client;
const ServerResource = server.ServerResource;

const Protocol = enum { http, tls, https };
const ProtocolData = union(Protocol) {
    http,
    tls: struct {},
    https: struct {
        _fill: usize,
    },
    pub fn init(protocol: Protocol) ProtocolData {
        switch (protocol) {
            .http => return .{ .http = void{} },
            .tls => return .{ .tls = .{} },
            .https => return .{ .https = .{ ._fill = 0 } },
        }
    }
};

const log = std.log.scoped(.SERVER);

const PORTS = [_]u16{ 8080, 8443 };
const DEFAULT_PROTOCOL = [_]Protocol{ .http, .tls };
const CLIENT_TIMEOUT_S = 60;

pub fn main() !void {
    const client_poll_offset = PORTS.len;

    const server_start = std.time.nanoTimestamp();

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();

    const gpa = gpa_state.allocator();

    var db = try DB.init("db.sqlite");
    defer db.deinit();

    var pollfds = std.ArrayList(posix.pollfd).init(gpa);
    defer {
        for (pollfds.items) |pollfd| {
            posix.close(pollfd.fd);
        }
        pollfds.deinit();
    }

    const ClientData = struct {
        client: Client,
        is_open: bool,
        last_commms: i128,
        ip: server.IP,
        protocol: ProtocolData,
    };
    var clients_data = std.ArrayList(ClientData).init(gpa);
    defer clients_data.deinit();

    const www = comptime http.gen_resources(structure.www);
    for (www.keys()) |key| {
        log.info("ADDED '{s}' at '{s}'", .{ @tagName(www.get(key).?), key });
    }

    var server_socks: [PORTS.len]posix.socket_t = undefined;
    for (0..PORTS.len) |port_index| {
        const port = PORTS[port_index];

        const server_sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);

        const on: [4]u8 = .{ 0, 0, 0, 1 };
        try posix.setsockopt(server_sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &on);

        var address = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = ((port & 0xFF00) >> 8) | ((port & 0x00FF) << 8),
            .addr = 0,
        };
        try posix.bind(server_sock, @ptrCast(&address), @sizeOf(@TypeOf(address)));
        try posix.listen(server_sock, 32);

        try pollfds.append(posix.pollfd{ .events = posix.POLL.IN, .fd = server_sock, .revents = 0 });

        log.info("Listening on port {d}.", .{port});
        server_socks[port_index] = server_sock;
    }

    const running = true;
    while (running) {
        {
            log.info("POLLING Server and {d} Clients", .{pollfds.items.len - 1});
            const ready_count = try posix.poll(pollfds.items, 2 * 1000);
            var handled_count: usize = 0;
            log.info("POLLED! {d} socks are ready.", .{ready_count});

            for (0..server_socks.len) |server_sock_index| {
                const server_sock = server_socks[server_sock_index];
                if (pollfds.items[server_sock_index].revents & posix.POLL.IN != 0) {
                    var addr: posix.sockaddr.in = undefined;
                    var addr_len: u32 = @sizeOf(@TypeOf(addr));
                    const client_sock = try posix.accept(server_sock, @ptrCast(&addr), &addr_len, posix.SOCK.NONBLOCK);

                    try pollfds.append(posix.pollfd{ .events = posix.POLL.IN, .fd = client_sock, .revents = 0 });
                    try clients_data.append(ClientData{
                        .client = Client{ .sock = client_sock },
                        .is_open = true,
                        .last_commms = std.time.nanoTimestamp() - server_start,
                        .ip = .{ .v4 = @bitCast(addr.addr) },
                        .protocol = ProtocolData.init(DEFAULT_PROTOCOL[server_sock_index]),
                    });

                    log.info("ACCEPTED Client({d}) with IP({})", .{ client_sock, clients_data.getLast().ip });

                    handled_count += 1;
                }
            }

            var poll_index: usize = client_poll_offset;
            while (handled_count < ready_count and poll_index < pollfds.items.len) {
                const pollfd = pollfds.items[poll_index];
                if (pollfd.revents & posix.POLL.IN != 0) {
                    const client = Client{ .sock = pollfd.fd };

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

                        try res.output_to(client.writer());
                    } else |err| {
                        switch (err) {
                            http.Request.ParseError.StreamEmpty => {
                                log.info("CLOSING {d}. Reason: Stream Empty", .{pollfd.fd});
                                clients_data.items[poll_index - client_poll_offset].is_open = false;
                            },
                            else => return err,
                        }
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
                    const pollfd = pollfds.swapRemove(poll_index);
                    _ = clients_data.swapRemove(client_index);
                    log.info("CLOSED {d}", .{pollfd.fd});
                }
            }
        }
    }
}
