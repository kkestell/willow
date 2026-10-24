//! Builds the syntax tree of one module from its tokens.

use crate::lexer::{FPart, Kind, Token};
use crate::{Diag, Pos};

pub struct Module {
    pub name: String,
    pub path: String,
    pub imports: Vec<Import>,
    pub funcs: Vec<Func>,
    pub classes: Vec<Class>,
    pub enums: Vec<Enum>,
    pub aliases: Vec<Alias>,
}

pub struct Import {
    pub pos: Pos,
    /// The module's full name, as in `app.util`.
    pub name: String,
}

pub struct Class {
    pub pos: Pos,
    pub name: String,
    pub fields: Vec<Field>,
    /// The methods, whose `params` leave out `self`.
    pub methods: Vec<Func>,
}

pub struct Field {
    pub pos: Pos,
    pub name: String,
    pub ty: TypeExpr,
    /// A literal default.
    pub default: Option<Expr>,
}

pub struct Enum {
    pub pos: Pos,
    pub name: String,
    pub members: Vec<(Pos, String)>,
}

/// A `type` declaration.
pub struct Alias {
    pub pos: Pos,
    pub name: String,
    pub ty: TypeExpr,
}

/// A `def`, or an `extern def` when `body` is `None`.
pub struct Func {
    pub pos: Pos,
    pub name: String,
    pub params: Vec<Param>,
    pub variadic: bool,
    pub ret: Option<TypeExpr>,
    pub body: Option<Vec<Stmt>>,
}

pub struct Param {
    pub pos: Pos,
    pub name: String,
    pub ty: TypeExpr,
}

pub struct TypeName {
    pub pos: Pos,
    /// The name, qualified with a module name as in `app.util.Item`.
    pub name: String,
    /// The arguments of a generic type, as in `list[int]`.
    pub args: Vec<TypeExpr>,
}

/// An annotation: one type name, or the members of a union.
pub struct TypeExpr {
    pub pos: Pos,
    pub members: Vec<TypeName>,
}

pub struct Stmt {
    pub pos: Pos,
    pub kind: StmtKind,
}

pub enum StmtKind {
    Assert {
        cond: Expr,
        message: Option<Expr>,
    },
    Assign {
        target: String,
        annotation: Option<TypeExpr>,
        value: Expr,
    },
    Expr(Expr),
    /// `if`/`elif` arms in order, then the `else` block.
    If {
        arms: Vec<(Expr, Vec<Stmt>)>,
        otherwise: Option<Vec<Stmt>>,
    },
    /// `for target in iterable:`, or `for key, value in d.items():`.
    For {
        /// Each target's position and name.
        targets: Vec<(Pos, String)>,
        iterable: Expr,
        body: Vec<Stmt>,
    },
    /// `object.name = value`.
    SetField {
        object: Expr,
        name_pos: Pos,
        name: String,
        value: Expr,
    },
    /// `object[index] = value`, with the position of `[`.
    SetIndex {
        bracket: Pos,
        object: Expr,
        index: Expr,
        value: Expr,
    },
    While {
        cond: Expr,
        body: Vec<Stmt>,
    },
    Return(Option<Expr>),
    Pass,
    Break,
    Continue,
}

pub struct Expr {
    pub pos: Pos,
    pub kind: ExprKind,
}

