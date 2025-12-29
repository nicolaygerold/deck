# deck

A terminal dashboard for running multiple dev processes with switchable logs.

Like `concurrently`, but with a TUI that lets you switch between process outputs.

## Usage

### Interactive TUI Mode

```bash
# Run multiple commands
deck "bun dev" "cargo watch" "make serve"

# With custom names
deck -n web,api,docs "bun dev" "cargo run" "make docs"
```

### Daemon Mode (AI-friendly)

Run processes in the background without a TUI:

```bash
# Start processes as a daemon
deck start -n web,api "bun dev" "cargo run"

# View logs for a process
deck logs web
deck logs web --tail=50
deck logs api --head=20

# Stop all daemon processes
deck stop
```

Logs are stored in `~/.local/share/deck/<session>/logs/` while running and cleaned up on stop.

### Sessions

By default, each working directory gets its own isolated session (based on path hash). This allows running multiple decks in parallel from different directories.

```bash
# Run deck in different directories - each gets its own session
cd ~/project-a && deck start -n web,api "bun dev" "cargo run"
cd ~/project-b && deck start -n client,server "npm run dev" "go run ."

# Named sessions for multiple decks in the same directory
deck start -s frontend -n web,api "bun dev" "fastify start"
deck start -s backend -n db,cache "postgres" "redis-server"

# Manage named sessions
deck logs web -s frontend
deck stop -s backend
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

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/nicolaygerold/deck/main/install.sh | sh
```

Or with wget:
```bash
wget -qO- https://raw.githubusercontent.com/nicolaygerold/deck/main/install.sh | sh
```

### From source

Requires **Zig 0.15.2**.

```bash
zig build -Doptimize=ReleaseFast
cp zig-out/bin/deck ~/.local/bin/
```

**Tip:** Use [anyzig](https://github.com/marler8997/anyzig) to automatically manage Zig versions:
```bash
cargo install anyzig  # or: brew install anyzig
anyzig build -Doptimize=ReleaseFast  # auto-downloads correct Zig version
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

---

Built entirely with [Amp](https://ampcode.com).
