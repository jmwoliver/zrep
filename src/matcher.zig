const std = @import("std");
const regex = @import("regex.zig");
const simd = @import("simd.zig");
const literal = @import("literal.zig");
const aho_corasick = @import("aho_corasick.zig");

pub const MatchResult = struct {
    start: usize,
    end: usize,
};

pub const Matcher = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    ignore_case: bool,
    word_boundary: bool,
    is_literal: bool,
    regex_engine: ?regex.Regex,
    lower_pattern: ?[]u8,

    // Multi-pattern support for pure-literal alternation (Aho-Corasick)
    ac_automaton: ?aho_corasick.AhoCorasick,
    alternation_info: ?literal.AlternationInfo,
    is_multi_literal: bool,
    lower_alternation_patterns: ?[][]u8, // Lowercased patterns for case-insensitive AC

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8, ignore_case: bool, word_boundary: bool) !Matcher {
        // First, try to detect pure-literal alternation for AC optimization
        if (try literal.extractAlternationLiterals(allocator, pattern)) |alt_info| {
            // Pure-literal alternation detected - use Aho-Corasick
            // For case-insensitive, build AC from lowercased patterns
            var patterns_to_use: []const []const u8 = alt_info.literals;
            var lower_patterns: ?[][]u8 = null;

            if (ignore_case) {
                lower_patterns = try allocator.alloc([]u8, alt_info.literals.len);
                errdefer {
                    if (lower_patterns) |lp| {
                        for (lp) |p| allocator.free(p);
                        allocator.free(lp);
                    }
                }
                for (alt_info.literals, 0..) |lit, i| {
                    lower_patterns.?[i] = try allocator.alloc(u8, lit.len);
                    for (lit, 0..) |c, j| {
                        lower_patterns.?[i][j] = std.ascii.toLower(c);
                    }
                }
                // Use the lowercased patterns slice for AC
                // Need to cast to []const []const u8
                patterns_to_use = @as([]const []const u8, @ptrCast(lower_patterns.?));
            }

            var ac = try aho_corasick.AhoCorasick.compile(allocator, patterns_to_use);
            errdefer ac.deinit();

            // Free the lower_patterns array (but not the strings - AC doesn't own them either)
            // Actually AC doesn't copy the strings, so we need to keep them
            // Store them in a separate field

            return .{
                .allocator = allocator,
                .pattern = pattern,
                .ignore_case = ignore_case,
                .word_boundary = word_boundary,
                .is_literal = false, // Not a single literal
                .regex_engine = null, // Don't need regex for pure-literal alternation
                .lower_pattern = null,
                .ac_automaton = ac,
                .alternation_info = alt_info,
                .is_multi_literal = true,
                .lower_alternation_patterns = lower_patterns,
            };
        }

        // Fall back to existing behavior for single patterns and complex regex
        const is_literal = !containsRegexMetaChars(pattern);

        var lower_pattern: ?[]u8 = null;
        if (ignore_case and is_literal) {
            lower_pattern = try allocator.alloc(u8, pattern.len);
            for (pattern, 0..) |c, i| {
                lower_pattern.?[i] = std.ascii.toLower(c);
            }
        }

        var regex_engine: ?regex.Regex = null;
        if (!is_literal) {
            regex_engine = try regex.Regex.compile(allocator, pattern);
        }

        return .{
            .allocator = allocator,
            .pattern = pattern,
            .ignore_case = ignore_case,
            .word_boundary = word_boundary,
            .is_literal = is_literal,
            .regex_engine = regex_engine,
            .lower_pattern = lower_pattern,
            .ac_automaton = null,
            .alternation_info = null,
            .is_multi_literal = false,
            .lower_alternation_patterns = null,
        };
    }

    pub fn deinit(self: *Matcher) void {
        if (self.regex_engine) |*re| {
            re.deinit();
        }
        if (self.lower_pattern) |lp| {
            self.allocator.free(lp);
        }
        // Free Aho-Corasick resources
        if (self.ac_automaton) |*ac| {
            ac.deinit();
        }
        if (self.alternation_info) |*info| {
            info.deinit();
        }
        // Free lowercased alternation patterns (for case-insensitive)
        if (self.lower_alternation_patterns) |lp| {
            for (lp) |p| {
                self.allocator.free(p);
            }
            self.allocator.free(lp);
        }
    }

    /// Find the first match in the given haystack
    pub fn findFirst(self: *const Matcher, haystack: []const u8) ?MatchResult {
        return self.findFirstFrom(haystack, 0);
    }

    /// Find the first match starting from a given offset
    fn findFirstFrom(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        if (start_offset >= haystack.len) return null;

        // Use Aho-Corasick for multi-literal alternation patterns
        if (self.is_multi_literal) {
            return self.findFirstMultiLiteral(haystack, start_offset);
        }

        const result = if (self.is_literal)
            self.findLiteralInFrom(haystack, start_offset)
        else blk: {
            if (self.regex_engine) |*re| {
                // Use findFrom to efficiently resume search from offset
                // This avoids re-running O(n²) suffix filter on each retry
                break :blk re.findFrom(haystack, start_offset);
            }
            break :blk null;
        };

        if (result) |r| {
            // If word boundary mode is enabled, validate the match
            if (self.word_boundary) {
                if (!isWordBoundaryMatch(haystack, r.start, r.end)) {
                    // Not a word boundary match, try again
                    // For patterns like .*SUFFIX where r.start is always 0,
                    // we need to skip past the END of the match to find the next
                    // suffix occurrence. Otherwise we'd get the same match forever.
                    const next_pos = if (r.end > start_offset) r.end else start_offset + 1;
                    return self.findFirstFrom(haystack, next_pos);
                }
            }

            return r;
        }

        return null;
    }

    /// Find first match using Aho-Corasick for multi-literal alternation
    fn findFirstMultiLiteral(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        const ac = &(self.ac_automaton orelse return null);

        // For case-insensitive, we need to lowercase the haystack
        // This is done on-the-fly to avoid allocation
        if (self.ignore_case) {
            return self.findFirstMultiLiteralIgnoreCase(haystack, start_offset);
        }

        if (ac.findFirstFrom(haystack, start_offset)) |match| {
            const result = MatchResult{
                .start = match.start,
                .end = match.end,
            };

            // Word boundary check
            if (self.word_boundary) {
                if (!isWordBoundaryMatch(haystack, result.start, result.end)) {
                    // Not a word boundary match, try again from after match start
                    return self.findFirstMultiLiteral(haystack, result.start + 1);
                }
            }

            return result;
        }
        return null;
    }

    /// Case-insensitive multi-literal search
    /// Uses a stack buffer to lowercase chunks of the haystack
    fn findFirstMultiLiteralIgnoreCase(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        const ac = &(self.ac_automaton orelse return null);
        const info = self.alternation_info orelse return null;

        // For small haystacks, lowercase the entire thing
        // For large haystacks, search each pattern individually using SIMD
        if (haystack.len <= 4096) {
            // Use stack buffer for lowercasing
            var lower_buf: [4096]u8 = undefined;
            const len = @min(haystack.len, 4096);
            for (haystack[0..len], 0..) |c, i| {
                lower_buf[i] = std.ascii.toLower(c);
            }

            if (ac.findFirstFrom(lower_buf[0..len], start_offset)) |match| {
                const result = MatchResult{
                    .start = match.start,
                    .end = match.end,
                };

                if (self.word_boundary) {
                    if (!isWordBoundaryMatch(haystack, result.start, result.end)) {
                        return self.findFirstMultiLiteralIgnoreCase(haystack, result.start + 1);
                    }
                }

                return result;
            }
            return null;
        }

        // For large haystacks, fall back to parallel SIMD search for each pattern
        var earliest_match: ?MatchResult = null;
        var earliest_pos: usize = std.math.maxInt(usize);

        for (info.literals) |lit| {
            if (simd.findSubstringFromIgnoreCase(haystack, lit, start_offset)) |pos| {
                if (pos < earliest_pos) {
                    earliest_pos = pos;
                    earliest_match = MatchResult{
                        .start = pos,
                        .end = pos + lit.len,
                    };
                }
            }
        }

        if (earliest_match) |result| {
            if (self.word_boundary) {
                if (!isWordBoundaryMatch(haystack, result.start, result.end)) {
                    return self.findFirstMultiLiteralIgnoreCase(haystack, result.start + 1);
                }
            }
            return result;
        }

        return null;
    }

    /// Get the maximum pattern length (useful for buffer overlap handling)
    pub fn getMaxPatternLen(self: *const Matcher) usize {
        if (self.ac_automaton) |*ac| {
            return ac.getMaxPatternLen();
        }
        return self.pattern.len;
    }

    /// Check if a match at the given position satisfies word boundary constraints
    fn isWordBoundaryMatch(haystack: []const u8, start: usize, end: usize) bool {
        // Check character before match (must be non-word char or start of string)
        const before_ok = (start == 0) or !isWordChar(haystack[start - 1]);
        // Check character after match (must be non-word char or end of string)
        const after_ok = (end >= haystack.len) or !isWordChar(haystack[end]);
        return before_ok and after_ok;
    }

    /// Check if a character is a "word" character for word boundary matching.
    /// Uses a simple heuristic: ASCII alphanumeric, underscore, or any non-ASCII byte.
    ///
    /// This treats all UTF-8 multibyte sequences as word characters, which correctly
    /// handles CJK ideographs (Chinese, Japanese kanji, Korean hanja) but has a known
    /// limitation: CJK punctuation marks are also treated as word characters.
    ///
    /// Edge case - these CJK punctuation chars will NOT create word boundaries:
    ///   U+3001 、 (ideographic comma)
    ///   U+3002 。 (ideographic full stop)
    ///   U+3000   (ideographic space)
    ///   U+300C 「 (left corner bracket)
    ///   U+300D 」 (right corner bracket)
    ///   U+300A 《 (left double angle bracket)
    ///   U+300B 》 (right double angle bracket)
    ///   U+30FB ・ (katakana middle dot)
    ///   U+FF0C ， (fullwidth comma)
    ///   U+FF0E ． (fullwidth full stop)
    ///   U+FF1A ： (fullwidth colon)
    ///   U+FF1B ； (fullwidth semicolon)
    ///
    /// For full Unicode-aware word boundaries, we would need
    /// Unicode property tables (~100KB) to check \p{Alphabetic}, \p{M}, \p{Pc}, etc.
    fn isWordChar(c: u8) bool {
        // UTF-8 bytes >= 0x80 are part of multibyte characters.
        // Treat them as word characters to handle CJK ideographs correctly.
        return c >= 0x80 or std.ascii.isAlphanumeric(c) or c == '_';
    }

    /// Check if the haystack contains a match
    pub fn matches(self: *const Matcher, haystack: []const u8) bool {
        return self.findFirst(haystack) != null;
    }

    fn findLiteralInFrom(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        if (self.ignore_case) {
            return self.findLiteralIgnoreCaseFrom(haystack, start_offset);
        }

        // Use SIMD-accelerated search for literal patterns
        if (simd.findSubstringFrom(haystack, self.pattern, start_offset)) |pos| {
            return MatchResult{
                .start = pos,
                .end = pos + self.pattern.len,
            };
        }
        return null;
    }

    fn findLiteralIgnoreCaseFrom(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        const lower_pat = self.lower_pattern orelse return null;

        // Simple case-insensitive search (could be optimized with SIMD later)
        if (haystack.len < lower_pat.len) return null;
        if (start_offset > haystack.len - lower_pat.len) return null;

        var i: usize = start_offset;
        outer: while (i <= haystack.len - lower_pat.len) : (i += 1) {
            for (lower_pat, 0..) |pc, j| {
                const hc = std.ascii.toLower(haystack[i + j]);
                if (hc != pc) continue :outer;
            }
            return MatchResult{
                .start = i,
                .end = i + lower_pat.len,
            };
        }
        return null;
    }

    pub fn containsRegexMetaChars(pattern: []const u8) bool {
        for (pattern) |c| {
            switch (c) {
                '.', '*', '+', '?', '[', ']', '(', ')', '{', '}', '|', '^', '$', '\\' => return true,
                else => {},
            }
        }
        return false;
    }
};

