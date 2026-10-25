/* Builds the syntax tree of one module from its tokens. */
#include "willow0.h"

#include <assert.h>
#include <string.h>

typedef struct Parser {
    String path;
    TokenVec tokens;
    size_t i;
} Parser;

static const char *const COMPARISONS[] = {"==", "!=", "<", "<=", ">", ">=", "in"};
static const char *const UNSUPPORTED_WORDS[] = {
    "as", "async", "await", "case", "del", "except", "finally", "from", "global",
    "lambda", "match", "nonlocal", "protocol", "raise", "try", "with", "yield"
};

static bool word_is(const Kind *kind, const char *word) {
    return kind->tag == KIND_Word && !strcmp(kind->as.Word, word);
}

static bool word_in(const Kind *kind, const char *const *words, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (word_is(kind, words[i])) {
            return true;
        }
    }
    return false;
}
#define WORD_IN(kind, ...) \
    word_in((kind), (const char *const[]){__VA_ARGS__}, \
            sizeof((const char *const[]){__VA_ARGS__}) / sizeof(const char *))

static String describe(const Kind *kind) {
    switch (kind->tag) {
    case KIND_Name: return str_format("'%s'", kind->as.Name.data);
    case KIND_Int: return STR("integer");
    case KIND_Float: return STR("float");
    case KIND_Str: return STR("string");
    case KIND_FStr: return STR("f-string");
    case KIND_Word: return str_format("'%s'", kind->as.Word);
    case KIND_Newline: return STR("end of line");
    case KIND_Indent: return STR("indent");
    case KIND_Dedent: return STR("dedent");
    case KIND_Eof: return STR("end of file");
    }
    assert(false);
    return STR("");
}

static bool is_construct(const Kind *kind) {
    return word_in(kind, UNSUPPORTED_WORDS, sizeof(UNSUPPORTED_WORDS) / sizeof(*UNSUPPORTED_WORDS));
}

static bool starts_expression(const Kind *kind) {
    switch (kind->tag) {
    case KIND_Name: case KIND_Int: case KIND_Float: case KIND_Str: case KIND_FStr:
        return true;
    case KIND_Word:
        return WORD_IN(kind, "true", "false", "none", "int", "float", "str", "bytes",
                       "(", "[", "{", "-", "+", "not", "await");
    default: return false;
    }
}

static const Kind *peek(const Parser *self) {
    return &self->tokens.data[self->i].kind;
}

static Pos pos(const Parser *self) {
    return self->tokens.data[self->i].pos;
}

static Token advance(Parser *self) {
    return self->tokens.data[self->i++];
}

static _Noreturn void parser_fail(const Parser *self, Pos at, String message) {
    fail(self->path, at, message);
}

static _Noreturn void unexpected(const Parser *self, const char *expected) {
    const Kind *kind = peek(self);
    if (is_construct(kind)) {
        parser_fail(self, pos(self), str_format("'%s' is not supported", kind->as.Word));
    }
    String found = describe(kind);
    parser_fail(self, pos(self), str_format("expected %s, found %s", expected, found.data));
}

static bool accept(Parser *self, const char *word) {
    if (word_is(peek(self), word)) {
        self->i++;
        return true;
    }
    return false;
}

static void expect(Parser *self, const char *word) {
    if (!accept(self, word)) {
        unexpected(self, str_format("'%s'", word).data);
    }
}

static bool accept_kind(Parser *self, KindTag kind) {
    if (peek(self)->tag == kind) {
        self->i++;
        return true;
    }
    return false;
}

static void expect_kind(Parser *self, KindTag kind, const char *expected) {
    if (!accept_kind(self, kind)) {
        unexpected(self, expected);
    }
}

static PosName name(Parser *self, const char *expected) {
    Pos at = pos(self);
    if (peek(self)->tag == KIND_Name) {
        String text = peek(self)->as.Name;
        self->i++;
        return (PosName){at, text};
    }
    unexpected(self, expected);
}

