//! Turns source text into tokens, following spec §2.

use crate::{Diag, Pos};

#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    Name(String),
    Int(i64),
    Float(f64),
    Str(String),
    /// An f-string's literal text and fields, in order, without empty text.
    FStr(Vec<FPart>),
    /// A reserved word or an operator.
    Word(&'static str),
    Newline,
    Indent,
    Dedent,
    Eof,
}

#[derive(Clone, Debug, PartialEq)]
pub enum FPart {
    Text(String),
    /// The tokens of a field's expression, followed by its `}` and an end of
    /// file.
    Field(Vec<Token>),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Token {
    pub kind: Kind,
    pub pos: Pos,
}

const RESERVED: &[&str] = &[
    "False",
    "None",
    "True",
    "and",
    "as",
    "assert",
    "async",
    "await",
    "break",
    "case",
    "class",
    "continue",
    "def",
    "del",
    "elif",
    "else",
    "enum",
    "except",
    "finally",
    "for",
    "from",
    "global",
    "if",
    "import",
    "in",
    "is",
    "lambda",
    "match",
    "nonlocal",
    "not",
    "or",
    "pass",
    "protocol",
    "raise",
    "return",
    "try",
    "type",
    "while",
    "with",
    "yield",
    "int",
    "float",
    "bool",
    "str",
    "bytes",
    "list",
    "dict",
    "tuple",
    "Iterable",
    "Iterator",
    "ContextManager",
    "Generator",
    "Coroutine",
];

const OPERATORS: &[&str] = &[
    "...", "->", "==", "!=", "<=", ">=", "//", "<", ">", "=", "+", "-", "*", "/", "%", "|", "(",
    ")", "[", "]", "{", "}", ",", ":", ".",
];

const UNSUPPORTED: &[&str] = &[
    "**=", "//=", "<<=", ">>=", "**", "<<", ">>", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=",
    ":=", "&", "^", "~",
];

const TABS: &str = "tabs are not allowed outside strings and comments";

struct Lexer<'a> {
    path: &'a str,
    chars: Vec<char>,
    i: usize,
    line: u32,
    line_start: usize,
    depth: u32,
    tokens: Vec<Token>,
}

pub fn lex(path: &str, bytes: &[u8]) -> Result<Vec<Token>, Diag> {
    let text = match std::str::from_utf8(bytes) {
        Ok(text) => text,
        Err(e) => {
            // Report the position of the first invalid byte.
            let valid = std::str::from_utf8(&bytes[..e.valid_up_to()]).unwrap();
            let line = valid.matches('\n').count() as u32 + 1;
            let col = valid.rsplit('\n').next().unwrap().chars().count() as u32 + 1;
            return Err(Diag::new(path, Pos { line, col }, "invalid UTF-8"));
        }
    };
    let mut lexer = Lexer {
        path,
        chars: text.chars().collect(),
        i: 0,
        line: 1,
        line_start: 0,
        depth: 0,
        tokens: Vec::new(),
    };
    lexer.check_carriage_returns()?;
    lexer.run()?;
    Ok(lexer.tokens)
}

