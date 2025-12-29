const std = @import("std");
const proc = @import("process.zig");
const cli = @import("cli.zig");
const Process = proc.Process;
const ProcessStatus = proc.ProcessStatus;
const ProcessManager = proc.ProcessManager;

test "Process init has correct initial state" {
    var p = Process.init(std.testing.allocator, "test", "echo hello");
    defer p.deinit();

    try std.testing.expectEqualStrings("test", p.name);
    try std.testing.expectEqualStrings("echo hello", p.command);
    try std.testing.expectEqual(ProcessStatus.pending, p.status);
    try std.testing.expectEqual(@as(?u8, null), p.exit_code);
    try std.testing.expectEqual(@as(?std.process.Child, null), p.child);
    try std.testing.expect(!p.isAlive());
}

test "ProcessManager init creates processes" {
    const commands = [_]cli.Command{
        .{ .name = "web", .cmd = "bun dev" },
        .{ .name = "api", .cmd = "cargo run" },
    };

    var manager = try ProcessManager.init(std.testing.allocator, &commands);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 2), manager.processes.len);
    try std.testing.expectEqualStrings("web", manager.processes[0].name);
    try std.testing.expectEqualStrings("bun dev", manager.processes[0].command);
    try std.testing.expectEqualStrings("api", manager.processes[1].name);
    try std.testing.expectEqualStrings("cargo run", manager.processes[1].command);
}

test "ProcessManager anyAlive returns false when no processes running" {
    const commands = [_]cli.Command{
        .{ .name = "test", .cmd = "echo hi" },
    };

    var manager = try ProcessManager.init(std.testing.allocator, &commands);
    defer manager.deinit();

    try std.testing.expect(!manager.anyAlive());
}

test "Process isAlive reflects status" {
    var p = Process.init(std.testing.allocator, "test", "echo hello");
    defer p.deinit();

    try std.testing.expect(!p.isAlive());

    p.status = .running;
    try std.testing.expect(p.isAlive());

    p.status = .exited;
    try std.testing.expect(!p.isAlive());

    p.status = .crashed;
    try std.testing.expect(!p.isAlive());
}

