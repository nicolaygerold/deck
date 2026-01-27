const std = @import("std");
const daemon = @import("daemon.zig");
const cli = @import("cli.zig");

fn createTestSession(allocator: std.mem.Allocator) !struct { dir: std.fs.Dir, session: []const u8, path: []const u8 } {
    const timestamp = std.time.milliTimestamp();
    const random = std.crypto.random.int(u32);
    const session = try std.fmt.allocPrint(allocator, "test-{d}-{d}", .{ timestamp, random });

    const data_dir = try daemon.getDataDir(allocator, session);

    try std.fs.cwd().makePath(data_dir);
    const logs_path = try std.fmt.allocPrint(allocator, "{s}/logs", .{data_dir});
    defer allocator.free(logs_path);
    try std.fs.cwd().makePath(logs_path);

    const dir = try std.fs.cwd().openDir(logs_path, .{});

    return .{ .dir = dir, .session = session, .path = data_dir };
}

fn cleanupTestSession(allocator: std.mem.Allocator, session: []const u8, path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    allocator.free(session);
    allocator.free(path);
}

fn writeLogFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    var file = try dir.createFile(name, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn readLogFile(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ![]u8 {
    var file = dir.openFile(name, .{}) catch return error.FileNotFound;
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

fn captureLogsOutput(allocator: std.mem.Allocator, opts: daemon.LogOptions) ![]u8 {
    const stdout_pipe = try std.posix.pipe();
    const stderr_pipe = try std.posix.pipe();

    const saved_stdout = try std.posix.dup(std.posix.STDOUT_FILENO);
    defer std.posix.close(saved_stdout);
    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    try std.posix.dup2(stdout_pipe[1], std.posix.STDOUT_FILENO);
    std.posix.close(stdout_pipe[1]);
    try std.posix.dup2(stderr_pipe[1], std.posix.STDERR_FILENO);
    std.posix.close(stderr_pipe[1]);

    daemon.logs(allocator, opts) catch {};

    try std.posix.dup2(saved_stdout, std.posix.STDOUT_FILENO);
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);

    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    var buf: [4096]u8 = undefined;

    while (true) {
        const n = std.posix.read(stdout_pipe[0], &buf) catch break;
        if (n == 0) break;
        try output.appendSlice(allocator, buf[0..n]);
    }
    std.posix.close(stdout_pipe[0]);

    while (true) {
        const n = std.posix.read(stderr_pipe[0], &buf) catch break;
        if (n == 0) break;
        try output.appendSlice(allocator, buf[0..n]);
    }
    std.posix.close(stderr_pipe[0]);

    return output.toOwnedSlice(allocator);
}

test "basic log reading - tail" {
    const allocator = std.testing.allocator;
    var setup = try createTestSession(allocator);
    defer {
        setup.dir.close();
        cleanupTestSession(allocator, setup.session, setup.path);
    }

    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(allocator);
    for (1..11) |i| {
        try content.writer(allocator).print("line{d}\n", .{i});
    }
    try writeLogFile(setup.dir, "test.log", content.items);

    const output = try captureLogsOutput(allocator, .{
        .name = "test",
        .head = null,
        .tail = 5,
        .session = setup.session,
        .grep = null,
        .level = null,
        .follow = false,
        .all = false,
        .json = false,
    });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "line6") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line10") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line5\n") == null);
}

test "basic log reading - head" {
    const allocator = std.testing.allocator;
    var setup = try createTestSession(allocator);
    defer {
        setup.dir.close();
        cleanupTestSession(allocator, setup.session, setup.path);
    }

    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(allocator);
    for (1..11) |i| {
        try content.writer(allocator).print("line{d}\n", .{i});
    }
    try writeLogFile(setup.dir, "test.log", content.items);

    const output = try captureLogsOutput(allocator, .{
        .name = "test",
        .head = 3,
        .tail = null,
        .session = setup.session,
        .grep = null,
        .level = null,
        .follow = false,
        .all = false,
        .json = false,
    });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line4") == null);
}

test "grep filtering" {
    const allocator = std.testing.allocator;
    var setup = try createTestSession(allocator);
    defer {
        setup.dir.close();
        cleanupTestSession(allocator, setup.session, setup.path);
    }

    const content = "INFO: started\nERROR: failed\nINFO: running\n";
    try writeLogFile(setup.dir, "test.log", content);

    const output = try captureLogsOutput(allocator, .{
        .name = "test",
        .head = null,
        .tail = null,
        .session = setup.session,
        .grep = "ERROR",
        .level = null,
        .follow = false,
        .all = false,
        .json = false,
    });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "ERROR: failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "INFO: started") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "INFO: running") == null);
}

test "level filtering - error only" {
    const allocator = std.testing.allocator;
    var setup = try createTestSession(allocator);
    defer {
        setup.dir.close();
        cleanupTestSession(allocator, setup.session, setup.path);
    }

    const content = "DEBUG: x=1\nINFO: started\nWARN: slow\nERROR: crash\n";
    try writeLogFile(setup.dir, "test.log", content);

    const output = try captureLogsOutput(allocator, .{
        .name = "test",
        .head = null,
        .tail = null,
        .session = setup.session,
        .grep = null,
        .level = .@"error",
        .follow = false,
        .all = false,
        .json = false,
    });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "ERROR: crash") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "DEBUG:") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "INFO:") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "WARN:") == null);
}

