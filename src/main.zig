const std = @import("std");
const cli = @import("cli.zig");
const proc = @import("process.zig");
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
            cli.ParseError.OutOfMemory => {
                std.debug.print("Error: out of memory\n", .{});
            },
        }
        std.process.exit(1);
    };
    defer args.deinit();

    var manager = try proc.ProcessManager.init(allocator, args.commands);
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