pub enum ExprKind {
    Int(i64),
    Float(f64),
    Str(String),
    /// An f-string's parts in order: `Str` for literal text, and fields.
    FStr(Vec<Expr>),
    Bool(bool),
    Name(String),
    Call(Box<Expr>, Vec<Expr>),
    /// A list display.
    List(Vec<Expr>),
    /// A dict display's entries.
    Dict(Vec<(Expr, Expr)>),
    Index(Box<Expr>, Box<Expr>),
    /// `object[start:stop]`, either bound omitted.
    Slice(Box<Expr>, Option<Box<Expr>>, Option<Box<Expr>>),
    /// `object.name`, with the position of the name.
    Attr(Box<Expr>, Pos, String),
    Unary(&'static str, Box<Expr>),
    /// The operator, its position, and the operands.
    Binary(&'static str, Pos, Box<Expr>, Box<Expr>),
    /// The `__type(T)` intrinsic, whose argument is a type.
    TypeOf(TypeName),
    None,
    /// `operand is None`, or `operand is not None` when negated, with the
    /// position of `is`.
    IsNone {
        operand: Box<Expr>,
        negated: bool,
        op_pos: Pos,
    },
}

struct Parser<'a> {
    path: &'a str,
    tokens: Vec<Token>,
    i: usize,
}

pub fn parse(name: &str, path: &str, tokens: Vec<Token>) -> Result<Module, Diag> {
    let mut p = Parser { path, tokens, i: 0 };
    let mut imports = Vec::new();
    while p.accept("import") {
        let (pos, mut name) = p.name("a module name")?;
        while p.accept(".") {
            name = format!("{name}.{}", p.name("a module name")?.1);
        }
        p.end_of_line()?;
        imports.push(Import { pos, name });
    }
    let mut module = Module {
        name: name.to_string(),
        path: path.to_string(),
        imports,
        funcs: Vec::new(),
        classes: Vec::new(),
        enums: Vec::new(),
        aliases: Vec::new(),
    };
    while p.peek() != &Kind::Eof {
        if p.peek() == &Kind::Word("import") {
            return p.fail(p.pos(), "imports must come before declarations");
        }
        if p.accept("class") {
            module.classes.push(p.class()?);
        } else if p.accept("enum") {
            module.enums.push(p.enumeration()?);
        } else if p.accept("type") {
            let (pos, name) = p.name("an alias name")?;
            p.expect("=")?;
            let ty = p.type_expr()?;
            p.end_of_line()?;
            module.aliases.push(Alias { pos, name, ty });
        } else {
            module.funcs.push(p.declaration(false)?);
        }
    }
    Ok(module)
}

const COMPARISONS: &[&str] = &["==", "!=", "<", "<=", ">", ">=", "in"];

fn describe(kind: &Kind) -> String {
    match kind {
        Kind::Name(name) => format!("'{name}'"),
        Kind::Int(_) => "integer".into(),
        Kind::Float(_) => "float".into(),
        Kind::Str(_) => "string".into(),
        Kind::FStr(_) => "f-string".into(),
        Kind::Word(word) => format!("'{word}'"),
        Kind::Newline => "end of line".into(),
        Kind::Indent => "indent".into(),
        Kind::Dedent => "dedent".into(),
        Kind::Eof => "end of file".into(),
    }
}

/// The reserved words that begin constructs stage 0 does not parse.
const UNSUPPORTED_WORDS: &[&str] = &[
    "as", "async", "await", "case", "del", "except", "finally", "from", "global", "lambda",
    "match", "nonlocal", "protocol", "raise", "try", "with", "yield",
];

fn is_construct(kind: &Kind) -> bool {
    matches!(kind, Kind::Word(w) if UNSUPPORTED_WORDS.contains(w))
}

/// Whether a token can begin an expression.
fn starts_expression(kind: &Kind) -> bool {
    match kind {
        Kind::Name(_) | Kind::Int(_) | Kind::Float(_) | Kind::Str(_) | Kind::FStr(_) => true,
        Kind::Word(w) => matches!(
            *w,
            "True"
                | "False"
                | "None"
                | "int"
                | "float"
                | "str"
                | "bytes"
                | "("
                | "["
                | "{"
                | "-"
                | "+"
                | "not"
                | "await"
        ),
        _ => false,
    }
}

impl Parser<'_> {
    fn peek(&self) -> &Kind {
        &self.tokens[self.i].kind
    }

    fn pos(&self) -> Pos {
        self.tokens[self.i].pos
    }

    fn advance(&mut self) -> Token {
        let token = self.tokens[self.i].clone();
        self.i += 1;
        token
    }

    fn fail<T>(&self, pos: Pos, message: impl Into<String>) -> Result<T, Diag> {
        Err(Diag::new(self.path, pos, message))
    }

    fn unexpected<T>(&self, expected: &str) -> Result<T, Diag> {
        let kind = self.peek();
        if let (true, Kind::Word(word)) = (is_construct(kind), kind) {
            return self.fail(self.pos(), format!("'{word}' is not supported"));
        }
        self.fail(
            self.pos(),
            format!("expected {expected}, found {}", describe(kind)),
        )
    }