/* After a list item, accept a comma or close and report whether it ended. */
static bool list_end(Parser *self, const char *close) {
    if (accept(self, ",")) {
        return false;
    }
    if (accept(self, close)) {
        return true;
    }
    unexpected(self, str_format("',' or '%s'", close).data);
}

static Class class(Parser *self);
static Enum enumeration(Parser *self);
static Func declaration(Parser *self, bool method);
static TypeExpr type_expr(Parser *self);
static TypeName parser_type_name(Parser *self);
static StmtVec block(Parser *self);
static Stmt statement(Parser *self);
static StmtKind simple_statement(Parser *self);
static IfArm arm(Parser *self);
static Expr expr(Parser *self);
static Expr logical(Parser *self, const char *op);
static Expr negation(Parser *self);
static Expr comparison(Parser *self);
static Expr sum(Parser *self);
static Expr term(Parser *self);
static Expr unary(Parser *self);
static Expr postfix(Parser *self);
static Expr subscript(Parser *self, Expr object);
static Expr primary(Parser *self);

static void end_of_line(Parser *self) {
    expect_kind(self, KIND_Newline, "end of line");
}

Module parse(String module_name, String path, TokenVec tokens) {
    Parser p = {.path = path, .tokens = tokens};
    ImportVec imports = {0};
    while (accept(&p, "import")) {
        PosName item = name(&p, "a module name");
        while (accept(&p, ".")) {
            PosName part = name(&p, "a module name");
            item.name = str_format("%s.%s", item.name.data, part.name.data);
        }
        end_of_line(&p);
        vec_push(imports, ((Import){item.pos, item.name}));
    }
    Module module = {.name = module_name, .path = path, .imports = imports};
    while (peek(&p)->tag != KIND_Eof) {
        if (word_is(peek(&p), "import")) {
            parser_fail(&p, pos(&p), STR("imports must come before declarations"));
        }
        if (accept(&p, "class")) {
            vec_push(module.classes, class(&p));
        } else if (accept(&p, "enum")) {
            vec_push(module.enums, enumeration(&p));
        } else if (accept(&p, "type")) {
            PosName item = name(&p, "an alias name");
            expect(&p, "=");
            TypeExpr ty = type_expr(&p);
            end_of_line(&p);
            vec_push(module.aliases, ((Alias){item.pos, item.name, ty}));
        } else {
            vec_push(module.funcs, declaration(&p, false));
        }
    }
    return module;
}

static Expr *boxed_expr(Expr value) {
    return box_copy(&value, sizeof(value));
}

static const char *binary_op(Parser *self, const char *const *ops, size_t len, Pos *op_pos) {
    if (word_in(peek(self), ops, len)) {
        const char *op = peek(self)->as.Word;
        *op_pos = advance(self).pos;
        return op;
    }
    return NULL;
}
#define BINARY_OP(self, at, ...) \
    binary_op((self), (const char *const[]){__VA_ARGS__}, \
              sizeof((const char *const[]){__VA_ARGS__}) / sizeof(const char *), (at))

/* A literal default, with an optional sign on numbers. */
static Expr literal(Parser *self) {
    Pos at = pos(self);
    Pos sign_pos;
    const char *sign = BINARY_OP(self, &sign_pos, "-", "+");
    Kind token = *peek(self);
    ExprKind kind;
    switch (token.tag) {
    case KIND_Int: kind = (ExprKind){.tag = EXPR_Int, .as.Int = token.as.Int}; break;
    case KIND_Float: kind = (ExprKind){.tag = EXPR_Float, .as.Float = token.as.Float}; break;
    case KIND_Str:
        if (sign) {
            parser_fail(self, pos(self), STR("a default must be a literal"));
        }
        kind = (ExprKind){.tag = EXPR_Str, .as.Str = token.as.Str};
        break;
    default:
        if (!sign && word_is(&token, "none")) {
            kind = (ExprKind){.tag = EXPR_None};
        } else if (!sign && WORD_IN(&token, "true", "false")) {
            kind = (ExprKind){.tag = EXPR_Bool, .as.Bool = word_is(&token, "true")};
        } else {
            parser_fail(self, pos(self), STR("a default must be a literal"));
        }
        break;
    }
    Pos value_pos = advance(self).pos;
    Expr value = {value_pos, kind};
    if (sign) {
        return (Expr){at, {.tag = EXPR_Unary, .as.Unary = {sign, boxed_expr(value)}}};
    }
    return value;
}

