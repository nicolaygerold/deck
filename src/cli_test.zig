const std = @import("std");
const cli = @import("cli.zig");
const parse = cli.parse;
const ParseError = cli.ParseError;

test "parse single command (tui mode)" {
    const argv = [_][]const u8{ "deck", "echo hello" };
    var args = try parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqual(cli.Mode.tui, args.mode);
    try std.testing.expectEqual(@as(usize, 1), args.commands.len);
    try std.testing.expectEqualStrings("echo", args.commands[0].name);
    try std.testing.expectEqualStrings("echo hello", args.commands[0].cmd);
}

test "parse multiple commands" {
    const argv = [_][]const u8{ "deck", "bun dev", "cargo watch" };
    var args = try parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqual(@as(usize, 2), args.commands.len);
    try std.testing.expectEqualStrings("bun", args.commands[0].name);
    try std.testing.expectEqualStrings("cargo", args.commands[1].name);
}

test "parse with custom names" {
    const argv = [_][]const u8{ "deck", "-n", "web,api", "bun dev", "cargo run" };
    var args = try parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqual(@as(usize, 2), args.commands.len);
    try std.testing.expectEqualStrings("web", args.commands[0].name);
    try std.testing.expectEqualStrings("api", args.commands[1].name);
}

test "parse with --names long form" {
    const argv = [_][]const u8{ "deck", "--names", "frontend,backend", "npm start", "python app.py" };
    var args = try parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqualStrings("frontend", args.commands[0].name);
    try std.testing.expectEqualStrings("backend", args.commands[1].name);
}

test "error on missing commands" {
    const argv = [_][]const u8{"deck"};
    const result = parse(std.testing.allocator, &argv);
    try std.testing.expectError(ParseError.MissingCommands, result);
}

test "error on name count mismatch" {
    const argv = [_][]const u8{ "deck", "-n", "one,two,three", "cmd1", "cmd2" };
    const result = parse(std.testing.allocator, &argv);
    try std.testing.expectError(ParseError.NameCountMismatch, result);
}

test "autoName extracts basename" {
    const autoName = @import("cli.zig").autoName;
    try std.testing.expectEqualStrings("node", autoName("/usr/bin/node server.js"));
    try std.testing.expectEqualStrings("bun", autoName("bun dev"));
    try std.testing.expectEqualStrings("make", autoName("make watch"));
}

test "error on -n without value" {
    const argv = [_][]const u8{ "deck", "cmd1", "-n" };
    const result = parse(std.testing.allocator, &argv);
    try std.testing.expectError(ParseError.MissingNamesValue, result);
}

test "parse ignores unknown flags" {
    const argv = [_][]const u8{ "deck", "--unknown", "echo hello" };
    var args = try parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqual(@as(usize, 1), args.commands.len);
    try std.testing.expectEqualStrings("echo hello", args.commands[0].cmd);
}

test "parse start mode" {
    const argv = [_][]const u8{ "deck", "start", "-n", "web,api", "bun dev", "cargo run" };
    var args = try parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqual(cli.Mode.start, args.mode);
    try std.testing.expectEqual(@as(usize, 2), args.commands.len);
    try std.testing.expectEqualStrings("web", args.commands[0].name);
}

test "parse stop mode" {
    const argv = [_][]const u8{ "deck", "stop" };
    var args = try parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqual(cli.Mode.stop, args.mode);
}

test "parse logs mode" {
    const argv = [_][]const u8{ "deck", "logs", "web" };
    var args = try parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqual(cli.Mode.logs, args.mode);
    try std.testing.expectEqualStrings("web", args.log_name.?);
    try std.testing.expectEqual(@as(?usize, 100), args.tail);
}

test "parse logs with tail" {
    const argv = [_][]const u8{ "deck", "logs", "api", "--tail=50" };
    var args = try parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqual(cli.Mode.logs, args.mode);
    try std.testing.expectEqualStrings("api", args.log_name.?);
    try std.testing.expectEqual(@as(?usize, 50), args.tail);
}

test "parse logs with head" {
    const argv = [_][]const u8{ "deck", "logs", "db", "--head=20" };
    var args = try parse(std.testing.allocator, &argv);
    defer args.deinit();

    try std.testing.expectEqual(cli.Mode.logs, args.mode);
    try std.testing.expectEqualStrings("db", args.log_name.?);
    try std.testing.expectEqual(@as(?usize, 20), args.head);
    try std.testing.expectEqual(@as(?usize, null), args.tail);
}

test "logs error on missing name" {
    const argv = [_][]const u8{ "deck", "logs" };
    const result = parse(std.testing.allocator, &argv);
    try std.testing.expectError(ParseError.MissingLogName, result);
}

test "sanitizeName replaces special chars" {
    const sanitized = try cli.sanitizeName(std.testing.allocator, "my/process name");
    defer std.testing.allocator.free(sanitized);
    try std.testing.expectEqualStrings("my_process_name", sanitized);
}
