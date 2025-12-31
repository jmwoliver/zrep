const std = @import("std");

/// Information about an extracted literal from a regex pattern
pub const LiteralInfo = struct {
    /// The extracted literal string (points to pattern_storage)
    literal: []const u8,
    /// Where in the pattern the literal appears
    position: Position,
    /// Minimum characters before this literal can appear (for inner literals)
    min_offset: usize,

    pub const Position = enum {
        prefix, // At start of pattern - most efficient
        suffix, // At end of pattern - second best
        inner, // Middle of pattern - least efficient but still helps
    };
};

/// Extract the best literal from a regex pattern for SIMD pre-filtering.
/// Returns null if no useful literal can be extracted.
///
/// Priority order:
/// 1. Prefix literals (most efficient - can start search there)
/// 2. Suffix literals (second best - search backwards or verify end)
/// 3. Inner literals (still helps - quick reject lines without the literal)
pub fn extractBestLiteral(pattern: []const u8) ?LiteralInfo {
    // Try prefix first (most efficient)
    if (extractLiteralPrefix(pattern)) |prefix| {
        return LiteralInfo{
            .literal = prefix,
            .position = .prefix,
            .min_offset = 0,
        };
    }

    // Try suffix second
    if (extractLiteralSuffix(pattern)) |suffix| {
        return LiteralInfo{
            .literal = suffix,
            .position = .suffix,
            .min_offset = 0,
        };
    }

    // Try inner literals
    return extractBestInnerLiteral(pattern);
}

/// Extract literal prefix from a regex pattern (before any metacharacters)
/// The prefix must be "required" - i.e., not followed by a quantifier that allows zero matches
/// NOTE: This only works for patterns without alternation at the top level, and without escapes
/// For patterns with escapes or alternation, we return null to fall back to suffix/inner extraction
fn extractLiteralPrefix(pattern: []const u8) ?[]const u8 {
    if (pattern.len == 0) return null;

    // Check if pattern contains alternation at top level - can't extract prefix
    // (would need to check if ALL alternatives share the prefix)
    var paren_depth: usize = 0;
    for (pattern) |c| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '|' => {
                if (paren_depth == 0) return null; // Top-level alternation
            },
            else => {},
        }
    }

    var end: usize = 0;
    var i: usize = 0;

    while (i < pattern.len) {
        const c = pattern[i];
        switch (c) {
            // Metacharacters that end literal prefix
            '.', '*', '+', '?', '[', ']', '(', ')', '{', '}', '|', '^', '$' => break,
            '\\' => {
                // Escaped characters are tricky - the literal includes the backslash
                // but the actual match is the escaped char. Stop here.
                break;
            },
            else => {
                // Check if this char is followed by * or ? (makes it optional)
                if (i + 1 < pattern.len and (pattern[i + 1] == '*' or pattern[i + 1] == '?')) {
                    // This char is optional, can't include it in required prefix
                    break;
                }
                end = i + 1;
                i += 1;
            },
        }
    }

    // Need at least 2 characters for useful prefix
    if (end >= 2) {
        return pattern[0..end];
    }
    return null;
}

/// Extract literal suffix from a regex pattern (after any metacharacters)
/// NOTE: For patterns with top-level alternation, returns null
fn extractLiteralSuffix(pattern: []const u8) ?[]const u8 {
    if (pattern.len == 0) return null;

    // Check if pattern contains alternation at top level - can't extract suffix
    var paren_depth: usize = 0;
    for (pattern) |c| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '|' => {
                if (paren_depth == 0) return null; // Top-level alternation
            },
            else => {},
        }
    }

    // Scan backwards from end to find where suffix starts
    var suffix_start: usize = pattern.len;
    var i: usize = pattern.len;

    while (i > 0) {
        i -= 1;
        const c = pattern[i];

        switch (c) {
            // Metacharacters that end the suffix search
            '.', '*', '+', '?', '[', ']', '(', ')', '{', '}', '|', '^', '$' => {
                // Found metachar - suffix starts after it
                suffix_start = i + 1;
                break;
            },
            '\\' => {
                // This is an escape - the actual character is pattern[i+1]
                // Can't use escaped chars in suffix reliably (would need to decode)
                suffix_start = i + 2; // Skip the entire escape sequence
                break;
            },
            else => {
                // Regular character - continue scanning backwards
            },
        }
    }

    // If we scanned all the way back, there's no prefix metachar
    // In that case, the whole pattern is literal (should have been caught by prefix extraction)
    if (i == 0 and suffix_start == pattern.len) {
        return null;
    }

    const suffix_len = pattern.len - suffix_start;

    // Need at least 2 characters for useful suffix
    if (suffix_len >= 2) {
        return pattern[suffix_start..];
    }
    return null;
}

