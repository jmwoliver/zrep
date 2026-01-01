# zipgrep

A high-performance grep implementation written in Zig, inspired by [ripgrep](https://github.com/BurntSushi/ripgrep).

zipgrep recursively searches directories for a regex pattern while respecting `.gitignore` files, with colorized output and parallel file searching.

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
brew install jmwoliver/tap/zipgrep
```

### Building from source

Requires [Zig](https://ziglang.org/) 0.15.0 or later.

```bash
# Clone the repository
git clone https://github.com/jmwoliver/zipgrep.git
cd zipgrep

# Build release version
zig build -Doptimize=ReleaseFast

# Binary is at ./zig-out/bin/zg
```

### Running tests

```bash
zig build test
```

## Usage

```
zg [OPTIONS] PATTERN [PATH ...]
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
zg TODO

# Search in specific directory
zg "function" src/

# Case-insensitive search
zg -i "error" logs/

# Word boundary matching (matches "test" but not "testing" or "contest")
zg -w "test" src/

# Count matches per file
zg -c "import" .

# List files containing matches
zg -l "TODO" .

# Force colored output (useful when piping)
zg --color always "pattern" | less -R

# Search with regex
zg "fn.*\(" src/       # Find function definitions
zg "[0-9]+" data/      # Find numbers
zg "foo|bar" .         # Find "foo" or "bar"

# File filtering with globs
zg "fn main" -g '*.zig'                  # Only search .zig files
zg "import" -g '*.zig' -g '!*_test.zig'  # Exclude test files
zg "TODO" -g '!vendor/'                  # Exclude vendor directory
zg "config" -g '*.json' -g '*.yaml'      # Search multiple file types

# Output format control
zg --heading "pattern" .      # Grouped output with file headers
zg --no-heading "pattern" .   # Flat file:line:content format

# Ignore gitignore and search everything
zg --no-ignore "secret" .

# Search hidden files
zg --hidden "config" .

# Limit search depth
zg -d 2 "config" .

# Control thread count
zg -j 1 "pattern" .    # Single-threaded (useful for debugging)
zg -j 8 "pattern" .    # Use 8 threads
```

## How It Works

### SIMD-Accelerated Search

zipgrep uses Zig's `@Vector` types for SIMD-accelerated byte searching:

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

Before applying regex matching, zipgrep extracts literal substrings from patterns to enable fast pre-filtering:

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

zipgrep implements a Thompson NFA-based regex engine supporting:
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

zipgrep uses parallel directory traversal for concurrent file searching:

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
zipgrep/
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

| Feature | zipgrep | ripgrep |
|---------|--------|---------|
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

### What zipgrep Supports

Can use zipgrep when:

```bash
# Simple literal searches in your project
zg "TODO" src/
zg "console.log" .
zg "import React" components/

# Case-insensitive literal searches
zg -i "error" logs/

# Word boundary matching
zg -w "test" src/          # Matches "test" but not "testing"
zg -w "main" .             # Find exact "main" word

# Basic regex patterns
zg "fn.*\(" src/           # Function definitions
zg "[0-9]+" data.txt       # Numbers
zg "foo|bar" .             # Alternation
zg "test_.*.zig" src/      # Wildcards

# File filtering
zg "TODO" -g '*.py'        # Only Python files
zg "import" -g '!vendor/'  # Exclude vendor directory

# Counting matches
zg -c "TODO" .

# Finding files with matches
zg -l "FIXME" .
```

### When to Use ripgrep Instead

Use ripgrep for these **unsupported patterns**:

```bash
# Character class shortcuts - NOT SUPPORTED
rg '\d{3}-\d{4}' .           # Phone numbers (digits)
rg '\w+@\w+\.\w+' .          # Email-like patterns
rg '\s+' .                   # Whitespace
# zipgrep alternative: use explicit classes
zg '[0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]' .
zg '[a-zA-Z0-9]+@[a-zA-Z0-9]+' .

# Quantifier ranges {n,m} - NOT SUPPORTED
rg 'a{2,4}' .                # 2 to 4 'a's
rg '.{10,}' .                # 10+ characters
# zipgrep has no equivalent

# Lookahead/lookbehind - NOT SUPPORTED
rg '(?<=\$)\d+' .            # Numbers after $
rg 'foo(?=bar)' .            # foo followed by bar
# zipgrep has no equivalent

# Non-greedy quantifiers - NOT SUPPORTED
rg '".*?"' .                 # Shortest quoted string
# zipgrep's .* is always greedy

# Backreferences - NOT SUPPORTED
rg '(\w+)\s+\1' .            # Repeated words
# zipgrep has no equivalent

# Unicode patterns - NOT SUPPORTED
rg '[\p{Greek}]+' .          # Greek letters
rg '\p{Emoji}' .             # Emoji characters
# zipgrep is ASCII-only

# Multiline patterns - NOT SUPPORTED
rg -U 'start.*?end' .        # Match across lines
# zipgrep matches line-by-line only

# Context lines - NOT SUPPORTED
rg -A 3 -B 2 'error' .       # Show surrounding lines
# zipgrep has no equivalent

# Search in compressed files - NOT SUPPORTED
rg -z 'pattern' file.gz
# zipgrep cannot read compressed files

# Replace mode - NOT SUPPORTED
rg 'old' --replace 'new' .
# zipgrep is search-only

# JSON output for tooling - NOT SUPPORTED
rg --json 'pattern' .
# zipgrep outputs text only

# Binary file handling - NOT SUPPORTED
rg --binary 'pattern' binary.exe
# zipgrep may produce garbled output on binary files

# Very large codebases (90k+ files)
rg 'pattern' ~/linux         # ripgrep is ~1.5x faster here
```

### Quick Reference: Regex Support

| Pattern | zipgrep | ripgrep | Example |
|---------|--------|---------|---------|
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
| Word boundary | ✓ `-w` flag | ✓ `-w` or `\b` | `zg -w "word"` |
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

zipgrep demonstrates several Zig advantages for systems programming:

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
