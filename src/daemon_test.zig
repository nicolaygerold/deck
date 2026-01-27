const std = @import("std");
const daemon = @import("daemon.zig");
const cli = @import("cli.zig");

// ============================================================================
// LogLevel.fromString tests
// ============================================================================

test "LogLevel.fromString parses valid levels" {
    // Arrange & Act & Assert
    try std.testing.expectEqual(cli.LogLevel.debug, cli.LogLevel.fromString("debug").?);
    try std.testing.expectEqual(cli.LogLevel.info, cli.LogLevel.fromString("info").?);
    try std.testing.expectEqual(cli.LogLevel.warning, cli.LogLevel.fromString("warn").?);
    try std.testing.expectEqual(cli.LogLevel.warning, cli.LogLevel.fromString("warning").?);
    try std.testing.expectEqual(cli.LogLevel.@"error", cli.LogLevel.fromString("error").?);
    try std.testing.expectEqual(cli.LogLevel.@"error", cli.LogLevel.fromString("err").?);
}

test "LogLevel.fromString is case insensitive" {
    try std.testing.expectEqual(cli.LogLevel.@"error", cli.LogLevel.fromString("ERROR").?);
    try std.testing.expectEqual(cli.LogLevel.warning, cli.LogLevel.fromString("WARN").?);
    try std.testing.expectEqual(cli.LogLevel.info, cli.LogLevel.fromString("INFO").?);
    try std.testing.expectEqual(cli.LogLevel.debug, cli.LogLevel.fromString("DEBUG").?);
}

test "LogLevel.fromString returns null for invalid input" {
    try std.testing.expectEqual(@as(?cli.LogLevel, null), cli.LogLevel.fromString("invalid"));
    try std.testing.expectEqual(@as(?cli.LogLevel, null), cli.LogLevel.fromString(""));
    try std.testing.expectEqual(@as(?cli.LogLevel, null), cli.LogLevel.fromString("trace"));
}

test "LogLevel.order returns correct ordering" {
    try std.testing.expect(cli.LogLevel.debug.order() < cli.LogLevel.info.order());
    try std.testing.expect(cli.LogLevel.info.order() < cli.LogLevel.warning.order());
    try std.testing.expect(cli.LogLevel.warning.order() < cli.LogLevel.@"error".order());
}

// ============================================================================
// detectLevel tests
// ============================================================================

test "detectLevel detects error level" {
    try std.testing.expectEqual(cli.LogLevel.@"error", daemon.detectLevel("ERROR: something failed").?);
    try std.testing.expectEqual(cli.LogLevel.@"error", daemon.detectLevel("[ERR] connection refused").?);
    try std.testing.expectEqual(cli.LogLevel.@"error", daemon.detectLevel("2024-01-01 ERR database timeout").?);
    try std.testing.expectEqual(cli.LogLevel.@"error", daemon.detectLevel("error: file not found").?);
}

test "detectLevel detects warning level" {
    try std.testing.expectEqual(cli.LogLevel.warning, daemon.detectLevel("WARNING: deprecated API").?);
    try std.testing.expectEqual(cli.LogLevel.warning, daemon.detectLevel("[WRN] low memory").?);
    try std.testing.expectEqual(cli.LogLevel.warning, daemon.detectLevel("warn: rate limit approaching").?);
}

test "detectLevel detects info level" {
    try std.testing.expectEqual(cli.LogLevel.info, daemon.detectLevel("INFO: server started").?);
    try std.testing.expectEqual(cli.LogLevel.info, daemon.detectLevel("[INF] listening on :3000").?);
    try std.testing.expectEqual(cli.LogLevel.info, daemon.detectLevel("info: connected to database").?);
}

test "detectLevel detects debug level" {
    try std.testing.expectEqual(cli.LogLevel.debug, daemon.detectLevel("DEBUG: variable x = 42").?);
    try std.testing.expectEqual(cli.LogLevel.debug, daemon.detectLevel("[DBG] entering function").?);
    try std.testing.expectEqual(cli.LogLevel.debug, daemon.detectLevel("debug: request payload").?);
}

test "detectLevel defaults to info for unknown" {
    try std.testing.expectEqual(cli.LogLevel.info, daemon.detectLevel("just some random text").?);
    try std.testing.expectEqual(cli.LogLevel.info, daemon.detectLevel("Server listening on port 8080").?);
}

// ============================================================================
// containsIgnoreCase tests
// ============================================================================

test "containsIgnoreCase finds exact match" {
    try std.testing.expect(daemon.containsIgnoreCase("hello world", "hello"));
    try std.testing.expect(daemon.containsIgnoreCase("hello world", "world"));
    try std.testing.expect(daemon.containsIgnoreCase("hello world", "lo wo"));
}

test "containsIgnoreCase is case insensitive" {
    try std.testing.expect(daemon.containsIgnoreCase("Hello World", "hello"));
    try std.testing.expect(daemon.containsIgnoreCase("hello world", "WORLD"));
    try std.testing.expect(daemon.containsIgnoreCase("ERROR: failed", "error"));
}

test "containsIgnoreCase returns false when not found" {
    try std.testing.expect(!daemon.containsIgnoreCase("hello world", "foo"));
    try std.testing.expect(!daemon.containsIgnoreCase("abc", "abcd"));
}

