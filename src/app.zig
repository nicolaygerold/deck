const std = @import("std");
const vaxis = @import("vaxis");
const proc = @import("process.zig");
const LogBuffer = @import("buffer.zig").LogBuffer;

// UI glyphs with ASCII fallbacks for non-UTF8 terminals
const Glyphs = struct {
    // separators & indicators
    vert: []const u8,
    select: []const u8,
    dot: []const u8,
    // status bar indicators
    scroll_auto: []const u8,
    scroll_manual: []const u8,
};

fn asciiRequestedOrNoUtf8(allocator: std.mem.Allocator) bool {
    // Explicit opt-in wins
    if (std.process.getEnvVarOwned(allocator, "DECK_ASCII")) |val| {
        defer allocator.free(val);
        if (std.ascii.eqlIgnoreCase(val, "1")) return true;
        if (std.ascii.eqlIgnoreCase(val, "true")) return true;
        if (std.ascii.eqlIgnoreCase(val, "yes")) return true;
        if (std.ascii.eqlIgnoreCase(val, "on")) return true;
        return false;
    } else |_| {}

    // Heuristics: prefer ASCII if locale is missing UTF-8
    const keys = [_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" };
    inline for (keys) |k| {
        if (std.process.getEnvVarOwned(allocator, k)) |v| {
            defer allocator.free(v);
            // case-insensitive contains("UTF-8") / ("UTF8")
            if (std.mem.indexOf(u8, v, "UTF-8") != null or std.mem.indexOf(u8, v, "utf-8") != null or std.mem.indexOf(u8, v, "UTF8") != null or std.mem.indexOf(u8, v, "utf8") != null) {
                return false;
            }
        } else |_| {}
    }
    // Default to ASCII if nothing indicates UTF-8
    return true;
}

pub const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    color_scheme: vaxis.Color.Scheme,
    color_report: vaxis.Color.Report,
    focus_in,
    focus_out,
};

