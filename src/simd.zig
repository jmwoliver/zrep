const std = @import("std");
const builtin = @import("builtin");

// Vector width selection based on target architecture
// AVX2 = 256 bits = 32 bytes, SSE = 128 bits = 16 bytes, fallback = 16 bytes
pub const VECTOR_WIDTH: usize = if (builtin.cpu.arch == .x86_64)
    if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) 32 else 16
else if (builtin.cpu.arch == .aarch64)
    16 // NEON is 128-bit
else
    16;

pub const Vec = @Vector(VECTOR_WIDTH, u8);
pub const BoolVec = @Vector(VECTOR_WIDTH, bool);

/// Find a single byte using SIMD
fn findByte(haystack: []const u8, byte: u8) ?usize {
    if (haystack.len == 0) return null;

    const byte_vec: Vec = @splat(byte);
    var pos: usize = 0;

    // SIMD loop - process VECTOR_WIDTH bytes at a time
    while (pos + VECTOR_WIDTH <= haystack.len) {
        const chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        const cmp: BoolVec = chunk == byte_vec;

        if (@reduce(.Or, cmp)) {
            const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
            const mask: MaskType = @bitCast(cmp);
            return pos + @ctz(mask);
        }
        pos += VECTOR_WIDTH;
    }

    // Scalar fallback for remaining bytes
    while (pos < haystack.len) : (pos += 1) {
        if (haystack[pos] == byte) return pos;
    }
    return null;
}

/// Byte frequency table for picking rare bytes to search for
/// Lower values = rarer bytes (based on typical text/code frequency)
const BYTE_FREQ: [256]u8 = blk: {
    var freq: [256]u8 = [_]u8{0} ** 256;
    // Common ASCII chars get high frequency
    freq[' '] = 255; // space is most common
    freq['e'] = 250;
    freq['t'] = 245;
    freq['a'] = 240;
    freq['o'] = 235;
    freq['i'] = 230;
    freq['n'] = 225;
    freq['s'] = 220;
    freq['r'] = 215;
    freq['h'] = 210;
    freq['l'] = 205;
    freq['d'] = 200;
    freq['c'] = 195;
    freq['u'] = 190;
    freq['m'] = 185;
    freq['f'] = 180;
    freq['p'] = 175;
    freq['g'] = 170;
    freq['w'] = 165;
    freq['y'] = 160;
    freq['b'] = 155;
    freq['v'] = 150;
    freq['k'] = 145;
    freq['x'] = 80;
    freq['j'] = 75;
    freq['q'] = 70;
    freq['z'] = 65;
    // Digits
    for (0..10) |d| freq['0' + d] = 100;
    // Uppercase (less common in code)
    for (0..26) |c| freq['A' + c] = 90;
    // Common punctuation in code
    freq['_'] = 140;
    freq['.'] = 150;
    freq[','] = 130;
    freq[';'] = 120;
    freq[':'] = 110;
    freq['('] = 135;
    freq[')'] = 135;
    freq['{'] = 100;
    freq['}'] = 100;
    freq['['] = 90;
    freq[']'] = 90;
    freq['"'] = 120;
    freq['\''] = 115;
    freq['='] = 125;
    freq['/'] = 110;
    freq['\\'] = 50;
    freq['\n'] = 200;
    freq['\t'] = 150;
    freq['\r'] = 100;
    // Rare chars stay at 0
    break :blk freq;
};

/// Pick the rarest byte in a pattern for searching
/// Returns (byte, offset) tuple
fn pickRareByte(needle: []const u8) struct { byte: u8, offset: usize } {
    if (needle.len == 0) return .{ .byte = 0, .offset = 0 };

    var rarest_byte = needle[0];
    var rarest_offset: usize = 0;
    var rarest_freq = BYTE_FREQ[needle[0]];

    for (needle[1..], 1..) |byte, i| {
        const freq = BYTE_FREQ[byte];
        if (freq < rarest_freq) {
            rarest_freq = freq;
            rarest_byte = byte;
            rarest_offset = i;
        }
    }

    return .{ .byte = rarest_byte, .offset = rarest_offset };
}

/// Find a substring using SIMD-accelerated rare byte search followed by memcmp
/// This is the "quick search" approach used by many fast string matchers
/// Picks the rarest byte in the pattern to minimize false positives
pub fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    // Single byte optimization: use SIMD byte search
    if (needle.len == 1) {
        return findByte(haystack, needle[0]);
    }

    // Pick the rarest byte in the needle to search for
    const rare = pickRareByte(needle);
    const rare_vec: Vec = @splat(rare.byte);
    const max_pos = haystack.len - needle.len;
    var pos: usize = 0;

    // SIMD loop - process VECTOR_WIDTH bytes at a time looking for rare byte
    while (pos + rare.offset + VECTOR_WIDTH <= haystack.len) {
        // Search for rare byte at its expected offset position
        const search_start = pos + rare.offset;
        const chunk: Vec = haystack[search_start..][0..VECTOR_WIDTH].*;
        const cmp: BoolVec = chunk == rare_vec;

        if (@reduce(.Or, cmp)) {
            // Found at least one rare-byte match in this chunk
            const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
            var mask: MaskType = @bitCast(cmp);

            // Process all matches in this chunk
            while (mask != 0) {
                const offset = @ctz(mask);
                const candidate = pos + offset; // Start of potential needle match

                // Check if we have room for full needle
                if (candidate <= max_pos) {
                    // Verify full needle match
                    if (std.mem.eql(u8, haystack[candidate..][0..needle.len], needle)) {
                        return candidate;
                    }
                }

                // Clear lowest set bit and check next match
                mask &= mask - 1;
            }
        }
        pos += VECTOR_WIDTH;
    }

    // Scalar fallback for remaining positions
    while (pos <= max_pos) : (pos += 1) {
        if (haystack[pos + rare.offset] == rare.byte) {
            if (std.mem.eql(u8, haystack[pos..][0..needle.len], needle)) {
                return pos;
            }
        }
    }

    return null;
}