test "literal matching" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "hello", false, false);
    defer m.deinit();

    try std.testing.expect(m.matches("hello world"));
    try std.testing.expect(m.matches("say hello"));
    try std.testing.expect(!m.matches("HELLO"));
    try std.testing.expect(!m.matches("helo"));
}

test "case insensitive matching" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "hello", true, false);
    defer m.deinit();

    try std.testing.expect(m.matches("HELLO world"));
    try std.testing.expect(m.matches("Hello"));
    try std.testing.expect(m.matches("hElLo"));
}

test "matcher regex pattern" {
    const allocator = std.testing.allocator;

    // Pattern with metacharacters should use regex
    var m = try Matcher.init(allocator, "hel+o", false, false);
    defer m.deinit();

    try std.testing.expect(!m.is_literal);
    try std.testing.expect(m.regex_engine != null);
    try std.testing.expect(m.matches("hello"));
    try std.testing.expect(m.matches("helllo"));
    try std.testing.expect(!m.matches("heo"));
}

test "matcher findFirst returns position" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "world", false, false);
    defer m.deinit();

    const result = m.findFirst("hello world");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 6), result.?.start);
    try std.testing.expectEqual(@as(usize, 11), result.?.end);
}

test "matcher no match returns null" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "xyz", false, false);
    defer m.deinit();

    try std.testing.expect(m.findFirst("hello") == null);
    try std.testing.expect(!m.matches("hello"));
}