pub const App = struct {
    manager: *proc.ProcessManager,
    selected: usize = 0,
    scroll_offset: usize = 0,
    auto_scroll: bool = true,
    wrap_enabled: bool = true,
    show_timestamps: bool = false,
    // Filtering
    filter_mode: bool = false,
    filter_len: usize = 0,
    filter_buf: [96]u8 = undefined,
    filter_min_level: ?LogLevel = null,
    search_mode: bool = false,
    search_len: usize = 0,
    search_buf: [96]u8 = undefined,
    allocator: std.mem.Allocator,
    vx: vaxis.Vaxis,
    tty: vaxis.Tty,
    should_quit: bool = false,
    visual_mode: bool = false,
    selection_anchor: usize = 0,
    cursor_line: usize = 0,
    focus_on_logs: bool = false,
    color_scheme: vaxis.Color.Scheme = .dark,
    terminal_bg: ?[3]u8 = null,
    // Folding and navigation
    folded_groups: std.AutoHashMap(usize, void) = undefined,
    // Bookmarks
    marks: [26]?usize = [_]?usize{null} ** 26,
    mark_set_mode: bool = false,
    jump_mode: bool = false,
    // JSON view and ANSI rendering
    json_message_view: bool = false,
    preserve_ansi: bool = false,

    tty_buf: [4096]u8 = undefined,
    glyphs: Glyphs = .{ .vert = "│", .select = "▶", .dot = "●", .scroll_auto = "↓", .scroll_manual = "•" },

    pub fn init(allocator: std.mem.Allocator, manager: *proc.ProcessManager) !*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);

        self.* = App{
            .manager = manager,
            .allocator = allocator,
            .vx = undefined,
            .tty = undefined,
        };

        // Initialize TTY first; this can fail in non-interactive environments
        // (e.g., no controlling terminal, CI). Fail fast without leaking `self`.
        self.tty = vaxis.Tty.init(&self.tty_buf) catch |e| {
            // Propagate original error; caller will map to a user-facing message.
            return e;
        };
        errdefer self.tty.deinit();

        // Initialize Vaxis after TTY so we can deinit cleanly on subsequent failure.
        self.vx = try vaxis.Vaxis.init(allocator, .{});

        // Choose glyph set based on environment capability
        if (asciiRequestedOrNoUtf8(allocator)) {
            self.glyphs = .{ .vert = "|", .select = ">", .dot = "*", .scroll_auto = "v", .scroll_manual = "." };
        } else {
            self.glyphs = .{ .vert = "│", .select = "▶", .dot = "●", .scroll_auto = "↓", .scroll_manual = "•" };
        }

        self.folded_groups = std.AutoHashMap(usize, void).init(allocator);
        return self;
    }

    pub fn deinit(self: *App) void {
        self.manager.killAll();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.folded_groups.deinit();
    }

    pub fn run(self: *App) !void {
        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();
        try loop.start();
        defer loop.stop();

        try self.vx.enterAltScreen(self.tty.writer());
        self.vx.queryTerminal(self.tty.writer(), 100 * std.time.ns_per_ms) catch {};
        self.vx.setMouseMode(self.tty.writer(), true) catch {};
        self.vx.subscribeToColorSchemeUpdates(self.tty.writer()) catch {};
        self.vx.queryColor(self.tty.writer(), .bg) catch {};

        while (!self.should_quit) {
            // Read process output
            const had_output = self.manager.readAll() catch false;

            // Auto-scroll to bottom if enabled and we got new output
            if (self.auto_scroll and had_output) {
                const log = &self.manager.processes[self.selected].log;
                const win = self.vx.window();
                const visible_lines = win.height -| 3;
                if (log.lineCount() > visible_lines) {
                    self.scroll_offset = log.lineCount() - visible_lines;
                }
            }

            // Handle events
            while (loop.tryEvent()) |event| {
                try self.handleEvent(event);
            }

            // Render
            try self.render();
            if (self.vx.render(self.tty.writer())) |_| {} else |_| {
                // If rendering fails, exit gracefully to restore terminal state
                self.should_quit = true;
            }

            // Small sleep to avoid busy loop
            std.Thread.sleep(16 * std.time.ns_per_ms);
        }

        try self.vx.exitAltScreen(self.tty.writer());
    }

    fn handleEvent(self: *App, event: Event) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
                    self.should_quit = true;
                    return;
                }

                // Handle search input mode first
                if (self.search_mode) {
                    if (key.matches(vaxis.Key.enter, .{})) {
                        self.search_mode = false;
                        // Jump to first match after current line if any
                        const q = self.search_buf[0..self.search_len];
                        if (q.len > 0) {
                            if (findNextMatch(self, self.cursor_line + 1, true)) |ln| {
                                self.cursor_line = ln;
                                self.ensureCursorVisible();
                            } else if (findNextMatch(self, 0, true)) |ln2| {
                                self.cursor_line = ln2;
                                self.ensureCursorVisible();
                            }
                        }
                        return;
                    }
                    if (key.matches(vaxis.Key.escape, .{})) {
                        self.search_mode = false;
                        return;
                    }
                    if (key.matches(vaxis.Key.backspace, .{})) {
                        if (self.search_len > 0) self.search_len -= 1;
                        return;
                    }
                    // Append printable ASCII
                    if (key.codepoint >= 32 and key.codepoint <= 126) {
                        if (self.search_len < self.search_buf.len) {
                            self.search_buf[self.search_len] = @intCast(key.codepoint);
                            self.search_len += 1;
                        }
                        return;
                    }
                    // Ignore other keys in search mode
                    return;
                }
                // Handle filter input mode
                if (self.filter_mode) {
                    if (key.matches(vaxis.Key.enter, .{})) {
                        self.filter_mode = false;
                        return;
                    }
                    if (key.matches(vaxis.Key.escape, .{})) {
                        self.filter_mode = false;
                        return;
                    }
                    if (key.matches(vaxis.Key.backspace, .{})) {
                        if (self.filter_len > 0) self.filter_len -= 1;
                        return;
                    }
                    if (key.codepoint >= 32 and key.codepoint <= 126) {
                        if (self.filter_len < self.filter_buf.len) {
                            self.filter_buf[self.filter_len] = @intCast(key.codepoint);
                            self.filter_len += 1;
                        }
                        return;
                    }
                    return;
                }
                if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                    if (self.visual_mode or self.focus_on_logs) {
                        const log = &self.manager.processes[self.selected].log;
                        if (self.cursor_line < log.lineCount() -| 1) {
                            self.cursor_line += 1;
                            self.ensureCursorVisible();
                        }
                    } else {
                        if (self.selected < self.manager.processes.len - 1) {
                            self.selected += 1;
                            self.scroll_offset = 0;
                            self.auto_scroll = true;
                        }
                    }
                    return;
                }
                if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                    if (self.visual_mode or self.focus_on_logs) {
                        self.cursor_line -|= 1;
                        self.ensureCursorVisible();
                    } else {
                        if (self.selected > 0) {
                            self.selected -= 1;
                            self.scroll_offset = 0;
                            self.auto_scroll = true;
                        }
                    }
                    return;
                }
                if (key.matches('r', .{})) {
                    self.manager.processes[self.selected].restart() catch {};
                    self.scroll_offset = 0;
                    self.auto_scroll = true;
                    return;
                }
                if (key.matches('o', .{})) {
                    // Toggle fold for group at cursor
                    const start = findGroupStart(self, self.cursor_line);
                    if (self.folded_groups.get(start) != null) {
                        _ = self.folded_groups.remove(start);
                    } else {
                        self.folded_groups.put(start, {}) catch {};
                    }
                    self.auto_scroll = false;
                    return;
                }
                if (key.matches('/', .{})) {
                    self.search_mode = true;
                    self.focus_on_logs = true;
                    self.auto_scroll = false;
                    return;
                }
                if (key.matches('j', .{})) {
                    self.json_message_view = !self.json_message_view;
                    self.auto_scroll = false;
                    return;
                }
                if (key.matches('A', .{})) {
                    self.preserve_ansi = !self.preserve_ansi;
                    self.auto_scroll = false;
                    return;
                }
                if (key.matches('Y', .{})) {
                    exportFilteredSnapshot(self) catch {};
                    return;
                }
                if (key.matches('m', .{})) {
                    self.mark_set_mode = true;
                    return;
                }
                if (key.matches('\'', .{})) { // jump
                    self.jump_mode = true;
                    return;
                }
                if (self.mark_set_mode or self.jump_mode) {
                    if (key.codepoint >= 'a' and key.codepoint <= 'z') {
                        const idx: usize = key.codepoint - 'a';
                        if (self.mark_set_mode) {
                            self.marks[idx] = self.cursor_line;
                        } else if (self.jump_mode) {
                            if (self.marks[idx]) |line| {
                                self.cursor_line = line;
                                self.ensureCursorVisible();
                            }
                        }
                    }
                    self.mark_set_mode = false;
                    self.jump_mode = false;
                    return;
                }
                if (key.matches(']', .{})) {
                    if (findNextImportant(self, self.cursor_line + 1, true)) |ln| {
                        self.cursor_line = ln;
                        self.ensureCursorVisible();
                    }
                    return;
                }
                if (key.matches('[', .{})) {
                    if (findNextImportant(self, self.cursor_line, false)) |ln| {
                        self.cursor_line = ln;
                        self.ensureCursorVisible();
                    }
                    return;
                }
                if (key.matches('f', .{})) {
                    self.filter_mode = true;
                    self.auto_scroll = false;
                    return;
                }
                if (key.matches('L', .{})) {
                    // Cycle minimum level: null -> debug -> info -> warning -> error -> null
                    self.filter_min_level = switch (self.filter_min_level orelse .debug) {
                        .debug => .info,
                        .info => .warning,
                        .warning => .@"error",
                        .@"error" => null,
                    };
                    self.auto_scroll = false;
                    return;
                }
                if (key.matches('n', .{})) {
                    const q = self.search_buf[0..self.search_len];
                    if (q.len > 0) {
                        if (findNextMatch(self, self.cursor_line + 1, true)) |ln| {
                            self.cursor_line = ln;
                            self.ensureCursorVisible();
                        } else if (findNextMatch(self, 0, true)) |ln2| {
                            self.cursor_line = ln2;
                            self.ensureCursorVisible();
                        }
                    }
                    return;
                }
                if (key.matches('N', .{})) {
                    const q = self.search_buf[0..self.search_len];
                    if (q.len > 0) {
                        if (findNextMatch(self, self.cursor_line, false)) |ln| {
                            self.cursor_line = ln;
                            self.ensureCursorVisible();
                        } else if (findNextMatch(self, @max(@as(usize, 1), self.manager.processes[self.selected].log.lineCount()) - 1, false)) |ln2| {
                            self.cursor_line = ln2;
                            self.ensureCursorVisible();
                        }
                    }
                    return;
                }
                if (key.matches('w', .{})) {
                    self.wrap_enabled = !self.wrap_enabled;
                    self.auto_scroll = false;
                    return;
                }
                if (key.matches('t', .{})) {
                    self.show_timestamps = !self.show_timestamps;
                    self.auto_scroll = false;
                    return;
                }
                if (key.matches('x', .{})) {
                    // Kill selected process
                    self.manager.processes[self.selected].kill();
                    return;
                }
                if (key.matches('G', .{})) {
                    // Jump to end, enable auto-scroll
                    const log = &self.manager.processes[self.selected].log;
                    const win = self.vx.window();
                    const visible_lines = win.height -| 3;
                    if (log.lineCount() > visible_lines) {
                        self.scroll_offset = log.lineCount() - visible_lines;
                    }
                    self.auto_scroll = true;
                    return;
                }
                if (key.matches('g', .{})) {
                    self.scroll_offset = 0;
                    self.auto_scroll = false;
                    return;
                }
                if (key.matches(vaxis.Key.page_down, .{}) or key.matches('d', .{ .ctrl = true })) {
                    const log = &self.manager.processes[self.selected].log;
                    const win = self.vx.window();
                    const visible_lines = win.height -| 3;
                    const max_scroll = if (log.lineCount() > visible_lines) log.lineCount() - visible_lines else 0;
                    self.scroll_offset = @min(self.scroll_offset + 20, max_scroll);
                    self.auto_scroll = (self.scroll_offset >= max_scroll);
                    return;
                }
                if (key.matches(vaxis.Key.page_up, .{}) or key.matches('u', .{ .ctrl = true })) {
                    self.scroll_offset -|= 20;
                    self.auto_scroll = false;
                    return;
                }
                if (key.matches('v', .{})) {
                    self.visual_mode = !self.visual_mode;
                    if (self.visual_mode) {
                        // If already focused on logs, use current cursor position
                        // Otherwise start at top of visible area
                        if (!self.focus_on_logs) {
                            const log = &self.manager.processes[self.selected].log;
                            self.cursor_line = @min(self.scroll_offset, log.lineCount() -| 1);
                        }
                        self.selection_anchor = self.cursor_line;
                        self.focus_on_logs = true;
                        self.auto_scroll = false;
                    }
                    return;
                }
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.visual_mode = false;
                    self.focus_on_logs = false;
                    self.search_mode = false;
                    self.filter_mode = false;
                    return;
                }
                if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{}) or key.matches(vaxis.Key.enter, .{})) {
                    if (!self.focus_on_logs and !self.visual_mode) {
                        self.focus_on_logs = true;
                        self.auto_scroll = false;
                        // Initialize cursor to current view position
                        const log = &self.manager.processes[self.selected].log;
                        self.cursor_line = @min(self.scroll_offset, log.lineCount() -| 1);
                    }
                    return;
                }
                if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
                    if (self.focus_on_logs and !self.visual_mode) {
                        self.focus_on_logs = false;
                    }
                    return;
                }
                if (key.matches('y', .{})) {
                    const log = &self.manager.processes[self.selected].log;
                    const content = if (self.visual_mode) blk: {
                        const start = @min(self.selection_anchor, self.cursor_line);
                        const end = @max(self.selection_anchor, self.cursor_line);
                        break :blk log.getTextRange(self.allocator, start, end + 1) catch return;
                    } else log.getAllText(self.allocator) catch return;
                    defer self.allocator.free(content);
                    self.vx.copyToSystemClipboard(self.tty.writer(), content, self.allocator) catch {};
                    self.visual_mode = false;
                    return;
                }
                // Number keys to select process
                if (key.codepoint >= '1' and key.codepoint <= '9') {
                    const idx = key.codepoint - '1';
                    if (idx < self.manager.processes.len) {
                        self.selected = idx;
                        self.scroll_offset = 0;
                        self.auto_scroll = true;
                        self.focus_on_logs = false;
                        self.visual_mode = false;
                    }
                    return;
                }
            },
            .mouse => |mouse| {
                if (mouse.button == .wheel_down) {
                    const log = &self.manager.processes[self.selected].log;
                    const win = self.vx.window();
                    const visible_lines = win.height -| 3;
                    const max_scroll = if (log.lineCount() > visible_lines) log.lineCount() - visible_lines else 0;
                    self.scroll_offset = @min(self.scroll_offset + 3, max_scroll);
                    self.auto_scroll = (self.scroll_offset >= max_scroll);
                    return;
                }
                if (mouse.button == .wheel_up) {
                    self.scroll_offset -|= 3;
                    self.auto_scroll = false;
                    return;
                }
                // While in filter/search prompt, ignore clicks
                if (self.search_mode or self.filter_mode) return;
                if (mouse.button == .left and mouse.type == .press) {
                    const win = self.vx.window();
                    const sidebar_width: u16 = @min(25, win.width / 4);

                    if (mouse.col < sidebar_width and mouse.row >= 2 and mouse.row < win.height - 1) {
                        const clicked_idx = @as(usize, @intCast(mouse.row - 2));
                        if (clicked_idx < self.manager.processes.len) {
                            self.selected = clicked_idx;
                            self.scroll_offset = 0;
                            self.auto_scroll = true;
                            self.visual_mode = false;
                        }
                    } else if (mouse.col > sidebar_width and mouse.row >= 2 and mouse.row < win.height - 1) {
                        const clicked_line = self.scroll_offset + @as(usize, @intCast(mouse.row - 2));
                        const log = &self.manager.processes[self.selected].log;
                        if (clicked_line < log.lineCount()) {
                            self.visual_mode = true;
                            self.selection_anchor = clicked_line;
                            self.cursor_line = clicked_line;
                        }
                    }
                    return;
                }
                if (mouse.button == .left and mouse.type == .drag and self.visual_mode) {
                    const win = self.vx.window();
                    const sidebar_width: u16 = @min(25, win.width / 4);
                    if (mouse.col > sidebar_width and mouse.row >= 2 and mouse.row < win.height - 1) {
                        const clicked_line = self.scroll_offset + @as(usize, @intCast(mouse.row - 2));
                        const log = &self.manager.processes[self.selected].log;
                        if (clicked_line < log.lineCount()) {
                            self.cursor_line = clicked_line;
                        }
                    }
                    return;
                }
            },
            .winsize => |ws| {
                self.vx.resize(self.allocator, self.tty.writer(), ws) catch {};
            },
            .color_scheme => |scheme| {
                self.color_scheme = scheme;
            },
            .color_report => |report| {
                if (report.kind == .bg) {
                    self.terminal_bg = report.value;
                }
            },
            else => {},
        }
    }

    fn render(self: *App) !void {
        const win = self.vx.window();
        win.clear();

        const width = win.width;
        const height = win.height;

        if (width < 40 or height < 5) {
            _ = win.printSegment(.{ .text = "Terminal too small", .style = .{ .fg = .{ .index = 1 } } }, .{});
            return;
        }

        const sidebar_width: u16 = @min(25, width / 4);

        // Draw sidebar
        self.drawSidebar(win, sidebar_width, height);

        // Draw separator
        for (0..height) |row| {
            _ = win.printSegment(.{ .text = self.glyphs.vert, .style = .{ .fg = .{ .index = 8 } } }, .{ .col_offset = sidebar_width, .row_offset = @intCast(row) });
        }

        // Draw log pane
        self.drawLogPane(win, sidebar_width + 1, width -| sidebar_width -| 1, height);

        // Draw status bar
        self.drawStatusBar(win, width, height);
    }

    fn drawSidebar(self: *App, win: vaxis.Window, width: u16, height: u16) void {
        // Header
        _ = win.printSegment(.{ .text = " PROCESSES", .style = .{ .bold = true, .fg = .{ .index = 4 } } }, .{ .col_offset = 0, .row_offset = 0 });

        // Process list
        for (self.manager.processes, 0..) |p, idx| {
            const row: u16 = @intCast(idx + 2);
            if (row >= height - 1) break;

            const is_selected = idx == self.selected;
            const status_color: vaxis.Cell.Color = switch (p.status) {
                .pending => .{ .index = 3 }, // yellow
                .running => .{ .index = 2 }, // green
                .exited => .{ .index = 8 }, // gray
                .crashed => .{ .index = 1 }, // red
            };

            // Selection indicator
            if (is_selected) {
                _ = win.printSegment(.{ .text = self.glyphs.select, .style = .{ .fg = .{ .index = 6 } } }, .{ .col_offset = 0, .row_offset = row });
            }

            // Status dot
            _ = win.printSegment(.{ .text = self.glyphs.dot, .style = .{ .fg = status_color } }, .{ .col_offset = 2, .row_offset = row });

            // Process name (truncate if needed)
            const max_name_len = width -| 5;
            const display_name = if (p.name.len > max_name_len)
                p.name[0..max_name_len]
            else
                p.name;

            _ = win.printSegment(.{
                .text = display_name,
                .style = if (is_selected) .{ .bold = true } else .{},
            }, .{ .col_offset = 4, .row_offset = row });
        }
    }

    fn drawLogPane(self: *App, win: vaxis.Window, start_col: u16, width: u16, height: u16) void {
        if (self.manager.processes.len == 0) return;

        const process = &self.manager.processes[self.selected];
        const log = &process.log;

        // Header: name + status + command
        _ = win.printSegment(.{
            .text = process.name,
            .style = .{ .bold = true, .fg = .{ .index = 6 } },
        }, .{ .col_offset = start_col, .row_offset = 0 });

        // Status badge
        const status_text = switch (process.status) {
            .pending => " [pending]",
            .running => " [running]",
            .exited => " [exited]",
            .crashed => " [crashed]",
        };
        const status_color: vaxis.Cell.Color = switch (process.status) {
            .pending => .{ .index = 3 },
            .running => .{ .index = 2 },
            .exited => .{ .index = 8 },
            .crashed => .{ .index = 1 },
        };
        const status_col = start_col + @as(u16, @intCast(process.name.len));
        _ = win.printSegment(.{
            .text = status_text,
            .style = .{ .fg = status_color },
        }, .{ .col_offset = status_col, .row_offset = 0 });

        // Show command (truncated)
        const cmd_start = status_col + @as(u16, @intCast(status_text.len)) + 1;
        const remaining_width = if (cmd_start < start_col + width) start_col + width - cmd_start else 0;
        const max_cmd_len = @min(process.command.len, remaining_width);
        if (max_cmd_len > 0) {
            _ = win.printSegment(.{
                .text = process.command[0..max_cmd_len],
                .style = .{ .fg = .{ .index = 8 } },
            }, .{ .col_offset = cmd_start, .row_offset = 0 });
        }

        // Log lines
        const visible_lines = height -| 3;
        const total_lines = log.lineCount();

        var start_line: usize = self.scroll_offset;
        if (total_lines > visible_lines and start_line > total_lines - visible_lines) {
            start_line = total_lines - visible_lines;
        }

        const sel_start = @min(self.selection_anchor, self.cursor_line);
        const sel_end = @max(self.selection_anchor, self.cursor_line);

        // Determine dynamic gutter width (optional timestamp + common small prefixes like "name: ")
        var row: u16 = 2;
        var tmp_idx: usize = start_line;
        var max_prefix: usize = 0;
        const ts_width: usize = if (self.show_timestamps) 9 else 0; // HH:MM:SS and trailing space
        while (tmp_idx < total_lines and (@as(u16, @intCast((tmp_idx - start_line))) < visible_lines)) : (tmp_idx += 1) {
            if (log.getLine(tmp_idx)) |line_for_prefix| {
                const maybe_sanitized_p = stripAnsiAlloc(self.allocator, line_for_prefix.text) catch null;
                const text_p = if (maybe_sanitized_p) |s| s else line_for_prefix.text;
                const colon = std.mem.indexOf(u8, text_p, ": ");
                if (colon) |ci| {
                    if (ci < 24 and ci + 2 > max_prefix) max_prefix = ci + 2;
                }
                if (maybe_sanitized_p) |s| self.allocator.free(s);
            }
        }
        const gutter_width: usize = @min(@as(usize, width), ts_width + max_prefix);
        const content_width: usize = if (gutter_width >= width) 0 else @as(usize, width) - gutter_width;

        var line_idx = start_line;
        while (line_idx < total_lines and row < height - 1) : (line_idx += 1) {
            if (log.getLine(line_idx)) |line| {
                // View-level filters (min level + grep)
                if (!passesViewFilters(self, line.text)) continue;

                // Folding: if current line is group leader and folded, print one line and skip
                const maybe_sanitized_leader = stripAnsiAlloc(self.allocator, line.text) catch null;
                const leader_text = if (maybe_sanitized_leader) |s| s else line.text;
                const is_cont = isContinuationLine(leader_text);
                if (maybe_sanitized_leader) |s| self.allocator.free(s);
                if (!is_cont) {
                    const group_start = line_idx;
                    const group_end = findGroupEndFor(self, group_start);
                    if (self.folded_groups.get(group_start) != null and group_end > group_start) {
                        var label_buf: [32]u8 = undefined;
                        const label = std.fmt.bufPrint(&label_buf, "  [+{d} lines]", .{group_end - group_start}) catch "";
                        const maybe_sanitized2 = stripAnsiAlloc(self.allocator, line.text) catch null;
                        const t2 = if (maybe_sanitized2) |s| s else line.text;
                        const max_len = @min(t2.len, content_width -| label.len);
                        _ = win.printSegment(.{ .text = t2[0..max_len], .style = .{} }, .{ .col_offset = start_col + @as(u16, @intCast(gutter_width)), .row_offset = row });
                        _ = win.printSegment(.{ .text = label, .style = .{ .fg = .{ .index = 8 } } }, .{ .col_offset = start_col + @as(u16, @intCast(gutter_width)) + @as(u16, @intCast(max_len)), .row_offset = row });
                        if (maybe_sanitized2) |s| self.allocator.free(s);
                        row += 1;
                        line_idx = group_end; // skip
                        continue;
                    }
                }
                const is_selected = self.visual_mode and line_idx >= sel_start and line_idx <= sel_end;
                const is_cursor = self.focus_on_logs and !self.visual_mode and line_idx == self.cursor_line;

                // Derive highlight colors from terminal's background
                const cursor_bg: vaxis.Color = if (self.terminal_bg) |bg| blk: {
                    // Shift towards gray for cursor highlight
                    const shift: i16 = if (self.color_scheme == .light) -25 else 25;
                    break :blk .{ .rgb = .{
                        @intCast(std.math.clamp(@as(i16, bg[0]) + shift, 0, 255)),
                        @intCast(std.math.clamp(@as(i16, bg[1]) + shift, 0, 255)),
                        @intCast(std.math.clamp(@as(i16, bg[2]) + shift, 0, 255)),
                    } };
                } else if (self.color_scheme == .light)
                    .{ .rgb = .{ 230, 230, 230 } }
                else
                    .{ .rgb = .{ 45, 45, 45 } };

                const visual_bg: vaxis.Color = if (self.terminal_bg) |bg| blk: {
                    // Shift towards blue for visual selection
                    const shift: i16 = if (self.color_scheme == .light) -20 else 20;
                    break :blk .{ .rgb = .{
                        @intCast(std.math.clamp(@as(i16, bg[0]) + shift - 10, 0, 255)),
                        @intCast(std.math.clamp(@as(i16, bg[1]) + shift, 0, 255)),
                        @intCast(std.math.clamp(@as(i16, bg[2]) + shift + 20, 0, 255)),
                    } };
                } else if (self.color_scheme == .light)
                    .{ .rgb = .{ 210, 220, 240 } }
                else
                    .{ .rgb = .{ 35, 45, 65 } };

                var style: vaxis.Style = .{};
                if (is_selected) style.bg = visual_bg else if (is_cursor) style.bg = cursor_bg;

                // Sanitize for display, optionally extract JSON message
                const maybe_sanitized = stripAnsiAlloc(self.allocator, line.text) catch null;
                const base_text = if (maybe_sanitized) |s| s else line.text;
                const maybe_json_msg = if (self.json_message_view) extractJsonMessage(self.allocator, base_text) catch null else null;
                const display_text = if (maybe_json_msg) |m| m else base_text;
                defer if (maybe_sanitized) |s| self.allocator.free(s);
                defer if (maybe_json_msg) |m| self.allocator.free(m);

                // Detect level for foreground coloring
                if (detectLevel(display_text)) |lvl| switch (lvl) {
                    .@"error" => style.fg = .{ .index = 1 },
                    .warning => style.fg = .{ .index = 3 },
                    .info => style.fg = .{ .index = 7 },
                    .debug => style.fg = .{ .index = 8 },
                };

                // Split off small prefix ending with ": " for gutter placement
                var msg_start: usize = 0;
                var prefix_len: usize = 0;
                if (max_prefix > 0) {
                    if (std.mem.indexOf(u8, display_text, ": ")) |ci| {
                        if (ci + 2 <= max_prefix) {
                            prefix_len = ci + 2;
                            msg_start = prefix_len;
                        }
                    }
                }

                // Print first row's gutter (timestamp + prefix)
                var first_row = true;
                var text_offset: usize = msg_start;
                if (content_width == 0) break; // no room
                while (row < height - 1) {
                    if (first_row) {
                        var gutter_col = start_col;
                        if (self.show_timestamps) {
                            var tbuf: [9]u8 = undefined; // HH:MM:SS␠
                            const ts = formatHms(&tbuf, line.timestamp);
                            _ = win.printSegment(.{ .text = ts, .style = .{ .fg = .{ .index = 8 } } }, .{ .col_offset = gutter_col, .row_offset = row });
                            gutter_col += 9;
                        }
                        if (prefix_len > 0) {
                            const take = @min(prefix_len, max_prefix);
                            const col_idx: u8 = colorIndexForString(display_text[0..take]);
                            _ = win.printSegment(.{ .text = display_text[0..take], .style = .{ .fg = .{ .index = col_idx } } }, .{ .col_offset = gutter_col, .row_offset = row });
                            gutter_col += @intCast(take);
                            // pad remaining gutter space if any
                            const pad = @as(usize, gutter_width) - ts_width - take;
                            if (pad > 0) {
                                var spaces: [32]u8 = undefined;
                                const p = @min(pad, spaces.len);
                                @memset(spaces[0..p], ' ');
                                _ = win.printSegment(.{ .text = spaces[0..p] }, .{ .col_offset = gutter_col, .row_offset = row });
                            }
                        } else if (gutter_width > ts_width) {
                            // fill non-prefix gutter area for alignment
                            var spaces: [32]u8 = undefined;
                            const pad = @min(gutter_width - ts_width, spaces.len);
                            @memset(spaces[0..pad], ' ');
                            _ = win.printSegment(.{ .text = spaces[0..pad] }, .{ .col_offset = gutter_col, .row_offset = row });
                        }
                    } else {
                        // continuation rows: blank gutter
                        if (gutter_width > 0) {
                            var spaces: [32]u8 = undefined;
                            const pad = @min(gutter_width, spaces.len);
                            @memset(spaces[0..pad], ' ');
                            _ = win.printSegment(.{ .text = spaces[0..pad] }, .{ .col_offset = start_col, .row_offset = row });
                        }
                    }

                    // Print message chunk (with optional search highlight)
                    const remaining = display_text.len - text_offset;
                    if (remaining == 0) {
                        // if first_row and empty message, still advance one row
                        row += 1;
                        break;
                    }
                    const chunk_len = @min(remaining, content_width);
                    const chunk = display_text[text_offset .. text_offset + chunk_len];
                    const q = self.search_buf[0..self.search_len];
                    if (q.len == 0 and self.preserve_ansi and maybe_sanitized == null and maybe_json_msg == null) {
                        // Try to render original text with ANSI if not sanitized/rewritten
                        _ = printWithAnsi(self, win, line.text[text_offset .. text_offset + chunk_len], style, start_col + @as(u16, @intCast(gutter_width)), row, @intCast(content_width));
                    } else if (q.len == 0) {
                        _ = win.printSegment(.{ .text = chunk, .style = style }, .{ .col_offset = start_col + @as(u16, @intCast(gutter_width)), .row_offset = row });
                    } else {
                        var local: usize = 0;
                        while (local < chunk.len) {
                            if (indexOfIgnoreCase(chunk[local..], q)) |rel| {
                                if (rel > 0) {
                                    _ = win.printSegment(.{ .text = chunk[local .. local + rel], .style = style }, .{ .col_offset = start_col + @as(u16, @intCast(gutter_width)) + @as(u16, @intCast(local)), .row_offset = row });
                                    local += rel;
                                }
                                const m_end = @min(local + q.len, chunk.len);
                                var match_style = style;
                                match_style.bold = true;
                                match_style.fg = .{ .index = 6 };
                                _ = win.printSegment(.{ .text = chunk[local..m_end], .style = match_style }, .{ .col_offset = start_col + @as(u16, @intCast(gutter_width)) + @as(u16, @intCast(local)), .row_offset = row });
                                local = m_end;
                            } else {
                                _ = win.printSegment(.{ .text = chunk[local..], .style = style }, .{ .col_offset = start_col + @as(u16, @intCast(gutter_width)) + @as(u16, @intCast(local)), .row_offset = row });
                                break;
                            }
                        }
                    }

                    text_offset += if (self.wrap_enabled) chunk_len else remaining;
                    row += 1;
                    if (!self.wrap_enabled or text_offset >= display_text.len) break;
                    first_row = false;
                }
            } else {
                row += 1;
            }
        }

        // Show empty state
        if (total_lines == 0) {
            _ = win.printSegment(.{
                .text = "(no output yet)",
                .style = .{ .fg = .{ .index = 8 } },
            }, .{ .col_offset = start_col, .row_offset = 2 });
        }
    }

    fn drawStatusBar(self: *App, win: vaxis.Window, width: u16, height: u16) void {
        const row = height - 1;

        // Theme-aware status bar colors
        const bar_style: vaxis.Style = if (self.terminal_bg) |bg| blk: {
            const shift: i16 = if (self.color_scheme == .light) -30 else 30;
            break :blk .{ .bg = .{ .rgb = .{
                @intCast(std.math.clamp(@as(i16, bg[0]) + shift, 0, 255)),
                @intCast(std.math.clamp(@as(i16, bg[1]) + shift, 0, 255)),
                @intCast(std.math.clamp(@as(i16, bg[2]) + shift, 0, 255)),
            } } };
        } else .{ .reverse = true };

        // Fill background
        for (0..width) |col| {
            win.writeCell(@intCast(col), row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = bar_style,
            });
        }

        var help: []const u8 = undefined;
        if (self.search_mode) {
            // Show search prompt
            var prompt_buf: [128]u8 = undefined;
            const q = self.search_buf[0..self.search_len];
            const prompt = std.fmt.bufPrint(&prompt_buf, "/{s}_  Enter:accept  Esc:cancel", .{q}) catch "/_";
            help = prompt;
        } else if (self.filter_mode) {
            var prompt_buf: [128]u8 = undefined;
            const p = self.filter_buf[0..self.filter_len];
            const lvl = self.filter_min_level;
            const lvl_str = if (lvl) |l| switch (l) {
                .debug => "debug",
                .info => "info",
                .warning => "warn",
                .@"error" => "error",
            } else "-";
            const prompt = std.fmt.bufPrint(&prompt_buf, "grep:{s}_  min:{s}  Enter:accept  Esc:cancel", .{ p, lvl_str }) catch "grep:_";
            help = prompt;
        } else if (self.visual_mode) {
            help = " v/Esc:exit visual  j/k:select  y:copy ";
        } else if (self.focus_on_logs) {
            help = " h/Esc:back  j/k:nav  /:search  n/N:next/prev  f:filter  L:min-level  v:visual  y:copy  g/G:top/end ";
        } else {
            help = " q:quit  j/k:select  l/Enter:logs  r:restart  x:kill  v:visual  y:copy ";
        }
        _ = win.printSegment(.{
            .text = help,
            .style = bar_style,
        }, .{ .col_offset = 0, .row_offset = row });

        // Right side: line count + scroll indicator + toggles
        if (self.manager.processes.len > 0) {
            const log = &self.manager.processes[self.selected].log;
            var buf: [128]u8 = undefined;
            const scroll_indicator = if (self.auto_scroll) self.glyphs.scroll_auto else self.glyphs.scroll_manual;
            const wrap_tag = if (self.wrap_enabled) " wrap" else " trunc";
            const ts_tag = if (self.show_timestamps) " ts" else "";
            var hits_buf: [24]u8 = undefined;
            const hits = if (self.search_len > 0) countMatches(self) else 0;
            const hits_str = if (self.search_len > 0) std.fmt.bufPrint(&hits_buf, " hits:{d}", .{hits}) catch "" else "";
            const lvl = self.filter_min_level;
            const lvl_str = if (lvl) |l| switch (l) {
                .debug => " d",
                .info => " i",
                .warning => " w",
                .@"error" => " e",
            } else "";
            const grep_str = if (self.filter_len > 0) " grep" else "";
            const count_str = std.fmt.bufPrint(&buf, "{s} {d} lines{s}{s}{s}{s}{s} ", .{ scroll_indicator, log.lineCount(), wrap_tag, ts_tag, hits_str, lvl_str, grep_str }) catch return;
            const start = width -| @as(u16, @intCast(count_str.len));
            _ = win.printSegment(.{
                .text = count_str,
                .style = bar_style,
            }, .{ .col_offset = start, .row_offset = row });
        }
    }

    fn ensureCursorVisible(self: *App) void {
        const win = self.vx.window();
        const visible_lines = win.height -| 3;
        if (visible_lines == 0) return;

        // Row-accurate adjustment: measure rows between scroll_offset and cursor
        const log = &self.manager.processes[self.selected].log;
        const widths = computeGutterAndContentWidth(self, win, log, self.scroll_offset, visible_lines);
        const content_width: usize = widths.content;

        // helper to count rows for a given line index
        const rowCountFor = struct {
            fn f(app: *App, l: []const u8, content: usize) usize {
                if (!passesViewFilters(app, l)) return 0;
                const maybe_s = stripAnsiAlloc(app.allocator, l) catch null;
                const base = if (maybe_s) |s| s else l;
                const maybe_msg = if (app.json_message_view) extractJsonMessage(app.allocator, base) catch null else null;
                const text = if (maybe_msg) |m| m else base;
                defer if (maybe_s) |s| app.allocator.free(s);
                defer if (maybe_msg) |m| app.allocator.free(m);
                if (!app.wrap_enabled or content == 0) return 1;
                const rows = (text.len + content - 1) / content;
                return if (rows == 0) 1 else rows;
            }
        }.f;

        var rows_above: usize = 0;
        var i = self.scroll_offset;
        while (i < self.cursor_line and rows_above <= visible_lines) : (i += 1) {
            if (log.getLine(i)) |ln| rows_above += rowCountFor(self, ln.text, content_width);
        }

        // If cursor is above, move scroll up
        if (self.cursor_line < self.scroll_offset) {
            self.scroll_offset = self.cursor_line;
            return;
        }

        // Scroll down until cursor fits in view
        while (rows_above >= visible_lines and self.scroll_offset < self.cursor_line) {
            if (log.getLine(self.scroll_offset)) |ln| {
                const r = rowCountFor(self, ln.text, content_width);
                rows_above -|= r;
            }
            self.scroll_offset += 1;
        }
    }
};

