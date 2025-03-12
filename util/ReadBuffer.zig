const std = @import("std");

const ReadBuffer = @This();
read_index: usize,
data: []const u8,

// doesn't own the data
pub fn init(data: []const u8) ReadBuffer {
    return ReadBuffer{
        .read_index = 0,
        .data = data,
    };
}

pub fn peek(self: *ReadBuffer) u8 {
    return self.data[self.read_index];
}

pub const Error = error{OutOfBounds};
pub fn read(self: *ReadBuffer, T: type) Error!T {
    const bitsize = @typeInfo(T).int.bits;
    const bytesize = bitsize / 8;
    if (self.read_index + bytesize >= self.data.len) {
        //std.debug.print("read_index:{d},bytesize:{d},self.data.len:{d}\n", .{ self.read_index, bytesize, self.data.len });
        return Error.OutOfBounds;
    }
    var value: T = 0;
    inline for (0..bytesize) |index| {
        value = value | (@as(T, self.data[self.read_index + index]) << (bitsize - 8 * (index + 1)));
    }
    self.read_index += bytesize;
    return @bitCast(value);
}

pub fn read_bytes(self: *ReadBuffer, len: usize) Error![]const u8 {
    if (self.read_index + len > self.data.len) {
        //std.debug.print("read_index:{d} len:{d}\n", .{ self.read_index, len });
        return Error.OutOfBounds;
    }
    const value = self.data[self.read_index .. self.read_index + len];
    self.read_index += len;
    return value;
}

pub fn read_bytes_until(self: *ReadBuffer, end: u8) Error![]const u8 {
    var end_index = self.read_index;
    while (end_index < self.data.len and self.data[end_index] != end) {
        end_index += 1;
    }
    if (end_index == self.data.len) {
        //std.debug.print("read_index:{d}\n", .{self.read_index});
        return Error.OutOfBounds;
    }
    const value = self.data[self.read_index..end_index];
    self.read_index = end_index;
    //std.debug.print("{s}\n", .{value});
    return value;
}

pub fn read_bytes_until_either(self: *ReadBuffer, comptime end: []const u8) Error![]const u8 {
    var end_index = self.read_index;
    loop: while (end_index < self.data.len) {
        inline for (end) |e| {
            if (self.data[end_index] == e) {
                break :loop;
            }
        }
        end_index += 1;
    }
    if (end_index == self.data.len) {
        //std.debug.print("read_index:{d},end_index:{d}\n", .{ self.read_index, end_index });
        return Error.OutOfBounds;
    }
    const value = self.data[self.read_index..end_index];
    self.read_index = end_index;
    //std.debug.print("{s}\n", .{value});
    return value;
}
