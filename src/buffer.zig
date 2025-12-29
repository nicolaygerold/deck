const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LogLine = struct {
    text: []const u8,
    timestamp: i64,
};

pub const LogBuffer = struct {
    const MAX_LINES = 1000;

    lines: [MAX_LINES]LogLine = undefined,
    line_storage: [MAX_LINES][]u8 = undefined,
    head: usize = 0,
    len: usize = 0,
    allocator: Allocator,
    partial_line: std.ArrayListUnmanaged(u8) = .{},

    pub fn init(allocator: Allocator) LogBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LogBuffer) void {
        // Free all stored lines
        const end = @min(self.len, MAX_LINES);
        for (0..end) |i| {
            const idx = (self.head + i) % MAX_LINES;
            self.allocator.free(self.line_storage[idx]);
        }
        self.partial_line.deinit(self.allocator);
    }

    pub fn append(self: *LogBuffer, data: []const u8) !void {
        var start: usize = 0;
        for (data, 0..) |c, i| {
            if (c == '\n') {
                const line_part = data[start..i];
                try self.partial_line.appendSlice(self.allocator, line_part);
                try self.commitLine();
                start = i + 1;
            }
        }
        // Store remaining partial line
        if (start < data.len) {
            try self.partial_line.appendSlice(self.allocator, data[start..]);
        }
    }

    fn commitLine(self: *LogBuffer) !void {
        const text = try self.allocator.dupe(u8, self.partial_line.items);
        self.partial_line.clearRetainingCapacity();

        const idx = (self.head + self.len) % MAX_LINES;

        // Free old line if overwriting
        if (self.len == MAX_LINES) {
            self.allocator.free(self.line_storage[self.head]);
            self.head = (self.head + 1) % MAX_LINES;
        } else {
            self.len += 1;
        }

        self.line_storage[idx] = text;
        self.lines[idx] = .{
            .text = text,
            .timestamp = std.time.milliTimestamp(),
        };
    }

    pub fn getLine(self: *const LogBuffer, index: usize) ?LogLine {
        if (index >= self.len) return null;
        return self.lines[(self.head + index) % MAX_LINES];
    }

    pub fn lineCount(self: *const LogBuffer) usize {
        return self.len;
    }

    pub fn getAllText(self: *const LogBuffer, allocator: Allocator) ![]u8 {
        return self.getTextRange(allocator, 0, self.len);
    }

    pub fn getTextRange(self: *const LogBuffer, allocator: Allocator, start: usize, end: usize) ![]u8 {
        var list: std.ArrayListUnmanaged(u8) = .{};
        errdefer list.deinit(allocator);
        const actual_end = @min(end, self.len);
        for (start..actual_end) |i| {
            if (self.getLine(i)) |line| {
                try list.appendSlice(allocator, line.text);
                try list.append(allocator, '\n');
            }
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn clear(self: *LogBuffer) void {
        const end = @min(self.len, MAX_LINES);
        for (0..end) |i| {
            const idx = (self.head + i) % MAX_LINES;
            self.allocator.free(self.line_storage[idx]);
        }
        self.head = 0;
        self.len = 0;
        self.partial_line.clearRetainingCapacity();
    }

    pub fn iterator(self: *const LogBuffer) Iterator {
        return .{ .buffer = self, .index = 0 };
    }

    pub fn iteratorFrom(self: *const LogBuffer, start: usize) Iterator {
        return .{ .buffer = self, .index = start };
    }

    pub const Iterator = struct {
        buffer: *const LogBuffer,
        index: usize,

        pub fn next(self: *Iterator) ?LogLine {
            if (self.index >= self.buffer.len) return null;
            const line = self.buffer.getLine(self.index);
            self.index += 1;
            return line;
        }
    };
};
