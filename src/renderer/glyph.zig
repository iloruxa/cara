//! The Glyph Document Language
//! The lexer for the four-rule grammer
//! Zero-Alloc
//! Every token's `text` is a slice into the source

const std = @import("std");
const scene_mod = @import("scene.zig");

const Scene = scene_mod.Scene;
const Entity = scene_mod.Entity;
const NodeKind = scene_mod.NodeKind;

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

pub const ParseError = error{ UnexpectedToken, UnexpectedEof };
pub const Error = ParseError || Scene.Error;

pub const Parser = struct {
    tz: Tokenizer,
    scene: *Scene,
    cur: Token,

    // 1-Token lookahead: distinguishes `key=value` from a sibling node
    ahead: Token,

    pub fn init(src: []const u8, sc: *Scene) Parser {
        var p = Parser{ .tz = Tokenizer.init(src), .scene = sc, .cur = undefined, .ahead = undefined };

        p.cur = p.tz.next();
        p.ahead = p.tz.next();

        return p;
    }

    fn advance(self: *Parser) void {
        self.cur = self.ahead;
        self.ahead = self.tz.next();
    }

    /// Parse the whole document under a synthetic `root`
    pub fn parse(self: *Parser) Error!Entity {
        const root = try self.scene.create(.root);

        while (self.cur.tag != .eof) {
            const child = try self.parseNode();
            self.scene.appendChild(root, child);
        }

        return root;
    }

    fn parseNode(self: *Parser) Error!Entity {
        if (self.cur.tag != .identifier) return error.UnexpectedToken;

        const entity = try self.scene.create(kindOf(self.cur.text));

        // Node name
        self.advance();

        // modifiers in any order: utilities, #id, key="value"
        while (true) {
            switch (self.cur.tag) {
                // style
                .utility => self.advance(),

                // id attr
                .hash_id => self.advance(),

                .identifier => {
                    // its the next sibling node
                    if (self.ahead.tag != .equals) break;

                    // key
                    self.advance();

                    // '='
                    self.advance();

                    switch (self.cur.tag) {
                        .string, .number, .signal => self.advance(),
                        else => return error.UnexpectedToken,
                    }
                },
                else => break,
            }
        }

        // children block, or a content string
        if (self.cur.tag == .lbrace) {
            // '{'
            self.advance();

            while (self.cur.tag != .rbrace) {
                if (self.cur.tag == .eof) return error.UnexpectedEof;

                const child = try self.parseNode();

                self.scene.appendChild(entity, child);
            }

            //'}'
            self.advance();
        } else if (self.cur.tag == .string) {
            // content (markdown-desugaring)
            self.advance();
        }

        return entity;
    }
};

fn kindOf(name: []const u8) NodeKind {
    if (std.mem.eql(u8, name, "box")) return .box;
    if (std.mem.eql(u8, name, "text")) return .text;
    if (std.mem.eql(u8, name, "button")) return .button;
    if (std.mem.eql(u8, name, "image")) return .image;

    // Capitalized
    if (name.len > 0 and std.ascii.isUpper(name[0])) return .component;

    // Unknown lowercase primitive: treat as a box for now
    return .box;
}

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

test "parses a nested document into a scene tree" {
    const s = try testing.allocator.create(Scene);
    defer testing.allocator.destroy(s);
    s.init();

    var p = Parser.init(
        \\box .flow-col .p-4 #panel {
        \\    text .bold "Hello"
        \\    button onClick=$save { text "Go" }
        \\}
    , s);
    const root = try p.parse();

    var rc = s.children(root);
    const box = rc.next().?;
    try testing.expectEqual(NodeKind.box, s.kind[box.index]);
    try testing.expect(rc.next() == null);

    var bc = s.children(box);
    const t = bc.next().?;
    const btn = bc.next().?;
    try testing.expectEqual(NodeKind.text, s.kind[t.index]);
    try testing.expectEqual(NodeKind.button, s.kind[btn.index]);
    try testing.expect(bc.next() == null);

    var btnc = s.children(btn);
    try testing.expectEqual(NodeKind.text, s.kind[(btnc.next().?).index]);
    try testing.expect(btnc.next() == null);
}

test "unclosed block is a parse error" {
    const s = try testing.allocator.create(Scene);
    defer testing.allocator.destroy(s);
    s.init();
    var p = Parser.init("box { text \"hi\"", s);
    try testing.expectError(error.UnexpectedEof, p.parse());
}
