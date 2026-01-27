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
    NoLogsDirectory,
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

pub const LogOptions = struct {
    name: ?[]const u8,
    head: ?usize,
    tail: ?usize,
    session: ?[]const u8,
    grep: ?[]const u8,
    level: ?cli.LogLevel,
    follow: bool,
    all: bool,
    json: bool,
};

pub fn logs(allocator: Allocator, opts: LogOptions) !void {
    const data_dir = try getDataDir(allocator, opts.session);
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

    if (opts.all) {
        try logsAll(allocator, logs_dir, opts);
    } else if (opts.name) |name| {
        try logsSingle(allocator, logs_dir, name, opts);
    }
}

fn logsSingle(allocator: Allocator, logs_dir: std.fs.Dir, name: []const u8, opts: LogOptions) !void {
    const sanitized = try cli.sanitizeName(allocator, name);
    defer allocator.free(sanitized);

    const filename = try std.fmt.allocPrint(allocator, "{s}.log", .{sanitized});
    defer allocator.free(filename);

    var file = logs_dir.openFile(filename, .{}) catch {
        std.debug.print("No logs found for process '{s}'\n", .{name});
        return DaemonError.LogNotFound;
    };
    defer file.close();

    if (opts.follow) {
        try followLog(allocator, file, name, opts);
    } else if (opts.head) |n| {
        try printFiltered(allocator, file, name, n, true, opts);
    } else if (opts.tail) |n| {
        try printFiltered(allocator, file, name, n, false, opts);
    } else {
        try printFiltered(allocator, file, name, null, false, opts);
    }
}

fn logsAll(allocator: Allocator, logs_dir: std.fs.Dir, opts: LogOptions) !void {
    const limit = opts.tail orelse opts.head orelse 100;

    var ring = LogEntryRing.init(allocator);
    defer ring.deinit();

    var dir_iter = logs_dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log")) continue;

        const process_name = entry.name[0 .. entry.name.len - 4];
        var file = logs_dir.openFile(entry.name, .{}) catch continue;
        defer file.close();

        var read_buf: [8192]u8 = undefined;
        var reader = file.reader(&read_buf);
        var line_num: usize = 0;

        while (true) {
            const line = reader.interface.takeDelimiterExclusive('\n') catch |err| {
                if (err == error.StreamTooLong) {
                    _ = reader.interface.discardDelimiterExclusive('\n') catch break;
                    continue;
                }
                break;
            };

            if (line.len == 0) continue;
            if (!matchesFilters(line, opts)) continue;

            try ring.push(line, process_name, line_num);
            line_num += 1;
        }
    }

    var iter = ring.iterate(limit);
    while (iter.next()) |e| {
        if (opts.json) {
            printJsonLine(e.process, e.line);
        } else {
            std.debug.print("[{s}] {s}\n", .{ e.process, e.line });
        }
    }
}

const LogEntryRing = struct {
    const MAX_LINES = 1000;

    const Entry = struct {
        line: []u8,
        process: []u8,
        order: usize,
    };

    entries: [MAX_LINES]Entry = undefined,
    head: usize = 0,
    len: usize = 0,
    allocator: Allocator,

    fn init(alloc: Allocator) LogEntryRing {
        return .{ .allocator = alloc };
    }

    fn deinit(self: *LogEntryRing) void {
        const count = @min(self.len, MAX_LINES);
        for (0..count) |i| {
            const idx = (self.head + i) % MAX_LINES;
            self.allocator.free(self.entries[idx].line);
            self.allocator.free(self.entries[idx].process);
        }
    }

    fn push(self: *LogEntryRing, line: []const u8, process: []const u8, order: usize) !void {
        const idx = (self.head + self.len) % MAX_LINES;

        if (self.len == MAX_LINES) {
            self.allocator.free(self.entries[self.head].line);
            self.allocator.free(self.entries[self.head].process);
            self.head = (self.head + 1) % MAX_LINES;
        } else {
            self.len += 1;
        }

        self.entries[idx] = .{
            .line = try self.allocator.dupe(u8, line),
            .process = try self.allocator.dupe(u8, process),
            .order = order,
        };
    }

    fn iterate(self: *const LogEntryRing, n: usize) Iterator {
        const count = @min(n, self.len);
        const start_offset = self.len - count;
        return .{
            .ring = self,
            .remaining = count,
            .pos = (self.head + start_offset) % MAX_LINES,
        };
    }

    const Iterator = struct {
        ring: *const LogEntryRing,
        remaining: usize,
        pos: usize,

        fn next(self: *Iterator) ?Entry {
            if (self.remaining == 0) return null;
            const entry = self.ring.entries[self.pos];
            self.pos = (self.pos + 1) % MAX_LINES;
            self.remaining -= 1;
            return entry;
        }
    };
};

