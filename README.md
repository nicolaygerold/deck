# deck

A terminal dashboard for running multiple dev processes with switchable logs.

Like `concurrently`, but with a TUI that lets you switch between process outputs.

## Usage

```bash
# Run multiple commands
deck "bun dev" "cargo watch" "make serve"

# With custom names
deck -n web,api,docs "bun dev" "cargo run" "make docs"
```

## Keybindings

| Key | Action |
|-----|--------|
| `q` / `Ctrl+C` | Quit |
| `j` / `↓` | Select next process |
| `k` / `↑` | Select previous process |
| `1-9` | Jump to process by number |
| `r` | Restart selected process |
| `x` | Kill selected process |
| `g` | Scroll to top |
| `G` | Scroll to bottom (enable auto-scroll) |
| `v` | Enter visual selection mode |
| `y` | Copy logs to clipboard (selection or all) |
| `Esc` | Exit visual mode |
| `Ctrl+D` / `PgDn` | Page down |
| `Ctrl+U` / `PgUp` | Page up |
| Mouse wheel | Scroll logs |

## Building

Requires Zig 0.15+.

```bash
zig build           # Build
zig build run -- "cmd1" "cmd2"  # Run
zig build test      # Test
```

## Install

```bash
zig build -Doptimize=ReleaseFast
cp zig-out/bin/deck ~/.local/bin/
```

## Screenshot

```
┌─ PROCESSES ────────┬── web [running] bun dev ─────────────┐
│ ▶ ● web            │  Starting dev server...              │
│   ● api            │  Compiled in 214ms                   │
│   ● docs           │  Listening on http://localhost:3000  │
│                    │                                      │
├────────────────────┴──────────────────────────────────────┤
│ q:quit j/k:nav r:restart x:kill g/G:top/end    ↓ 3 lines │
└───────────────────────────────────────────────────────────┘
```

## License

MIT
