const std = @import("std");
const LogBuffer = @import("buffer.zig").LogBuffer;
const LogLine = @import("buffer.zig").LogLine;

test "log buffer single line" {
    var buf = LogBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.append("hello world\n");

    try std.testing.expectEqual(@as(usize, 1), buf.lineCount());
    const line = buf.getLine(0).?;
    try std.testing.expectEqualStrings("hello world", line.text);
}

test "log buffer multiple lines" {
    var buf = LogBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.append("line 1\nline 2\nline 3\n");

    try std.testing.expectEqual(@as(usize, 3), buf.lineCount());
    try std.testing.expectEqualStrings("line 1", buf.getLine(0).?.text);
    try std.testing.expectEqualStrings("line 2", buf.getLine(1).?.text);
    try std.testing.expectEqualStrings("line 3", buf.getLine(2).?.text);
}

test "log buffer partial lines" {
    var buf = LogBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.append("hel");
    try buf.append("lo ");
    try buf.append("world\n");

    try std.testing.expectEqual(@as(usize, 1), buf.lineCount());
    try std.testing.expectEqualStrings("hello world", buf.getLine(0).?.text);
}

test "log buffer iterator" {
    var buf = LogBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.append("a\nb\nc\n");

    var iter = buf.iterator();
    try std.testing.expectEqualStrings("a", iter.next().?.text);
    try std.testing.expectEqualStrings("b", iter.next().?.text);
    try std.testing.expectEqualStrings("c", iter.next().?.text);
    try std.testing.expectEqual(@as(?LogLine, null), iter.next());
}

test "log buffer clear" {
    var buf = LogBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.append("line 1\nline 2\n");
    try std.testing.expectEqual(@as(usize, 2), buf.lineCount());

    buf.clear();
    try std.testing.expectEqual(@as(usize, 0), buf.lineCount());
}

test "log buffer ring wraparound" {
    var buf = LogBuffer.init(std.testing.allocator);
    defer buf.deinit();

    for (0..1005) |i| {
        var line_buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "line {d}\n", .{i}) catch unreachable;
        try buf.append(line);
    }

    try std.testing.expectEqual(@as(usize, 1000), buf.lineCount());
    try std.testing.expectEqualStrings("line 5", buf.getLine(0).?.text);
    try std.testing.expectEqualStrings("line 1004", buf.getLine(999).?.text);
}

test "log buffer getLine out of bounds" {
    var buf = LogBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.append("only line\n");
    try std.testing.expectEqual(@as(?LogLine, null), buf.getLine(1));
    try std.testing.expectEqual(@as(?LogLine, null), buf.getLine(100));
}

test "log buffer iteratorFrom" {
    var buf = LogBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.append("a\nb\nc\nd\n");

    var iter = buf.iteratorFrom(2);
    try std.testing.expectEqualStrings("c", iter.next().?.text);
    try std.testing.expectEqualStrings("d", iter.next().?.text);
    try std.testing.expectEqual(@as(?LogLine, null), iter.next());
}