/* A class declaration after its class keyword. */
static Class class(Parser *self) {
    PosName item = name(self, "a class name");
    if (word_is(peek(self), "(")) {
        parser_fail(self, pos(self), STR("base classes are not supported"));
    }
    if (word_is(peek(self), "[")) {
        parser_fail(self, pos(self), STR("type parameters are not supported"));
    }
    expect(self, ":");
    expect_kind(self, KIND_Newline, "end of line");
    expect_kind(self, KIND_Indent, "an indented block");
    FieldVec fields = {0};
    FuncVec methods = {0};
    while (!accept_kind(self, KIND_Dedent)) {
        if (word_is(peek(self), "def")) {
            vec_push(methods, declaration(self, true));
            continue;
        }
        bool is_field = peek(self)->tag == KIND_Name &&
            word_is(&self->tokens.data[self->i + 1].kind, ":");
        if (!is_field) {
            parser_fail(self, pos(self), STR("class bodies hold only field and method declarations"));
        }
        if (methods.len) {
            parser_fail(self, pos(self), STR("fields must come before methods"));
        }
        PosName field = name(self, "a field name");
        self->i++;
        TypeExpr ty = type_expr(self);
        Expr *default_ = accept(self, "=") ? boxed_expr(literal(self)) : NULL;
        end_of_line(self);
        vec_push(fields, ((Field){field.pos, field.name, ty, default_}));
    }
    return (Class){item.pos, item.name, fields, methods};
}

static Enum enumeration(Parser *self) {
    PosName item = name(self, "an enum name");
    expect(self, ":");
    expect_kind(self, KIND_Newline, "end of line");
    expect_kind(self, KIND_Indent, "an indented block");
    PosNameVec members = {0};
    while (!accept_kind(self, KIND_Dedent)) {
        bool is_member = peek(self)->tag == KIND_Name &&
            self->tokens.data[self->i + 1].kind.tag == KIND_Newline;
        if (!is_member) {
            parser_fail(self, pos(self), STR("enum bodies hold only member names"));
        }
        vec_push(members, name(self, "a member name"));
        self->i++;
    }
    return (Enum){item.pos, item.name, members};
}

/* A function, extern def, or method with an unannotated first self parameter. */
static Func declaration(Parser *self, bool method) {
    bool external = peek(self)->tag == KIND_Name && str_equal(peek(self)->as.Name, STR("extern")) &&
        word_is(&self->tokens.data[self->i + 1].kind, "def");
    if (external) {
        self->i++;
    } else if (!word_is(peek(self), "def")) {
        if (is_construct(peek(self))) {
            unexpected(self, "a declaration");
        }
        parser_fail(self, pos(self), STR("only function, class, protocol, enum, and type declarations are allowed at file scope"));
    }
    self->i++;
    PosName item = name(self, "a function name");
    expect(self, "(");
    if (method) {
        if (peek(self)->tag != KIND_Name || !str_equal(peek(self)->as.Name, STR("self"))) {
            parser_fail(self, pos(self), str_format("method '%s' must take 'self' as its first parameter", item.name.data));
        }
        self->i++;
        if (word_is(peek(self), ":")) {
            parser_fail(self, pos(self), STR("'self' cannot have an annotation"));
        }
        if (!accept(self, ",") && !word_is(peek(self), ")")) {
            unexpected(self, "',' or ')'");
        }
    }
    ParamVec params = {0};
    bool variadic = false;
    while (!accept(self, ")")) {
        if (external && accept(self, "...")) {
            variadic = true;
            expect(self, ")");
            break;
        }
        PosName param = name(self, "a parameter name");
        expect(self, ":");
        TypeExpr ty = type_expr(self);
        vec_push(params, ((Param){param.pos, param.name, ty}));
        if (list_end(self, ")")) {
            break;
        }
    }
    TypeExpr *ret = NULL;
    if (accept(self, "->")) {
        TypeExpr ty = type_expr(self);
        ret = box_copy(&ty, sizeof(ty));
    }
    StmtVec *body = NULL;
    if (external) {
        expect_kind(self, KIND_Newline, "end of line");
    } else {
        expect(self, ":");
        StmtVec stmts = block(self);
        body = box_copy(&stmts, sizeof(stmts));
    }
    return (Func){item.pos, item.name, params, variadic, ret, body};
}

