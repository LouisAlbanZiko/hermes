const ServerResource = @This();
pub const Type = enum { directory, handler, template, file };

path: []const u8,
value: union(Type) {
    directory: []const ServerResource,
    handler: type,
    template: []const u8,
    file: []const u8,
},