const LogEntry = struct {
    line: []const u8,
    process: []const u8,
    order: usize,
};

fn matchesFilters(line: []const u8, opts: LogOptions) bool {
    if (opts.level) |min_level| {
        const line_level = detectLevel(line) orelse return false;
        if (line_level.order() < min_level.order()) return false;
    }

    if (opts.grep) |pattern| {
        if (!containsIgnoreCase(line, pattern)) return false;
    }

    return true;
}

fn detectLevel(line: []const u8) ?cli.LogLevel {
    const check_len = @min(line.len, 100);

    if (containsIgnoreCaseInRange(line, 0, check_len, "error") or
        containsIgnoreCaseInRange(line, 0, check_len, "[err]") or
        containsIgnoreCaseInRange(line, 0, check_len, " err "))
    {
        return .@"error";
    }
    if (containsIgnoreCaseInRange(line, 0, check_len, "warn") or
        containsIgnoreCaseInRange(line, 0, check_len, "[wrn]"))
    {
        return .warning;
    }
    if (containsIgnoreCaseInRange(line, 0, check_len, "info") or
        containsIgnoreCaseInRange(line, 0, check_len, "[inf]"))
    {
        return .info;
    }
    if (containsIgnoreCaseInRange(line, 0, check_len, "debug") or
        containsIgnoreCaseInRange(line, 0, check_len, "[dbg]"))
    {
        return .debug;
    }

    return .info;
}