/// Find a substring starting from a given offset
/// Returns the position relative to the start of haystack (not the offset)
pub fn findSubstringFrom(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (start >= haystack.len) return null;
    if (needle.len == 0) return start;
    if (start + needle.len > haystack.len) return null;

    // Search in the slice starting from offset
    if (findSubstring(haystack[start..], needle)) |pos| {
        return start + pos;
    }
    return null;
}

/// Case-insensitive byte comparison helper
inline fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Case-insensitive memory comparison
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (toLower(ac) != toLower(bc)) return false;
    }
    return true;
}

/// Find a substring case-insensitively using SIMD-accelerated rare byte search
/// Searches for both uppercase and lowercase versions of the rare byte simultaneously
pub fn findSubstringIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    // Pick the rarest byte in the needle
    const rare = pickRareByte(needle);
    const rare_lower = toLower(rare.byte);
    const rare_upper = if (rare_lower >= 'a' and rare_lower <= 'z') rare_lower - 32 else rare_lower;

    // Single byte optimization
    if (needle.len == 1) {
        return findByteIgnoreCase(haystack, rare_lower, rare_upper);
    }

    const lower_vec: Vec = @splat(rare_lower);
    const upper_vec: Vec = @splat(rare_upper);
    const max_pos = haystack.len - needle.len;
    var pos: usize = 0;

    // SIMD loop - search for both cases of the rare byte
    while (pos + rare.offset + VECTOR_WIDTH <= haystack.len) {
        const search_start = pos + rare.offset;
        const chunk: Vec = haystack[search_start..][0..VECTOR_WIDTH].*;

        // Check for both lowercase and uppercase matches
        const cmp_lower: BoolVec = chunk == lower_vec;
        const cmp_upper: BoolVec = chunk == upper_vec;

        // Combine both matches with OR
        const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
        const mask_lower: MaskType = @bitCast(cmp_lower);
        const mask_upper: MaskType = @bitCast(cmp_upper);
        var mask = mask_lower | mask_upper;

        while (mask != 0) {
            const offset = @ctz(mask);
            const candidate = pos + offset;

            if (candidate <= max_pos) {
                if (eqlIgnoreCase(haystack[candidate..][0..needle.len], needle)) {
                    return candidate;
                }
            }

            mask &= mask - 1;
        }
        pos += VECTOR_WIDTH;
    }

    // Scalar fallback
    while (pos <= max_pos) : (pos += 1) {
        const c = toLower(haystack[pos + rare.offset]);
        if (c == rare_lower) {
            if (eqlIgnoreCase(haystack[pos..][0..needle.len], needle)) {
                return pos;
            }
        }
    }

    return null;
}

/// Find a byte case-insensitively using SIMD
fn findByteIgnoreCase(haystack: []const u8, lower: u8, upper: u8) ?usize {
    if (haystack.len == 0) return null;

    const lower_vec: Vec = @splat(lower);
    const upper_vec: Vec = @splat(upper);
    var pos: usize = 0;

    while (pos + VECTOR_WIDTH <= haystack.len) {
        const chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        const cmp_lower: BoolVec = chunk == lower_vec;
        const cmp_upper: BoolVec = chunk == upper_vec;

        const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
        const mask_lower: MaskType = @bitCast(cmp_lower);
        const mask_upper: MaskType = @bitCast(cmp_upper);
        const mask = mask_lower | mask_upper;

        if (mask != 0) {
            return pos + @ctz(mask);
        }
        pos += VECTOR_WIDTH;
    }

    // Scalar fallback
    while (pos < haystack.len) : (pos += 1) {
        const c = toLower(haystack[pos]);
        if (c == lower) return pos;
    }
    return null;
}

/// Find a substring case-insensitively starting from a given offset
pub fn findSubstringFromIgnoreCase(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (start >= haystack.len) return null;
    if (needle.len == 0) return start;
    if (start + needle.len > haystack.len) return null;

    if (findSubstringIgnoreCase(haystack[start..], needle)) |pos| {
        return start + pos;
    }
    return null;
}