static TypeExpr type_expr(Parser *self) {
    Pos at = pos(self);
    TypeNameVec members = {0};
    vec_push(members, parser_type_name(self));
    while (accept(self, "|")) {
        vec_push(members, parser_type_name(self));
    }
    return (TypeExpr){at, members};
}

static TypeName parser_type_name(Parser *self) {
    Pos at = pos(self);
    String text;
    if (peek(self)->tag == KIND_Name) {
        text = peek(self)->as.Name;
        self->i++;
        while (accept(self, ".")) {
            PosName part = name(self, "a type name");
            text = str_format("%s.%s", text.data, part.name.data);
        }
    } else if (WORD_IN(peek(self), "int", "float", "bool", "str", "none", "list", "dict")) {
        text = str_from_cstr(peek(self)->as.Word);
        self->i++;
    } else {
        unexpected(self, "a type");
    }
    TypeExprVec args = {0};
    if (accept(self, "[")) {
        do {
            vec_push(args, type_expr(self));
        } while (accept(self, ","));
        expect(self, "]");
    }
    return (TypeName){at, text, args};
}

/* The argument of __type may name an otherwise reserved built-in type. */
static TypeName descriptor_type(Parser *self) {
    Pos at = pos(self);
    if (WORD_IN(peek(self), "int", "float", "bool", "str", "bytes", "list", "dict", "tuple")) {
        String text = str_from_cstr(peek(self)->as.Word);
        self->i++;
        return (TypeName){.pos = at, .name = text};
    }
    return parser_type_name(self);
}

static StmtVec block(Parser *self) {
    expect_kind(self, KIND_Newline, "end of line");
    expect_kind(self, KIND_Indent, "an indented block");
    StmtVec stmts = {0};
    while (peek(self)->tag != KIND_Dedent) {
        vec_push(stmts, statement(self));
    }
    self->i++;
    return stmts;
}