const GutterContentWidths = struct { gutter: usize, content: usize };

fn computePrefixLenFor(text: []const u8) usize {
    if (std.mem.indexOf(u8, text, ": ")) |ci| {
        if (ci < 24) return ci + 2;
    }
    return 0;
}

fn computeGutterAndContentWidth(self: *App, win: vaxis.Window, log: *const LogBuffer, start_line: usize, visible_lines: u16) GutterContentWidths {
    const ts_width: usize = if (self.show_timestamps) 9 else 0;
    var max_prefix: usize = 0;
    var i = start_line;
    var sampled: u16 = 0;
    while (log.getLine(i)) |line| : (i += 1) {
        const maybe_s = stripAnsiAlloc(self.allocator, line.text) catch null;
        const t = if (maybe_s) |s| s else line.text;
        const p = computePrefixLenFor(t);
        if (p > max_prefix) max_prefix = p;
        if (maybe_s) |s| self.allocator.free(s);
        sampled += 1;
        if (sampled >= visible_lines) break;
    }
    const gutter = @min(@as(usize, win.width), ts_width + max_prefix);
    const content = if (gutter >= win.width) 0 else @as(usize, win.width) - gutter;
    return .{ .gutter = gutter, .content = content };
}

// Strip ANSI escape sequences (CSI/OSC and related) for display in the TUI.
// This avoids rendering raw sequences like "[31m" in the log pane. We do not
// mutate or re-write the underlying stored logs; this is a view concern only.
fn stripAnsiAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == 0x1b) { // ESC
            if (i + 1 >= input.len) break;
            const n = input[i + 1];
            switch (n) {
                '[' => { // CSI
                    i += 2;
                    while (i < input.len) : (i += 1) {
                        const b = input[i];
                        if (b >= 0x40 and b <= 0x7E) { // final byte
                            i += 1;
                            break;
                        }
                    }
                    continue;
                },
                ']' => { // OSC terminated by BEL or ST (ESC \\)
                    i += 2;
                    while (i < input.len) : (i += 1) {
                        if (input[i] == 0x07) { // BEL
                            i += 1;
                            break;
                        }
                        if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                            i += 2; // ST
                            break;
                        }
                    }
                    continue;
                },
                'P', 'X', '^', '_' => { // DCS/PM/APC terminated by ST
                    i += 2;
                    while (i < input.len) : (i += 1) {
                        if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                            i += 2;
                            break;
                        }
                    }
                    continue;
                },
                else => {
                    // Simple two-byte sequences like ESC=, ESC>
                    i += 2;
                    continue;
                },
            }
        }
        if (c != '\r') try out.append(allocator, c);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