    fn accept(&mut self, word: &str) -> bool {
        if matches!(self.peek(), Kind::Word(w) if *w == word) {
            self.i += 1;
            true
        } else {
            false
        }
    }

    fn expect(&mut self, word: &str) -> Result<(), Diag> {
        if self.accept(word) {
            Ok(())
        } else {
            self.unexpected(&format!("'{word}'"))
        }
    }

    fn accept_kind(&mut self, kind: Kind) -> bool {
        if *self.peek() == kind {
            self.i += 1;
            true
        } else {
            false
        }
    }

    fn expect_kind(&mut self, kind: Kind, expected: &str) -> Result<(), Diag> {
        if self.accept_kind(kind) {
            Ok(())
        } else {
            self.unexpected(expected)
        }
    }

    /// A name, which `expected` describes in a diagnostic.
    fn name(&mut self, expected: &str) -> Result<(Pos, String), Diag> {
        let pos = self.pos();
        match self.peek().clone() {
            Kind::Name(name) => {
                self.i += 1;
                Ok((pos, name))
            }
            _ => self.unexpected(expected),
        }
    }

    /// After an item of a parenthesized or bracketed list, accepts `,` or the
    /// list's `close`; returns whether the list ended.
    fn list_end(&mut self, close: &str) -> Result<bool, Diag> {
        if self.accept(",") {
            Ok(false)
        } else if self.accept(close) {
            Ok(true)
        } else {
            self.unexpected(&format!("',' or '{close}'"))
        }
    }

    /// A class declaration after its `class`.
    fn class(&mut self) -> Result<Class, Diag> {
        let (pos, name) = self.name("a class name")?;
        match self.peek() {
            Kind::Word("(") => return self.fail(self.pos(), "base classes are not supported"),
            Kind::Word("[") => return self.fail(self.pos(), "type parameters are not supported"),
            _ => {}
        }
        self.expect(":")?;
        self.expect_kind(Kind::Newline, "end of line")?;
        self.expect_kind(Kind::Indent, "an indented block")?;
        let mut fields = Vec::new();
        let mut methods = Vec::new();
        while !self.accept_kind(Kind::Dedent) {
            if self.peek() == &Kind::Word("def") {
                methods.push(self.declaration(true)?);
                continue;
            }
            let is_field = matches!(self.peek(), Kind::Name(_))
                && self.tokens[self.i + 1].kind == Kind::Word(":");
            if !is_field {
                return self.fail(
                    self.pos(),
                    "class bodies hold only field and method declarations",
                );
            }
            if !methods.is_empty() {
                return self.fail(self.pos(), "fields must come before methods");
            }
            let (pos, name) = self.name("a field name")?;
            self.i += 1;
            let ty = self.type_expr()?;
            let default = if self.accept("=") {
                Some(self.literal()?)
            } else {
                None
            };
            self.end_of_line()?;
            fields.push(Field {
                pos,
                name,
                ty,
                default,
            });
        }
        Ok(Class {
            pos,
            name,
            fields,
            methods,
        })
    }

    /// A literal default: None, True, False, a string, or a number with an
    /// optional sign.
    fn literal(&mut self) -> Result<Expr, Diag> {
        let pos = self.pos();
        let sign = self.binary_op(&["-", "+"]).map(|(op, _)| op);
        let kind = match (self.peek().clone(), sign) {
            (Kind::Int(n), _) => ExprKind::Int(n),
            (Kind::Float(x), _) => ExprKind::Float(x),
            (Kind::Str(text), None) => ExprKind::Str(text),
            (Kind::Word("None"), None) => ExprKind::None,
            (Kind::Word("True"), None) => ExprKind::Bool(true),
            (Kind::Word("False"), None) => ExprKind::Bool(false),
            _ => return self.fail(self.pos(), "a default must be a literal"),
        };
        let value_pos = self.advance().pos;
        let value = Expr {
            pos: value_pos,
            kind,
        };
        Ok(match sign {
            Some(op) => Expr {
                pos,
                kind: ExprKind::Unary(op, Box::new(value)),
            },
            None => value,
        })
    }