test "matcher empty haystack" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "test", false, false);
    defer m.deinit();

    try std.testing.expect(m.findFirst("") == null);
    try std.testing.expect(!m.matches(""));
}

test "matcher pattern at start" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "hello", false, false);
    defer m.deinit();

    const result = m.findFirst("hello world");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
}

test "matcher pattern at end" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "world", false, false);
    defer m.deinit();

    const result = m.findFirst("hello world");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 6), result.?.start);
    try std.testing.expectEqual(@as(usize, 11), result.?.end);
}

test "matcher multiple matches returns first" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "ab", false, false);
    defer m.deinit();

    const result = m.findFirst("ab ab ab");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
}

test "containsRegexMetaChars" {
    // All metacharacters should be detected
    try std.testing.expect(Matcher.containsRegexMetaChars("."));
    try std.testing.expect(Matcher.containsRegexMetaChars("*"));
    try std.testing.expect(Matcher.containsRegexMetaChars("+"));
    try std.testing.expect(Matcher.containsRegexMetaChars("?"));
    try std.testing.expect(Matcher.containsRegexMetaChars("["));
    try std.testing.expect(Matcher.containsRegexMetaChars("]"));
    try std.testing.expect(Matcher.containsRegexMetaChars("("));
    try std.testing.expect(Matcher.containsRegexMetaChars(")"));
    try std.testing.expect(Matcher.containsRegexMetaChars("{"));
    try std.testing.expect(Matcher.containsRegexMetaChars("}"));
    try std.testing.expect(Matcher.containsRegexMetaChars("|"));
    try std.testing.expect(Matcher.containsRegexMetaChars("^"));
    try std.testing.expect(Matcher.containsRegexMetaChars("$"));
    try std.testing.expect(Matcher.containsRegexMetaChars("\\"));

    // Plain text should not be detected
    try std.testing.expect(!Matcher.containsRegexMetaChars("hello"));
    try std.testing.expect(!Matcher.containsRegexMetaChars("test123"));
    try std.testing.expect(!Matcher.containsRegexMetaChars(""));
}

