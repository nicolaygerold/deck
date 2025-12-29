const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Command = struct {
    name: []const u8,
    cmd: []const u8,
};

pub const ParseError = error{
    MissingCommands,
    MissingNamesValue,
    NameCountMismatch,
    OutOfMemory,
};

pub const Args = struct {
    commands: []Command,
    allocator: Allocator,

    pub fn deinit(self: *Args) void {
        self.allocator.free(self.commands);
    }
};

pub fn parse(allocator: Allocator, argv: []const []const u8) ParseError!Args {
    var names: ?[]const u8 = null;
    var commands = std.ArrayListUnmanaged([]const u8){};
    defer commands.deinit(allocator);

    var i: usize = 1; // skip program name
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--names")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingNamesValue;
            names = argv[i];
        } else if (arg.len > 0 and arg[0] == '-') {
            // unknown flag, skip for now
        } else {
            commands.append(allocator, arg) catch return ParseError.OutOfMemory;
        }
    }

    if (commands.items.len == 0) {
        return ParseError.MissingCommands;
    }

    // Parse names if provided
    var name_list = std.ArrayListUnmanaged([]const u8){};
    defer name_list.deinit(allocator);

    if (names) |n| {
        var iter = std.mem.splitScalar(u8, n, ',');
        while (iter.next()) |name| {
            name_list.append(allocator, name) catch return ParseError.OutOfMemory;
        }

        if (name_list.items.len != commands.items.len) {
            return ParseError.NameCountMismatch;
        }
    }

    // Build Command structs
    const result = allocator.alloc(Command, commands.items.len) catch return ParseError.OutOfMemory;

    for (commands.items, 0..) |cmd, idx| {
        result[idx] = .{
            .name = if (names != null) name_list.items[idx] else autoName(cmd),
            .cmd = cmd,
        };
    }

    return .{
        .commands = result,
        .allocator = allocator,
    };
}

pub fn autoName(cmd: []const u8) []const u8 {
    // Extract first word of command as name
    var iter = std.mem.splitScalar(u8, cmd, ' ');
    const first = iter.next() orelse return cmd;

    // Get basename if it's a path
    if (std.mem.lastIndexOfScalar(u8, first, '/')) |idx| {
        return first[idx + 1 ..];
    }
    return first;
}

pub fn printUsage() void {
    std.debug.print(
        \\Usage: deck [OPTIONS] "cmd1" "cmd2" ...
        \\
        \\A terminal dashboard for running multiple dev processes.
        \\
        \\Options:
        \\  -n, --names NAME1,NAME2,...  Set custom names for processes
        \\
        \\Examples:
        \\  deck "bun dev" "cargo watch"
        \\  deck -n web,api "bun dev" "cargo run"
        \\
    , .{});
}