impl Lexer<'_> {
    fn pos_at(&self, i: usize) -> Pos {
        Pos {
            line: self.line,
            col: (i - self.line_start) as u32 + 1,
        }
    }

    fn fail<T>(&self, i: usize, message: impl Into<String>) -> Result<T, Diag> {
        Err(Diag::new(self.path, self.pos_at(i), message))
    }

    fn peek(&self, i: usize) -> Option<char> {
        self.chars.get(i).copied()
    }

    fn add(&mut self, kind: Kind, i: usize) {
        let pos = self.pos_at(i);
        self.tokens.push(Token { kind, pos });
    }

    /// Rejects every CR that does not start a CRLF, so the rest of the lexer
    /// can skip CRs.
    fn check_carriage_returns(&mut self) -> Result<(), Diag> {
        for i in 0..self.chars.len() {
            if self.chars[i] == '\r' && self.peek(i + 1) != Some('\n') {
                return self.fail(i, "bare carriage return; line endings must be LF or CRLF");
            }
            if self.chars[i] == '\n' {
                self.line += 1;
                self.line_start = i + 1;
            }
        }
        self.line = 1;
        self.line_start = 0;
        Ok(())
    }

    fn run(&mut self) -> Result<(), Diag> {
        let mut level = 0;
        while self.i < self.chars.len() {
            if self.depth == 0 {
                let mut first = self.i;
                while self.peek(first) == Some(' ') {
                    first += 1;
                }
                match self.peek(first) {
                    Some('\t') => return self.fail(first, TABS),
                    None | Some('\n' | '\r' | '#') => {
                        // Blank and comment-only lines produce no tokens.
                        self.i = first;
                        self.skip_comment();
                        self.end_line();
                        continue;
                    }
                    _ => {}
                }
                let width = first - self.i;
                if width % 4 != 0 {
                    return self.fail(first, "indentation must be a multiple of four spaces");
                }
                let new_level = width / 4;
                if new_level > level + 1 {
                    return self.fail(first, "unexpected indent");
                }
                if new_level > level {
                    self.add(Kind::Indent, first);
                }
                for _ in new_level..level {
                    self.add(Kind::Dedent, first);
                }
                level = new_level;
                self.i = first;
            }
            self.lex_line()?;
        }
        if !matches!(
            self.tokens.last().map(|t| &t.kind),
            None | Some(Kind::Newline)
        ) {
            self.add(Kind::Newline, self.i);
        }
        for _ in 0..level {
            self.add(Kind::Dedent, self.i);
        }
        self.add(Kind::Eof, self.i);
        Ok(())
    }

    fn skip_comment(&mut self) {
        if self.peek(self.i) == Some('#') {
            while !matches!(self.peek(self.i), None | Some('\n' | '\r')) {
                self.i += 1;
            }
        }
    }

    /// Consumes the line terminator at `i`, if any.
    fn end_line(&mut self) {
        if self.peek(self.i) == Some('\r') {
            self.i += 1;
        }
        if self.peek(self.i) == Some('\n') {
            self.i += 1;
            self.line += 1;
            self.line_start = self.i;
        }
    }

    /// Tokenizes up to and including the end of the current line, which a
    /// triple-quoted string may move to a later line.
    fn lex_line(&mut self) -> Result<(), Diag> {
        loop {
            let i = self.i;
            let Some(c) = self.peek(i) else { return Ok(()) };
            if c == '\r' || c == '\n' {
                if self.depth == 0 {
                    self.add(Kind::Newline, i);
                }
                self.end_line();
                return Ok(());
            }
            self.lex_token(c)?;
        }
    }

    /// Reads the token, space, or comment that starts with `c` at `self.i`.
    fn lex_token(&mut self, c: char) -> Result<(), Diag> {
        match c {
            ' ' => self.i += 1,
            '\t' => return self.fail(self.i, TABS),
            '#' => self.skip_comment(),
            '\'' | '"' => self.lex_string(false)?,
            '0'..='9' => self.lex_number()?,
            c if c.is_ascii_alphabetic() || c == '_' => self.lex_word()?,
            _ => self.lex_operator()?,
        }
        Ok(())
    }

    fn lex_word(&mut self) -> Result<(), Diag> {
        let start = self.i;
        while matches!(self.peek(self.i), Some(c) if c.is_ascii_alphanumeric() || c == '_') {
            self.i += 1;
        }
        let word: String = self.chars[start..self.i].iter().collect();
        if word == "f" && matches!(self.peek(self.i), Some('\'' | '"')) {
            return self.lex_string(true);
        }
        let kind = match RESERVED.iter().find(|&&r| r == word) {
            Some(r) => Kind::Word(r),
            None => Kind::Name(word),
        };
        self.add(kind, start);
        Ok(())
    }

    fn lex_number(&mut self) -> Result<(), Diag> {
        let start = self.i;
        let digits_end = self.skip_digits(start);
        let mut end = digits_end;
        if self.peek(end) == Some('.') && matches!(self.peek(end + 1), Some('0'..='9')) {
            end = self.skip_digits(end + 1);
        }
        if matches!(self.peek(end), Some('e' | 'E')) {
            let sign = usize::from(matches!(self.peek(end + 1), Some('+' | '-')));
            if matches!(self.peek(end + 1 + sign), Some('0'..='9')) {
                end = self.skip_digits(end + 1 + sign);
            }
        }
        let text: String = self.chars[start..end].iter().collect();
        // The rest of a malformed literal, including the sign of an exponent
        // without digits, as in `1e+`.
        let mut rest = end;
        loop {
            match self.peek(rest) {
                Some(c) if c.is_ascii_alphanumeric() || c == '_' || c == '.' => rest += 1,
                Some('+' | '-') if matches!(self.peek(rest - 1), Some('e' | 'E')) => rest += 1,
                _ => break,
            }
        }
        if rest > end {
            let all: String = self.chars[start..rest].iter().collect();
            return self.fail(start, format!("invalid number literal '{all}'"));
        }
        let float = end > digits_end;
        if digits_end - start > 1 && self.chars[start] == '0' {
            let kind = if float { "float" } else { "integer" };
            return self.fail(start, format!("{kind} literal has leading zeros"));
        }
        if float {
            // Rust's parse rounds to nearest, as the spec requires.
            let value: f64 = text.parse().unwrap();
            if value.is_infinite() {
                return self.fail(start, "float literal out of range");
            }
            self.add(Kind::Float(value), start);
        } else {
            // The int range is symmetric, so i64::MIN is not a literal value.
            match text.parse::<i64>() {
                Ok(value) => self.add(Kind::Int(value), start),
                Err(_) => return self.fail(start, "integer literal out of range"),
            }
        }
        self.i = end;
        Ok(())
    }

    fn skip_digits(&self, mut i: usize) -> usize {
        while matches!(self.peek(i), Some('0'..='9')) {
            i += 1;
        }
        i
    }

    /// Reads the string, or the f-string when `formatted`, whose opening
    /// quote is at `self.i`.
    fn lex_string(&mut self, formatted: bool) -> Result<(), Diag> {
        let start = self.i;
        let opening = self.pos_at(if formatted { start - 1 } else { start });
        let quote = self.chars[start];
        let triple = self.peek(start + 1) == Some(quote) && self.peek(start + 2) == Some(quote);
        let width = if triple { 3 } else { 1 };
        let mut parts = Vec::new();
        let mut text = String::new();
        self.i += width;
        loop {
            let i = self.i;
            let closing = (0..width).all(|k| self.peek(i + k) == Some(quote));
            match self.peek(i) {
                None => return Err(Diag::new(self.path, opening, "unterminated string literal")),
                Some('\n' | '\r') if !triple => {
                    return Err(Diag::new(self.path, opening, "unterminated string literal"))
                }
                Some(_) if closing => break,
                Some('\r') => self.i += 1,
                Some('\n') => {
                    text.push('\n');
                    self.i += 1;
                    self.line += 1;
                    self.line_start = self.i;
                }
                Some('\\') => text.push(self.lex_escape(opening, triple)?),
                Some('{') if formatted && self.peek(i + 1) != Some('{') => {
                    if !text.is_empty() {
                        parts.push(FPart::Text(std::mem::take(&mut text)));
                    }
                    let field = self.lex_field(quote, triple)?;
                    parts.push(FPart::Field(field));
                }
                Some(c @ ('{' | '}')) if formatted => {
                    if self.peek(i + 1) != Some(c) {
                        return self.fail(i, "single '}' is not allowed in an f-string");
                    }
                    text.push(c);
                    self.i += 2;
                }
                Some(c) => {
                    text.push(c);
                    self.i += 1;
                }
            }
        }
        self.i += width;
        let kind = if formatted {
            if !text.is_empty() {
                parts.push(FPart::Text(text));
            }
            Kind::FStr(parts)
        } else {
            Kind::Str(text)
        };
        self.tokens.push(Token { kind, pos: opening });
        Ok(())
    }

    /// Reads the field whose `{` is at `self.i`, in an f-string delimited by
    /// `quote`, and returns its tokens.
    fn lex_field(&mut self, quote: char, triple: bool) -> Result<Vec<Token>, Diag> {
        let open = self.i;
        let (line, line_start) = (self.line, self.line_start);
        let unterminated = Diag::new(self.path, self.pos_at(open), "unterminated f-string field");
        // Find the closing `}` first; the scan advances lines for its
        // diagnostics, and lexing the field advances them again.
        let mut nesting = 0;
        let mut i = open + 1;
        loop {
            let Some(c) = self.peek(i) else { return Err(unterminated) };
            match c {
                '\n' if triple => {
                    self.line += 1;
                    self.line_start = i + 1;
                }
                '\n' | '\r' if !triple => return Err(unterminated),
                '\\' => return self.fail(i, "f-string fields cannot contain a backslash"),
                '#' => return self.fail(i, "f-string fields cannot contain '#'"),
                c if c == quote => {
                    return self.fail(
                        i,
                        "f-string fields cannot contain the f-string's quote character",
                    )
                }
                '\'' | '"' => {
                    // A string in the other quote character may hold braces.
                    let mut close = i + 1;
                    while !matches!(self.peek(close), None | Some('\n' | '\r'))
                        && self.chars[close] != c
                    {
                        close += 1;
                    }
                    if self.peek(close) != Some(c) {
                        return self.fail(i, "unterminated string literal");
                    }
                    let bad = (i + 1..close).find(|&j| {
                        matches!(self.chars[j], '\\' | '#') || self.chars[j] == quote
                    });
                    if let Some(j) = bad {
                        let message = format!("f-string fields cannot contain '{}'", self.chars[j]);
                        return self.fail(j, message);
                    }
                    i = close;
                }
                '(' | '[' | '{' => nesting += 1,
                ')' | ']' => nesting -= 1,
                '}' if nesting == 0 => break,
                '}' => nesting -= 1,
                ':' if nesting == 0 => {
                    return self.fail(i, "format specifications are not supported")
                }
                '!' if nesting == 0 && self.peek(i + 1) != Some('=') => {
                    return self.fail(i, "conversions are not supported")
                }
                _ => {}
            }
            i += 1;
        }
        let stop = i;
        self.line = line;
        self.line_start = line_start;
        if self.chars[open + 1..stop].iter().all(|&c| matches!(c, ' ' | '\r' | '\n')) {
            return self.fail(open, "empty f-string field");
        }
        let outer = std::mem::take(&mut self.tokens);
        // Newlines inside a field do not end a statement.
        let depth = std::mem::replace(&mut self.depth, 1);
        self.i = open + 1;
        while self.i < stop {
            match self.chars[self.i] {
                '\r' | '\n' => self.end_line(),
                c => self.lex_token(c)?,
            }
        }
        self.add(Kind::Word("}"), stop);
        self.add(Kind::Eof, stop);
        self.depth = depth;
        self.i = stop + 1;
        Ok(std::mem::replace(&mut self.tokens, outer))
    }

    /// Reads the escape sequence at `self.i` in the string opened at
    /// `opening`, which is triple-quoted when `triple`.
    fn lex_escape(&mut self, opening: Pos, triple: bool) -> Result<char, Diag> {
        let at = self.i;
        let escaped = match self.peek(at + 1) {
            Some('\n' | '\r') if !triple => {
                return Err(Diag::new(self.path, opening, "unterminated string literal"))
            }
            None => return Err(Diag::new(self.path, opening, "unterminated string literal")),
            Some(c) => c,
        };
        let simple = match escaped {
            '\\' => Some('\\'),
            '\'' => Some('\''),
            '"' => Some('"'),
            'n' => Some('\n'),
            'r' => Some('\r'),
            't' => Some('\t'),
            _ => None,
        };
        if let Some(c) = simple {
            self.i += 2;
            return Ok(c);
        }
        let count = match escaped {
            'x' => 2,
            'u' => 4,
            'U' => 8,
            _ => return self.fail(at, format!("unknown escape sequence '\\{escaped}'")),
        };
        let digits: String = self.chars[at + 2..].iter().take(count).collect();
        if digits.chars().count() != count || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
            return self.fail(
                at,
                format!("escape '\\{escaped}' needs {count} hexadecimal digits"),
            );
        }
        let code = u32::from_str_radix(&digits, 16).unwrap();
        let Some(c) = char::from_u32(code) else {
            return self.fail(
                at,
                format!("escape '\\{escaped}{digits}' is not a valid code point"),
            );
        };
        self.i += 2 + count;
        Ok(c)
    }

    fn lex_operator(&mut self) -> Result<(), Diag> {
        let i = self.i;
        for length in (1..=3).rev() {
            let text: String = self.chars[i..].iter().take(length).collect();
            if text.chars().count() != length {
                continue;
            }
            if UNSUPPORTED.contains(&text.as_str()) {
                return self.fail(i, format!("unsupported operator '{text}'"));
            }
            if let Some(&op) = OPERATORS.iter().find(|&&op| op == text) {
                match op {
                    "(" | "[" | "{" => self.depth += 1,
                    ")" | "]" | "}" if self.depth > 0 => self.depth -= 1,
                    _ => {}
                }
                self.add(Kind::Word(op), i);
                self.i += length;
                return Ok(());
            }
        }
        self.fail(i, format!("unexpected character '{}'", self.chars[i]))
    }
}