test "matcher literal is detected" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "hello", false, false);
    defer m.deinit();

    try std.testing.expect(m.is_literal);
    try std.testing.expect(m.regex_engine == null);
}

test "matcher case insensitive creates lower pattern" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "HeLLo", true, false);
    defer m.deinit();

    try std.testing.expect(m.lower_pattern != null);
    try std.testing.expectEqualStrings("hello", m.lower_pattern.?);
}

test "matcher case insensitive position" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "WORLD", true, false);
    defer m.deinit();

    const result = m.findFirst("hello world");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 6), result.?.start);
    try std.testing.expectEqual(@as(usize, 11), result.?.end);
}

test "word boundary literal match" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, true); // word_boundary=true
    defer m.deinit();

    // Should match "foo" as a whole word
    try std.testing.expect(m.matches("foo"));
    try std.testing.expect(m.matches("foo bar"));
    try std.testing.expect(m.matches("bar foo"));
    try std.testing.expect(m.matches("bar foo baz"));

    // Should NOT match "foo" as part of another word
    try std.testing.expect(!m.matches("foobar"));
    try std.testing.expect(!m.matches("barfoo"));
    try std.testing.expect(!m.matches("barfoobar"));
}

test "word boundary skips non-boundary matches" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, true);
    defer m.deinit();

    // "xfoo foo" - should skip match at pos 1, find match at pos 5
    const result = m.findFirst("xfoo foo");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 5), result.?.start);
    try std.testing.expectEqual(@as(usize, 8), result.?.end);
}

