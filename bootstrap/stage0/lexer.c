/* Turns source text into tokens, following spec §2. */
#include "willow0.h"

#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static const char *const RESERVED[] = {
    "and", "as", "assert", "async", "await", "break", "case", "class", "continue",
    "def", "del", "else", "enum", "except", "false", "finally", "for",
    "from", "global", "if", "import", "in", "is", "lambda", "match", "none",
    "nonlocal", "not", "or", "pass", "protocol", "raise", "return", "true", "try",
    "type", "while", "with", "yield", "int", "float", "bool", "str", "bytes",
    "list", "dict", "tuple", "Iterable", "Iterator", "ContextManager", "Generator",
    "Coroutine"
};
static const char *const OPERATORS[] = {
    "...", "->", "==", "!=", "<=", ">=", "//", "<", ">", "=", "+", "-", "*", "/",
    "%", "|", "(", ")", "[", "]", "{", "}", ",", ":", "."
};
static const char *const UNSUPPORTED[] = {
    "**=", "//=", "<<=", ">>=", "**", "<<", ">>", "+=", "-=", "*=", "/=", "%=",
    "&=", "|=", "^=", ":=", "&", "^", "~"
};
static const char *const TABS = "tabs are not allowed outside strings and comments";
#define NO_CHAR UINT32_MAX

typedef struct Lexer {
    String path;
    CharVec chars;
    size_t i;
    uint32_t line;
    size_t line_start;
    uint32_t depth;
    TokenVec tokens;
} Lexer;

static Pos pos_at(const Lexer *self, size_t i) {
    return (Pos){self->line, (uint32_t)(i - self->line_start) + 1};
}

static _Noreturn void lexer_fail(const Lexer *self, size_t i, String message) {
    fail(self->path, pos_at(self, i), message);
}

static uint32_t peek(const Lexer *self, size_t i) {
    return i < self->chars.len ? self->chars.data[i] : NO_CHAR;
}

static void add(Lexer *self, Kind kind, size_t i) {
    vec_push(self->tokens, ((Token){kind, pos_at(self, i)}));
}

static bool digit(uint32_t c) {
    return c >= '0' && c <= '9';
}