/// Extract the best inner literal from a regex pattern
/// Only extracts literals that are REQUIRED (not followed by * or ?)
/// NOTE: For patterns with top-level alternation, returns null (can't guarantee literal is required)
fn extractBestInnerLiteral(pattern: []const u8) ?LiteralInfo {
    if (pattern.len < 4) return null; // Need room for metachar + literal + metachar

    // Check if pattern contains alternation at top level - can't extract inner literal
    var paren_depth: usize = 0;
    for (pattern) |c| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '|' => {
                if (paren_depth == 0) return null; // Top-level alternation
            },
            else => {},
        }
    }

    var best_literal: ?[]const u8 = null;
    var best_score: u32 = 0;
    var best_min_offset: usize = 0;

    var i: usize = 0;
    var literal_start: ?usize = null;
    var min_chars_before: usize = 0;

    while (i < pattern.len) {
        const c = pattern[i];

        if (isMetachar(c)) {
            // Check if this is * or ? which makes previous element optional
            if (c == '*' or c == '?') {
                // Previous element is optional - remove last char from literal if any
                if (literal_start) |start| {
                    // End literal BEFORE the last character (which is now optional)
                    const end = if (i > 0) i - 1 else i;
                    if (end > start and end - start >= 2) {
                        const lit = pattern[start..end];
                        const score = scoreLiteral(lit);
                        if (score > best_score) {
                            best_score = score;
                            best_literal = lit;
                            best_min_offset = if (min_chars_before > (end - start)) min_chars_before - (end - start) else 0;
                        }
                    }
                    literal_start = null;
                }
                if (min_chars_before > 0) min_chars_before -= 1;
                i += 1;
                continue;
            }

            // End current literal if any (for other metachars)
            if (literal_start) |start| {
                if (i > start and i - start >= 2) {
                    const lit = pattern[start..i];
                    const score = scoreLiteral(lit);
                    if (score > best_score) {
                        best_score = score;
                        best_literal = lit;
                        best_min_offset = if (min_chars_before > (i - start)) min_chars_before - (i - start) else 0;
                    }
                }
                literal_start = null;
            }

            // Update min_chars_before based on metachar
            switch (c) {
                '.' => {
                    min_chars_before += 1; // . matches exactly 1 char
                    i += 1;
                },
                '+' => {
                    // Previous element is now 1+, keep min the same
                    i += 1;
                },
                '[' => {
                    // Character class - skip to closing bracket
                    min_chars_before += 1;
                    i += 1;
                    while (i < pattern.len and pattern[i] != ']') : (i += 1) {}
                    if (i < pattern.len) i += 1; // Skip ']'
                },
                '(' => {
                    // Group - for simplicity, just skip the paren
                    i += 1;
                },
                ')' => {
                    i += 1;
                },
                '|' => {
                    // Alternation - reset everything, can't use literals across alternations reliably
                    literal_start = null;
                    min_chars_before = 0;
                    i += 1;
                },
                '\\' => {
                    // Escape sequence - end any current literal and skip
                    // We can't include escaped chars in literals without decoding them
                    if (literal_start) |start| {
                        if (i > start and i - start >= 2) {
                            const lit = pattern[start..i];
                            const score = scoreLiteral(lit);
                            if (score > best_score) {
                                best_score = score;
                                best_literal = lit;
                                best_min_offset = if (min_chars_before > (i - start)) min_chars_before - (i - start) else 0;
                            }
                        }
                        literal_start = null;
                    }

                    if (i + 1 < pattern.len) {
                        const escaped = pattern[i + 1];
                        switch (escaped) {
                            'd', 'D', 'w', 'W', 's', 'S' => {
                                min_chars_before += 1;
                                i += 2;
                            },
                            'b', 'B' => {
                                // Zero-width assertion
                                i += 2;
                            },
                            else => {
                                // Check if followed by * or ?
                                if (i + 2 < pattern.len and (pattern[i + 2] == '*' or pattern[i + 2] == '?')) {
                                    // This escaped char is optional
                                    i += 2;
                                } else {
                                    // Required escaped char - just skip it, don't include in literal
                                    min_chars_before += 1;
                                    i += 2;
                                }
                            },
                        }
                    } else {
                        i += 1;
                    }
                },
                else => {
                    i += 1;
                },
            }
        } else {
            // Regular character - check if followed by * or ?
            if (i + 1 < pattern.len and (pattern[i + 1] == '*' or pattern[i + 1] == '?')) {
                // This char is optional, end current literal and don't include this char
                if (literal_start) |start| {
                    if (i > start and i - start >= 2) {
                        const lit = pattern[start..i];
                        const score = scoreLiteral(lit);
                        if (score > best_score) {
                            best_score = score;
                            best_literal = lit;
                            best_min_offset = if (min_chars_before > (i - start)) min_chars_before - (i - start) else 0;
                        }
                    }
                    literal_start = null;
                }
                min_chars_before += 1;
                i += 1;
            } else {
                // Required character
                if (literal_start == null) {
                    literal_start = i;
                }
                min_chars_before += 1;
                i += 1;
            }
        }
    }

    // Handle trailing literal
    if (literal_start) |start| {
        if (pattern.len > start and pattern.len - start >= 2) {
            const lit = pattern[start..];
            const score = scoreLiteral(lit);
            if (score > best_score) {
                best_score = score;
                best_literal = lit;
                best_min_offset = if (min_chars_before > (pattern.len - start)) min_chars_before - (pattern.len - start) else 0;
            }
        }
    }

    if (best_literal) |lit| {
        return LiteralInfo{
            .literal = lit,
            .position = .inner,
            .min_offset = best_min_offset,
        };
    }

    return null;
}