test "word boundary with underscore" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, true);
    defer m.deinit();

    // Underscore is a word character, so foo_bar should NOT match "foo"
    try std.testing.expect(!m.matches("foo_bar"));
    try std.testing.expect(!m.matches("bar_foo"));

    // But "foo_" alone should not match either (underscore is word char)
    try std.testing.expect(!m.matches("foo_"));
    try std.testing.expect(!m.matches("_foo"));
}

test "word boundary at string boundaries" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, true);
    defer m.deinit();

    // Match at start of string
    const result1 = m.findFirst("foo bar");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(usize, 0), result1.?.start);

    // Match at end of string
    const result2 = m.findFirst("bar foo");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(usize, 4), result2.?.start);
}

test "word boundary with punctuation" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, true);
    defer m.deinit();

    // Punctuation is not a word character, so these should match
    try std.testing.expect(m.matches("foo.bar"));
    try std.testing.expect(m.matches("foo,bar"));
    try std.testing.expect(m.matches("(foo)"));
    try std.testing.expect(m.matches("foo!"));
}

test "word boundary disabled" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, false); // word_boundary=false
    defer m.deinit();

    // Without word boundary, should match anywhere
    try std.testing.expect(m.matches("foobar"));
    try std.testing.expect(m.matches("barfoo"));
    try std.testing.expect(m.matches("barfoobar"));
}

test "word boundary with .* prefix pattern" {
    const allocator = std.testing.allocator;

    // Pattern .*_cache with word boundary - should find first valid word boundary match
    var m = try Matcher.init(allocator, ".*_cache", false, true);
    defer m.deinit();

    // For .*SUFFIX patterns, the match STARTS at position 0 (beginning of line).
    // Word boundary check: start=0 is word boundary (beginning of string), end depends on suffix.
    // "x_cache " - match from 0 to 7, end boundary: char at 7 is ' ' (non-word) = valid!
    const input = "x_cache foo_cache bar_cache_baz";

    // Should find match ending at first _cache (position 7) since it has valid word boundary
    const result = m.findFirst(input);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
    try std.testing.expectEqual(@as(usize, 7), result.?.end); // "x_cache" = 7 chars
}

test "word boundary with .* prefix finds match at end of string" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, ".*_suffix", false, true);
    defer m.deinit();

    // For greedy .*, it matches up to the LAST _suffix
    // The last _suffix ends at position 26 (end of string = word boundary)
    // Word boundary check: start=0 (OK), end=26 (end of string = OK)
    const input = "x_suffix_more text._suffix";

    const result = m.findFirst(input);
    try std.testing.expect(result != null);
    // Should match ending at the last _suffix (position 26 = end of string)
    try std.testing.expectEqual(@as(usize, 26), result.?.end);
}

