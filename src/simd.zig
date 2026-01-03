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

/// Two-byte SIMD substring search - checks first and last byte simultaneously
/// This reduces false positives by ~256x compared to single-byte search
/// Based on ripgrep's "packed pair" algorithm from the memchr crate
fn findSubstringTwoByte(haystack: []const u8, needle: []const u8) ?usize {
    // Preconditions: needle.len >= 2, needle.len <= haystack.len
    const first_byte = needle[0];
    const last_byte = needle[needle.len - 1];
    const offset = needle.len - 1;

    const first_vec: Vec = @splat(first_byte);
    const last_vec: Vec = @splat(last_byte);
    const max_pos = haystack.len - needle.len;

    var pos: usize = 0;

    // SIMD loop - check first AND last byte simultaneously
    while (pos + VECTOR_WIDTH <= max_pos + 1) {
        // Load bytes at positions where first byte would be
        const first_chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        // Load bytes at positions where last byte would be (offset positions forward)
        const last_chunk: Vec = haystack[pos + offset ..][0..VECTOR_WIDTH].*;

        // Check where first byte matches
        const first_eq: BoolVec = first_chunk == first_vec;
        // Check where last byte matches
        const last_eq: BoolVec = last_chunk == last_vec;
        // AND them - only positions where BOTH match are candidates
        // Use bitwise AND on the integer representation of the bool vectors
        const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
        const first_mask: MaskType = @bitCast(first_eq);
        const last_mask: MaskType = @bitCast(last_eq);
        var mask = first_mask & last_mask;

        if (mask != 0) {
            // Found at least one position where both first and last byte match
            while (mask != 0) {
                const bit_pos = @ctz(mask);
                const candidate = pos + bit_pos;

                if (candidate <= max_pos) {
                    // First and last byte already match, only verify middle if needed
                    if (needle.len == 2 or
                        std.mem.eql(u8, haystack[candidate + 1 ..][0 .. needle.len - 2], needle[1 .. needle.len - 1]))
                    {
                        return candidate;
                    }
                }

                // Clear lowest set bit
                mask &= mask - 1;
            }
        }
        pos += VECTOR_WIDTH;
    }

    // Scalar fallback for tail
    while (pos <= max_pos) : (pos += 1) {
        if (haystack[pos] == first_byte and haystack[pos + offset] == last_byte) {
            if (needle.len == 2 or std.mem.eql(u8, haystack[pos..][0..needle.len], needle)) {
                return pos;
            }
        }
    }
    return null;
}

/// Find a substring using SIMD-accelerated two-byte fingerprinting
/// For patterns >= 2 bytes, searches for first AND last byte simultaneously
/// This dramatically reduces false positives compared to single-byte search
pub fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    // Single byte: use direct byte search
    if (needle.len == 1) {
        return findByte(haystack, needle[0]);
    }

    // Two or more bytes: use two-byte fingerprinting (first + last byte)
    return findSubstringTwoByte(haystack, needle);
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