test "containsIgnoreCase handles empty needle" {
    try std.testing.expect(daemon.containsIgnoreCase("hello", ""));
}

test "containsIgnoreCase handles needle longer than haystack" {
    try std.testing.expect(!daemon.containsIgnoreCase("hi", "hello"));
}

// ============================================================================
// matchesFilters tests
// ============================================================================

fn makeOpts(grep: ?[]const u8, level: ?cli.LogLevel) daemon.LogOptions {
    return .{
        .name = null,
        .head = null,
        .tail = null,
        .session = null,
        .grep = grep,
        .level = level,
        .follow = false,
        .all = false,
        .json = false,
    };
}

test "matchesFilters with no filters matches all" {
    const opts = makeOpts(null, null);
    try std.testing.expect(daemon.matchesFilters("any line", opts));
    try std.testing.expect(daemon.matchesFilters("", opts));
}

test "matchesFilters with grep filters correctly" {
    const opts = makeOpts("error", null);

    try std.testing.expect(daemon.matchesFilters("ERROR: something failed", opts));
    try std.testing.expect(daemon.matchesFilters("an error occurred", opts));
    try std.testing.expect(!daemon.matchesFilters("all good here", opts));
}

test "matchesFilters with level filters correctly" {
    const opts_error = makeOpts(null, .@"error");
    const opts_warn = makeOpts(null, .warning);
    const opts_info = makeOpts(null, .info);

    // Error level: only errors pass
    try std.testing.expect(daemon.matchesFilters("ERROR: failed", opts_error));
    try std.testing.expect(!daemon.matchesFilters("WARN: deprecated", opts_error));
    try std.testing.expect(!daemon.matchesFilters("INFO: started", opts_error));

    // Warning level: errors and warnings pass
    try std.testing.expect(daemon.matchesFilters("ERROR: failed", opts_warn));
    try std.testing.expect(daemon.matchesFilters("WARN: deprecated", opts_warn));
    try std.testing.expect(!daemon.matchesFilters("INFO: started", opts_warn));

    // Info level: errors, warnings, and info pass
    try std.testing.expect(daemon.matchesFilters("ERROR: failed", opts_info));
    try std.testing.expect(daemon.matchesFilters("WARN: deprecated", opts_info));
    try std.testing.expect(daemon.matchesFilters("INFO: started", opts_info));
}

test "matchesFilters with both grep and level" {
    const opts = makeOpts("database", .@"error");

    try std.testing.expect(daemon.matchesFilters("ERROR: database connection failed", opts));
    try std.testing.expect(!daemon.matchesFilters("ERROR: file not found", opts)); // no "database"
    try std.testing.expect(!daemon.matchesFilters("INFO: database connected", opts)); // wrong level
}

// ============================================================================
// CLI parsing tests for new options
// ============================================================================

test "parse logs with grep option" {
    const argv = [_][]const u8{ "deck", "logs", "web", "--grep=error" };
    var args = try cli.parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqual(cli.Mode.logs, args.mode);
    try std.testing.expectEqualStrings("error", args.grep.?);
}

test "parse logs with level option" {
    const argv = [_][]const u8{ "deck", "logs", "web", "--level=error" };
    var args = try cli.parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqual(cli.Mode.logs, args.mode);
    try std.testing.expectEqual(cli.LogLevel.@"error", args.level.?);
}

test "parse logs with follow flag" {
    const argv = [_][]const u8{ "deck", "logs", "web", "-f" };
    var args = try cli.parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expect(args.follow);
    try std.testing.expectEqual(@as(?usize, null), args.tail); // no default tail in follow mode
}

test "parse logs with all flag" {
    const argv = [_][]const u8{ "deck", "logs", "--all" };
    var args = try cli.parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expect(args.all);
    try std.testing.expectEqual(@as(?[]const u8, null), args.log_name);
}

test "parse logs with json flag" {
    const argv = [_][]const u8{ "deck", "logs", "web", "--json" };
    var args = try cli.parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expect(args.json);
}

test "parse logs with combined options" {
    const argv = [_][]const u8{ "deck", "logs", "api", "--grep=timeout", "--level=warn", "--tail=50", "--json" };
    var args = try cli.parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqualStrings("api", args.log_name.?);
    try std.testing.expectEqualStrings("timeout", args.grep.?);
    try std.testing.expectEqual(cli.LogLevel.warning, args.level.?);
    try std.testing.expectEqual(@as(?usize, 50), args.tail);
    try std.testing.expect(args.json);
}

test "parse clear mode" {
    const argv = [_][]const u8{ "deck", "clear", "web" };
    var args = try cli.parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqual(cli.Mode.clear, args.mode);
    try std.testing.expectEqualStrings("web", args.log_name.?);
}

test "parse clear mode without name clears all" {
    const argv = [_][]const u8{ "deck", "clear" };
    var args = try cli.parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqual(cli.Mode.clear, args.mode);
    try std.testing.expectEqual(@as(?[]const u8, null), args.log_name);
}

test "parse logs with invalid level returns error" {
    const argv = [_][]const u8{ "deck", "logs", "web", "--level=invalid" };
    const result = cli.parse(std.testing.allocator, &argv);
    try std.testing.expectError(cli.ParseError.InvalidLevelValue, result);
}