const LogLevel = enum { debug, info, warning, @"error" };

fn containsIgnoreCaseInRange(haystack: []const u8, start: usize, end_excl: usize, needle: []const u8) bool {
    const end = @min(end_excl, haystack.len);
    var i: usize = start;
    while (i + needle.len <= end) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn detectLevel(line: []const u8) ?LogLevel {
    const check_len = @min(line.len, 100);
    if (containsIgnoreCaseInRange(line, 0, check_len, "error") or
        containsIgnoreCaseInRange(line, 0, check_len, "[err]") or
        containsIgnoreCaseInRange(line, 0, check_len, " err "))
        return .@"error";
    if (containsIgnoreCaseInRange(line, 0, check_len, "warn") or
        containsIgnoreCaseInRange(line, 0, check_len, "[wrn]"))
        return .warning;
    if (containsIgnoreCaseInRange(line, 0, check_len, "info") or
        containsIgnoreCaseInRange(line, 0, check_len, "[inf]"))
        return .info;
    if (containsIgnoreCaseInRange(line, 0, check_len, "debug") or
        containsIgnoreCaseInRange(line, 0, check_len, "[dbg]"))
        return .debug;
    return null;
}

fn formatHms(buf: *[9]u8, ts_ms: i64) []const u8 {
    // Format as HH:MM:SS␠ (9 bytes)
    const total_ms: u64 = if (ts_ms > 0) @as(u64, @intCast(ts_ms)) else 0;
    const total_s: u64 = total_ms / 1000;
    const sec_in_day: u64 = 24 * 60 * 60;
    const s_day = total_s % sec_in_day;
    const h: u8 = @intCast((s_day / 3600) % 24);
    const m: u8 = @intCast((s_day / 60) % 60);
    const s: u8 = @intCast(s_day % 60);
    buf.* = .{
        '0' + @as(u8, h / 10), '0' + @as(u8, h % 10), ':',
        '0' + @as(u8, m / 10), '0' + @as(u8, m % 10), ':',
        '0' + @as(u8, s / 10), '0' + @as(u8, s % 10), ' ',
    };
    return buf[0..9];
}

fn asciiEqIgnoreCase(a: u8, b: u8) bool {
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and asciiEqIgnoreCase(haystack[i + j], needle[j])) : (j += 1) {}
        if (j == needle.len) return i;
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCase(haystack, needle) != null;
}