    /// An enum declaration after its `enum`.
    fn enumeration(&mut self) -> Result<Enum, Diag> {
        let (pos, name) = self.name("an enum name")?;
        self.expect(":")?;
        self.expect_kind(Kind::Newline, "end of line")?;
        self.expect_kind(Kind::Indent, "an indented block")?;
        let mut members = Vec::new();
        while !self.accept_kind(Kind::Dedent) {
            let is_member = matches!(self.peek(), Kind::Name(_))
                && self.tokens[self.i + 1].kind == Kind::Newline;
            if !is_member {
                return self.fail(self.pos(), "enum bodies hold only member names");
            }
            members.push(self.name("a member name")?);
            self.i += 1;
        }
        Ok(Enum { pos, name, members })
    }

    /// A function, an `extern def`, or a method when `method`, whose first
    /// parameter must be an unannotated `self`.
    fn declaration(&mut self, method: bool) -> Result<Func, Diag> {
        let external = matches!(self.peek(), Kind::Name(n) if n == "extern")
            && matches!(self.tokens[self.i + 1].kind, Kind::Word("def"));
        if external {
            self.i += 1;
        } else if self.peek() != &Kind::Word("def") {
            if is_construct(self.peek()) {
                return self.unexpected("a declaration");
            }
            return self.fail(
                self.pos(),
                "only function, class, protocol, enum, and type declarations are allowed at file scope",
            );
        }
        self.i += 1;
        let (pos, name) = self.name("a function name")?;
        self.expect("(")?;
        if method {
            if !matches!(self.peek(), Kind::Name(n) if n == "self") {
                return self.fail(
                    self.pos(),
                    format!("method '{name}' must take 'self' as its first parameter"),
                );
            }
            self.i += 1;
            if self.peek() == &Kind::Word(":") {
                return self.fail(self.pos(), "'self' cannot have an annotation");
            }
            if !self.accept(",") && self.peek() != &Kind::Word(")") {
                return self.unexpected("',' or ')'");
            }
        }
        let mut params = Vec::new();
        let mut variadic = false;
        while !self.accept(")") {
            if external && self.accept("...") {
                variadic = true;
                self.expect(")")?;
                break;
            }
            let (pos, name) = self.name("a parameter name")?;
            self.expect(":")?;
            let ty = self.type_expr()?;
            params.push(Param { pos, name, ty });
            if self.list_end(")")? {
                break;
            }
        }
        let ret = if self.accept("->") {
            Some(self.type_expr()?)
        } else {
            None
        };
        let body = if external {
            self.expect_kind(Kind::Newline, "end of line")?;
            None
        } else {
            self.expect(":")?;
            Some(self.block()?)
        };
        Ok(Func {
            pos,
            name,
            params,
            variadic,
            ret,
            body,
        })
    }

    fn type_expr(&mut self) -> Result<TypeExpr, Diag> {
        let pos = self.pos();
        let mut members = vec![self.type_name()?];
        while self.accept("|") {
            members.push(self.type_name()?);
        }
        Ok(TypeExpr { pos, members })
    }

    fn type_name(&mut self) -> Result<TypeName, Diag> {
        let pos = self.pos();
        let name = match self.peek().clone() {
            Kind::Name(mut name) => {
                self.i += 1;
                while self.accept(".") {
                    name = format!("{name}.{}", self.name("a type name")?.1);
                }
                name
            }
            Kind::Word(w @ ("int" | "float" | "bool" | "str" | "None" | "list" | "dict")) => {
                self.i += 1;
                w.to_string()
            }
            _ => return self.unexpected("a type"),
        };
        let mut args = Vec::new();
        if self.accept("[") {
            loop {
                args.push(self.type_expr()?);
                if !self.accept(",") {
                    break;
                }
            }
            self.expect("]")?;
        }
        Ok(TypeName { pos, name, args })
    }

    /// The argument of `__type`, which may name a built-in type that is
    /// otherwise reserved.
    fn descriptor_type(&mut self) -> Result<TypeName, Diag> {
        let pos = self.pos();
        match self.peek().clone() {
            Kind::Word(w @ ("int" | "float" | "bool" | "str" | "bytes" | "list" | "dict" | "tuple")) => {
                self.i += 1;
                Ok(TypeName {
                    pos,
                    name: w.to_string(),
                    args: Vec::new(),
                })
            }
            _ => self.type_name(),
        }
    }