test "word boundary .* pattern with all non-boundary occurrences" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, ".*_cache", false, true);
    defer m.deinit();

    // All _cache occurrences have word characters adjacent
    const input = "x_cache_y a_cache_b";

    // Should NOT match since no _cache is at a word boundary
    try std.testing.expect(m.findFirst(input) == null);
}

test "word boundary .* pattern skips early non-boundary to find later valid match" {
    const allocator = std.testing.allocator;

    // This test validates the fix for the bug where .*_cache with -w failed
    // to find matches in long lines. The issue was that the greedy .* would
    // match to the LAST _cache occurrence, and if that didn't satisfy word
    // boundary, we'd skip past ALL _cache occurrences and return no match.
    //
    // The fix returns matches ending at EACH _cache occurrence in turn,
    // allowing word boundary validation to try each one.

    var m = try Matcher.init(allocator, ".*_cache", false, true);
    defer m.deinit();

    // Multiple _cache occurrences (verified with Python re.finditer):
    // - _cache at 1-7, next char: '_' (not word boundary)
    // - _cache at 10-16, next char: '_' (not word boundary)
    // - _cache at 19-25, next char: ' ' (VALID word boundary!)
    // - _cache at 27-33, next char: '_' (not word boundary)
    const input = "a_cache_ b_cache_ c_cache d_cache_x";

    const result = m.findFirst(input);
    try std.testing.expect(result != null);
    // Should find match ending at "c_cache" (position 25) - the first with valid word boundary
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
    try std.testing.expectEqual(@as(usize, 25), result.?.end);
}

test "word boundary with CJK ideographs" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "cache", false, true);
    defer m.deinit();

    // CJK ideographs are word characters - should NOT match when surrounded by Chinese
    try std.testing.expect(!m.matches("硬件cache更小")); // Chinese: "hardware cache smaller"
    try std.testing.expect(!m.matches("硬件cache")); // cache at end after Chinese
    try std.testing.expect(!m.matches("cache更小")); // cache at start before Chinese

    // Japanese hiragana - should NOT match
    try std.testing.expect(!m.matches("あcacheい"));

    // But should match when there's whitespace
    try std.testing.expect(m.matches("硬件 cache 更小"));
    try std.testing.expect(m.matches("硬件 cache"));
    try std.testing.expect(m.matches("cache 更小"));
}

test "word boundary with CJK punctuation - known edge case" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "cache", false, true);
    defer m.deinit();

    // KNOWN LIMITATION: CJK punctuation is treated as word characters with our simple heuristic.
    // Full Unicode support would match these (punctuation = word boundary), but we won't.
    // This is documented as an acceptable trade-off for simplicity.
    //
    // These tests document the current (imperfect) behavior:
    try std.testing.expect(!m.matches("test、cache")); // ideographic comma U+3001
    try std.testing.expect(!m.matches("test。cache")); // ideographic full stop U+3002
    try std.testing.expect(!m.matches("test「cache")); // left corner bracket U+300C
    try std.testing.expect(!m.matches("test，cache")); // fullwidth comma U+FF0C
    try std.testing.expect(!m.matches("test：cache")); // fullwidth colon U+FF1A

    // ASCII punctuation still works correctly
    try std.testing.expect(m.matches("test,cache")); // ASCII comma - DOES match
    try std.testing.expect(m.matches("test.cache")); // ASCII period - DOES match
}

test "word boundary with mixed ASCII and UTF-8" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, true);
    defer m.deinit();

    // UTF-8 continuation bytes should be treated as word chars
    // This prevents false matches when ASCII appears inside multibyte sequences
    try std.testing.expect(!m.matches("日foo本")); // Japanese: should NOT match
    try std.testing.expect(m.matches("日 foo 本")); // With spaces: should match
}

// =============================================================================
// Multi-literal Alternation Tests (Aho-Corasick)
// =============================================================================