fn passesMinLevel(text: []const u8, min: LogLevel) bool {
    if (detectLevel(text)) |lvl| {
        const order = struct {
            fn ord(l: LogLevel) u8 {
                return switch (l) {
                    .debug => 0,
                    .info => 1,
                    .warning => 2,
                    .@"error" => 3,
                };
            }
        };
        return order.ord(lvl) >= order.ord(min);
    }
    // No detectable level counts as info
    const assumed: LogLevel = .info;
    const order = struct {
        fn ord(l: LogLevel) u8 {
            return switch (l) {
                .debug => 0,
                .info => 1,
                .warning => 2,
                .@"error" => 3,
            };
        }
    };
    return order.ord(assumed) >= order.ord(min);
}

fn passesViewFilters(self: *App, raw: []const u8) bool {
    // Sanitize for tests and matching
    const maybe_s = stripAnsiAlloc(self.allocator, raw) catch null;
    const text = if (maybe_s) |s| s else raw;
    const ok = blk: {
        if (self.filter_min_level) |lvl| {
            if (!passesMinLevel(text, lvl)) break :blk false;
        }
        if (self.filter_len > 0) {
            const p = self.filter_buf[0..self.filter_len];
            if (!containsIgnoreCase(text, p)) break :blk false;
        }
        break :blk true;
    };
    if (maybe_s) |s| self.allocator.free(s);
    return ok;
}

