const std = @import("std");
const vaxis = @import("vaxis");
const proc = @import("process.zig");
const LogBuffer = @import("buffer.zig").LogBuffer;

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

    tty_buf: [4096]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, manager: *proc.ProcessManager) !*App {
        const self = try allocator.create(App);
        self.* = App{
            .manager = manager,
            .allocator = allocator,
            .vx = undefined,
            .tty = undefined,
        };
        self.tty = try vaxis.Tty.init(&self.tty_buf);
        self.vx = try vaxis.Vaxis.init(allocator, .{});
        return self;
    }

    pub fn deinit(self: *App) void {
        self.manager.killAll();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
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
        try self.vx.queryTerminal(self.tty.writer(), 100 * std.time.ns_per_ms);
        try self.vx.setMouseMode(self.tty.writer(), true);
        try self.vx.subscribeToColorSchemeUpdates(self.tty.writer());
        try self.vx.queryColor(self.tty.writer(), .bg);

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
            try self.vx.render(self.tty.writer());

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
            win.writeCell(sidebar_width, @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = .{ .fg = .{ .index = 8 } },
            });
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
                _ = win.printSegment(.{ .text = "▶", .style = .{ .fg = .{ .index = 6 } } }, .{ .col_offset = 0, .row_offset = row });
            }

            // Status dot
            _ = win.printSegment(.{ .text = "●", .style = .{ .fg = status_color } }, .{ .col_offset = 2, .row_offset = row });

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

        var row: u16 = 2;
        var line_idx = start_line;
        while (line_idx < total_lines and row < height - 1) : (line_idx += 1) {
            if (log.getLine(line_idx)) |line| {
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
                    
                const style: vaxis.Style = if (is_selected)
                    .{ .bg = visual_bg }
                else if (is_cursor)
                    .{ .bg = cursor_bg }
                else
                    .{};

                // Expand marked lines to wrap across multiple rows
                if ((is_selected or is_cursor) and line.text.len > width) {
                    var text_offset: usize = 0;
                    while (text_offset < line.text.len and row < height - 1) {
                        const remaining = line.text.len - text_offset;
                        const chunk_len = @min(remaining, width);
                        _ = win.printSegment(.{
                            .text = line.text[text_offset .. text_offset + chunk_len],
                            .style = style,
                        }, .{ .col_offset = start_col, .row_offset = row });
                        text_offset += chunk_len;
                        row += 1;
                    }
                } else {
                    const max_len = @min(line.text.len, width);
                    _ = win.printSegment(.{
                        .text = line.text[0..max_len],
                        .style = style,
                    }, .{ .col_offset = start_col, .row_offset = row });
                    row += 1;
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
        const bar_style: vaxis.Style = .{ .reverse = true };

        // Fill background with reverse video
        for (0..width) |col| {
            win.writeCell(@intCast(col), row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = bar_style,
            });
        }

        const help = if (self.visual_mode)
            " v/Esc:exit visual  j/k:select  y:copy "
        else if (self.focus_on_logs)
            " h/Esc:back  j/k:nav  v:visual  y:copy  g/G:top/end "
        else
            " q:quit  j/k:select  l/Enter:logs  r:restart  x:kill  v:visual  y:copy ";
        _ = win.printSegment(.{
            .text = help,
            .style = bar_style,
        }, .{ .col_offset = 0, .row_offset = row });

        // Right side: line count + scroll indicator
        if (self.manager.processes.len > 0) {
            const log = &self.manager.processes[self.selected].log;
            var buf: [48]u8 = undefined;
            const scroll_indicator = if (self.auto_scroll) "↓" else "•";
            const count_str = std.fmt.bufPrint(&buf, "{s} {d} lines ", .{ scroll_indicator, log.lineCount() }) catch return;
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

        // Scroll up if cursor is above visible area
        if (self.cursor_line < self.scroll_offset) {
            self.scroll_offset = self.cursor_line;
        }
        // Scroll down if cursor is below visible area
        else if (self.cursor_line >= self.scroll_offset + visible_lines) {
            self.scroll_offset = self.cursor_line - visible_lines + 1;
        }
    }
};