test "multi-literal alternation basic" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo|bar|baz", false, false);
    defer m.deinit();

    try std.testing.expect(m.is_multi_literal);
    try std.testing.expect(m.ac_automaton != null);
    try std.testing.expect(m.matches("foo"));
    try std.testing.expect(m.matches("bar"));
    try std.testing.expect(m.matches("baz"));
    try std.testing.expect(m.matches("hello foo world"));
    try std.testing.expect(m.matches("hello bar world"));
    try std.testing.expect(!m.matches("hello world"));
}

test "multi-literal alternation benchmark pattern" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT", false, false);
    defer m.deinit();

    try std.testing.expect(m.is_multi_literal);
    try std.testing.expect(m.matches("test ERR_SYS here"));
    try std.testing.expect(m.matches("test PME_TURN_OFF here"));
    try std.testing.expect(m.matches("test LINK_REQ_RST here"));
    try std.testing.expect(m.matches("test CFG_BME_EVT here"));
    try std.testing.expect(!m.matches("test NO_MATCH here"));
}

test "multi-literal alternation findFirst position" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo|bar", false, false);
    defer m.deinit();

    const result1 = m.findFirst("hello foo world");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(usize, 6), result1.?.start);
    try std.testing.expectEqual(@as(usize, 9), result1.?.end);

    const result2 = m.findFirst("hello bar world");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(usize, 6), result2.?.start);
    try std.testing.expectEqual(@as(usize, 9), result2.?.end);
}

test "multi-literal alternation finds earliest match" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "bar|foo", false, false);
    defer m.deinit();

    // "foo" appears first in the string, should be found first regardless of pattern order
    const result = m.findFirst("hello foo bar");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 6), result.?.start);
}

test "multi-literal alternation with word boundary" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo|bar", false, true);
    defer m.deinit();

    try std.testing.expect(m.matches("foo bar"));
    try std.testing.expect(m.matches("hello foo"));
    try std.testing.expect(!m.matches("foobar")); // "foo" not at word boundary
    try std.testing.expect(!m.matches("barfoo")); // "bar" not at word boundary
}

test "multi-literal max pattern length" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "a|abc|abcdefghij", false, false);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 10), m.getMaxPatternLen());
}

test "multi-literal case insensitive small haystack" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "FOO|BAR", true, false);
    defer m.deinit();

    try std.testing.expect(m.matches("hello foo world"));
    try std.testing.expect(m.matches("hello FOO world"));
    try std.testing.expect(m.matches("hello FoO world"));
    try std.testing.expect(m.matches("hello bar world"));
    try std.testing.expect(m.matches("hello BAR world"));
}

// =============================================================================
// Additional Multi-literal Tests
// =============================================================================

test "multi-literal alternation position tracking" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "ERR|WARN|INFO", false, false);
    defer m.deinit();

    // Test findFirst returns correct positions
    const result1 = m.findFirst("some ERR message");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(usize, 5), result1.?.start);
    try std.testing.expectEqual(@as(usize, 8), result1.?.end);

    const result2 = m.findFirst("some WARN message");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(usize, 5), result2.?.start);
    try std.testing.expectEqual(@as(usize, 9), result2.?.end);

    const result3 = m.findFirst("some INFO message");
    try std.testing.expect(result3 != null);
    try std.testing.expectEqual(@as(usize, 5), result3.?.start);
    try std.testing.expectEqual(@as(usize, 9), result3.?.end);
}

test "multi-literal alternation finds earliest match regardless of pattern order" {
    const allocator = std.testing.allocator;

    // Pattern order shouldn't affect which match is found first
    var m = try Matcher.init(allocator, "WARN|ERR|INFO", false, false);
    defer m.deinit();

    // ERR appears first in the string
    const result = m.findFirst("test ERR then WARN then INFO");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 5), result.?.start);
    try std.testing.expectEqual(@as(usize, 8), result.?.end);
}

test "multi-literal with word boundary skips embedded matches" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "ERR|WARN", false, true);
    defer m.deinit();

    // "ERROR" contains "ERR" but not at word boundary
    try std.testing.expect(!m.matches("ERROR"));
    try std.testing.expect(!m.matches("WARNING"));

    // But standalone should match
    try std.testing.expect(m.matches("ERR"));
    try std.testing.expect(m.matches("WARN"));
    try std.testing.expect(m.matches("test ERR here"));
    try std.testing.expect(m.matches("test WARN here"));
}