/// Find the next newline character using SIMD
pub fn findNewline(haystack: []const u8) ?usize {
    if (haystack.len == 0) return null;

    const newline_vec: Vec = @splat('\n');
    var pos: usize = 0;

    // SIMD loop - process VECTOR_WIDTH bytes at a time
    while (pos + VECTOR_WIDTH <= haystack.len) {
        const chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        const cmp: BoolVec = chunk == newline_vec;

        if (@reduce(.Or, cmp)) {
            // Found at least one newline in this chunk
            const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
            const mask: MaskType = @bitCast(cmp);
            return pos + @ctz(mask);
        }
        pos += VECTOR_WIDTH;
    }

    // Scalar fallback for remaining bytes
    while (pos < haystack.len) : (pos += 1) {
        if (haystack[pos] == '\n') return pos;
    }
    return null;
}


// Tests

test "findSubstring basic" {
    const data = "hello world, hello universe";
    try std.testing.expectEqual(@as(?usize, 0), findSubstring(data, "hello"));
    try std.testing.expectEqual(@as(?usize, 6), findSubstring(data, "world"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring(data, "xyz"));
}

test "findSubstring empty needle" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("hello", ""));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("", ""));
}

test "findSubstring needle longer than haystack" {
    try std.testing.expectEqual(@as(?usize, null), findSubstring("hi", "hello"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring("", "x"));
}

test "findSubstring single char" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("abc", "a"));
    try std.testing.expectEqual(@as(?usize, 1), findSubstring("abc", "b"));
    try std.testing.expectEqual(@as(?usize, 2), findSubstring("abc", "c"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring("abc", "d"));
}

test "findSubstring at start" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("hello world", "hello"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("test", "test"));
}

test "findSubstring at end" {
    try std.testing.expectEqual(@as(?usize, 6), findSubstring("hello world", "world"));
    try std.testing.expectEqual(@as(?usize, 3), findSubstring("abcdef", "def"));
}

test "findSubstring no match" {
    try std.testing.expectEqual(@as(?usize, null), findSubstring("hello", "xyz"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring("aaa", "aaaa"));
}

test "findSubstring partial match not found" {
    // Partial prefix that doesn't complete
    try std.testing.expectEqual(@as(?usize, null), findSubstring("hel", "hello"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring("abc", "abd"));
}

test "findSubstring overlapping occurrences" {
    // Should return first match
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("aaaa", "aa"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("abab", "ab"));
}

test "findSubstring exact match" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("hello", "hello"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("x", "x"));
}

test "findNewline basic" {
    try std.testing.expectEqual(@as(?usize, 5), findNewline("hello\nworld"));
    try std.testing.expectEqual(@as(?usize, 0), findNewline("\ntest"));
}

test "findNewline not found" {
    try std.testing.expectEqual(@as(?usize, null), findNewline("hello world"));
    try std.testing.expectEqual(@as(?usize, null), findNewline("no newlines here"));
}

test "findNewline at start" {
    try std.testing.expectEqual(@as(?usize, 0), findNewline("\n"));
    try std.testing.expectEqual(@as(?usize, 0), findNewline("\nhello"));
}

test "findNewline empty input" {
    try std.testing.expectEqual(@as(?usize, null), findNewline(""));
}

test "findNewline multiple newlines" {
    // Should return first newline
    try std.testing.expectEqual(@as(?usize, 1), findNewline("a\nb\nc"));
    try std.testing.expectEqual(@as(?usize, 0), findNewline("\n\n\n"));
}

test "findSubstringFrom basic" {
    const data = "hello world, hello universe";
    // Find first "hello" starting from 0
    try std.testing.expectEqual(@as(?usize, 0), findSubstringFrom(data, "hello", 0));
    // Find second "hello" starting from 1
    try std.testing.expectEqual(@as(?usize, 13), findSubstringFrom(data, "hello", 1));
    // Find "world" starting from 0
    try std.testing.expectEqual(@as(?usize, 6), findSubstringFrom(data, "world", 0));
    // Find "world" starting after "world"
    try std.testing.expectEqual(@as(?usize, null), findSubstringFrom(data, "world", 7));
}

test "findSubstringFrom at offset" {
    const data = "abcabc";
    try std.testing.expectEqual(@as(?usize, 0), findSubstringFrom(data, "abc", 0));
    try std.testing.expectEqual(@as(?usize, 3), findSubstringFrom(data, "abc", 1));
    try std.testing.expectEqual(@as(?usize, 3), findSubstringFrom(data, "abc", 3));
    try std.testing.expectEqual(@as(?usize, null), findSubstringFrom(data, "abc", 4));
}

test "findSubstringFrom edge cases" {
    try std.testing.expectEqual(@as(?usize, null), findSubstringFrom("hello", "hello", 1));
    try std.testing.expectEqual(@as(?usize, null), findSubstringFrom("hello", "world", 0));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringFrom("hello", "", 0));
    try std.testing.expectEqual(@as(?usize, 3), findSubstringFrom("hello", "", 3));
    try std.testing.expectEqual(@as(?usize, null), findSubstringFrom("hello", "", 10));
}





