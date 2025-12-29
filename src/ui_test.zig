const std = @import("std");
const proc = @import("process.zig");
const cli = @import("cli.zig");
const LogBuffer = @import("buffer.zig").LogBuffer;

/// Mock window for testing UI rendering
const MockWindow = struct {
    cells: [][]Cell,
    width: u16,
    height: u16,
    allocator: std.mem.Allocator,

    const Cell = struct {
        char: u8 = ' ',
        style: Style = .{},
    };

    const Style = struct {
        bold: bool = false,
        fg_index: ?u8 = null,
        bg_index: ?u8 = null,
    };

    fn init(allocator: std.mem.Allocator, width: u16, height: u16) !MockWindow {
        const cells = try allocator.alloc([]Cell, height);
        for (cells) |*row| {
            row.* = try allocator.alloc(Cell, width);
            for (row.*) |*cell| {
                cell.* = .{};
            }
        }
        return .{
            .cells = cells,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    fn deinit(self: *MockWindow) void {
        for (self.cells) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.cells);
    }

    fn writeChar(self: *MockWindow, col: u16, row: u16, char: u8) void {
        if (row < self.height and col < self.width) {
            self.cells[row][col].char = char;
        }
    }

    fn writeString(self: *MockWindow, col: u16, row: u16, str: []const u8) void {
        for (str, 0..) |c, i| {
            self.writeChar(col + @as(u16, @intCast(i)), row, c);
        }
    }

    fn getRow(self: *MockWindow, row: u16) []const u8 {
        if (row >= self.height) return "";
        var result: [256]u8 = undefined;
        var len: usize = 0;
        for (self.cells[row]) |cell| {
            result[len] = cell.char;
            len += 1;
            if (len >= 256) break;
        }
        // Trim trailing spaces
        while (len > 0 and result[len - 1] == ' ') {
            len -= 1;
        }
        return result[0..len];
    }

    fn contains(self: *MockWindow, needle: []const u8) bool {
        for (0..self.height) |row| {
            const row_str = self.getRowAlloc(@intCast(row)) catch continue;
            defer self.allocator.free(row_str);
            if (std.mem.indexOf(u8, row_str, needle) != null) {
                return true;
            }
        }
        return false;
    }

    fn getRowAlloc(self: *MockWindow, row: u16) ![]u8 {
        if (row >= self.height) return error.OutOfBounds;
        const result = try self.allocator.alloc(u8, self.width);
        for (self.cells[row], 0..) |cell, i| {
            result[i] = cell.char;
        }
        return result;
    }
};

/// Simulates drawing the sidebar
fn drawSidebar(win: *MockWindow, processes: []const proc.Process, selected: usize) void {
    win.writeString(1, 0, "PROCESSES");

    for (processes, 0..) |p, idx| {
        const row: u16 = @intCast(idx + 2);
        if (row >= win.height - 1) break;

        // Selection indicator
        if (idx == selected) {
            win.writeChar(0, row, '>');
        }

        // Status indicator
        const status_char: u8 = switch (p.status) {
            .pending => '?',
            .running => '*',
            .exited => '-',
            .crashed => '!',
        };
        win.writeChar(2, row, status_char);

        // Process name
        for (p.name, 0..) |c, i| {
            if (4 + i >= win.width) break;
            win.writeChar(@intCast(4 + i), row, c);
        }
    }
}

/// Simulates drawing the log pane
fn drawLogPane(win: *MockWindow, log: *const LogBuffer, start_col: u16, width: u16, height: u16, scroll_offset: usize) void {
    const visible_lines = height -| 3;
    const total_lines = log.lineCount();

    var start_line: usize = scroll_offset;
    if (total_lines > visible_lines and start_line > total_lines - visible_lines) {
        start_line = total_lines - visible_lines;
    }

    var row: u16 = 2;
    var line_idx = start_line;
    while (line_idx < total_lines and row < height - 1) : (line_idx += 1) {
        if (log.getLine(line_idx)) |line| {
            const max_len = @min(line.text.len, width);
            for (line.text[0..max_len], 0..) |c, i| {
                win.writeChar(start_col + @as(u16, @intCast(i)), row, c);
            }
        }
        row += 1;
    }
}

test "sidebar shows process names" {
    var win = try MockWindow.init(std.testing.allocator, 20, 10);
    defer win.deinit();

    var p1 = proc.Process.init(std.testing.allocator, "web", "echo test");
    var p2 = proc.Process.init(std.testing.allocator, "api", "echo test");
    defer p1.deinit();
    defer p2.deinit();

    const processes = [_]proc.Process{ p1, p2 };
    drawSidebar(&win, &processes, 0);

    // Check header
    const row0 = try win.getRowAlloc(0);
    defer std.testing.allocator.free(row0);
    try std.testing.expect(std.mem.indexOf(u8, row0, "PROCESSES") != null);

    // Check process names appear
    const row2 = try win.getRowAlloc(2);
    defer std.testing.allocator.free(row2);
    try std.testing.expect(std.mem.indexOf(u8, row2, "web") != null);

    const row3 = try win.getRowAlloc(3);
    defer std.testing.allocator.free(row3);
    try std.testing.expect(std.mem.indexOf(u8, row3, "api") != null);
}

test "sidebar shows selection indicator" {
    var win = try MockWindow.init(std.testing.allocator, 20, 10);
    defer win.deinit();

    var p1 = proc.Process.init(std.testing.allocator, "web", "echo test");
    var p2 = proc.Process.init(std.testing.allocator, "api", "echo test");
    defer p1.deinit();
    defer p2.deinit();

    const processes = [_]proc.Process{ p1, p2 };

    // Test selection on first process
    drawSidebar(&win, &processes, 0);
    try std.testing.expectEqual(@as(u8, '>'), win.cells[2][0].char);
    try std.testing.expectEqual(@as(u8, ' '), win.cells[3][0].char);

    // Clear and test selection on second process
    for (win.cells) |row| {
        for (row) |*cell| {
            cell.* = .{};
        }
    }
    drawSidebar(&win, &processes, 1);
    try std.testing.expectEqual(@as(u8, ' '), win.cells[2][0].char);
    try std.testing.expectEqual(@as(u8, '>'), win.cells[3][0].char);
}

test "sidebar shows status indicators" {
    var win = try MockWindow.init(std.testing.allocator, 20, 10);
    defer win.deinit();

    var p1 = proc.Process.init(std.testing.allocator, "running", "echo test");
    var p2 = proc.Process.init(std.testing.allocator, "crashed", "echo test");
    var p3 = proc.Process.init(std.testing.allocator, "exited", "echo test");
    defer p1.deinit();
    defer p2.deinit();
    defer p3.deinit();

    p1.status = .running;
    p2.status = .crashed;
    p3.status = .exited;

    const processes = [_]proc.Process{ p1, p2, p3 };
    drawSidebar(&win, &processes, 0);

    // Check status indicators (col 2)
    try std.testing.expectEqual(@as(u8, '*'), win.cells[2][2].char); // running
    try std.testing.expectEqual(@as(u8, '!'), win.cells[3][2].char); // crashed
    try std.testing.expectEqual(@as(u8, '-'), win.cells[4][2].char); // exited
}

test "log pane shows log lines" {
    var win = try MockWindow.init(std.testing.allocator, 40, 10);
    defer win.deinit();

    var log = LogBuffer.init(std.testing.allocator);
    defer log.deinit();

    try log.append("first line\n");
    try log.append("second line\n");
    try log.append("third line\n");

    drawLogPane(&win, &log, 0, 40, 10, 0);

    const row2 = try win.getRowAlloc(2);
    defer std.testing.allocator.free(row2);
    try std.testing.expect(std.mem.indexOf(u8, row2, "first line") != null);

    const row3 = try win.getRowAlloc(3);
    defer std.testing.allocator.free(row3);
    try std.testing.expect(std.mem.indexOf(u8, row3, "second line") != null);

    const row4 = try win.getRowAlloc(4);
    defer std.testing.allocator.free(row4);
    try std.testing.expect(std.mem.indexOf(u8, row4, "third line") != null);
}

test "log pane respects scroll offset" {
    var win = try MockWindow.init(std.testing.allocator, 40, 6);
    defer win.deinit();

    var log = LogBuffer.init(std.testing.allocator);
    defer log.deinit();

    try log.append("line1\n");
    try log.append("line2\n");
    try log.append("line3\n");
    try log.append("line4\n");
    try log.append("line5\n");

    // Scroll offset 2, visible area is 3 lines (height 6 - 3)
    drawLogPane(&win, &log, 0, 40, 6, 2);

    // With scroll_offset=2, should show line3, line4, line5
    const row2 = try win.getRowAlloc(2);
    defer std.testing.allocator.free(row2);
    try std.testing.expect(std.mem.indexOf(u8, row2, "line3") != null);
}

test "log pane truncates long lines" {
    var win = try MockWindow.init(std.testing.allocator, 20, 10);
    defer win.deinit();

    var log = LogBuffer.init(std.testing.allocator);
    defer log.deinit();

    try log.append("this is a very long line that should be truncated\n");

    drawLogPane(&win, &log, 0, 20, 10, 0);

    // Line should be truncated to width
    const row2 = try win.getRowAlloc(2);
    defer std.testing.allocator.free(row2);
    try std.testing.expect(row2.len <= 20);
    try std.testing.expect(std.mem.indexOf(u8, row2, "this is a very long") != null);
}

test "log buffer handles rapid appends" {
    var log = LogBuffer.init(std.testing.allocator);
    defer log.deinit();

    // Simulate rapid process output
    for (0..100) |i| {
        var buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "line {d}\n", .{i}) catch continue;
        try log.append(line);
    }

    try std.testing.expectEqual(@as(usize, 100), log.lineCount());
}

test "log buffer ring behavior" {
    var log = LogBuffer.init(std.testing.allocator);
    defer log.deinit();

    // Fill past capacity (1000 lines)
    for (0..1050) |i| {
        var buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "line {d}\n", .{i}) catch continue;
        try log.append(line);
    }

    // Should have exactly 1000 lines (capacity)
    try std.testing.expectEqual(@as(usize, 1000), log.lineCount());

    // First line should be line 50 (0-49 were pushed out)
    const first = log.getLine(0).?;
    try std.testing.expectEqualStrings("line 50", first.text);

    // Last line should be line 1049
    const last = log.getLine(999).?;
    try std.testing.expectEqualStrings("line 1049", last.text);
}
