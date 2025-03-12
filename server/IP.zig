const std = @import("std");

v4: [4]u8,
pub fn format(
    self: @This(),
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try std.fmt.format(writer, "{d}.{d}.{d}.{d}", .{ self.v4[0], self.v4[1], self.v4[2], self.v4[3] });
}