fn hasMatchInLine(self: *App, line_text: []const u8) bool {
    const q = self.search_buf[0..self.search_len];
    if (q.len == 0) return false;
    const maybe_sanitized = stripAnsiAlloc(self.allocator, line_text) catch null;
    const text = if (maybe_sanitized) |s| s else line_text;
    const result = containsIgnoreCase(text, q);
    if (maybe_sanitized) |s| self.allocator.free(s);
    return result;
}

fn findNextMatch(self: *App, start_line: usize, forward: bool) ?usize {
    const log = &self.manager.processes[self.selected].log;
    const total = log.lineCount();
    if (total == 0 or self.search_len == 0) return null;
    if (forward) {
        var i: usize = start_line;
        while (i < total) : (i += 1) {
            if (log.getLine(i)) |l| if (hasMatchInLine(self, l.text)) return i;
        }
    } else {
        var i: isize = @intCast(start_line);
        while (i >= 0) : (i -= 1) {
            const ui: usize = @intCast(i);
            if (log.getLine(ui)) |l| if (hasMatchInLine(self, l.text)) return ui;
        }
    }
    return null;
}

fn countMatches(self: *App) usize {
    const log = &self.manager.processes[self.selected].log;
    const total = log.lineCount();
    if (self.search_len == 0) return 0;
    var hits: usize = 0;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        if (log.getLine(i)) |l| {
            if (hasMatchInLine(self, l.text)) hits += 1;
        }
    }
    return hits;
}

