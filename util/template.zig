const std = @import("std");

pub fn template(writer: anytype, comptime content: []const u8, values: anytype) @TypeOf(writer).Error!void {
    const State = enum {
        STATIC,
        OPEN_VAR,
        CLOSE_VAR,
        VARIABLE,
    };
    comptime var index: usize = 0;
    comptime var part_start: usize = 0;
    comptime var state: State = .STATIC;

    @setEvalBranchQuota(2000000);
    inline while (index < content.len) {
        const c = content[index];
        switch (state) {
            .STATIC => {
                if (c == '{') {
                    state = .OPEN_VAR;
                }
            },
            .OPEN_VAR => {
                if (c == '{') {
                    const part = content[part_start .. index - 1];
                    try writer.writeAll(part);

                    state = .VARIABLE;
                    part_start = index + 1;
                } else {
                    state = .STATIC;
                }
            },
            .VARIABLE => {
                if (c == '}') {
                    state = .CLOSE_VAR;
                }
            },
            .CLOSE_VAR => {
                if (c == '}') {
                    const name = content[part_start .. index - 1];
                    const part = @field(values, name);

                    comptime var fmt: []const u8 = undefined;
                    switch (@typeInfo(@TypeOf(part))) {
                        .pointer, .array => {
                            fmt = "{s}";
                        },
                        .int, .float => {
                            fmt = "{d}";
                        },
                        else => {
                            fmt = "{}";
                        },
                    }
                    try std.fmt.format(writer, fmt, .{part});

                    state = .STATIC;
                    part_start = index + 1;
                } else {
                    state = .VARIABLE;
                }
            },
        }
        index += 1;
    }
    switch (state) {
        .STATIC => {
            const part = content[part_start..index];
            try writer.writeAll(part);
        },
        .VARIABLE => {
            @compileError(std.fmt.comptimePrint("Template has open ended brackets: '{s}'", .{content}));
        },
        .OPEN_VAR => {
            const part = content[part_start..index];
            try writer.writeAll(part);
        },
        .CLOSE_VAR => {
            @compileError(std.fmt.comptimePrint("Template has open ended brackets: '{s}'", .{content}));
        },
    }
}