    fn block(&mut self) -> Result<Vec<Stmt>, Diag> {
        self.expect_kind(Kind::Newline, "end of line")?;
        self.expect_kind(Kind::Indent, "an indented block")?;
        let mut stmts = Vec::new();
        while !matches!(self.peek(), Kind::Dedent) {
            stmts.push(self.statement()?);
        }
        self.i += 1;
        Ok(stmts)
    }

    fn end_of_line(&mut self) -> Result<(), Diag> {
        self.expect_kind(Kind::Newline, "end of line")
    }

    fn statement(&mut self) -> Result<Stmt, Diag> {
        let pos = self.pos();
        let kind = if self.accept("if") {
            let mut arms = vec![self.arm()?];
            while self.accept("elif") {
                arms.push(self.arm()?);
            }
            let otherwise = if self.accept("else") {
                self.expect(":")?;
                Some(self.block()?)
            } else {
                None
            };
            StmtKind::If { arms, otherwise }
        } else if self.accept("while") {
            let (cond, body) = self.arm()?;
            StmtKind::While { cond, body }
        } else if self.accept("for") {
            let mut targets = vec![self.name("a loop variable name")?];
            while self.accept(",") {
                targets.push(self.name("a loop variable name")?);
            }
            self.expect("in")?;
            let iterable = self.expr()?;
            self.expect(":")?;
            let body = self.block()?;
            StmtKind::For {
                targets,
                iterable,
                body,
            }
        } else if self.accept("return") {
            let value = if self.peek() == &Kind::Newline {
                None
            } else {
                Some(self.expr()?)
            };
            self.end_of_line()?;
            StmtKind::Return(value)
        } else if self.accept("assert") {
            let cond = self.expr()?;
            let message = if self.accept(",") {
                Some(self.expr()?)
            } else {
                None
            };
            self.end_of_line()?;
            StmtKind::Assert { cond, message }
        } else if self.accept("pass") {
            self.end_of_line()?;
            StmtKind::Pass
        } else if self.accept("break") {
            self.end_of_line()?;
            StmtKind::Break
        } else if self.accept("continue") {
            self.end_of_line()?;
            StmtKind::Continue
        } else if self.peek() == &Kind::Word("def") {
            return self.fail(pos, "'def' is not supported");
        } else if !starts_expression(self.peek()) {
            return self.unexpected("a statement");
        } else {
            self.simple_statement()?
        };
        Ok(Stmt { pos, kind })
    }

    fn arm(&mut self) -> Result<(Expr, Vec<Stmt>), Diag> {
        let cond = self.expr()?;
        self.expect(":")?;
        Ok((cond, self.block()?))
    }

    fn simple_statement(&mut self) -> Result<StmtKind, Diag> {
        let expr = self.expr()?;
        let equals = self.pos();
        let annotation = if self.peek() == &Kind::Word(":") {
            if !matches!(expr.kind, ExprKind::Name(_)) {
                return self.fail(self.pos(), "only a name can have an annotation");
            }
            self.i += 1;
            let ty = self.type_expr()?;
            if self.peek() != &Kind::Word("=") {
                return self.fail(self.pos(), "annotated assignment needs an initializer");
            }
            Some(ty)
        } else {
            None
        };
        if self.accept("=") {
            let value = self.expr()?;
            if self.peek() == &Kind::Word("=") {
                return self.fail(self.pos(), "chained assignment is not supported");
            }
            self.end_of_line()?;
            return match expr.kind {
                ExprKind::Name(target) => Ok(StmtKind::Assign {
                    target,
                    annotation,
                    value,
                }),
                ExprKind::Attr(object, name_pos, name) => Ok(StmtKind::SetField {
                    object: *object,
                    name_pos,
                    name,
                    value,
                }),
                ExprKind::Index(object, index) => Ok(StmtKind::SetIndex {
                    bracket: expr.pos,
                    object: *object,
                    index: *index,
                    value,
                }),
                _ => self.fail(equals, "cannot assign to this expression"),
            };
        }
        if !matches!(expr.kind, ExprKind::Call(..)) {
            return self.fail(
                expr.pos,
                "only calls and await expressions can be used as statements",
            );
        }
        self.end_of_line()?;
        Ok(StmtKind::Expr(expr))
    }

