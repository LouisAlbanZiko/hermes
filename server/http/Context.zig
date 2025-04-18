const std = @import("std");
const util = @import("util");
const Database = @import("../Database.zig");
const Request = @import("Request.zig");

arena_state: std.heap.ArenaAllocator,
db: *Database,
has_session: ?Database.SessionToken,
has_user: ?Database.UserID,
pub fn init(gpa: std.mem.Allocator, db: *Database, req: *const Request) @This() {
    var self: @This() = undefined;
    self.arena_state = std.heap.ArenaAllocator.init(gpa);
    self.db = db;
    self.has_session = null;
    if (req.cookies.get("SessionToken")) |session_token_hex| {
        if (Database.SessionToken.from_hex(session_token_hex)) |session_token| {
            if (db.check_session_id(session_token)) |check| {
                if (check == .Valid) {
                    self.has_session = session_token;
                }
            } else |_| {}
        } else |_| {}
    }
    self.has_user = null;
    if (self.has_session) |session_token| {
        if (db.get_session_user(session_token)) |has_user| {
            self.has_user = has_user;
        } else |_| {}
    }
    return self;
}
pub fn deinit(self: *@This()) void {
    self.arena_state.deinit();
}

pub fn arena(self: *@This()) std.mem.Allocator {
    return self.arena_state.allocator();
}
pub fn template(_: *@This(), writer: anytype, comptime content: []const u8, values: anytype) @TypeOf(writer).Error!void {
    try util.template(writer, content, values);
}