fn containsIgnoreCaseInRange(haystack: []const u8, range_start: usize, range_end: usize, needle: []const u8) bool {
    if (needle.len == 0) return true;
    const actual_end = @min(range_end, haystack.len);
    if (range_start >= actual_end or needle.len > actual_end - range_start) return false;

    var i: usize = range_start;
    while (i + needle.len <= actual_end) : (i += 1) {
        var matches = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matches = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn printFiltered(allocator: Allocator, file: std.fs.File, process: []const u8, limit: ?usize, from_head: bool, opts: LogOptions) !void {
    if (from_head) {
        try printHead(file, process, limit orelse std.math.maxInt(usize), opts);
    } else {
        try printTailFiltered(allocator, file, process, limit orelse 100, opts);
    }
}

fn printHead(file: std.fs.File, process: []const u8, limit: usize, opts: LogOptions) !void {
    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(&read_buf);
    var printed: usize = 0;

    while (printed < limit) {
        const line = reader.interface.takeDelimiterExclusive('\n') catch |err| {
            if (err == error.StreamTooLong) {
                _ = reader.interface.discardDelimiterExclusive('\n') catch break;
                continue;
            }
            break;
        };

        if (!matchesFilters(line, opts)) continue;

        if (opts.json) {
            printJsonLine(process, line);
        } else {
            _ = std.posix.write(std.posix.STDOUT_FILENO, line) catch break;
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch break;
        }
        printed += 1;
    }
}

const RingBuffer = struct {
    const MAX_LINES = 1000;

    lines: [MAX_LINES][]u8 = undefined,
    head: usize = 0,
    len: usize = 0,
    allocator: Allocator,

    fn init(alloc: Allocator) RingBuffer {
        return .{ .allocator = alloc };
    }

    fn deinit(self: *RingBuffer) void {
        const count = @min(self.len, MAX_LINES);
        for (0..count) |i| {
            const idx = (self.head + i) % MAX_LINES;
            self.allocator.free(self.lines[idx]);
        }
    }

    fn push(self: *RingBuffer, line: []const u8) !void {
        const idx = (self.head + self.len) % MAX_LINES;

        if (self.len == MAX_LINES) {
            self.allocator.free(self.lines[self.head]);
            self.head = (self.head + 1) % MAX_LINES;
        } else {
            self.len += 1;
        }

        self.lines[idx] = try self.allocator.dupe(u8, line);
    }

    fn getLastN(self: *const RingBuffer, n: usize) []const []u8 {
        const count = @min(n, self.len);
        const start_offset = self.len - count;
        return self.lines[(self.head + start_offset) % MAX_LINES ..][0..count];
    }

    fn iterate(self: *const RingBuffer, n: usize) Iterator {
        const count = @min(n, self.len);
        const start_offset = self.len - count;
        return .{
            .ring = self,
            .remaining = count,
            .pos = (self.head + start_offset) % MAX_LINES,
        };
    }

    const Iterator = struct {
        ring: *const RingBuffer,
        remaining: usize,
        pos: usize,

        fn next(self: *Iterator) ?[]const u8 {
            if (self.remaining == 0) return null;
            const line = self.ring.lines[self.pos];
            self.pos = (self.pos + 1) % MAX_LINES;
            self.remaining -= 1;
            return line;
        }
    };
};

fn printTailFiltered(allocator: Allocator, file: std.fs.File, process: []const u8, limit: usize, opts: LogOptions) !void {
    var ring = RingBuffer.init(allocator);
    defer ring.deinit();

    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(&read_buf);

    while (true) {
        const line = reader.interface.takeDelimiterExclusive('\n') catch |err| {
            if (err == error.StreamTooLong) {
                _ = reader.interface.discardDelimiterExclusive('\n') catch break;
                continue;
            }
            break;
        };

        if (!matchesFilters(line, opts)) continue;
        try ring.push(line);
    }

    var iter = ring.iterate(limit);
    while (iter.next()) |line| {
        if (opts.json) {
            printJsonLine(process, line);
        } else {
            _ = std.posix.write(std.posix.STDOUT_FILENO, line) catch break;
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch break;
        }
    }
}

fn printJsonLine(process: []const u8, line: []const u8) void {
    const level = detectLevel(line) orelse .info;
    const level_str = switch (level) {
        .debug => "debug",
        .info => "info",
        .warning => "warning",
        .@"error" => "error",
    };

    std.debug.print("{{\"process\":\"{s}\",\"level\":\"{s}\",\"message\":\"", .{ process, level_str });
    for (line) |c| {
        switch (c) {
            '"' => std.debug.print("\\\"", .{}),
            '\\' => std.debug.print("\\\\", .{}),
            '\n' => std.debug.print("\\n", .{}),
            '\r' => std.debug.print("\\r", .{}),
            '\t' => std.debug.print("\\t", .{}),
            else => std.debug.print("{c}", .{c}),
        }
    }
    std.debug.print("\"}}\n", .{});
}

fn followLog(allocator: Allocator, file: std.fs.File, process: []const u8, opts: LogOptions) !void {
    _ = allocator;

    var last_size: u64 = 0;
    const stat = try file.stat();
    last_size = stat.size;

    try file.seekTo(last_size);

    while (true) {
        std.Thread.sleep(100 * std.time.ns_per_ms);

        const new_stat = try file.stat();
        if (new_stat.size > last_size) {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = try file.read(&buf);
                if (n == 0) break;

                var line_start: usize = 0;
                for (buf[0..n], 0..) |c, i| {
                    if (c == '\n') {
                        const line = buf[line_start..i];
                        if (matchesFilters(line, opts)) {
                            if (opts.json) {
                                printJsonLine(process, line);
                            } else {
                                _ = std.posix.write(std.posix.STDOUT_FILENO, line) catch {};
                                _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
                            }
                        }
                        line_start = i + 1;
                    }
                }
            }
            last_size = new_stat.size;
        }
    }
}

pub fn clear(allocator: Allocator, name: ?[]const u8, session: ?[]const u8) !void {
    const data_dir = try getDataDir(allocator, session);
    defer allocator.free(data_dir);

    var dir = std.fs.cwd().openDir(data_dir, .{}) catch {
        std.debug.print("No deck session found\n", .{});
        return;
    };
    defer dir.close();

    var logs_dir = dir.openDir("logs", .{}) catch {
        std.debug.print("No deck logs found\n", .{});
        return;
    };
    defer logs_dir.close();

    if (name) |n| {
        const sanitized = try cli.sanitizeName(allocator, n);
        defer allocator.free(sanitized);

        const filename = try std.fmt.allocPrint(allocator, "{s}.log", .{sanitized});
        defer allocator.free(filename);

        var file = logs_dir.createFile(filename, .{ .truncate = true }) catch {
            std.debug.print("No logs found for process '{s}'\n", .{n});
            return;
        };
        file.close();
        std.debug.print("Cleared logs for '{s}'\n", .{n});
    } else {
        var dir_iter = logs_dir.iterate();
        var count: usize = 0;
        while (try dir_iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".log")) continue;

            var file = logs_dir.createFile(entry.name, .{ .truncate = true }) catch continue;
            file.close();
            count += 1;
        }
        std.debug.print("Cleared logs for {d} process(es)\n", .{count});
    }
}