fn waitForOutput(process: *proc.Process, timeout_ms: u64) !bool {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        if (try process.readOutput()) {
            return true;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return false;
}

fn waitForLines(process: *proc.Process, expected_lines: usize, timeout_ms: u64) !bool {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        _ = try process.readOutput();
        if (process.log.lineCount() >= expected_lines) {
            return true;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return false;
}

fn waitForStatus(process: *proc.Process, expected_status: proc.ProcessStatus, timeout_ms: u64) !bool {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        _ = try process.readOutput();
        if (process.status == expected_status) {
            return true;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return false;
}

test "process captures single line output" {
    var process = proc.Process.init(std.testing.allocator, "test", "echo 'hello world'");
    defer process.deinit();

    try process.spawn();
    try std.testing.expect(process.status == .running);

    const got_output = try waitForLines(&process, 1, 2000);
    try std.testing.expect(got_output);

    try std.testing.expectEqual(@as(usize, 1), process.log.lineCount());
    const line = process.log.getLine(0).?;
    try std.testing.expectEqualStrings("hello world", line.text);
}

test "process captures multiple lines" {
    var process = proc.Process.init(std.testing.allocator, "test", "echo 'line1'; echo 'line2'; echo 'line3'");
    defer process.deinit();

    try process.spawn();

    const got_output = try waitForLines(&process, 3, 2000);
    try std.testing.expect(got_output);

    try std.testing.expectEqual(@as(usize, 3), process.log.lineCount());
    try std.testing.expectEqualStrings("line1", process.log.getLine(0).?.text);
    try std.testing.expectEqualStrings("line2", process.log.getLine(1).?.text);
    try std.testing.expectEqualStrings("line3", process.log.getLine(2).?.text);
}

test "process captures output over time" {
    var process = proc.Process.init(
        std.testing.allocator,
        "delayed",
        "echo 'first'; sleep 0.1; echo 'second'; sleep 0.1; echo 'third'",
    );
    defer process.deinit();

    try process.spawn();

    const got_output = try waitForLines(&process, 3, 3000);
    try std.testing.expect(got_output);

    try std.testing.expectEqual(@as(usize, 3), process.log.lineCount());
    try std.testing.expectEqualStrings("first", process.log.getLine(0).?.text);
    try std.testing.expectEqualStrings("second", process.log.getLine(1).?.text);
    try std.testing.expectEqualStrings("third", process.log.getLine(2).?.text);
}

test "process status transitions to exited on success" {
    var process = proc.Process.init(std.testing.allocator, "test", "echo 'done'");
    defer process.deinit();

    try process.spawn();
    try std.testing.expect(process.status == .running);

    const exited = try waitForStatus(&process, .exited, 2000);
    try std.testing.expect(exited);
    try std.testing.expectEqual(@as(?u8, 0), process.exit_code);
}

test "process status transitions to crashed on failure" {
    var process = proc.Process.init(std.testing.allocator, "test", "exit 1");
    defer process.deinit();

    try process.spawn();

    const crashed = try waitForStatus(&process, .crashed, 2000);
    try std.testing.expect(crashed);
    try std.testing.expectEqual(@as(?u8, 1), process.exit_code);
}

test "process can be killed" {
    var process = proc.Process.init(std.testing.allocator, "test", "sleep 10");
    defer process.deinit();

    try process.spawn();
    try std.testing.expect(process.status == .running);

    process.kill();
    try std.testing.expect(process.status == .exited);
}

test "process can be restarted" {
    var process = proc.Process.init(std.testing.allocator, "test", "echo 'output'");
    defer process.deinit();

    try process.spawn();
    _ = try waitForLines(&process, 1, 2000);
    try std.testing.expectEqual(@as(usize, 1), process.log.lineCount());

    try process.restart();
    _ = try waitForLines(&process, 1, 2000);

    // After restart, log should be cleared and have new output
    try std.testing.expectEqual(@as(usize, 1), process.log.lineCount());
    try std.testing.expectEqualStrings("output", process.log.getLine(0).?.text);
}

test "process manager spawns all processes" {
    const commands = [_]cli.Command{
        .{ .name = "p1", .cmd = "echo 'from p1'" },
        .{ .name = "p2", .cmd = "echo 'from p2'" },
    };

    var manager = try proc.ProcessManager.init(std.testing.allocator, &commands);
    defer manager.deinit();

    try manager.spawnAll();

    // Wait for both to produce output
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < 2000) {
        _ = try manager.readAll();
        if (manager.processes[0].log.lineCount() >= 1 and
            manager.processes[1].log.lineCount() >= 1)
        {
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expectEqual(@as(usize, 2), manager.processes.len);
    try std.testing.expect(manager.processes[0].log.lineCount() >= 1);
    try std.testing.expect(manager.processes[1].log.lineCount() >= 1);
    try std.testing.expectEqualStrings("from p1", manager.processes[0].log.getLine(0).?.text);
    try std.testing.expectEqualStrings("from p2", manager.processes[1].log.getLine(0).?.text);
}

test "process manager kills all processes" {
    const commands = [_]cli.Command{
        .{ .name = "p1", .cmd = "sleep 10" },
        .{ .name = "p2", .cmd = "sleep 10" },
    };

    var manager = try proc.ProcessManager.init(std.testing.allocator, &commands);
    defer manager.deinit();

    try manager.spawnAll();
    try std.testing.expect(manager.anyAlive());

    manager.killAll();
    try std.testing.expect(!manager.anyAlive());
}

test "process captures long output without truncation" {
    var process = proc.Process.init(std.testing.allocator, "test", "seq 1 100");
    defer process.deinit();

    try process.spawn();

    const got_output = try waitForLines(&process, 100, 3000);
    try std.testing.expect(got_output);

    try std.testing.expectEqual(@as(usize, 100), process.log.lineCount());
    try std.testing.expectEqualStrings("1", process.log.getLine(0).?.text);
    try std.testing.expectEqualStrings("50", process.log.getLine(49).?.text);
    try std.testing.expectEqualStrings("100", process.log.getLine(99).?.text);
}

test "process handles partial line buffering" {
    // printf without newline followed by printf with newline
    var process = proc.Process.init(
        std.testing.allocator,
        "test",
        "printf 'hel'; printf 'lo\\n'",
    );
    defer process.deinit();

    try process.spawn();

    const got_output = try waitForLines(&process, 1, 2000);
    try std.testing.expect(got_output);

    try std.testing.expectEqual(@as(usize, 1), process.log.lineCount());
    try std.testing.expectEqualStrings("hello", process.log.getLine(0).?.text);
}
