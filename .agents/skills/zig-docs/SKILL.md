---
name: zig-docs
description: Looks up Zig standard library and dependency documentation using zigdoc. Use when asked about Zig APIs, symbols, types, or how to use std library functions.
---

# Zig Documentation Lookup

Use the `zigdoc` command to look up documentation for Zig symbols.

## Usage

```bash
zigdoc <symbol>
```

## Examples

```bash
# Standard library
zigdoc std.ArrayList
zigdoc std.mem.Allocator
zigdoc std.http.Server
zigdoc std.fs.File

# Imported modules from build.zig
zigdoc vaxis.Window
zigdoc zeit.timezone.Posix
```

## Capabilities

- View documentation for any public symbol in the Zig standard library
- Access documentation for imported modules from your build.zig
- Shows symbol location, category, and signature
- Displays doc comments and members
- Follows aliases to implementation

## When to Use

- User asks "how do I use std.ArrayList?"
- User needs to understand a Zig type's methods or fields
- Looking up function signatures in std library
- Exploring available members of a type
