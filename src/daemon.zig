const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");
const proc = @import("process.zig");

const DaemonError = error{
    AlreadyRunning,
    NotRunning,
    ForkFailed,
    InvalidPid,
    LogNotFound,
} || std.fs.File.OpenError || std.posix.OpenError || Allocator.Error || std.posix.ReadError;

var stop_requested: bool = false;

fn sigtermHandler(_: c_int) callconv(.c) void {
    stop_requested = true;
}

fn setsid() void {
    if (native_os == .linux) {
        _ = std.os.linux.syscall0(.setsid);
    } else if (native_os == .macos) {
        _ = std.c.setsid();
    }
}

pub fn getDataDir(allocator: Allocator, session: ?[]const u8) ![]u8 {
    const session_id = if (session) |s| blk: {
        break :blk s;
    } else blk: {
        const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch "/tmp";
        defer if (!std.mem.eql(u8, cwd, "/tmp")) allocator.free(cwd);

        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(cwd);
        const hash = hasher.final();

        break :blk std.fmt.allocPrint(allocator, "{x}", .{hash}) catch return error.OutOfMemory;
    };
    defer if (session == null) allocator.free(session_id);

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}/.local/share/deck/{s}", .{ home, session_id });
    } else |_| {
        return std.fmt.allocPrint(allocator, "/tmp/deck/{s}", .{session_id});
    }
}

pub fn start(allocator: Allocator, commands: []const cli.Command, session: ?[]const u8) !void {
    const data_dir = try getDataDir(allocator, session);
    defer allocator.free(data_dir);

    var data_dir_buf: [256]u8 = undefined;
    @memcpy(data_dir_buf[0..data_dir.len], data_dir);
    const data_dir_copy = data_dir_buf[0..data_dir.len];

    std.fs.cwd().makePath(data_dir) catch {};

    {
        var dir = try std.fs.cwd().openDir(data_dir, .{});
        defer dir.close();

        if (isDaemonRunning(dir)) {
            std.debug.print("deck daemon is already running\n", .{});
            return DaemonError.AlreadyRunning;
        }
    }

    const pid = std.posix.fork() catch return DaemonError.ForkFailed;

    if (pid != 0) {
        std.debug.print("deck daemon started (pid {d})\n", .{pid});
        return;
    }

    setsid();

    const child_allocator = std.heap.page_allocator;

    std.fs.cwd().makePath(data_dir_copy) catch {};
    var dir = std.fs.cwd().openDir(data_dir_copy, .{}) catch {
        std.process.exit(1);
    };

    runDaemon(child_allocator, dir, commands) catch {};

    dir.close();

    std.process.exit(0);
}

fn runDaemon(allocator: Allocator, dir: std.fs.Dir, commands: []const cli.Command) !void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = sigtermHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.INT, &action, null);

    const my_pid = std.posix.system.getpid();
    var pid_file = try dir.createFile("daemon.pid", .{});
    var buf: [32]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&buf, "{d}\n", .{my_pid}) catch unreachable;
    _ = try pid_file.writeAll(pid_str);
    pid_file.close();

    dir.makePath("logs") catch {};
    var logs_dir = try dir.openDir("logs", .{});
    defer logs_dir.close();

    var manager = try proc.ProcessManager.init(allocator, commands);
    defer manager.deinit();

    var log_files = try allocator.alloc(?std.fs.File, manager.processes.len);
    defer allocator.free(log_files);

    for (manager.processes, 0..) |p, i| {
        const sanitized = try cli.sanitizeName(allocator, p.name);
        defer allocator.free(sanitized);

        const filename = try std.fmt.allocPrint(allocator, "{s}.log", .{sanitized});
        defer allocator.free(filename);

        log_files[i] = logs_dir.createFile(filename, .{ .truncate = true }) catch null;
    }

    defer {
        for (log_files) |maybe_file| {
            if (maybe_file) |f| {
                var file = f;
                file.close();
            }
        }
    }

    try manager.spawnAll();

    while (!stop_requested and manager.anyAlive()) {
        var any_read = false;
        for (manager.processes, 0..) |*p, i| {
            if (readToFile(p, log_files[i]) catch false) {
                any_read = true;
            }
        }

        if (!any_read) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }

    manager.killAll();

    for (manager.processes) |p| {
        const sanitized = cli.sanitizeName(allocator, p.name) catch continue;
        defer allocator.free(sanitized);
        const filename = std.fmt.allocPrint(allocator, "{s}.log", .{sanitized}) catch continue;
        defer allocator.free(filename);
        logs_dir.deleteFile(filename) catch {};
    }

    dir.deleteFile("daemon.pid") catch {};
}

