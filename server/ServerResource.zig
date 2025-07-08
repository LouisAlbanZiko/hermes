const ServerResource = @This();
pub const Type = enum { directory, handler, file, priv };

path: [:0]const u8,
value: union(Type) {
    directory: []const ServerResource,
    handler: type,
    file: [:0]const u8,
    priv: [:0]const u8,
},
