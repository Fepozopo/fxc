//! Bounded shell-list scanning for permission rules, without executing or expanding input.
//! Only list and pipeline operators are supported. Other shell grammar falls back
//! to the caller's existing whole-command permission checks.
const std = @import("std");

/// A borrowed iterator over literal commands separated by &&, ||, ;, newline,
/// |, |&, or &. No memory is allocated. An error invalidates the entire scan,
/// including commands already returned; callers must not execute partial lists.
pub const Iterator = struct {
    command: []const u8,
    index: usize = 0,
    has_operators: bool = false,
    needs_command: bool = false,
    finished: bool = false,

    /// Borrows command after rejecting NUL and invalid UTF-8. Returns an error
    /// when the input cannot be safely interpreted as shell text.
    pub fn init(command: []const u8) error{UnsupportedSyntax}!Iterator {
        if (!std.unicode.utf8ValidateSlice(command) or std.mem.findScalar(u8, command, 0) != null)
            return error.UnsupportedSyntax;
        return .{ .command = command };
    }

    /// Returns the next borrowed command, null at the end, or UnsupportedSyntax
    /// for malformed lists or grammar outside the literal-command subset.
    pub fn next(self: *Iterator) error{UnsupportedSyntax}!?[]const u8 {
        if (self.finished) return null;
        var start = self.index;
        var in_single_quote = false;
        while (self.index < self.command.len) {
            const byte = self.command[self.index];
            if (byte == '\'') {
                in_single_quote = !in_single_quote;
                self.index += 1;
                continue;
            }
            if (in_single_quote) {
                self.index += 1;
                continue;
            }
            switch (byte) {
                // Do not mistake redirects, substitutions, comments, or groups
                // for a flat list. The existing static allow grammar also
                // excludes double quotes and escapes, so keep that boundary.
                '"', '\\', '$', '`', '(', ')', '{', '}', '<', '>', '#', '\r' => return error.UnsupportedSyntax,
                '&', '|', ';', '\n' => {
                    const end = self.index;
                    const following = if (end + 1 < self.command.len) self.command[end + 1] else 0;
                    if (byte == '&' and following == '>') return error.UnsupportedSyntax;
                    const paired = (byte == '&' and following == '&') or
                        (byte == '|' and (following == '|' or following == '&'));
                    self.index += if (paired) @as(usize, 2) else 1;
                    self.has_operators = true;
                    const segment = std.mem.trim(u8, self.command[start..end], " \t");
                    if (segment.len == 0) {
                        // Shells permit blank lines, including after && or |,
                        // but an empty operand before another operator is invalid.
                        if (byte != '\n') return error.UnsupportedSyntax;
                        start = self.index;
                        continue;
                    }
                    try checkSimpleCommand(segment);
                    self.needs_command = paired or byte == '|';
                    return segment;
                },
                else => self.index += 1,
            }
        }
        if (in_single_quote) return error.UnsupportedSyntax;
        const segment = std.mem.trim(u8, self.command[start..], " \t");
        if (segment.len == 0 and self.needs_command) return error.UnsupportedSyntax;
        self.finished = true;
        if (segment.len == 0) return null;
        try checkSimpleCommand(segment);
        return segment;
    }
};

/// Rejects shell control words at the start of a segment. Treating `then git
/// push` as a literal executable would hide the actual command from its rule.
fn checkSimpleCommand(command: []const u8) error{UnsupportedSyntax}!void {
    const end = std.mem.findAny(u8, command, " \t") orelse command.len;
    const first_word = command[0..end];
    for ([_][]const u8{
        "if",     "then",    "elif", "else",     "fi",     "for",  "while",  "until", "do", "done",
        "case",   "in",      "esac", "function", "select", "time", "coproc", "!",     "[[", "]]",
        // Also reject the control words used by the supported user shells.
        "repeat", "foreach", "end",  "switch",   "begin",
    }) |keyword| {
        if (std.mem.eql(u8, first_word, keyword)) return error.UnsupportedSyntax;
    }
}