static Stmt statement(Parser *self) {
    Pos at = pos(self);
    StmtKind kind;
    if (accept(self, "if")) {
        IfArmVec arms = {0};
        vec_push(arms, arm(self));
        while (self->i + 1 < self->tokens.len && word_is(peek(self), "else") &&
               word_is(&self->tokens.data[self->i + 1].kind, "if")) {
            self->i += 2;
            vec_push(arms, arm(self));
        }
        StmtVec *otherwise = NULL;
        if (accept(self, "else")) {
            expect(self, ":");
            StmtVec stmts = block(self);
            otherwise = box_copy(&stmts, sizeof(stmts));
        }
        kind = (StmtKind){.tag = STMT_If, .as.If = {arms, otherwise}};
    } else if (accept(self, "while")) {
        IfArm branch = arm(self);
        kind = (StmtKind){.tag = STMT_While, .as.While = {branch.cond, branch.body}};
    } else if (accept(self, "for")) {
        PosNameVec targets = {0};
        vec_push(targets, name(self, "a loop variable name"));
        while (accept(self, ",")) {
            vec_push(targets, name(self, "a loop variable name"));
        }
        expect(self, "in");
        Expr iterable = expr(self);
        expect(self, ":");
        StmtVec body = block(self);
        kind = (StmtKind){.tag = STMT_For, .as.For = {targets, iterable, body}};
    } else if (accept(self, "return")) {
        Expr *value = peek(self)->tag == KIND_Newline ? NULL : boxed_expr(expr(self));
        end_of_line(self);
        kind = (StmtKind){.tag = STMT_Return, .as.Return = value};
    } else if (accept(self, "assert")) {
        Expr cond = expr(self);
        Expr *message = accept(self, ",") ? boxed_expr(expr(self)) : NULL;
        end_of_line(self);
        kind = (StmtKind){.tag = STMT_Assert, .as.Assert = {cond, message}};
    } else if (accept(self, "pass")) {
        end_of_line(self);
        kind = (StmtKind){.tag = STMT_Pass};
    } else if (accept(self, "break")) {
        end_of_line(self);
        kind = (StmtKind){.tag = STMT_Break};
    } else if (accept(self, "continue")) {
        end_of_line(self);
        kind = (StmtKind){.tag = STMT_Continue};
    } else if (word_is(peek(self), "def")) {
        parser_fail(self, at, STR("'def' is not supported"));
    } else if (!starts_expression(peek(self))) {
        unexpected(self, "a statement");
    } else {
        kind = simple_statement(self);
    }
    return (Stmt){at, kind};
}

static IfArm arm(Parser *self) {
    Expr cond = expr(self);
    expect(self, ":");
    return (IfArm){cond, block(self)};
}

static StmtKind simple_statement(Parser *self) {
    Expr target = expr(self);
    Pos equals = pos(self);
    TypeExpr *annotation = NULL;
    if (word_is(peek(self), ":")) {
        if (target.kind.tag != EXPR_Name) {
            parser_fail(self, pos(self), STR("only a name can have an annotation"));
        }
        self->i++;
        TypeExpr ty = type_expr(self);
        if (!word_is(peek(self), "=")) {
            parser_fail(self, pos(self), STR("annotated assignment needs an initializer"));
        }
        annotation = box_copy(&ty, sizeof(ty));
    }
    if (accept(self, "=")) {
        Expr value = expr(self);
        if (word_is(peek(self), "=")) {
            parser_fail(self, pos(self), STR("chained assignment is not supported"));
        }
        end_of_line(self);
        switch (target.kind.tag) {
        case EXPR_Name:
            return (StmtKind){.tag = STMT_Assign, .as.Assign = {target.kind.as.Name, annotation, value}};
        case EXPR_Attr:
            return (StmtKind){.tag = STMT_SetField, .as.SetField = {
                *target.kind.as.Attr.object, target.kind.as.Attr.name_pos, target.kind.as.Attr.name, value}};
        case EXPR_Index:
            return (StmtKind){.tag = STMT_SetIndex, .as.SetIndex = {
                target.pos, *target.kind.as.Index.object, *target.kind.as.Index.index, value}};
        default:
            parser_fail(self, equals, STR("cannot assign to this expression"));
        }
    }
    if (target.kind.tag != EXPR_Call) {
        parser_fail(self, target.pos, STR("only calls and await expressions can be used as statements"));
    }
    end_of_line(self);
    return (StmtKind){.tag = STMT_Expr, .as.Expr = target};
}

static Expr expr(Parser *self) {
    return logical(self, "or");
}

static Expr logical(Parser *self, const char *op) {
    Expr left = !strcmp(op, "or") ? logical(self, "and") : negation(self);
    Pos op_pos;
    while (BINARY_OP(self, &op_pos, op)) {
        Expr right = !strcmp(op, "or") ? logical(self, "and") : negation(self);
        left = (Expr){op_pos, {.tag = EXPR_Binary, .as.Binary = {
            op, op_pos, boxed_expr(left), boxed_expr(right)}}};
    }
    return left;
}