fn colorIndexForString(s: []const u8) u8 {
    // Deterministic but varied mapping to palette indexes 2..7
    var h: u32 = 2166136261;
    for (s) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return @intCast(2 + (h % 6));
}

fn isContinuationLine(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[0] == ' ' or text[0] == '\t') return true;
    if (text.len >= 3 and std.ascii.eqlIgnoreCase(text[0..3], "at ")) return true;
    if (text.len >= 7 and std.ascii.eqlIgnoreCase(text[0..7], "caused ")) return true;
    if (text.len >= 9 and std.ascii.eqlIgnoreCase(text[0..9], "traceback")) return true;
    return false;
}

fn findGroupEndFor(self: *App, start: usize) usize {
    const log = &self.manager.processes[self.selected].log;
    var i = start + 1;
    while (log.getLine(i)) |l| : (i += 1) {
        const maybe_s = stripAnsiAlloc(self.allocator, l.text) catch null;
        const t = if (maybe_s) |s| s else l.text;
        const cont = isContinuationLine(t);
        if (maybe_s) |s| self.allocator.free(s);
        if (!cont) break;
    }
    return i - 1;
}

fn findGroupStart(self: *App, index: usize) usize {
    const log = &self.manager.processes[self.selected].log;
    if (index == 0) return 0;
    var i = index;
    while (i > 0) {
        const prev_i = i - 1;
        if (log.getLine(prev_i)) |l| {
            const maybe_s = stripAnsiAlloc(self.allocator, l.text) catch null;
            const t = if (maybe_s) |s| s else l.text;
            const cont = isContinuationLine(t);
            if (maybe_s) |s| self.allocator.free(s);
            if (!cont) break;
            i = prev_i;
        } else break;
    }
    return i;
}

