pub const ReadBuffer = @import("ReadBuffer.zig");
pub const template = @import("template.zig").template;
pub const timestamp_to_iso8601 = @cImport({
    @cInclude("time_fmt.h");
}).timestamp_to_iso8601;
