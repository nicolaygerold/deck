const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");
const LogBuffer = @import("buffer.zig").LogBuffer;

pub const ProcessStatus = enum {
    pending,
    running,
    exited,
    crashed,
};

pub const Process = struct {
    name: []const u8,
    command: []const u8,
    status: ProcessStatus = .pending,
    exit_code: ?u8 = null,
    child: ?std.process.Child = null,
    stdout: ?std.posix.fd_t = null,
    stderr: ?std.posix.fd_t = null,
    log: LogBuffer,
    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8, command: []const u8) Process {
        return .{
            .name = name,
            .command = command,
            .log = LogBuffer.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Process) void {
        self.kill();
        self.log.deinit();
    }

    pub fn spawn(self: *Process) !void {
        var child = std.process.Child.init(
            &[_][]const u8{ "/bin/sh", "-c", self.command },
            self.allocator,
        );
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        self.child = child;
        self.stdout = if (child.stdout) |f| f.handle else null;
        self.stderr = if (child.stderr) |f| f.handle else null;

        // Set non-blocking mode on stdout/stderr
        if (self.stdout) |fd| {
            _ = std.posix.fcntl(fd, std.posix.F.SETFL, @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }))) catch {};
        }
        if (self.stderr) |fd| {
            _ = std.posix.fcntl(fd, std.posix.F.SETFL, @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }))) catch {};
        }

        self.status = .running;
    }

    pub fn readOutput(self: *Process) !bool {
        if (self.child == null or self.stdout == null) return false;

        var buf: [4096]u8 = undefined;
        const fd = self.stdout.?;

        const n = std.posix.read(fd, &buf) catch |err| {
            if (err == error.WouldBlock) return false;
            self.status = .crashed;
            return false;
        };

        if (n == 0) {
            self.checkExit();
            return false;
        }

        try self.log.append(buf[0..n]);
        return true;
    }

    pub fn checkExit(self: *Process) void {
        if (self.child) |*child| {
            const result = child.wait() catch {
                self.status = .crashed;
                return;
            };
            switch (result) {
                .Exited => |code| {
                    self.exit_code = code;
                    self.status = if (code == 0) .exited else .crashed;
                },
                else => {
                    self.status = .crashed;
                },
            }
            self.child = null;
        }
    }

    pub fn kill(self: *Process) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
            self.status = .exited;
            self.child = null;
        }
    }

    pub fn restart(self: *Process) !void {
        self.kill();
        self.log.clear();
        self.status = .pending;
        self.exit_code = null;
        try self.spawn();
    }

    pub fn isAlive(self: *const Process) bool {
        return self.status == .running;
    }
};

pub const ProcessManager = struct {
    processes: []Process,
    allocator: Allocator,

    pub fn init(allocator: Allocator, commands: []const cli.Command) !ProcessManager {
        const processes = try allocator.alloc(Process, commands.len);
        for (commands, 0..) |cmd, i| {
            processes[i] = Process.init(allocator, cmd.name, cmd.cmd);
        }
        return .{
            .processes = processes,
            .allocator = allocator,
        };
    }

    pub fn spawnAll(self: *ProcessManager) !void {
        for (self.processes) |*p| {
            try p.spawn();
        }
    }

    pub fn killAll(self: *ProcessManager) void {
        for (self.processes) |*p| {
            p.kill();
        }
    }

    pub fn readAll(self: *ProcessManager) !bool {
        var any_read = false;
        for (self.processes) |*p| {
            if (try p.readOutput()) {
                any_read = true;
            }
        }
        return any_read;
    }

    pub fn anyAlive(self: *const ProcessManager) bool {
        for (self.processes) |p| {
            if (p.isAlive()) return true;
        }
        return false;
    }

    pub fn deinit(self: *ProcessManager) void {
        for (self.processes) |*p| {
            p.deinit();
        }
        self.allocator.free(self.processes);
    }
};
