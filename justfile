# Run all checks (format, lint, test)
check-all:
    zig fmt --check src/
    zig build test

# Run all checks with fixes applied (format, lint, test)
check-fix:
    zig fmt src/
    zig build test