test "multi-literal case insensitive with word boundary" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo|bar", true, true);
    defer m.deinit();

    // Should match case-insensitive at word boundaries
    try std.testing.expect(m.matches("FOO bar"));
    try std.testing.expect(m.matches("foo BAR"));
    try std.testing.expect(m.matches("test FOO test"));
    try std.testing.expect(m.matches("test Bar test"));

    // Should NOT match when not at word boundary
    try std.testing.expect(!m.matches("FOOBAR"));
    try std.testing.expect(!m.matches("testFOOtest"));
}

test "multi-literal no match returns null" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "xyz|abc|def", false, false);
    defer m.deinit();

    try std.testing.expect(m.findFirst("hello world") == null);
    try std.testing.expect(!m.matches("hello world"));
}

test "multi-literal empty haystack" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo|bar", false, false);
    defer m.deinit();

    try std.testing.expect(m.findFirst("") == null);
    try std.testing.expect(!m.matches(""));
}

test "multi-literal single character alternatives" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "a|b|c", false, false);
    defer m.deinit();

    try std.testing.expect(m.matches("a"));
    try std.testing.expect(m.matches("b"));
    try std.testing.expect(m.matches("c"));
    try std.testing.expect(m.matches("xyz a xyz"));
    try std.testing.expect(!m.matches("xyz"));
}

test "multi-literal mixed length patterns" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "a|abc|abcdef", false, false);
    defer m.deinit();

    // Should find match even with mixed lengths
    try std.testing.expect(m.matches("abcdef"));
    try std.testing.expect(m.matches("abc"));
    try std.testing.expect(m.matches("a"));
}

test "multi-literal special characters preserved" {
    const allocator = std.testing.allocator;

    // Underscores and numbers are literal, not regex
    var m = try Matcher.init(allocator, "ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT", false, false);
    defer m.deinit();

    try std.testing.expect(m.is_multi_literal);
    try std.testing.expect(m.matches("test ERR_SYS here"));
    try std.testing.expect(m.matches("test PME_TURN_OFF here"));
    try std.testing.expect(m.matches("test LINK_REQ_RST here"));
    try std.testing.expect(m.matches("test CFG_BME_EVT here"));
    try std.testing.expect(!m.matches("test ERR_OTHER here"));
}

test "multi-literal vs regex fallback" {
    const allocator = std.testing.allocator;

    // Pure literals should use AC
    {
        var m = try Matcher.init(allocator, "foo|bar", false, false);
        defer m.deinit();
        try std.testing.expect(m.is_multi_literal);
        try std.testing.expect(m.ac_automaton != null);
        try std.testing.expect(m.regex_engine == null);
    }

    // Pattern with regex metachar should NOT use AC
    {
        var m = try Matcher.init(allocator, "foo.*|bar", false, false);
        defer m.deinit();
        try std.testing.expect(!m.is_multi_literal);
        try std.testing.expect(m.ac_automaton == null);
        try std.testing.expect(m.regex_engine != null);
    }
}

test "multi-literal case insensitive position" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "FOO|BAR", true, false);
    defer m.deinit();

    // Check positions are correct for case-insensitive matches
    const result = m.findFirst("test foo here");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 5), result.?.start);
    try std.testing.expectEqual(@as(usize, 8), result.?.end);
}

test "multi-literal overlapping patterns in haystack" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "ab|bc", false, false);
    defer m.deinit();

    // "abc" contains both "ab" and "bc" overlapping
    const result1 = m.findFirst("xabcx");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(usize, 1), result1.?.start);
}

test "multi-literal consecutive matches" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "aa|bb", false, false);
    defer m.deinit();

    // Test that we can find multiple consecutive matches
    try std.testing.expect(m.matches("aabb"));
    try std.testing.expect(m.matches("bbaa"));

    const result = m.findFirst("aabb");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
}