/// Check if a character is a regex metacharacter
fn isMetachar(c: u8) bool {
    return switch (c) {
        '.', '*', '+', '?', '[', ']', '(', ')', '{', '}', '|', '^', '$', '\\' => true,
        else => false,
    };
}

/// Score a literal for filtering effectiveness
/// Higher score = better for filtering (more selective)
fn scoreLiteral(lit: []const u8) u32 {
    var score: u32 = 0;

    // Longer literals are better (more selective)
    score += @intCast(lit.len * 10);

    // Score based on character rarity
    for (lit) |c| {
        switch (c) {
            // Very rare characters - high bonus
            '_', 'Q', 'X', 'Z', 'q', 'x', 'z' => score += 5,
            // Uppercase letters - moderately uncommon
            'A'...'O', 'R'...'W', 'Y' => score += 3,
            // P is somewhat common
            'P' => score += 2,
            // Numbers - somewhat uncommon in prose
            '0'...'9' => score += 2,
            // Very common letters - no bonus
            'e', 't', 'a', 'o', 'i', 'n', 's', ' ' => {},
            // Other lowercase letters - small bonus
            else => score += 1,
        }
    }

    return score;
}

// Tests

test "extract prefix from hello.*" {
    const info = extractBestLiteral("hello.*");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("hello", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.prefix, info.?.position);
}

test "extract suffix from .*_PLATFORM" {
    const info = extractBestLiteral(".*_PLATFORM");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("_PLATFORM", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.suffix, info.?.position);
}

test "extract prefix from CONFIG_.*" {
    const info = extractBestLiteral("CONFIG_.*");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("CONFIG_", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.prefix, info.?.position);
}

test "extract inner from [a-z]+_FOO_[a-z]+" {
    const info = extractBestLiteral("[a-z]+_FOO_[a-z]+");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("_FOO_", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.inner, info.?.position);
}

test "no literal extraction for [a-z]+" {
    const info = extractBestLiteral("[a-z]+");
    try std.testing.expect(info == null);
}

test "no literal extraction for .*" {
    const info = extractBestLiteral(".*");
    try std.testing.expect(info == null);
}

test "no literal extraction for .+" {
    const info = extractBestLiteral(".+");
    try std.testing.expect(info == null);
}

test "extract prefix with escaped metachar" {
    const info = extractBestLiteral("foo\\.bar.*");
    try std.testing.expect(info != null);
    // Should extract "foo" as prefix (escape stops prefix extraction)
    // This is conservative - we don't include escaped chars to avoid complexity
    try std.testing.expectEqualStrings("foo", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.prefix, info.?.position);
}

test "short pattern returns null" {
    const info = extractBestLiteral("a");
    try std.testing.expect(info == null);
}

test "empty pattern returns null" {
    const info = extractBestLiteral("");
    try std.testing.expect(info == null);
}

test "pure literal returns prefix" {
    const info = extractBestLiteral("hello");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("hello", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.prefix, info.?.position);
}

test "suffix with quantifier prefix" {
    const info = extractBestLiteral(".+CONFIG");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("CONFIG", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.suffix, info.?.position);
}