    fn binary_op(&mut self, ops: &[&'static str]) -> Option<(&'static str, Pos)> {
        match self.peek() {
            Kind::Word(w) if ops.contains(w) => {
                let op = *w;
                Some((op, self.advance().pos))
            }
            _ => None,
        }
    }

    fn expr(&mut self) -> Result<Expr, Diag> {
        self.logical("or")
    }

    /// A chain of `or`, or of `and` within it; `and` binds more tightly.
    fn logical(&mut self, op: &'static str) -> Result<Expr, Diag> {
        let operand = |p: &mut Self| {
            if op == "or" {
                p.logical("and")
            } else {
                p.negation()
            }
        };
        let mut left = operand(self)?;
        while let Some((_, op_pos)) = self.binary_op(&[op]) {
            let right = operand(self)?;
            left = Expr {
                pos: op_pos,
                kind: ExprKind::Binary(op, op_pos, Box::new(left), Box::new(right)),
            };
        }
        Ok(left)
    }

    fn negation(&mut self) -> Result<Expr, Diag> {
        let pos = self.pos();
        if self.accept("not") {
            let operand = self.negation()?;
            return Ok(Expr {
                pos,
                kind: ExprKind::Unary("not", Box::new(operand)),
            });
        }
        self.comparison()
    }

    fn comparison(&mut self) -> Result<Expr, Diag> {
        let left = self.sum()?;
        let pos = self.pos();
        let kind = if let Some((_, op_pos)) = self.binary_op(&["is"]) {
            let negated = self.accept("not");
            if !self.accept("None") {
                return self.fail(self.pos(), "'is' can only test for None");
            }
            ExprKind::IsNone {
                operand: Box::new(left),
                negated,
                op_pos,
            }
        } else if self.peek() == &Kind::Word("not")
            && self.tokens[self.i + 1].kind == Kind::Word("in")
        {
            let op_pos = self.pos();
            self.i += 2;
            let right = self.sum()?;
            ExprKind::Binary("not in", op_pos, Box::new(left), Box::new(right))
        } else if let Some((op, op_pos)) = self.binary_op(COMPARISONS) {
            let right = self.sum()?;
            ExprKind::Binary(op, op_pos, Box::new(left), Box::new(right))
        } else {
            return Ok(left);
        };
        if matches!(self.peek(), Kind::Word(w) if COMPARISONS.contains(w) || *w == "is") {
            return self.fail(self.pos(), "comparison chains are not supported");
        }
        Ok(Expr { pos, kind })
    }

    fn sum(&mut self) -> Result<Expr, Diag> {
        let mut left = self.term()?;
        while let Some((op, op_pos)) = self.binary_op(&["+", "-"]) {
            let right = self.term()?;
            left = Expr {
                pos: op_pos,
                kind: ExprKind::Binary(op, op_pos, Box::new(left), Box::new(right)),
            };
        }
        Ok(left)
    }

    fn term(&mut self) -> Result<Expr, Diag> {
        let mut left = self.unary()?;
        while let Some((op, op_pos)) = self.binary_op(&["*", "/", "//", "%"]) {
            let right = self.unary()?;
            left = Expr {
                pos: op_pos,
                kind: ExprKind::Binary(op, op_pos, Box::new(left), Box::new(right)),
            };
        }
        Ok(left)
    }

    fn unary(&mut self) -> Result<Expr, Diag> {
        if let Some((op, pos)) = self.binary_op(&["-", "+"]) {
            let operand = self.unary()?;
            return Ok(Expr {
                pos,
                kind: ExprKind::Unary(op, Box::new(operand)),
            });
        }
        self.postfix()
    }

    fn postfix(&mut self) -> Result<Expr, Diag> {
        let mut expr = self.primary()?;
        loop {
            if self.accept(".") {
                let (name_pos, name) = self.name("a field or method name")?;
                expr = Expr {
                    pos: name_pos,
                    kind: ExprKind::Attr(Box::new(expr), name_pos, name),
                };
                continue;
            }
            if self.peek() == &Kind::Word("[") {
                expr = self.subscript(expr)?;
                continue;
            }
            if !self.accept("(") {
                break;
            }
            let mut args = Vec::new();
            while !self.accept(")") {
                args.push(self.expr()?);
                if self.list_end(")")? {
                    break;
                }
            }
            let pos = expr.pos;
            expr = Expr {
                pos,
                kind: ExprKind::Call(Box::new(expr), args),
            };
        }
        Ok(expr)
    }

    /// An index or slice of `object`, positioned at its `[`.
    fn subscript(&mut self, object: Expr) -> Result<Expr, Diag> {
        let pos = self.advance().pos;
        let start = if self.peek() == &Kind::Word(":") {
            None
        } else {
            Some(Box::new(self.expr()?))
        };
        let kind = if self.accept(":") {
            let stop = if matches!(self.peek(), Kind::Word("]" | ":")) {
                None
            } else {
                Some(Box::new(self.expr()?))
            };
            if self.peek() == &Kind::Word(":") {
                return self.fail(self.pos(), "slice steps are not supported");
            }
            ExprKind::Slice(Box::new(object), start, stop)
        } else {
            ExprKind::Index(Box::new(object), start.unwrap())
        };
        self.expect("]")?;
        Ok(Expr { pos, kind })
    }

    fn primary(&mut self) -> Result<Expr, Diag> {
        let pos = self.pos();
        let kind = match self.peek().clone() {
            Kind::Int(value) => ExprKind::Int(value),
            Kind::Float(value) => ExprKind::Float(value),
            // Conversions and isinstance name types by their reserved words.
            Kind::Word(w @ ("int" | "float" | "bool" | "str" | "list" | "dict")) => {
                ExprKind::Name(w.to_string())
            }
            Kind::Word("{") => {
                self.i += 1;
                let mut entries = Vec::new();
                while !self.accept("}") {
                    let key = self.expr()?;
                    self.expect(":")?;
                    entries.push((key, self.expr()?));
                    if self.list_end("}")? {
                        break;
                    }
                }
                return Ok(Expr {
                    pos,
                    kind: ExprKind::Dict(entries),
                });
            }
            Kind::Word("[") => {
                self.i += 1;
                let mut items = Vec::new();
                while !self.accept("]") {
                    items.push(self.expr()?);
                    if self.list_end("]")? {
                        break;
                    }
                }
                return Ok(Expr {
                    pos,
                    kind: ExprKind::List(items),
                });
            }
            Kind::Word("None") => ExprKind::None,
            Kind::Str(text) => ExprKind::Str(text),
            Kind::FStr(parts) => {
                self.i += 1;
                let mut exprs = Vec::new();
                for part in parts {
                    match part {
                        FPart::Text(text) => exprs.push(Expr {
                            pos,
                            kind: ExprKind::Str(text),
                        }),
                        FPart::Field(tokens) => {
                            let outer = std::mem::replace(&mut self.tokens, tokens);
                            let i = std::mem::replace(&mut self.i, 0);
                            exprs.push(self.expr()?);
                            self.expect("}")?;
                            self.tokens = outer;
                            self.i = i;
                        }
                    }
                }
                return Ok(Expr {
                    pos,
                    kind: ExprKind::FStr(exprs),
                });
            }
            Kind::Name(name)
                if name == "__type" && self.tokens[self.i + 1].kind == Kind::Word("(") =>
            {
                self.i += 2;
                let ty = self.descriptor_type()?;
                self.expect(")")?;
                return Ok(Expr {
                    pos,
                    kind: ExprKind::TypeOf(ty),
                });
            }
            Kind::Name(name) => ExprKind::Name(name),
            Kind::Word("True") => ExprKind::Bool(true),
            Kind::Word("False") => ExprKind::Bool(false),
            Kind::Word("(") => {
                self.i += 1;
                let expr = self.expr()?;
                self.expect(")")?;
                return Ok(expr);
            }
            _ => return self.unexpected("an expression"),
        };
        self.i += 1;
        Ok(Expr { pos, kind })
    }
}