test "level filtering - warn and above" {
    const allocator = std.testing.allocator;
    var setup = try createTestSession(allocator);
    defer {
        setup.dir.close();
        cleanupTestSession(allocator, setup.session, setup.path);
    }

    const content = "DEBUG: x=1\nINFO: started\nWARN: slow\nERROR: crash\n";
    try writeLogFile(setup.dir, "test.log", content);

    const output = try captureLogsOutput(allocator, .{
        .name = "test",
        .head = null,
        .tail = null,
        .session = setup.session,
        .grep = null,
        .level = .warning,
        .follow = false,
        .all = false,
        .json = false,
    });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "WARN: slow") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ERROR: crash") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "DEBUG:") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "INFO:") == null);
}

test "combined filters - grep and level" {
    const allocator = std.testing.allocator;
    var setup = try createTestSession(allocator);
    defer {
        setup.dir.close();
        cleanupTestSession(allocator, setup.session, setup.path);
    }

    const content =
        \\DEBUG: database connected
        \\INFO: database query executed
        \\WARN: database slow
        \\ERROR: database connection lost
        \\ERROR: network timeout
        \\INFO: other stuff
    ++ "\n";
    try writeLogFile(setup.dir, "test.log", content);

    const output = try captureLogsOutput(allocator, .{
        .name = "test",
        .head = null,
        .tail = null,
        .session = setup.session,
        .grep = "database",
        .level = .@"error",
        .follow = false,
        .all = false,
        .json = false,
    });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "ERROR: database connection lost") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ERROR: network timeout") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "WARN: database slow") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "INFO:") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "DEBUG:") == null);
}

test "clear logs - single process" {
    const allocator = std.testing.allocator;
    var setup = try createTestSession(allocator);
    defer {
        setup.dir.close();
        cleanupTestSession(allocator, setup.session, setup.path);
    }

    try writeLogFile(setup.dir, "web.log", "web log line 1\nweb log line 2\n");
    try writeLogFile(setup.dir, "api.log", "api log line 1\n");

    try daemon.clear(allocator, "web", setup.session);

    const web_content = try readLogFile(allocator, setup.dir, "web.log");
    defer allocator.free(web_content);
    try std.testing.expectEqual(@as(usize, 0), web_content.len);

    const api_content = try readLogFile(allocator, setup.dir, "api.log");
    defer allocator.free(api_content);
    try std.testing.expect(api_content.len > 0);
}

test "clear logs - all processes" {
    const allocator = std.testing.allocator;
    var setup = try createTestSession(allocator);
    defer {
        setup.dir.close();
        cleanupTestSession(allocator, setup.session, setup.path);
    }

    try writeLogFile(setup.dir, "web.log", "web log content\n");
    try writeLogFile(setup.dir, "api.log", "api log content\n");

    try daemon.clear(allocator, null, setup.session);

    const web_content = try readLogFile(allocator, setup.dir, "web.log");
    defer allocator.free(web_content);
    try std.testing.expectEqual(@as(usize, 0), web_content.len);

    const api_content = try readLogFile(allocator, setup.dir, "api.log");
    defer allocator.free(api_content);
    try std.testing.expectEqual(@as(usize, 0), api_content.len);
}

test "all logs - multiple files" {
    const allocator = std.testing.allocator;
    var setup = try createTestSession(allocator);
    defer {
        setup.dir.close();
        cleanupTestSession(allocator, setup.session, setup.path);
    }

    try writeLogFile(setup.dir, "web.log", "web line 1\nweb line 2\n");
    try writeLogFile(setup.dir, "api.log", "api line 1\napi line 2\n");

    const output = try captureLogsOutput(allocator, .{
        .name = null,
        .head = null,
        .tail = null,
        .session = setup.session,
        .grep = null,
        .level = null,
        .follow = false,
        .all = true,
        .json = false,
    });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "[web]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[api]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "web line") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "api line") != null);
}

test "case insensitive grep" {
    const allocator = std.testing.allocator;
    var setup = try createTestSession(allocator);
    defer {
        setup.dir.close();
        cleanupTestSession(allocator, setup.session, setup.path);
    }

    const content = "INFO: Started\nERROR: STARTED again\nDEBUG: not matching\n";
    try writeLogFile(setup.dir, "test.log", content);

    const output = try captureLogsOutput(allocator, .{
        .name = "test",
        .head = null,
        .tail = null,
        .session = setup.session,
        .grep = "started",
        .level = null,
        .follow = false,
        .all = false,
        .json = false,
    });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "INFO: Started") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ERROR: STARTED again") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "DEBUG: not matching") == null);
}

test "empty log file" {
    const allocator = std.testing.allocator;
    var setup = try createTestSession(allocator);
    defer {
        setup.dir.close();
        cleanupTestSession(allocator, setup.session, setup.path);
    }

    try writeLogFile(setup.dir, "empty.log", "");

    const output = try captureLogsOutput(allocator, .{
        .name = "empty",
        .head = null,
        .tail = 10,
        .session = setup.session,
        .grep = null,
        .level = null,
        .follow = false,
        .all = false,
        .json = false,
    });
    defer allocator.free(output);

    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "tail larger than file returns all lines" {
    const allocator = std.testing.allocator;
    var setup = try createTestSession(allocator);
    defer {
        setup.dir.close();
        cleanupTestSession(allocator, setup.session, setup.path);
    }

    const content = "line1\nline2\nline3\n";
    try writeLogFile(setup.dir, "test.log", content);

    const output = try captureLogsOutput(allocator, .{
        .name = "test",
        .head = null,
        .tail = 100,
        .session = setup.session,
        .grep = null,
        .level = null,
        .follow = false,
        .all = false,
        .json = false,
    });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line3") != null);
}