static bool alphabetic(uint32_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static String text_between(const Lexer *self, size_t start, size_t end) {
    StringBuilder text = {0};
    for (size_t i = start; i < end; i++) {
        sb_push_char(&text, self->chars.data[i]);
    }
    return sb_finish(&text);
}

static String char_message(const char *before, uint32_t c, const char *after) {
    StringBuilder text = {0};
    sb_append(&text, str_from_cstr(before));
    sb_push_char(&text, c);
    sb_append(&text, str_from_cstr(after));
    return sb_finish(&text);
}

/* Reject every CR that does not start a CRLF, so the lexer can skip CRs. */
static void check_carriage_returns(Lexer *self) {
    for (size_t i = 0; i < self->chars.len; i++) {
        if (self->chars.data[i] == '\r' && peek(self, i + 1) != '\n') {
            lexer_fail(self, i, STR("bare carriage return; line endings must be LF or CRLF"));
        }
        if (self->chars.data[i] == '\n') {
            self->line++;
            self->line_start = i + 1;
        }
    }
    self->line = 1;
    self->line_start = 0;
}

static void lex_token(Lexer *self, uint32_t c);
static void lex_string(Lexer *self, bool formatted);

static void skip_comment(Lexer *self) {
    if (peek(self, self->i) == '#') {
        while (peek(self, self->i) != NO_CHAR && peek(self, self->i) != '\n' &&
               peek(self, self->i) != '\r') {
            self->i++;
        }
    }
}

/* Consume the line terminator at i, if any. */
static void end_line(Lexer *self) {
    if (peek(self, self->i) == '\r') {
        self->i++;
    }
    if (peek(self, self->i) == '\n') {
        self->i++;
        self->line++;
        self->line_start = self->i;
    }
}

static void lex_line(Lexer *self) {
    for (;;) {
        size_t i = self->i;
        uint32_t c = peek(self, i);
        if (c == NO_CHAR) {
            return;
        }
        if (c == '\r' || c == '\n') {
            if (self->depth == 0) {
                add(self, (Kind){.tag = KIND_Newline}, i);
            }
            end_line(self);
            return;
        }
        lex_token(self, c);
    }
}

static void run(Lexer *self) {
    size_t level = 0;
    while (self->i < self->chars.len) {
        if (self->depth == 0) {
            size_t first = self->i;
            while (peek(self, first) == ' ') {
                first++;
            }
            switch (peek(self, first)) {
            case '\t':
                lexer_fail(self, first, str_from_cstr(TABS));
            case NO_CHAR: case '\n': case '\r': case '#':
                self->i = first;
                skip_comment(self);
                end_line(self);
                continue;
            default: break;
            }
            size_t width = first - self->i;
            if (width % 4 != 0) {
                lexer_fail(self, first, STR("indentation must be a multiple of four spaces"));
            }
            size_t new_level = width / 4;
            if (new_level > level + 1) {
                lexer_fail(self, first, STR("unexpected indent"));
            }
            if (new_level > level) {
                add(self, (Kind){.tag = KIND_Indent}, first);
            }
            for (size_t j = new_level; j < level; j++) {
                add(self, (Kind){.tag = KIND_Dedent}, first);
            }
            level = new_level;
            self->i = first;
        }
        lex_line(self);
    }
    if (self->tokens.len && self->tokens.data[self->tokens.len - 1].kind.tag != KIND_Newline) {
        add(self, (Kind){.tag = KIND_Newline}, self->i);
    }
    for (size_t j = 0; j < level; j++) {
        add(self, (Kind){.tag = KIND_Dedent}, self->i);
    }
    add(self, (Kind){.tag = KIND_Eof}, self->i);
}

TokenVec lex(String path, String source) {
    Lexer lexer = {.path = path, .line = 1};
    size_t at = 0;
    Pos pos = {1, 1};
    while (at < source.len) {
        uint32_t c;
        if (!utf8_decode(source, &at, &c)) {
            fail(path, pos, STR("invalid UTF-8"));
        }
        vec_push(lexer.chars, c);
        if (c == '\n') {
            pos.line++;
            pos.col = 1;
        } else {
            pos.col++;
        }
    }
    check_carriage_returns(&lexer);
    run(&lexer);
    return lexer.tokens;
}

static void lex_word(Lexer *self) {
    size_t start = self->i;
    uint32_t c;
    while ((c = peek(self, self->i)), alphabetic(c) || digit(c) || c == '_') {
        self->i++;
    }
    String word = text_between(self, start, self->i);
    c = peek(self, self->i);
    if (str_equal(word, STR("f")) && (c == '\'' || c == '"')) {
        lex_string(self, true);
        return;
    }
    Kind kind = {.tag = KIND_Name, .as.Name = word};
    for (size_t j = 0; j < sizeof(RESERVED) / sizeof(*RESERVED); j++) {
        if (str_equal(word, str_from_cstr(RESERVED[j]))) {
            kind = (Kind){.tag = KIND_Word, .as.Word = RESERVED[j]};
            break;
        }
    }
    add(self, kind, start);
}

static size_t skip_digits(const Lexer *self, size_t i) {
    while (digit(peek(self, i))) {
        i++;
    }
    return i;
}

static void lex_number(Lexer *self) {
    size_t start = self->i;
    size_t digits_end = skip_digits(self, start);
    size_t end = digits_end;
    if (peek(self, end) == '.' && digit(peek(self, end + 1))) {
        end = skip_digits(self, end + 1);
    }
    if (peek(self, end) == 'e' || peek(self, end) == 'E') {
        size_t sign = peek(self, end + 1) == '+' || peek(self, end + 1) == '-';
        if (digit(peek(self, end + 1 + sign))) {
            end = skip_digits(self, end + 1 + sign);
        }
    }
    String text = text_between(self, start, end);
    size_t rest = end;
    for (;;) {
        uint32_t c = peek(self, rest);
        if (alphabetic(c) || digit(c) || c == '_' || c == '.') {
            rest++;
        } else if ((c == '+' || c == '-') &&
                   (peek(self, rest - 1) == 'e' || peek(self, rest - 1) == 'E')) {
            rest++;
        } else {
            break;
        }
    }
    if (rest > end) {
        String all = text_between(self, start, rest);
        lexer_fail(self, start, str_format("invalid number literal '%s'", all.data));
    }
    bool floating = end > digits_end;
    if (digits_end - start > 1 && self->chars.data[start] == '0') {
        lexer_fail(self, start, str_format("%s literal has leading zeros", floating ? "float" : "integer"));
    }
    if (floating) {
        double value = strtod(text.data, NULL);
        if (isinf(value)) {
            lexer_fail(self, start, STR("float literal out of range"));
        }
        add(self, (Kind){.tag = KIND_Float, .as.Float = value}, start);
    } else {
        errno = 0;
        long long value = strtoll(text.data, NULL, 10);
        if (errno == ERANGE || value > INT64_MAX) {
            lexer_fail(self, start, STR("integer literal out of range"));
        }
        add(self, (Kind){.tag = KIND_Int, .as.Int = (int64_t)value}, start);
    }
    self->i = end;
}

/* Read the field whose { is at i in an f-string delimited by quote. */
static TokenVec lex_field(Lexer *self, uint32_t quote, bool triple) {
    size_t open = self->i;
    uint32_t line = self->line;
    size_t line_start = self->line_start;
    Pos unterminated = pos_at(self, open);
    int nesting = 0;
    size_t i = open + 1;
    for (;;) {
        uint32_t c = peek(self, i);
        if (c == NO_CHAR || (!triple && (c == '\n' || c == '\r'))) {
            fail(self->path, unterminated, STR("unterminated f-string field"));
        }
        if (c == '\n' && triple) {
            self->line++;
            self->line_start = i + 1;
        } else if (c == '\\') {
            lexer_fail(self, i, STR("f-string fields cannot contain a backslash"));
        } else if (c == '#') {
            lexer_fail(self, i, STR("f-string fields cannot contain '#'"));
        } else if (c == quote) {
            lexer_fail(self, i, STR("f-string fields cannot contain the f-string's quote character"));
        } else if (c == '\'' || c == '"') {
            size_t close = i + 1;
            while (peek(self, close) != NO_CHAR && peek(self, close) != '\n' &&
                   peek(self, close) != '\r' && self->chars.data[close] != c) {
                close++;
            }
            if (peek(self, close) != c) {
                lexer_fail(self, i, STR("unterminated string literal"));
            }
            for (size_t j = i + 1; j < close; j++) {
                uint32_t ch = self->chars.data[j];
                if (ch == '\\' || ch == '#' || ch == quote) {
                    lexer_fail(self, j, char_message("f-string fields cannot contain '", ch, "'"));
                }
            }
            i = close;
        } else if (c == '(' || c == '[' || c == '{') {
            nesting++;
        } else if (c == ')' || c == ']') {
            nesting--;
        } else if (c == '}' && nesting == 0) {
            break;
        } else if (c == '}') {
            nesting--;
        } else if (c == ':' && nesting == 0) {
            lexer_fail(self, i, STR("format specifications are not supported"));
        } else if (c == '!' && nesting == 0 && peek(self, i + 1) != '=') {
            lexer_fail(self, i, STR("conversions are not supported"));
        }
        i++;
    }
    size_t stop = i;
    self->line = line;
    self->line_start = line_start;
    bool empty = true;
    for (size_t j = open + 1; j < stop; j++) {
        uint32_t c = self->chars.data[j];
        if (c != ' ' && c != '\r' && c != '\n') {
            empty = false;
            break;
        }
    }
    if (empty) {
        lexer_fail(self, open, STR("empty f-string field"));
    }
    TokenVec outer = self->tokens;
    self->tokens = (TokenVec){0};
    uint32_t depth = self->depth;
    self->depth = 1;
    self->i = open + 1;
    while (self->i < stop) {
        uint32_t c = self->chars.data[self->i];
        if (c == '\r' || c == '\n') {
            end_line(self);
        } else {
            lex_token(self, c);
        }
    }
    add(self, (Kind){.tag = KIND_Word, .as.Word = "}"}, stop);
    add(self, (Kind){.tag = KIND_Eof}, stop);
    self->depth = depth;
    self->i = stop + 1;
    TokenVec field = self->tokens;
    self->tokens = outer;
    return field;
}

static uint32_t lex_escape(Lexer *self, Pos opening, bool triple) {
    size_t at = self->i;
    uint32_t escaped = peek(self, at + 1);
    if (escaped == NO_CHAR || (!triple && (escaped == '\n' || escaped == '\r'))) {
        fail(self->path, opening, STR("unterminated string literal"));
    }
    uint32_t simple;
    switch (escaped) {
    case '\\': simple = '\\'; break;
    case '\'': simple = '\''; break;
    case '"': simple = '"'; break;
    case 'n': simple = '\n'; break;
    case 'r': simple = '\r'; break;
    case 't': simple = '\t'; break;
    default: simple = NO_CHAR; break;
    }
    if (simple != NO_CHAR) {
        self->i += 2;
        return simple;
    }
    size_t count;
    switch (escaped) {
    case 'x': count = 2; break;
    case 'u': count = 4; break;
    case 'U': count = 8; break;
    default:
        lexer_fail(self, at, char_message("unknown escape sequence '\\", escaped, "'"));
    }
    uint32_t code = 0;
    for (size_t j = 0; j < count; j++) {
        uint32_t c = peek(self, at + 2 + j);
        uint32_t value;
        if (digit(c)) {
            value = c - '0';
        } else if (c >= 'a' && c <= 'f') {
            value = c - 'a' + 10;
        } else if (c >= 'A' && c <= 'F') {
            value = c - 'A' + 10;
        } else {
            lexer_fail(self, at, str_format("escape '\\%c' needs %zu hexadecimal digits", (int)escaped, count));
        }
        code = code * 16 + value;
    }
    if (code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) {
        String digits = text_between(self, at + 2, at + 2 + count);
        lexer_fail(self, at, str_format("escape '\\%c%s' is not a valid code point", (int)escaped, digits.data));
    }
    self->i += 2 + count;
    return code;
}

/* Read a string whose opening quote is at i. */
static void lex_string(Lexer *self, bool formatted) {
    size_t start = self->i;
    Pos opening = pos_at(self, formatted ? start - 1 : start);
    uint32_t quote = self->chars.data[start];
    bool triple = peek(self, start + 1) == quote && peek(self, start + 2) == quote;
    size_t width = triple ? 3 : 1;
    FPartVec parts = {0};
    StringBuilder text = {0};
    self->i += width;
    for (;;) {
        size_t i = self->i;
        bool closing = true;
        for (size_t k = 0; k < width; k++) {
            if (peek(self, i + k) != quote) {
                closing = false;
            }
        }
        uint32_t c = peek(self, i);
        if (c == NO_CHAR || (!triple && (c == '\n' || c == '\r'))) {
            fail(self->path, opening, STR("unterminated string literal"));
        } else if (closing) {
            break;
        } else if (c == '\r') {
            self->i++;
        } else if (c == '\n') {
            sb_push_char(&text, '\n');
            self->i++;
            self->line++;
            self->line_start = self->i;
        } else if (c == '\\') {
            sb_push_char(&text, lex_escape(self, opening, triple));
        } else if (c == '{' && formatted && peek(self, i + 1) != '{') {
            if (text.len) {
                vec_push(parts, ((FPart){.tag = FPART_Text, .as.Text = sb_finish(&text)}));
            }
            TokenVec field = lex_field(self, quote, triple);
            vec_push(parts, ((FPart){.tag = FPART_Field, .as.Field = field}));
        } else if ((c == '{' || c == '}') && formatted) {
            if (peek(self, i + 1) != c) {
                lexer_fail(self, i, STR("single '}' is not allowed in an f-string"));
            }
            sb_push_char(&text, c);
            self->i += 2;
        } else {
            sb_push_char(&text, c);
            self->i++;
        }
    }
    self->i += width;
    Kind kind;
    if (formatted) {
        if (text.len) {
            vec_push(parts, ((FPart){.tag = FPART_Text, .as.Text = sb_finish(&text)}));
        }
        kind = (Kind){.tag = KIND_FStr, .as.FStr = parts};
    } else {
        kind = (Kind){.tag = KIND_Str, .as.Str = sb_finish(&text)};
    }
    vec_push(self->tokens, ((Token){kind, opening}));
}

static void lex_operator(Lexer *self) {
    size_t i = self->i;
    for (size_t length = 3; length > 0; length--) {
        if (length > self->chars.len - i) {
            continue;
        }
        String text = text_between(self, i, i + length);
        for (size_t j = 0; j < sizeof(UNSUPPORTED) / sizeof(*UNSUPPORTED); j++) {
            if (str_equal(text, str_from_cstr(UNSUPPORTED[j]))) {
                lexer_fail(self, i, str_format("unsupported operator '%s'", text.data));
            }
        }
        for (size_t j = 0; j < sizeof(OPERATORS) / sizeof(*OPERATORS); j++) {
            const char *op = OPERATORS[j];
            if (!str_equal(text, str_from_cstr(op))) {
                continue;
            }
            if (!strcmp(op, "(") || !strcmp(op, "[") || !strcmp(op, "{")) {
                self->depth++;
            } else if (self->depth > 0 &&
                       (!strcmp(op, ")") || !strcmp(op, "]") || !strcmp(op, "}"))) {
                self->depth--;
            }
            add(self, (Kind){.tag = KIND_Word, .as.Word = op}, i);
            self->i += length;
            return;
        }
    }
    lexer_fail(self, i, char_message("unexpected character '", self->chars.data[i], "'"));
}

static void lex_token(Lexer *self, uint32_t c) {
    switch (c) {
    case ' ': self->i++; break;
    case '\t': lexer_fail(self, self->i, str_from_cstr(TABS));
    case '#': skip_comment(self); break;
    case '\'': case '"': lex_string(self, false); break;
    default:
        if (digit(c)) {
            lex_number(self);
        } else if (alphabetic(c) || c == '_') {
            lex_word(self);
        } else {
            lex_operator(self);
        }
        break;
    }
}
