const std = @import("std");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const Method = @import("protocol.zig").Method;
const ServerResource = @import("../ServerResource.zig");

root_dir: Directory,
pub fn init(comptime resources: []const ServerResource) @This() {
    return .{
        .root_dir = comptime Directory.init(resources),
    };
}

pub const Context = struct {
    arena: std.mem.Allocator,
    root_dir: Directory,
    current_dir: Directory,
};

pub const Callback = *const fn (ctx: Context, *const Request) std.mem.Allocator.Error!Response;
pub const ResourceType = ServerResource.Type;
pub const Resource = union(ResourceType) {
    directory: Directory,
    handler: [@typeInfo(Method).@"enum".fields.len]?Callback,
    file: [:0]const u8,
};
pub const Directory = struct {
    resources: std.StaticStringMap(Resource),
    pub fn init(comptime resources: []const ServerResource) @This() {
        var values: [resources.len]struct { []const u8, Resource } = undefined;

        inline for (resources, 0..) |resource, index| {
            switch (resource.value) {
                .directory => |d| {
                    values[index] = .{ resource.path, .{ .directory = @This().init(d) } };
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

        return Directory{
            .resources = std.StaticStringMap(Resource).initComptime(values),
        };
    }
    pub fn find_resource(dir: @This(), path: []const u8) ?struct { @This(), Resource } {
        var path_iter = std.mem.splitScalar(u8, path, '/');
        var current_path = path_iter.next() orelse return null;
        if (current_path.len == 0) {
            current_path = "index";
        }
        const resource = dir.resources.get(current_path) orelse return null;
        const next_path = path_iter.rest();
        if (next_path.len == 0) {
            switch (resource) {
                .directory => |child_dir| {
                    return find_resource(child_dir, "");
                },
                else => {
                    return .{ dir, resource };
                },
            }
        } else {
            switch (resource) {
                .directory => |child_dir| {
                    return find_resource(child_dir, next_path);
                },
                else => {
                    return null;
                },
            }
        }
    }
    pub fn find_directory(self: @This(), path: []const u8) ?Directory {
        switch (self.find_resource(path) orelse {
            return null;
        }) {
            .directory => |dir| {
                return dir;
            },
            else => {
                return null;
            },
        }
    }
};

//pub fn find_resource(self: *const @This(), path: []const u8) ?Resource {
//    var path_iter = std.mem.splitScalar(u8, path, '/');
//
//    var dir = self.root_dir;
//    var current_path: []const u8 = path_iter.next() orelse "index";
//    if (current_path.len == 0) {
//        current_path = "index";
//    }
//    while (true) {
//        if (dir.get(current_path)) |res| {
//            switch (res) {
//                .directory => |child_dir| {
//                    dir = child_dir;
//                    current_path = path_iter.next() orelse "index";
//                    if (current_path.len == 0) {
//                        current_path = "index";
//                    }
//                    continue;
//                },
//                else => {
//                    if (path_iter.peek()) |_| {
//                        return null;
//                    } else {
//                        return res;
//                    }
//                },
//            }
//        } else {
//            return null;
//        }
//    }
//    unreachable;
//}