/// Two-byte case-insensitive SIMD substring search
/// Checks both cases of first and last byte simultaneously
fn findSubstringTwoByteIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    // Preconditions: needle.len >= 2, needle.len <= haystack.len
    const first_lower = toLower(needle[0]);
    const first_upper = if (first_lower >= 'a' and first_lower <= 'z') first_lower - 32 else first_lower;
    const last_lower = toLower(needle[needle.len - 1]);
    const last_upper = if (last_lower >= 'a' and last_lower <= 'z') last_lower - 32 else last_lower;
    const offset = needle.len - 1;

    const first_lower_vec: Vec = @splat(first_lower);
    const first_upper_vec: Vec = @splat(first_upper);
    const last_lower_vec: Vec = @splat(last_lower);
    const last_upper_vec: Vec = @splat(last_upper);
    const max_pos = haystack.len - needle.len;

    var pos: usize = 0;

    // SIMD loop - check first AND last byte (both cases) simultaneously
    while (pos + VECTOR_WIDTH <= max_pos + 1) {
        const first_chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        const last_chunk: Vec = haystack[pos + offset ..][0..VECTOR_WIDTH].*;

        // Check first byte (both cases)
        const first_eq_lower: BoolVec = first_chunk == first_lower_vec;
        const first_eq_upper: BoolVec = first_chunk == first_upper_vec;

        // Check last byte (both cases)
        const last_eq_lower: BoolVec = last_chunk == last_lower_vec;
        const last_eq_upper: BoolVec = last_chunk == last_upper_vec;

        // Convert to masks and combine: (first_lower OR first_upper) AND (last_lower OR last_upper)
        const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
        const first_lower_mask: MaskType = @bitCast(first_eq_lower);
        const first_upper_mask: MaskType = @bitCast(first_eq_upper);
        const last_lower_mask: MaskType = @bitCast(last_eq_lower);
        const last_upper_mask: MaskType = @bitCast(last_eq_upper);
        const first_mask = first_lower_mask | first_upper_mask;
        const last_mask = last_lower_mask | last_upper_mask;
        var mask = first_mask & last_mask;

        if (mask != 0) {

            while (mask != 0) {
                const bit_pos = @ctz(mask);
                const candidate = pos + bit_pos;

                if (candidate <= max_pos) {
                    if (needle.len == 2 or
                        eqlIgnoreCase(haystack[candidate + 1 ..][0 .. needle.len - 2], needle[1 .. needle.len - 1]))
                    {
                        return candidate;
                    }
                }

                mask &= mask - 1;
            }
        }
        pos += VECTOR_WIDTH;
    }

    // Scalar fallback
    while (pos <= max_pos) : (pos += 1) {
        const first_c = toLower(haystack[pos]);
        const last_c = toLower(haystack[pos + offset]);
        if (first_c == first_lower and last_c == last_lower) {
            if (needle.len == 2 or eqlIgnoreCase(haystack[pos..][0..needle.len], needle)) {
                return pos;
            }
        }
    }
    return null;
}

/// Find a substring case-insensitively using SIMD-accelerated two-byte fingerprinting
/// Searches for both uppercase and lowercase versions of first AND last byte simultaneously
pub fn findSubstringIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    // Single byte optimization
    if (needle.len == 1) {
        const lower = toLower(needle[0]);
        const upper = if (lower >= 'a' and lower <= 'z') lower - 32 else lower;
        return findByteIgnoreCase(haystack, lower, upper);
    }

    // Two or more bytes: use two-byte fingerprinting
    return findSubstringTwoByteIgnoreCase(haystack, needle);
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