static Expr negation(Parser *self) {
    Pos at = pos(self);
    if (accept(self, "not")) {
        Expr operand = negation(self);
        return (Expr){at, {.tag = EXPR_Unary, .as.Unary = {"not", boxed_expr(operand)}}};
    }
    return comparison(self);
}

static Expr comparison(Parser *self) {
    Expr left = sum(self);
    Pos at = pos(self);
    Pos op_pos;
    ExprKind kind;
    if (BINARY_OP(self, &op_pos, "is")) {
        bool negated = accept(self, "not");
        if (!accept(self, "none")) {
            parser_fail(self, pos(self), STR("'is' can only test for none"));
        }
        kind = (ExprKind){.tag = EXPR_IsNone, .as.IsNone = {boxed_expr(left), negated, op_pos}};
    } else if (word_is(peek(self), "not") && word_is(&self->tokens.data[self->i + 1].kind, "in")) {
        op_pos = pos(self);
        self->i += 2;
        Expr right = sum(self);
        kind = (ExprKind){.tag = EXPR_Binary, .as.Binary = {"not in", op_pos, boxed_expr(left), boxed_expr(right)}};
    } else {
        const char *op = binary_op(self, COMPARISONS, sizeof(COMPARISONS) / sizeof(*COMPARISONS), &op_pos);
        if (!op) {
            return left;
        }
        Expr right = sum(self);
        kind = (ExprKind){.tag = EXPR_Binary, .as.Binary = {op, op_pos, boxed_expr(left), boxed_expr(right)}};
    }
    if (word_in(peek(self), COMPARISONS, sizeof(COMPARISONS) / sizeof(*COMPARISONS)) || word_is(peek(self), "is")) {
        parser_fail(self, pos(self), STR("comparison chains are not supported"));
    }
    return (Expr){at, kind};
}

static Expr sum(Parser *self) {
    Expr left = term(self);
    Pos op_pos;
    const char *op;
    while ((op = BINARY_OP(self, &op_pos, "+", "-"))) {
        Expr right = term(self);
        left = (Expr){op_pos, {.tag = EXPR_Binary, .as.Binary = {op, op_pos, boxed_expr(left), boxed_expr(right)}}};
    }
    return left;
}

static Expr term(Parser *self) {
    Expr left = unary(self);
    Pos op_pos;
    const char *op;
    while ((op = BINARY_OP(self, &op_pos, "*", "/", "//", "%"))) {
        Expr right = unary(self);
        left = (Expr){op_pos, {.tag = EXPR_Binary, .as.Binary = {op, op_pos, boxed_expr(left), boxed_expr(right)}}};
    }
    return left;
}

static Expr unary(Parser *self) {
    Pos at;
    const char *op = BINARY_OP(self, &at, "-", "+");
    if (op) {
        Expr operand = unary(self);
        return (Expr){at, {.tag = EXPR_Unary, .as.Unary = {op, boxed_expr(operand)}}};
    }
    return postfix(self);
}

static Expr postfix(Parser *self) {
    Expr value = primary(self);
    for (;;) {
        if (accept(self, ".")) {
            PosName attr = name(self, "a field or method name");
            value = (Expr){attr.pos, {.tag = EXPR_Attr, .as.Attr = {boxed_expr(value), attr.pos, attr.name}}};
            continue;
        }
        if (word_is(peek(self), "[")) {
            value = subscript(self, value);
            continue;
        }
        if (!accept(self, "(")) {
            break;
        }
        ExprVec args = {0};
        while (!accept(self, ")")) {
            vec_push(args, expr(self));
            if (list_end(self, ")")) {
                break;
            }
        }
        Pos at = value.pos;
        value = (Expr){at, {.tag = EXPR_Call, .as.Call = {boxed_expr(value), args}}};
    }
    return value;
}

