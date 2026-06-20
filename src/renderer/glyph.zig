//! The Glyph Document Language
//! The lexer for the four-rule grammer
//! Zero-Alloc
//! Every token's `text` is a slice into the source

const std = @import("std");

pub const Token = struct {
    tag: Tag,

    // This is:
    //  - Identifier
    //  - Utility
    //  - ID
    //  - String inner
    //  - Number
    //  - Signal bytes
    text: []const u8,

    triple_quoted: bool = false,

    pub const Tag = enum {
        // box, text, Card
        // also attribute keys; parser disambiguates by context
        identifier,

        // .flow-col -> text = "flow-col"
        utility,

        // #settings -> text = "settings"
        hash_id,

        // =
        equals,

        // "..." / """...""" -> text = inner bytes
        string,

        // 420, 6.9
        number,

        // $saveData -> text = "saveData"
        signal,

        // {
        lbrace,

        // }
        rbrace,

        // unrecognized bytes; the parser turns this into a positioned error
        invalid,

        // End of file
        eof,
    };
};

pub const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn init(src: []const u8) Tokenizer {
        return .{ .src = src };
    }

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }

    fn isNumberChar(c: u8) bool {
        return std.ascii.isDigit(c) or c == '.';
    }

    fn span(self: *Tokenizer, start: usize, comptime pred: fn (u8) bool) []const u8 {
        while (self.pos < self.src.len and pred(self.src[self.pos])) self.pos += 1;

        return self.src[start..self.pos];
    }

    fn one(self: *Tokenizer, tag: Token.Tag) Token {
        self.pos += 1;

        return .{ .tag = tag, .text = self.src[self.pos - 1 .. self.pos] };
    }

    pub fn next(self: *Tokenizer) Token {
        while (self.pos < self.src.len and std.ascii.isWhitespace(self.src[self.pos])) self.pos += 1;

        if (self.pos >= self.src.len) return .{ .tag = .eof, .text = self.src[self.src.len..] };

        const c = self.src[self.pos];

        switch (c) {
            '{' => return self.one(.lbrace),
            '}' => return self.one(.rbrace),
            '=' => return self.one(.equals),
            '"' => return self.readString(),
            '.' => {
                self.pos += 1;

                return .{ .tag = .utility, .text = self.span(self.pos, isIdentChar) };
            },
            '#' => {
                self.pos += 1;

                return .{
                    .tag = .hash_id,
                    .text = self.span(self.pos, isIdentChar),
                };
            },
            '$' => {
                self.pos += 1;

                return .{ .tag = .signal, .text = self.span(self.pos, isIdentChar) };
            },
            else => {
                if (isIdentStart(c)) return .{ .tag = .identifier, .text = self.span(self.pos, isIdentChar) };

                if (std.ascii.isDigit(c)) return .{ .tag = .number, .text = self.span(self.pos, isNumberChar) };

                return self.one(.invalid);
            },
        }
    }

    fn readString(self: *Tokenizer) Token {
        const triple = self.pos + 3 <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "\"\"\"");

        if (triple) {
            // skip opening """
            self.pos += 3;
            const start = self.pos;

            while (self.pos + 3 <= self.src.len and !std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "\"\"\"")) self.pos += 1;

            const text = self.src[start..self.pos];

            // skip closing """
            if (self.pos + 3 <= self.src.len) self.pos += 3;

            return .{ .tag = .string, .text = text, .triple_quoted = triple };
        }

        // skip opening "
        self.pos += 1;

        const start = self.pos;

        while (self.pos < self.src.len and self.src[self.pos] != '"') {
            // \x escapes the next byte (resolved in markdown pass)
            // it never closes the string
            self.pos += if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len) 2 else 1;
        }

        const text = self.src[start..self.pos];

        // skip closing "
        if (self.pos < self.src.len) self.pos += 1;

        return .{ .tag = .string, .text = text };
    }
};

// --- Tests ---
const testing = std.testing;

test "token sequence over a representative document" {
    var tz = Tokenizer.init(
        \\box #panel .flow-col .p-4 {
        \\    text .bold "Hello"
        \\    button onClick=$save { text "Go" }
        \\}
    );
    const expected = [_]Token.Tag{
        .identifier, .hash_id, .utility, .utility,    .lbrace,
        .identifier, .utility, .string,  .identifier, .identifier,
        .equals,     .signal,  .lbrace,  .identifier, .string,
        .rbrace,     .rbrace,  .eof,
    };
    for (expected) |tag| {
        try testing.expectEqual(tag, tz.next().tag);
    }
}

test "token text is the meaningful slice (no dot, no quotes)" {
    var tz = Tokenizer.init("text .text-xl \"a **b** c\"");
    const a = tz.next();
    try testing.expectEqual(Token.Tag.identifier, a.tag);
    try testing.expectEqualStrings("text", a.text);

    const u = tz.next();
    try testing.expectEqual(Token.Tag.utility, u.tag);
    try testing.expectEqualStrings("text-xl", u.text);

    const s = tz.next();
    try testing.expectEqual(Token.Tag.string, s.tag);
    try testing.expectEqualStrings("a **b** c", s.text);
    try testing.expect(!s.triple_quoted);
}

test "triple-quoted string keeps raw inner bytes and flags opt-out" {
    var tz = Tokenizer.init("text \"\"\"raw **not bold**\"\"\"");
    _ = tz.next(); // text
    const s = tz.next();
    try testing.expectEqual(Token.Tag.string, s.tag);
    try testing.expect(s.triple_quoted);
    try testing.expectEqualStrings("raw **not bold**", s.text);
}
