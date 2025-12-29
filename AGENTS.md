# Agents

## Commands

- `zig build` - Build the project
- `zig build run` - Run deck
- `zig build test` - Run unit tests
- `zig fmt src/` - Format code
- `just check-all` - Check format and run tests
- `just check-fix` - Fix format and run tests

## Releasing

To create a new release, tag and push:

```bash
git tag v<version>
git push --tags
```

This triggers GitHub Actions to build binaries for all platforms and create a release.

## Project

**deck** - A terminal dashboard for running multiple dev processes with switchable logs.

Uses libvaxis (vxfw) for TUI.

## Testing

Tests are inline in source files using `test` blocks.

### Key principles

- No business logic in tests — assert outcomes, don't re-implement logic
- Minimize mocking — only mock external systems (network, time)
- Test public behavior, not internals
- One concern per test
- Tests must be deterministic and fast