fn readToFile(process: *proc.Process, maybe_file: ?std.fs.File) !bool {
    if (process.child == null) return false;

    var any_read = false;
    var buf: [4096]u8 = undefined;

    if (process.stdout) |fd| {
        const n = std.posix.read(fd, &buf) catch |err| {
            if (err == error.WouldBlock) {
                return false;
            }
            process.status = .crashed;
            return false;
        };

        if (n == 0) {
            process.checkExit();
            return any_read;
        } else {
            if (maybe_file) |f| {
                _ = f.write(buf[0..n]) catch {};
            }
            any_read = true;
        }
    }

    if (process.stderr) |fd| {
        const n = std.posix.read(fd, &buf) catch |err| {
            if (err != error.WouldBlock) {
                return any_read;
            }
            return any_read;
        };

        if (n > 0) {
            if (maybe_file) |f| {
                _ = f.write(buf[0..n]) catch {};
            }
            any_read = true;
        }
    }

    return any_read;
}

fn isDaemonRunning(dir: std.fs.Dir) bool {
    var pid_file = dir.openFile("daemon.pid", .{}) catch return false;
    defer pid_file.close();

    var buf: [32]u8 = undefined;
    const n = pid_file.readAll(&buf) catch return false;
    const content = std.mem.trimRight(u8, buf[0..n], &[_]u8{ '\n', '\r', ' ' });
    const pid = std.fmt.parseInt(i32, content, 10) catch return false;

    std.posix.kill(pid, 0) catch |err| {
        if (err == error.ProcessNotFound) {
            dir.deleteFile("daemon.pid") catch {};
            return false;
        }
    };
    return true;
}

pub fn stop(allocator: Allocator, session: ?[]const u8) !void {
    const data_dir = try getDataDir(allocator, session);
    defer allocator.free(data_dir);

    var dir = std.fs.cwd().openDir(data_dir, .{}) catch {
        std.debug.print("No deck daemon running\n", .{});
        return;
    };
    defer dir.close();

    var pid_file = dir.openFile("daemon.pid", .{}) catch {
        std.debug.print("No deck daemon running\n", .{});
        return;
    };
    defer pid_file.close();

    var buf: [32]u8 = undefined;
    const n = try pid_file.readAll(&buf);
    const content = std.mem.trimRight(u8, buf[0..n], &[_]u8{ '\n', '\r', ' ' });
    const pid = std.fmt.parseInt(i32, content, 10) catch return DaemonError.InvalidPid;

    std.posix.kill(pid, std.posix.SIG.TERM) catch |err| {
        if (err == error.ProcessNotFound) {
            dir.deleteFile("daemon.pid") catch {};
            std.debug.print("Daemon was not running (cleaned up stale pidfile)\n", .{});
            return;
        }
        return err;
    };

    std.debug.print("Stopped deck daemon (pid {d})\n", .{pid});
}

pub fn logs(allocator: Allocator, name: []const u8, head: ?usize, tail: ?usize, session: ?[]const u8) !void {
    const data_dir = try getDataDir(allocator, session);
    defer allocator.free(data_dir);

    var dir = std.fs.cwd().openDir(data_dir, .{}) catch {
        std.debug.print("No deck logs found\n", .{});
        return DaemonError.LogNotFound;
    };
    defer dir.close();

    var logs_dir = dir.openDir("logs", .{}) catch {
        std.debug.print("No deck logs found\n", .{});
        return DaemonError.LogNotFound;
    };
    defer logs_dir.close();

    const sanitized = try cli.sanitizeName(allocator, name);
    defer allocator.free(sanitized);

    const filename = try std.fmt.allocPrint(allocator, "{s}.log", .{sanitized});
    defer allocator.free(filename);

    var file = logs_dir.openFile(filename, .{}) catch {
        std.debug.print("No logs found for process '{s}'\n", .{name});
        return DaemonError.LogNotFound;
    };
    defer file.close();

    if (head) |n| {
        try printHead(allocator, file, n);
    } else if (tail) |n| {
        try printTail(allocator, file, n);
    } else {
        try printAll(file);
    }
}

fn printHead(allocator: Allocator, file: std.fs.File, n: usize) !void {
    const stat = try file.stat();
    const size = stat.size;
    if (size == 0) return;

    const content = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(content);
    _ = try file.readAll(content);

    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line_count >= n) break;
        _ = std.posix.write(std.posix.STDOUT_FILENO, line) catch break;
        _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch break;
        line_count += 1;
    }
}

fn printTail(allocator: Allocator, file: std.fs.File, n: usize) !void {
    const stat = try file.stat();
    const size = stat.size;
    if (size == 0) return;

    const buf = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(buf);
    _ = try file.readAll(buf);

    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);

    var iter = std.mem.splitScalar(u8, buf, '\n');
    while (iter.next()) |line| {
        if (line.len > 0 or iter.peek() != null) {
            lines.append(allocator, line) catch {};
        }
    }

    const start_idx = if (lines.items.len > n) lines.items.len - n else 0;
    for (lines.items[start_idx..]) |line| {
        _ = std.posix.write(std.posix.STDOUT_FILENO, line) catch break;
        _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch break;
    }
}

fn printAll(file: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        _ = std.posix.write(std.posix.STDOUT_FILENO, buf[0..n]) catch break;
    }
}
