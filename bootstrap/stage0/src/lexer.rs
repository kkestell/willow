//! Turns source text into tokens, following spec §2.

use crate::{Diag, Pos};

#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    Name(String),
    Int(i64),
    Str(String),
    /// A reserved word or an operator.
    Word(&'static str),
    Newline,
    Indent,
    Dedent,
    Eof,
}

#[derive(Clone, Debug)]
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

    /// Tokenizes up to and including the end of the current line.
    fn lex_line(&mut self) -> Result<(), Diag> {
        loop {
            let i = self.i;
            let Some(c) = self.peek(i) else { return Ok(()) };
            match c {
                ' ' => self.i += 1,
                '\t' => return self.fail(i, TABS),
                '#' => self.skip_comment(),
                '\r' | '\n' => {
                    if self.depth == 0 {
                        self.add(Kind::Newline, i);
                    }
                    self.end_line();
                    return Ok(());
                }
                '\'' | '"' => self.lex_string()?,
                '0'..='9' => self.lex_number()?,
                c if c.is_ascii_alphabetic() || c == '_' => self.lex_word()?,
                _ => self.lex_operator()?,
            }
        }
    }

    fn lex_word(&mut self) -> Result<(), Diag> {
        let start = self.i;
        while matches!(self.peek(self.i), Some(c) if c.is_ascii_alphanumeric() || c == '_') {
            self.i += 1;
        }
        let word: String = self.chars[start..self.i].iter().collect();
        if word == "f" && matches!(self.peek(self.i), Some('\'' | '"')) {
            return self.fail(start, "f-strings are not supported");
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
        while matches!(self.peek(self.i), Some('0'..='9')) {
            self.i += 1;
        }
        let digits: String = self.chars[start..self.i].iter().collect();
        let fraction =
            self.peek(self.i) == Some('.') && matches!(self.peek(self.i + 1), Some('0'..='9'));
        if fraction || matches!(self.peek(self.i), Some('e' | 'E')) {
            return self.fail(start, "float literals are not supported");
        }
        if matches!(self.peek(self.i), Some(c) if c.is_ascii_alphanumeric() || c == '_') {
            let mut end = self.i;
            while matches!(self.peek(end), Some(c) if c.is_ascii_alphanumeric() || c == '_') {
                end += 1;
            }
            let text: String = self.chars[start..end].iter().collect();
            return self.fail(start, format!("invalid number literal '{text}'"));
        }
        if digits.len() > 1 && digits.starts_with('0') {
            return self.fail(start, "integer literal has leading zeros");
        }
        // The int range is symmetric, so i64::MIN is not a literal value.
        match digits.parse::<i64>() {
            Ok(value) => self.add(Kind::Int(value), start),
            Err(_) => return self.fail(start, "integer literal out of range"),
        }
        Ok(())
    }

    fn lex_string(&mut self) -> Result<(), Diag> {
        let start = self.i;
        let quote = self.chars[start];
        if self.peek(start + 1) == Some(quote) && self.peek(start + 2) == Some(quote) {
            return self.fail(start, "triple-quoted strings are not supported");
        }
        let mut text = String::new();
        self.i += 1;
        loop {
            let i = self.i;
            match self.peek(i) {
                None | Some('\n' | '\r') => return self.fail(start, "unterminated string literal"),
                Some(c) if c == quote => break,
                Some('\\') => text.push(self.lex_escape(start)?),
                Some(c) => {
                    text.push(c);
                    self.i += 1;
                }
            }
        }
        self.i += 1;
        self.add(Kind::Str(text), start);
        Ok(())
    }

    /// Reads the escape sequence at `i` in the string opened at `start`.
    fn lex_escape(&mut self, start: usize) -> Result<char, Diag> {
        let at = self.i;
        let escaped = match self.peek(at + 1) {
            None | Some('\n' | '\r') => return self.fail(start, "unterminated string literal"),
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
