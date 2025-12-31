# zrep

A high-performance grep implementation written in Zig, inspired by [ripgrep](https://github.com/BurntSushi/ripgrep).

zrep recursively searches directories for a regex pattern while respecting `.gitignore` files, with colorized output and parallel file searching.

## Features

- **Fast literal search** using SIMD-accelerated byte matching
- **Literal string optimization** - extracts literals from regex patterns for fast pre-filtering
- **Basic regex support** with `.`, `*`, `+`, `?`, `|`, and character classes
- **Word boundary matching** with `-w` flag
- **Parallel file searching** using a thread pool across multiple CPU cores
- **Gitignore support** - automatically respects `.gitignore` patterns
- **Glob file filtering** with `-g` flag for include/exclude patterns
- **Binary file detection** - automatically skips binary files
- **Colorized output** - file paths, line numbers, and matches are highlighted
- **Smart output formatting** - auto-detects TTY vs pipe for heading/color defaults
- **Memory-mapped I/O** for efficient large file handling
- **Small binary** - ~500KB compared to ripgrep's 6.5MB

## Installation

### Homebrew (macOS)

```bash
brew install jmwoliver/tap/zrep
```

### Building from source

Requires [Zig](https://ziglang.org/) 0.15.0 or later.

```bash
# Clone the repository
git clone https://github.com/jmwoliver/zrep.git
cd zrep

# Build release version
zig build -Doptimize=ReleaseFast

# Binary is at ./zig-out/bin/zrep
```

### Running tests

```bash
zig build test
```

## Usage

```
zrep [OPTIONS] PATTERN [PATH ...]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `PATTERN` | The pattern to search for (literal string or regex) |
| `PATH` | Files or directories to search (default: current directory) |

### Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-i, --ignore-case` | Case insensitive search |
| `-w, --word-regexp` | Match whole words only |
| `-n, --line-number` | Show line numbers (default: on) |
| `-c, --count` | Only show count of matching lines per file |
| `-l, --files-with-matches` | Only show filenames containing matches |
| `-g, --glob GLOB` | Include/exclude files or directories (supports `!` for negation) |
| `--no-ignore` | Don't respect `.gitignore` files |
| `--hidden` | Search hidden files and directories |
| `-j, --threads NUM` | Number of threads to use (default: CPU count) |
| `-d, --max-depth NUM` | Maximum directory depth to search |
| `--color MODE` | Color mode: `auto`, `always`, `never` (default: `auto`) |
| `--heading` | Group matches by file with headers (default for TTY) |
| `--no-heading` | Print `file:line:content` format (default for pipes) |

### Examples

```bash
# Search for "TODO" in current directory
zrep TODO

# Search in specific directory
zrep "function" src/

# Case-insensitive search
zrep -i "error" logs/

# Word boundary matching (matches "test" but not "testing" or "contest")
zrep -w "test" src/

# Count matches per file
zrep -c "import" .

# List files containing matches
zrep -l "TODO" .

# Force colored output (useful when piping)
zrep --color always "pattern" | less -R

# Search with regex
zrep "fn.*\(" src/       # Find function definitions
zrep "[0-9]+" data/      # Find numbers
zrep "foo|bar" .         # Find "foo" or "bar"

# File filtering with globs
zrep "fn main" -g '*.zig'                  # Only search .zig files
zrep "import" -g '*.zig' -g '!*_test.zig'  # Exclude test files
zrep "TODO" -g '!vendor/'                  # Exclude vendor directory
zrep "config" -g '*.json' -g '*.yaml'      # Search multiple file types

# Output format control
zrep --heading "pattern" .      # Grouped output with file headers
zrep --no-heading "pattern" .   # Flat file:line:content format

# Ignore gitignore and search everything
zrep --no-ignore "secret" .

# Search hidden files
zrep --hidden "config" .

# Limit search depth
zrep -d 2 "config" .

# Control thread count
zrep -j 1 "pattern" .    # Single-threaded (useful for debugging)
zrep -j 8 "pattern" .    # Use 8 threads
```

## How It Works

### SIMD-Accelerated Search

zrep uses Zig's `@Vector` types for SIMD-accelerated byte searching:

```zig
const Vec = @Vector(16, u8);  // 128-bit vectors on ARM64

pub fn findByte(haystack: []const u8, needle: u8) ?usize {
    const needle_vec: Vec = @splat(needle);
    // Process 16 bytes at a time
    while (i + 16 <= haystack.len) : (i += 16) {
        const chunk: Vec = haystack[i..][0..16].*;
        const matches = chunk == needle_vec;
        if (@reduce(.Or, matches)) {
            return i + @ctz(@as(u16, @bitCast(matches)));
        }
    }
    // ... scalar fallback
}
```

### Literal String Optimization

Before applying regex matching, zrep extracts literal substrings from patterns to enable fast pre-filtering:

```zig
// For pattern "hello.*world", extract "hello" as a prefix literal
// Use SIMD to quickly find candidates, then apply full regex only on matches
const info = literal.extractLiteral(pattern);

switch (info.position) {
    .prefix => {
        // Most efficient: literal must appear at line start
        // Example: "hello.*" -> scan for "hello" at position 0
    },
    .suffix => {
        // Second best: literal must appear at line end
        // Example: ".*_PLATFORM" -> scan for "_PLATFORM" at end
    },
    .inner => {
        // Fallback: literal appears somewhere in the match
        // Example: "[a-z]+_FOO_[a-z]+" -> scan for "_FOO_"
    },
}
```

The literal extraction uses a scoring system to select the most selective literal:
- Longer literals score higher (better filtering)
- Rare characters (`_`, `Q`, `X`, `Z`, digits) score higher than common letters
- This enables fast rejection of non-matching lines before expensive regex evaluation

### Regex Engine

zrep implements a Thompson NFA-based regex engine supporting:
- `.` - any character (except newline)
- `*` - zero or more
- `+` - one or more
- `?` - zero or one
- `|` - alternation
- `[abc]` - character classes
- `[^abc]` - negated character classes
- `[a-z]` - character ranges
- `\n`, `\t`, `\r` - escape sequences

### File I/O Strategy

| Scenario | Strategy |
|----------|----------|
| Files < 128MB | Memory-mapped I/O (zero-copy) |
| Larger files | Buffered reading (64KB chunks) |
| stdin | Buffered reading |

### Parallelism

zrep uses parallel directory traversal for concurrent file searching:

```zig
// Parallel walker spawns worker threads for directory traversal
const parallel_walker = try ParallelWalker.init(allocator, num_threads, options);
defer parallel_walker.deinit();

// Workers use a shared deque for work stealing
// Each thread processes directories and searches files concurrently
parallel_walker.walk(root_path, matcher, output);
```

Key characteristics:
- **Parallel traversal** - Directory walking and file searching happen concurrently
- **Work stealing** - Threads use a deque to balance work dynamically
- **Configurable** - Use `-j N` to control thread count (defaults to CPU core count)
- **Sorted output** - Results are collected and sorted for consistent ordering

## Project Structure

```
zrep/
├── build.zig             # Build configuration
├── build.zig.zon         # Package manifest
├── src/
│   ├── main.zig          # CLI entry point and argument parsing
│   ├── simd.zig          # SIMD byte/substring search
│   ├── regex.zig         # Thompson NFA regex engine
│   ├── literal.zig       # Literal string extraction for optimization
│   ├── matcher.zig       # Pattern matching coordinator
│   ├── walker.zig        # Directory traversal and binary detection
│   ├── parallel_walker.zig # Parallel directory traversal
│   ├── reader.zig        # File I/O (mmap + buffered)
│   ├── gitignore.zig     # Gitignore and glob pattern parsing
│   ├── output.zig        # Colorized output formatting
│   └── deque.zig         # Double-ended queue for work distribution
├── tests/                # Integration tests
└── bench/
    └── run_benchmarks.sh # Benchmark script
```

## Comparison with ripgrep

### Feature Matrix

| Feature | zrep | ripgrep |
|---------|------|---------|
| Literal search speed | ✓ Faster (small dirs) | ✓ Faster (large dirs) |
| Full PCRE2 regex | ✗ Basic only | ✓ Full support |
| Unicode support | ✗ ASCII only | ✓ Full Unicode |
| Binary file detection | ✓ NUL-byte based | ✓ More sophisticated |
| Word boundary matching | ✓ `-w` flag | ✓ `-w` flag or `\b` |
| File glob filtering | ✓ `-g` flag | ✓ `-g` flag |
| Compressed file search | ✗ No | ✓ Yes |
| JSON output | ✗ No | ✓ Yes |
| Replace mode | ✗ No | ✓ Yes |
| Context lines (-A/-B/-C) | ✗ No | ✓ Yes |
| Multiline matching | ✗ No | ✓ Yes |
| Binary size | ~500 KB | ~6.5 MB |

### What zrep Supports

Can use zrep when:

```bash
# Simple literal searches in your project
zrep "TODO" src/
zrep "console.log" .
zrep "import React" components/

# Case-insensitive literal searches
zrep -i "error" logs/

# Word boundary matching
zrep -w "test" src/          # Matches "test" but not "testing"
zrep -w "main" .             # Find exact "main" word

# Basic regex patterns
zrep "fn.*\(" src/           # Function definitions
zrep "[0-9]+" data.txt       # Numbers
zrep "foo|bar" .             # Alternation
zrep "test_.*.zig" src/      # Wildcards

# File filtering
zrep "TODO" -g '*.py'        # Only Python files
zrep "import" -g '!vendor/'  # Exclude vendor directory

# Counting matches
zrep -c "TODO" .

# Finding files with matches
zrep -l "FIXME" .
```

### When to Use ripgrep Instead

Use ripgrep for these **unsupported patterns**:

```bash
# Character class shortcuts - NOT SUPPORTED
rg '\d{3}-\d{4}' .           # Phone numbers (digits)
rg '\w+@\w+\.\w+' .          # Email-like patterns
rg '\s+' .                   # Whitespace
# zrep alternative: use explicit classes
zrep '[0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]' .
zrep '[a-zA-Z0-9]+@[a-zA-Z0-9]+' .

# Quantifier ranges {n,m} - NOT SUPPORTED
rg 'a{2,4}' .                # 2 to 4 'a's
rg '.{10,}' .                # 10+ characters
# zrep has no equivalent

# Lookahead/lookbehind - NOT SUPPORTED  
rg '(?<=\$)\d+' .            # Numbers after $
rg 'foo(?=bar)' .            # foo followed by bar
# zrep has no equivalent

# Non-greedy quantifiers - NOT SUPPORTED
rg '".*?"' .                 # Shortest quoted string
# zrep's .* is always greedy

# Backreferences - NOT SUPPORTED
rg '(\w+)\s+\1' .            # Repeated words
# zrep has no equivalent

# Unicode patterns - NOT SUPPORTED
rg '[\p{Greek}]+' .          # Greek letters
rg '\p{Emoji}' .             # Emoji characters
# zrep is ASCII-only

# Multiline patterns - NOT SUPPORTED
rg -U 'start.*?end' .        # Match across lines
# zrep matches line-by-line only

# Context lines - NOT SUPPORTED
rg -A 3 -B 2 'error' .       # Show surrounding lines
# zrep has no equivalent

# Search in compressed files - NOT SUPPORTED
rg -z 'pattern' file.gz
# zrep cannot read compressed files

# Replace mode - NOT SUPPORTED
rg 'old' --replace 'new' .
# zrep is search-only

# JSON output for tooling - NOT SUPPORTED
rg --json 'pattern' .
# zrep outputs text only

# Binary file handling - NOT SUPPORTED
rg --binary 'pattern' binary.exe
# zrep may produce garbled output on binary files

# Very large codebases (90k+ files)
rg 'pattern' ~/linux         # ripgrep is ~1.5x faster here
```

### Quick Reference: Regex Support

| Pattern | zrep | ripgrep | Example |
|---------|------|---------|---------|
| Literal text | ✓ | ✓ | `hello` |
| Any character | ✓ `.` | ✓ | `h.llo` → hello, hallo |
| Zero or more | ✓ `*` | ✓ | `ab*c` → ac, abc, abbc |
| One or more | ✓ `+` | ✓ | `ab+c` → abc, abbc |
| Optional | ✓ `?` | ✓ | `colou?r` → color, colour |
| Alternation | ✓ `\|` | ✓ | `cat\|dog` |
| Character class | ✓ `[abc]` | ✓ | `[aeiou]` |
| Negated class | ✓ `[^abc]` | ✓ | `[^0-9]` |
| Range | ✓ `[a-z]` | ✓ | `[A-Za-z]` |
| Escape sequences | ✓ `\n\t\r` | ✓ | `line1\nline2` |
| Word boundary | ✓ `-w` flag | ✓ `-w` or `\b` | `zrep -w "word"` |
| Digit | ✗ | ✓ `\d` | `\d+` |
| Word char | ✗ | ✓ `\w` | `\w+` |
| Whitespace | ✗ | ✓ `\s` | `\s+` |
| Quantifier range | ✗ | ✓ `{n,m}` | `a{2,4}` |
| Non-greedy | ✗ | ✓ `*?` `+?` | `".*?"` |
| Lookahead | ✗ | ✓ `(?=)` | `foo(?=bar)` |
| Lookbehind | ✗ | ✓ `(?<=)` | `(?<=\$)\d+` |
| Backreference | ✗ | ✓ `\1` | `(\w+)\s+\1` |
| Named groups | ✗ | ✓ `(?P<name>)` | `(?P<word>\w+)` |
| Unicode classes | ✗ | ✓ `\p{L}` | `\p{Greek}` |

## Why Zig?

zrep demonstrates several Zig advantages for systems programming:

1. **Explicit SIMD** - `@Vector` provides portable SIMD without relying on autovectorization
2. **No hidden allocations** - All memory allocation is explicit and controllable
3. **No garbage collector** - Predictable performance with zero GC pauses
4. **Compile-time execution** - `comptime` enables zero-cost abstractions
5. **Small binaries** - No runtime overhead

## Areas of Improvement

- [ ] Full Unicode support
- [ ] More regex features (`\d`, `\w`, `\s`, `{n,m}`, lookahead, etc.)
- [ ] Context lines (`-A`, `-B`, `-C` flags)
- [ ] JSON output format
- [ ] Replace mode (`--replace`)
- [ ] Compressed file search (`.gz`, `.zip`)
- [ ] More sophisticated binary file detection

## License

MIT License - see LICENSE file for details.

## Acknowledgments

- [ripgrep](https://github.com/BurntSushi/ripgrep) by Andrew Gallant - the gold standard for grep tools
- [BurntSushi's blog post](https://blog.burntsushi.net/ripgrep/) explaining ripgrep's design decisions

