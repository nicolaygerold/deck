const std = @import("std");
const cli = @import("cli.zig");
const proc = @import("process.zig");
const daemon = @import("daemon.zig");
const App = @import("app.zig").App;

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var args = cli.parse(allocator, argv) catch |err| {
        switch (err) {
            cli.ParseError.MissingCommands => {
                cli.printUsage();
            },
            cli.ParseError.MissingNamesValue => {
                std.debug.print("Error: -n/--names requires a value\n\n", .{});
                cli.printUsage();
            },
            cli.ParseError.NameCountMismatch => {
                std.debug.print("Error: number of names must match number of commands\n\n", .{});
                cli.printUsage();
            },
            cli.ParseError.MissingLogName => {
                std.debug.print("Error: logs command requires a process name\n\n", .{});
                cli.printUsage();
            },
            cli.ParseError.MissingSessionValue => {
                std.debug.print("Error: -s/--session requires a value\n\n", .{});
                cli.printUsage();
            },
            cli.ParseError.InvalidHeadValue => {
                std.debug.print("Error: --head requires a valid number\n\n", .{});
            },
            cli.ParseError.InvalidTailValue => {
                std.debug.print("Error: --tail requires a valid number\n\n", .{});
            },
            cli.ParseError.OutOfMemory => {
                std.debug.print("Error: out of memory\n", .{});
            },
        }
        std.process.exit(1);
    };
    defer args.deinit();

    switch (args.mode) {
        .tui => try runTui(allocator, args.commands),
        .start => daemon.start(allocator, args.commands, args.session) catch |err| {
            if (err != error.AlreadyRunning) {
                std.debug.print("Failed to start daemon: {}\n", .{err});
                std.process.exit(1);
            }
        },
        .stop => daemon.stop(allocator, args.session) catch |err| {
            std.debug.print("Failed to stop daemon: {}\n", .{err});
            std.process.exit(1);
        },
        .logs => daemon.logs(allocator, args.log_name.?, args.head, args.tail, args.session) catch |err| {
            if (err != error.LogNotFound) {
                std.debug.print("Failed to read logs: {}\n", .{err});
                std.process.exit(1);
            }
        },
    }
}

fn runTui(allocator: std.mem.Allocator, commands: []const cli.Command) !void {
    var manager = try proc.ProcessManager.init(allocator, commands);
    defer {
        std.debug.print("\nCleaning up processes...\n", .{});
        manager.deinit();
        std.debug.print("All processes terminated\n", .{});
    }

    try manager.spawnAll();

    var app = try App.init(allocator, &manager);
    defer {
        app.deinit();
        allocator.destroy(app);
    }

    try app.run();
}

test {
    _ = @import("buffer_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("process_test.zig");
    _ = @import("ui_test.zig");
}