fn findNextImportant(self: *App, start_line: usize, forward: bool) ?usize {
    const log = &self.manager.processes[self.selected].log;
    const total = log.lineCount();
    if (total == 0) return null;
    if (forward) {
        var i: usize = start_line;
        while (i < total) : (i += 1) {
            if (log.getLine(i)) |l| {
                const maybe_s = stripAnsiAlloc(self.allocator, l.text) catch null;
                const t = if (maybe_s) |s| s else l.text;
                const ok = if (detectLevel(t)) |lvl| (lvl == .@"error" or lvl == .warning) else false;
                if (maybe_s) |s| self.allocator.free(s);
                if (ok) return i;
            }
        }
    } else {
        var i: isize = @intCast(start_line);
        while (i >= 0) : (i -= 1) {
            const ui: usize = @intCast(i);
            if (log.getLine(ui)) |l| {
                const maybe_s = stripAnsiAlloc(self.allocator, l.text) catch null;
                const t = if (maybe_s) |s| s else l.text;
                const ok = if (detectLevel(t)) |lvl| (lvl == .@"error" or lvl == .warning) else false;
                if (maybe_s) |s| self.allocator.free(s);
                if (ok) return ui;
            }
        }
    }
    return null;
}

fn extractJsonMessage(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    // Very small heuristic: find "message":"..." and unescape common escapes
    const key = "\"message\":";
    const pos_opt = std.mem.indexOf(u8, text, key);
    if (pos_opt == null) return null;
    var i: usize = pos_opt.? + key.len;
    // Skip whitespace and optional quotes
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    if (i >= text.len or text[i] != '"') return null;
    i += 1;
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '"') break;
        if (c == '\\' and i + 1 < text.len) {
            i += 1;
            const e = text[i];
            const mapped: u8 = switch (e) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                else => e,
            };
            try out.append(allocator, mapped);
        } else try out.append(allocator, c);
    }
    return try out.toOwnedSlice(allocator);
}

fn printWithAnsi(self: *App, win: vaxis.Window, text: []const u8, base: vaxis.Style, col: u16, row: u16, max_cols: u16) bool {
    _ = self; // not currently used, reserved for future theme-aware mapping
    var style = base;
    var i: usize = 0;
    var used: u16 = 0;
    var seg_start: usize = 0;
    while (i < text.len and used < max_cols) {
        const c = text[i];
        if (c == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            // Flush pending segment
            if (i > seg_start and used < max_cols) {
                const take = @min(@as(usize, max_cols - used), i - seg_start);
                _ = win.printSegment(.{ .text = text[seg_start .. seg_start + take], .style = style }, .{ .col_offset = col + used, .row_offset = row });
                used += @intCast(take);
            }
            // Parse CSI ... m
            i += 2;
            var num: u16 = 0;
            var have_num = false;
            while (i < text.len) : (i += 1) {
                const b = text[i];
                if (b >= '0' and b <= '9') {
                    have_num = true;
                    num = num * 10 + @as(u16, @intCast(b - '0'));
                    continue;
                }
                if (b == ';') {
                    if (have_num) {
                        applySgr(&style, num);
                        have_num = false;
                        num = 0;
                    }
                    continue;
                }
                if (b == 'm') {
                    if (have_num) {
                        applySgr(&style, num);
                    }
                    i += 1;
                    break;
                }
            }
            seg_start = i;
            continue;
        }
        i += 1;
    }
    if (used < max_cols and i > seg_start) {
        const take = @min(@as(usize, max_cols - used), i - seg_start);
        _ = win.printSegment(.{ .text = text[seg_start .. seg_start + take], .style = style }, .{ .col_offset = col + used, .row_offset = row });
        used += @intCast(take);
    }
    return true;
}

fn applySgr(style: *vaxis.Style, code: u16) void {
    switch (code) {
        0 => style.* = .{},
        1 => style.bold = true,
        2 => {}, // ignore dim
        4 => {}, // ignore underline not supported in vaxis style here
        39 => {},
        30...37 => style.fg = .{ .index = @intCast(code - 30 + 8) },
        90...97 => style.fg = .{ .index = @intCast(code - 90 + 8) },
        else => {},
    }
}

fn exportFilteredSnapshot(self: *App) !void {
    const log = &self.manager.processes[self.selected].log;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(self.allocator);
    var i: usize = 0;
    while (i < log.lineCount()) : (i += 1) {
        if (log.getLine(i)) |l| {
            if (!passesViewFilters(self, l.text)) continue;
            try out.appendSlice(self.allocator, l.text);
            try out.append(self.allocator, '\n');
        }
    }
    const dir = std.fs.cwd();
    var path_buf: [128]u8 = undefined;
    const ts = std.time.milliTimestamp();
    const fname = std.fmt.bufPrint(&path_buf, "/tmp/deck-snapshot-{d}.log", .{ts}) catch return;
    var f = try dir.createFile(fname, .{ .truncate = true });
    defer f.close();
    _ = try f.write(out.items);
}
