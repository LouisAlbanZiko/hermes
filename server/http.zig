const std = @import("std");
const http = @import("http");

const DB = @import("DB.zig");
const ServerResource = @import("ServerResource.zig");

pub const Request = http.Request;
pub const Response = http.Response;

pub const Context = struct {
    db: DB,
};

pub const Callback = *const fn (*Context, *const http.Request, *http.Response) std.mem.Allocator.Error!void;
pub const ResourceType = ServerResource.Type;
pub const Directory = std.StaticStringMap(Resource);
pub const Resource = union(ResourceType) {
    directory: Directory,
    handler: [@typeInfo(http.Request.Method).@"enum".fields.len]?Callback,
    template: []const u8,
    file: []const u8,
};

pub fn gen_resources(resources: []const ServerResource) Directory {
    var values: [resources.len]struct { []const u8, Resource } = undefined;

    inline for (resources, 0..) |resource, index| {
        switch (resource.value) {
            .directory => |d| {
                values[index] = .{ resource.path, .{ .directory = gen_resources(d) } };
            },
            .handler => |t| {
                var callbacks: [@typeInfo(http.Method).@"enum".fields.len]?Callback = undefined;
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

    return Directory.initComptime(values);
}

pub fn find_resource(path: []const u8, root_dir: Directory) ?Resource {
    var path_iter = std.mem.splitScalar(u8, path, '/');

    var dir = root_dir;
    while (path_iter.next()) |current_path| {
        if (dir.get(current_path)) |res| {
            switch (res) {
                .directory => |child_dir| {
                    if (path_iter.peek()) |_| {
                        dir = child_dir;
                        continue;
                    } else {
                        return null;
                    }
                },
                else => {
                    if (path_iter.peek()) |_| {
                        return null;
                    } else {
                        return res;
                    }
                },
            }
        } else {
            return null;
        }
    }
    unreachable;
}
