const std = @import("std");
const sqlite = @import("sqlite");

conn: sqlite.Connection,

pub fn init(file_path: [:0]const u8) sqlite.Error!@This() {
    const conn = try sqlite.Connection.open(file_path);

    return .{ .conn = conn };
}

pub fn deinit(self: @This()) void {
    self.conn.close();
}
