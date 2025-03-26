const ServerResource = @This();
pub const Type = enum { directory, handler, file };

path: []const u8,
value: union(Type) {
    directory: []const ServerResource,
    handler: type,
    file: []const u8,
},
