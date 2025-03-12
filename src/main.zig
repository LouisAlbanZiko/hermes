const std = @import("std");
const posix = std.posix;

const http = @import("http");
const structure = @import("structure");
const server = @import("server");

const DB = server.DB;
const Client = server.Client;
const ServerResource = server.ServerResource;

const log = std.log.scoped(.SERVER);

const PORT = 8080;
const CLIENT_TIMEOUT_S = 60;

pub fn main() !void {
    const client_poll_offset = 1;
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
        is_open: bool,
        last_commms: i128,
        ip: server.IP,
    };
    var clients_data = std.ArrayList(ClientData).init(gpa);
    defer clients_data.deinit();

    const www = comptime http_gen_resources(structure.www);
    for (www.keys()) |key| {
        log.info("ADDED '{s}' at '{s}'", .{ @tagName(www.get(key).?), key });
    }

    const server_sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);

    const on: [4]u8 = .{ 0, 0, 0, 1 };
    try posix.setsockopt(server_sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &on);

    var address = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = ((PORT & 0xFF00) >> 8) | ((PORT & 0x00FF) << 8),
        .addr = 0,
    };
    try posix.bind(server_sock, @ptrCast(&address), @sizeOf(@TypeOf(address)));
    try posix.listen(server_sock, 32);

    try pollfds.append(posix.pollfd{ .events = posix.POLL.IN, .fd = server_sock, .revents = 0 });

    log.info("Listening on port {d}.", .{PORT});

    const running = true;
    while (running) {
        {
            log.info("POLLING Server and {d} Clients", .{pollfds.items.len - 1});
            const ready_count = try posix.poll(pollfds.items, 2 * 1000);
            var handled_count: usize = 0;
            log.info("POLLED! {d} socks are ready.", .{ready_count});

            if (pollfds.items[0].revents & posix.POLL.IN != 0) {
                var addr: posix.sockaddr.in = undefined;
                var addr_len: u32 = @sizeOf(@TypeOf(addr));
                const client_sock = try posix.accept(server_sock, @ptrCast(&addr), &addr_len, posix.SOCK.NONBLOCK);

                try pollfds.append(posix.pollfd{ .events = posix.POLL.IN, .fd = client_sock, .revents = 0 });
                try clients_data.append(ClientData{ .is_open = true, .last_commms = std.time.nanoTimestamp() - server_start, .ip = .{ .v4 = @bitCast(addr.addr) } });

                log.info("ACCEPTED Client({d}) with IP({})", .{ client_sock, clients_data.getLast().ip });

                handled_count += 1;
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
                            var path_iter = std.mem.splitScalar(u8, req.path[1..], '/');
                            if (path_iter.next()) |current_path| {
                                if (find_resource(current_path, &path_iter, www)) |resource| {
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
                                                callback(db, &req, &res) catch |err| {
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
                                log.debug("Request path '{s}' not found.", .{req.path});
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

const HTTP_Callback = *const fn (DB, *const http.Request, *http.Response) std.mem.Allocator.Error!void;
const HTTP_ResourceType = ServerResource.Type;
const HTTP_Directory = std.StaticStringMap(HTTP_Resource);
const HTTP_Resource = union(HTTP_ResourceType) {
    directory: HTTP_Directory,
    handler: [@typeInfo(http.Request.Method).@"enum".fields.len]?HTTP_Callback,
    template: []const u8,
    file: []const u8,
};

fn http_gen_resources(resources: []const ServerResource) HTTP_Directory {
    var values: [resources.len]struct { []const u8, HTTP_Resource } = undefined;

    inline for (resources, 0..) |resource, index| {
        switch (resource.value) {
            .directory => |d| {
                values[index] = .{ resource.path, .{ .directory = http_gen_resources(d) } };
            },
            .handler => |t| {
                var callbacks: [@typeInfo(http.Method).@"enum".fields.len]?HTTP_Callback = undefined;
                inline for (@typeInfo(http.Method).@"enum".fields) |field| {
                    const fn_name = "http_" ++ field.name;
                    if (std.meta.hasFn(t, fn_name)) {
                        callbacks[field.value] = @field(t, fn_name);
                    } else {
                        callbacks[field.value] = null;
                    }
                }
                values[index] = .{ resource.path, .{ .handler = callbacks } };
            },
            .file => |content| {
                values[index] = .{ resource.path, .{ .file = content } };
            },
            .template => |content| {
                values[index] = .{ resource.path, .{ .template = content } };
            },
        }
    }

    return HTTP_Directory.initComptime(values);
}

const PathIterator = std.mem.SplitIterator(u8, .scalar);
pub fn find_resource(current_path: []const u8, path_iter: *PathIterator, dir: HTTP_Directory) ?HTTP_Resource {
    std.debug.print("///////////////////////////// {s}", .{current_path});
    if (dir.get(current_path)) |res| {
        if (path_iter.next()) |child_path| {
            switch (res) {
                .directory => |child_dir| {
                    return find_resource(child_path, path_iter, child_dir);
                },
                else => {
                    return null;
                },
            }
        } else {
            return res;
        }
    } else {
        return null;
    }
}
