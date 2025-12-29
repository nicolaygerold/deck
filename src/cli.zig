const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Command = struct {
    name: []const u8,
    cmd: []const u8,
};

pub const Mode = enum {
    tui,
    start,
    stop,
    logs,
};

pub const ParseError = error{
    MissingCommands,
    MissingNamesValue,
    MissingLogName,
    MissingSessionValue,
    NameCountMismatch,
    OutOfMemory,
    InvalidHeadValue,
    InvalidTailValue,
};

pub const Args = struct {
    mode: Mode,
    commands: []Command,
    log_name: ?[]const u8,
    head: ?usize,
    tail: ?usize,
    session: ?[]const u8,
    allocator: Allocator,

    pub fn deinit(self: *Args) void {
        self.allocator.free(self.commands);
    }
};

pub fn parse(allocator: Allocator, argv: []const []const u8) ParseError!Args {
    if (argv.len < 2) {
        return ParseError.MissingCommands;
    }

    const first_arg = argv[1];

    if (std.mem.eql(u8, first_arg, "start")) {
        return parseStart(allocator, argv[2..]);
    } else if (std.mem.eql(u8, first_arg, "stop")) {
        return parseStop(allocator, argv[2..]);
    } else if (std.mem.eql(u8, first_arg, "logs")) {
        return parseLogs(allocator, argv[2..]);
    } else {
        return parseTui(allocator, argv);
    }
}

fn parseStart(allocator: Allocator, argv: []const []const u8) ParseError!Args {
    var names: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var commands = std.ArrayListUnmanaged([]const u8){};
    defer commands.deinit(allocator);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--names")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingNamesValue;
            names = argv[i];
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingSessionValue;
            session = argv[i];
        } else if (arg.len > 0 and arg[0] == '-') {
            // unknown flag, skip
        } else {
            commands.append(allocator, arg) catch return ParseError.OutOfMemory;
        }
    }

    if (commands.items.len == 0) {
        return ParseError.MissingCommands;
    }

    const result = try buildCommands(allocator, commands.items, names);

    return .{
        .mode = .start,
        .commands = result,
        .log_name = null,
        .head = null,
        .tail = null,
        .session = session,
        .allocator = allocator,
    };
}

fn parseStop(allocator: Allocator, argv: []const []const u8) ParseError!Args {
    var session: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingSessionValue;
            session = argv[i];
        }
    }

    return .{
        .mode = .stop,
        .commands = &[_]Command{},
        .log_name = null,
        .head = null,
        .tail = null,
        .session = session,
        .allocator = allocator,
    };
}

fn parseLogs(allocator: Allocator, argv: []const []const u8) ParseError!Args {
    if (argv.len == 0) {
        return ParseError.MissingLogName;
    }

    var log_name: ?[]const u8 = null;
    var head: ?usize = null;
    var tail: ?usize = null;
    var session: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.startsWith(u8, arg, "--head=")) {
            const val = arg["--head=".len..];
            head = std.fmt.parseInt(usize, val, 10) catch return ParseError.InvalidHeadValue;
        } else if (std.mem.startsWith(u8, arg, "--tail=")) {
            const val = arg["--tail=".len..];
            tail = std.fmt.parseInt(usize, val, 10) catch return ParseError.InvalidTailValue;
        } else if (std.mem.eql(u8, arg, "--head")) {
            i += 1;
            if (i >= argv.len) return ParseError.InvalidHeadValue;
            head = std.fmt.parseInt(usize, argv[i], 10) catch return ParseError.InvalidHeadValue;
        } else if (std.mem.eql(u8, arg, "--tail")) {
            i += 1;
            if (i >= argv.len) return ParseError.InvalidTailValue;
            tail = std.fmt.parseInt(usize, argv[i], 10) catch return ParseError.InvalidTailValue;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingSessionValue;
            session = argv[i];
        } else if (arg.len > 0 and arg[0] != '-') {
            log_name = arg;
        }
    }

    if (log_name == null) {
        return ParseError.MissingLogName;
    }

    return .{
        .mode = .logs,
        .commands = &[_]Command{},
        .log_name = log_name,
        .head = head,
        .tail = if (head == null and tail == null) 100 else tail,
        .session = session,
        .allocator = allocator,
    };
}