/* An index or slice positioned at its opening bracket. */
static Expr subscript(Parser *self, Expr object) {
    Pos at = advance(self).pos;
    Expr *start = word_is(peek(self), ":") ? NULL : boxed_expr(expr(self));
    ExprKind kind;
    if (accept(self, ":")) {
        Expr *stop = WORD_IN(peek(self), "]", ":") ? NULL : boxed_expr(expr(self));
        if (word_is(peek(self), ":")) {
            parser_fail(self, pos(self), STR("slice steps are not supported"));
        }
        kind = (ExprKind){.tag = EXPR_Slice, .as.Slice = {boxed_expr(object), start, stop}};
    } else {
        assert(start);
        kind = (ExprKind){.tag = EXPR_Index, .as.Index = {boxed_expr(object), start}};
    }
    expect(self, "]");
    return (Expr){at, kind};
}

static Expr primary(Parser *self) {
    Pos at = pos(self);
    Kind token = *peek(self);
    ExprKind kind;
    switch (token.tag) {
    case KIND_Int: kind = (ExprKind){.tag = EXPR_Int, .as.Int = token.as.Int}; break;
    case KIND_Float: kind = (ExprKind){.tag = EXPR_Float, .as.Float = token.as.Float}; break;
    case KIND_Str: kind = (ExprKind){.tag = EXPR_Str, .as.Str = token.as.Str}; break;
    case KIND_FStr: {
        self->i++;
        ExprVec exprs = {0};
        for (size_t j = 0; j < token.as.FStr.len; j++) {
            FPart part = token.as.FStr.data[j];
            switch (part.tag) {
            case FPART_Text:
                vec_push(exprs, ((Expr){at, {.tag = EXPR_Str, .as.Str = part.as.Text}}));
                break;
            case FPART_Field: {
                TokenVec outer = self->tokens;
                self->tokens = part.as.Field;
                size_t i = self->i;
                self->i = 0;
                vec_push(exprs, expr(self));
                expect(self, "}");
                self->tokens = outer;
                self->i = i;
                break;
            }
            }
        }
        return (Expr){at, {.tag = EXPR_FStr, .as.FStr = exprs}};
    }
    case KIND_Name:
        if (str_equal(token.as.Name, STR("__type")) && word_is(&self->tokens.data[self->i + 1].kind, "(")) {
            self->i += 2;
            TypeName ty = descriptor_type(self);
            expect(self, ")");
            return (Expr){at, {.tag = EXPR_TypeOf, .as.TypeOf = ty}};
        }
        kind = (ExprKind){.tag = EXPR_Name, .as.Name = token.as.Name};
        break;
    case KIND_Word:
        if (WORD_IN(&token, "int", "float", "bool", "str", "list", "dict")) {
            kind = (ExprKind){.tag = EXPR_Name, .as.Name = str_from_cstr(token.as.Word)};
        } else if (word_is(&token, "{")) {
            self->i++;
            ExprEntryVec entries = {0};
            while (!accept(self, "}")) {
                Expr key = expr(self);
                expect(self, ":");
                Expr value = expr(self);
                vec_push(entries, ((ExprEntry){key, value}));
                if (list_end(self, "}")) {
                    break;
                }
            }
            return (Expr){at, {.tag = EXPR_Dict, .as.Dict = entries}};
        } else if (word_is(&token, "[")) {
            self->i++;
            ExprVec items = {0};
            while (!accept(self, "]")) {
                vec_push(items, expr(self));
                if (list_end(self, "]")) {
                    break;
                }
            }
            return (Expr){at, {.tag = EXPR_List, .as.List = items}};
        } else if (word_is(&token, "none")) {
            kind = (ExprKind){.tag = EXPR_None};
        } else if (WORD_IN(&token, "true", "false")) {
            kind = (ExprKind){.tag = EXPR_Bool, .as.Bool = word_is(&token, "true")};
        } else if (word_is(&token, "(")) {
            self->i++;
            Expr value = expr(self);
            expect(self, ")");
            return value;
        } else {
            unexpected(self, "an expression");
        }
        break;
    default: unexpected(self, "an expression");
    }
    self->i++;
    return (Expr){at, kind};
}
