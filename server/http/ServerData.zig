const std = @import("std");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const Method = @import("protocol.zig").Method;
const ServerResource = @import("../ServerResource.zig");
const Context = @import("Context.zig");

root_dir: Directory,
pub fn init(comptime resources: []const ServerResource) @This() {
    return .{
        .root_dir = comptime gen_resources(resources),
    };
}

pub const Callback = *const fn (*Context, *const Request) std.mem.Allocator.Error!Response;
pub const ResourceType = ServerResource.Type;
pub const Directory = std.StaticStringMap(Resource);
pub const Resource = union(ResourceType) {
    directory: Directory,
    handler: [@typeInfo(Method).@"enum".fields.len]?Callback,
    file: []const u8,
};

pub fn gen_resources(comptime resources: []const ServerResource) Directory {
    var values: [resources.len]struct { []const u8, Resource } = undefined;

    inline for (resources, 0..) |resource, index| {
        switch (resource.value) {
            .directory => |d| {
                values[index] = .{ resource.path, .{ .directory = gen_resources(d) } };
            },
            .handler => |t| {
                var callbacks: [@typeInfo(Method).@"enum".fields.len]?Callback = undefined;
                inline for (@typeInfo(Method).@"enum".fields) |field| {
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
        }
    }

    return Directory.initComptime(values);
}

pub fn find_resource(self: *@This(), path: []const u8) ?Resource {
    var path_iter = std.mem.splitScalar(u8, path, '/');

    var dir = self.root_dir;
    var current_path: []const u8 = path_iter.next() orelse "index";
    if (current_path.len == 0) {
        current_path = "index";
    }
    while (true) {
        if (dir.get(current_path)) |res| {
            switch (res) {
                .directory => |child_dir| {
                    dir = child_dir;
                    current_path = path_iter.next() orelse "index";
                    if (current_path.len == 0) {
                        current_path = "index";
                    }
                    continue;
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