fn parseTui(allocator: Allocator, argv: []const []const u8) ParseError!Args {
    var names: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var commands = std.ArrayListUnmanaged([]const u8){};
    defer commands.deinit(allocator);

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--names")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingNamesValue;
            names = argv[i];
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingSessionValue;
            session = argv[i];
        } else if (arg.len > 0 and arg[0] == '-') {
            // unknown flag, skip
        } else {
            commands.append(allocator, arg) catch return ParseError.OutOfMemory;
        }
    }

    if (commands.items.len == 0) {
        return ParseError.MissingCommands;
    }

    const result = try buildCommands(allocator, commands.items, names);

    return .{
        .mode = .tui,
        .commands = result,
        .log_name = null,
        .head = null,
        .tail = null,
        .session = session,
        .allocator = allocator,
    };
}

fn buildCommands(allocator: Allocator, commands: []const []const u8, names: ?[]const u8) ParseError![]Command {
    var name_list = std.ArrayListUnmanaged([]const u8){};
    defer name_list.deinit(allocator);

    if (names) |n| {
        var iter = std.mem.splitScalar(u8, n, ',');
        while (iter.next()) |name| {
            name_list.append(allocator, name) catch return ParseError.OutOfMemory;
        }

        if (name_list.items.len != commands.len) {
            return ParseError.NameCountMismatch;
        }
    }

    const result = allocator.alloc(Command, commands.len) catch return ParseError.OutOfMemory;

    for (commands, 0..) |cmd, idx| {
        result[idx] = .{
            .name = if (names != null) name_list.items[idx] else autoName(cmd),
            .cmd = cmd,
        };
    }

    return result;
}

pub fn autoName(cmd: []const u8) []const u8 {
    var iter = std.mem.splitScalar(u8, cmd, ' ');
    const first = iter.next() orelse return cmd;

    if (std.mem.lastIndexOfScalar(u8, first, '/')) |idx| {
        return first[idx + 1 ..];
    }
    return first;
}

pub fn sanitizeName(allocator: Allocator, name: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        result[i] = if (c == '/' or c == ' ' or c == '\\') '_' else c;
    }
    return result;
}

pub fn printUsage() void {
    std.debug.print(
        \\Usage: deck [COMMAND] [OPTIONS]
        \\
        \\A terminal dashboard for running multiple dev processes.
        \\
        \\Commands:
        \\  (default)    Interactive TUI mode
        \\  start        Start processes in background (daemon mode)
        \\  stop         Stop the background daemon
        \\  logs <name>  View logs for a process
        \\
        \\TUI Mode:
        \\  deck [OPTIONS] "cmd1" "cmd2" ...
        \\
        \\Start Mode (daemon):
        \\  deck start [OPTIONS] "cmd1" "cmd2" ...
        \\
        \\Stop Mode:
        \\  deck stop [OPTIONS]
        \\
        \\Logs Mode:
        \\  deck logs <name> [--head=N] [--tail=N] [OPTIONS]
        \\
        \\Options:
        \\  -n, --names NAME1,NAME2,...  Set custom names for processes
        \\  -s, --session NAME           Set session name (default: auto from pwd)
        \\
        \\Sessions:
        \\  By default, each working directory gets its own isolated session.
        \\  Use --session to run multiple decks in the same directory or to
        \\  access a session from a different directory.
        \\
        \\Examples:
        \\  deck "bun dev" "cargo watch"                     # TUI mode
        \\  deck start -n web,api "bun dev" "cargo run"      # daemon
        \\  deck start -s myapp -n web,api "bun dev" "go run ."  # named session
        \\  deck logs web --tail=50                          # last 50 lines
        \\  deck stop                                        # stop daemon
        \\  deck stop -s myapp                               # stop named session
        \\
    , .{});
}