/// Count newlines in a buffer using SIMD
/// Much faster than a scalar loop for counting characters
pub fn countNewlines(data: []const u8) usize {
    if (data.len == 0) return 0;

    const newline_vec: Vec = @splat('\n');
    var count: usize = 0;
    var pos: usize = 0;

    // SIMD loop - count newlines in VECTOR_WIDTH bytes at a time
    while (pos + VECTOR_WIDTH <= data.len) {
        const chunk: Vec = data[pos..][0..VECTOR_WIDTH].*;
        const matches: BoolVec = chunk == newline_vec;

        // Convert bool vector to integer mask and popcount
        const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
        const mask: MaskType = @bitCast(matches);
        count += @popCount(mask);

        pos += VECTOR_WIDTH;
    }

    // Scalar tail
    for (data[pos..]) |c| {
        if (c == '\n') count += 1;
    }

    return count;
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

// =============================================================================
// Two-Byte SIMD Fingerprinting Tests (Phase 1 optimization)
// =============================================================================

test "findSubstringTwoByte two char patterns" {
    // Exact 2-char patterns (no middle verification needed)
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("ab", "ab"));
    try std.testing.expectEqual(@as(?usize, 1), findSubstring("xab", "ab"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring("axb", "ab"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("abcd", "ab"));
}

test "findSubstringTwoByte same first and last byte" {
    // Edge case: pattern starts and ends with same byte
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("aba", "aba"));
    try std.testing.expectEqual(@as(?usize, 1), findSubstring("xabax", "aba"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("aaa", "aa"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("aaaa", "aaa"));
}

test "findSubstringTwoByte long patterns" {
    // Patterns longer than SIMD width (16 bytes on ARM)
    const long_pattern = "this is a very long pattern here";
    const haystack = "prefix " ++ long_pattern ++ " suffix";
    try std.testing.expectEqual(@as(?usize, 7), findSubstring(haystack, long_pattern));
}

test "findSubstringTwoByte at SIMD boundaries" {
    // Pattern crosses SIMD chunk boundaries (16/32 bytes)
    var haystack: [48]u8 = undefined;
    @memset(&haystack, 'x');
    // Place "needle" at position 14 (crosses 16-byte boundary)
    @memcpy(haystack[14..20], "needle");
    try std.testing.expectEqual(@as(?usize, 14), findSubstring(&haystack, "needle"));

    // Place at position 15
    @memset(&haystack, 'x');
    @memcpy(haystack[15..21], "needle");
    try std.testing.expectEqual(@as(?usize, 15), findSubstring(&haystack, "needle"));

    // Place at position 31 (another boundary)
    @memset(&haystack, 'x');
    @memcpy(haystack[31..37], "needle");
    try std.testing.expectEqual(@as(?usize, 31), findSubstring(&haystack, "needle"));
}

test "findSubstringTwoByte many false positives" {
    // Test with many first+last byte matches but few full matches
    // Pattern "aba" has 'a' at both ends
    const haystack = "aa aa aa aba aa aa";
    try std.testing.expectEqual(@as(?usize, 9), findSubstring(haystack, "aba"));

    // More complex: "xyzx" where 'x' appears often
    const haystack2 = "xxxx xyzx xxxx";
    try std.testing.expectEqual(@as(?usize, 5), findSubstring(haystack2, "xyzx"));
}

test "findSubstringTwoByte scalar fallback" {
    // Test patterns that exercise the scalar tail path
    // Haystack just long enough to use SIMD once, then scalar
    var haystack: [20]u8 = undefined;
    @memset(&haystack, 'x');
    // Put pattern in scalar tail region (after first 16 bytes)
    @memcpy(haystack[17..19], "ab");
    try std.testing.expectEqual(@as(?usize, 17), findSubstring(&haystack, "ab"));
}

// =============================================================================
// Case-Insensitive Two-Byte Search Tests
// =============================================================================

test "findSubstringIgnoreCase basic" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("HELLO", "hello"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("hello", "HELLO"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("HeLLo", "hello"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("hElLo", "HELLO"));
}

test "findSubstringIgnoreCase mixed case pattern" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("hello", "HeLLo"));
    try std.testing.expectEqual(@as(?usize, 6), findSubstringIgnoreCase("hello WORLD", "world"));
    try std.testing.expectEqual(@as(?usize, 6), findSubstringIgnoreCase("hello world", "WORLD"));
}

test "findSubstringIgnoreCase non-alpha chars" {
    // Non-alphabetic characters should match exactly
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("123", "123"));
    try std.testing.expectEqual(@as(?usize, null), findSubstringIgnoreCase("123", "124"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("a1b", "A1B"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("A1B", "a1b"));
}

test "findSubstringIgnoreCase single char" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("A", "a"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("a", "A"));
    try std.testing.expectEqual(@as(?usize, 2), findSubstringIgnoreCase("xxA", "a"));
}

test "findSubstringIgnoreCase two char patterns" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("AB", "ab"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("ab", "AB"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("Ab", "aB"));
}

test "findSubstringFromIgnoreCase basic" {
    const data = "Hello World, HELLO Universe";
    try std.testing.expectEqual(@as(?usize, 0), findSubstringFromIgnoreCase(data, "hello", 0));
    try std.testing.expectEqual(@as(?usize, 13), findSubstringFromIgnoreCase(data, "hello", 1));
    try std.testing.expectEqual(@as(?usize, null), findSubstringFromIgnoreCase(data, "hello", 20));
}

test "findSubstringIgnoreCase long pattern" {
    const haystack = "THIS IS A VERY LONG STRING WITH PATTERN";
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase(haystack, "this is a very long"));
    // "PATTERN" starts at index 32 in the haystack
    try std.testing.expectEqual(@as(?usize, 32), findSubstringIgnoreCase(haystack, "pattern"));
}

// =============================================================================
// SIMD Newline Counting Tests (Phase 4 optimization)
// =============================================================================

test "countNewlines empty" {
    try std.testing.expectEqual(@as(usize, 0), countNewlines(""));
}

test "countNewlines no newlines" {
    try std.testing.expectEqual(@as(usize, 0), countNewlines("hello world"));
    try std.testing.expectEqual(@as(usize, 0), countNewlines("x"));
    try std.testing.expectEqual(@as(usize, 0), countNewlines("abc def ghi jkl"));
}

test "countNewlines single newline" {
    try std.testing.expectEqual(@as(usize, 1), countNewlines("\n"));
    try std.testing.expectEqual(@as(usize, 1), countNewlines("hello\n"));
    try std.testing.expectEqual(@as(usize, 1), countNewlines("hello\nworld"));
    try std.testing.expectEqual(@as(usize, 1), countNewlines("\nworld"));
}

test "countNewlines multiple newlines" {
    try std.testing.expectEqual(@as(usize, 3), countNewlines("a\nb\nc\n"));
    try std.testing.expectEqual(@as(usize, 5), countNewlines("\n\n\n\n\n"));
    try std.testing.expectEqual(@as(usize, 2), countNewlines("line1\nline2\n"));
}

test "countNewlines large buffer SIMD path" {
    // Test with buffer larger than SIMD width to exercise SIMD path
    var buf: [256]u8 = undefined;
    @memset(&buf, 'x');
    // Add 10 newlines at various positions
    buf[15] = '\n';
    buf[32] = '\n';
    buf[47] = '\n';
    buf[64] = '\n';
    buf[79] = '\n';
    buf[100] = '\n';
    buf[120] = '\n';
    buf[150] = '\n';
    buf[200] = '\n';
    buf[255] = '\n';
    try std.testing.expectEqual(@as(usize, 10), countNewlines(&buf));
}

test "countNewlines all newlines" {
    var buf: [64]u8 = undefined;
    @memset(&buf, '\n');
    try std.testing.expectEqual(@as(usize, 64), countNewlines(&buf));

    var small_buf: [16]u8 = undefined;
    @memset(&small_buf, '\n');
    try std.testing.expectEqual(@as(usize, 16), countNewlines(&small_buf));
}

test "countNewlines scalar tail" {
    // Test the scalar tail path (buffer not divisible by SIMD width)
    try std.testing.expectEqual(@as(usize, 2), countNewlines("a\nb\n")); // 4 bytes (< 16)
    try std.testing.expectEqual(@as(usize, 2), countNewlines("123456789012345\n1\n")); // 18 bytes

    // 17 bytes - one SIMD chunk + 1 scalar byte
    var buf17: [17]u8 = undefined;
    @memset(&buf17, 'x');
    buf17[0] = '\n';
    buf17[16] = '\n';
    try std.testing.expectEqual(@as(usize, 2), countNewlines(&buf17));
}

test "countNewlines at SIMD boundaries" {
    // Test newlines exactly at SIMD boundaries (16, 32, 48...)
    var buf: [64]u8 = undefined;
    @memset(&buf, 'x');
    buf[15] = '\n'; // Last byte of first chunk
    buf[16] = '\n'; // First byte of second chunk
    buf[31] = '\n'; // Last byte of second chunk
    buf[32] = '\n'; // First byte of third chunk
    try std.testing.expectEqual(@as(usize, 4), countNewlines(&buf));
}


