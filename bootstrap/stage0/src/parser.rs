//! Builds the syntax tree of one module from its tokens.

use crate::lexer::{Kind, Token};
use crate::{Diag, Pos};

pub struct Module {
    pub name: String,
    pub path: String,
    pub imports: Vec<Import>,
    pub funcs: Vec<Func>,
}

pub struct Import {
    pub pos: Pos,
    pub name: String,
}

/// A `def`, or an `extern def` when `body` is `None`.
pub struct Func {
    pub pos: Pos,
    pub name: String,
    pub params: Vec<Param>,
    pub variadic: bool,
    pub ret: Option<TypeName>,
    pub body: Option<Vec<Stmt>>,
}

pub struct Param {
    pub pos: Pos,
    pub name: String,
    pub ty: TypeName,
}

pub struct TypeName {
    pub pos: Pos,
    pub name: String,
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
        annotation: Option<TypeName>,
        value: Expr,
    },
    Expr(Expr),
    /// `if`/`elif` arms in order, then the `else` block.
    If {
        arms: Vec<(Expr, Vec<Stmt>)>,
        otherwise: Option<Vec<Stmt>>,
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
    Bool(bool),
    Name(String),
    Call(Box<Expr>, Vec<Expr>),
    /// `object.name`, with the position of the name.
    Attr(Box<Expr>, Pos, String),
    Unary(&'static str, Box<Expr>),
    /// The operator, its position, and the operands.
    Binary(&'static str, Pos, Box<Expr>, Box<Expr>),
    /// The `__type(T)` intrinsic, whose argument is a type.
    TypeOf(TypeName),
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
        let (pos, name) = p.name()?;
        p.end_of_line()?;
        imports.push(Import { pos, name });
    }
    let mut funcs = Vec::new();
    while p.peek() != &Kind::Eof {
        if p.peek() == &Kind::Word("import") {
            return p.fail(p.pos(), "imports must come before declarations");
        }
        funcs.push(p.declaration()?);
    }
    Ok(Module {
        name: name.to_string(),
        path: path.to_string(),
        imports,
        funcs,
    })
}

const COMPARISONS: &[&str] = &["==", "!=", "<", "<=", ">", ">="];

fn describe(kind: &Kind) -> String {
    match kind {
        Kind::Name(name) => format!("'{name}'"),
        Kind::Int(_) => "integer".into(),
        Kind::Float(_) => "float".into(),
        Kind::Str(_) => "string".into(),
        Kind::Word(word) => format!("'{word}'"),
        Kind::Newline => "end of line".into(),
        Kind::Indent => "indent".into(),
        Kind::Dedent => "dedent".into(),
        Kind::Eof => "end of file".into(),
    }
}

/// A reserved word that begins a construct stage 0 does not parse here.
fn is_construct(kind: &Kind) -> bool {
    matches!(kind, Kind::Word(w) if w.starts_with(|c: char| c.is_ascii_alphabetic())
        && !matches!(*w, "True" | "False" | "None" | "not" | "and" | "or"))
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

    fn expect_kind(&mut self, kind: Kind, expected: &str) -> Result<(), Diag> {
        if *self.peek() == kind {
            self.i += 1;
            Ok(())
        } else {
            self.unexpected(expected)
        }
    }

    fn name(&mut self) -> Result<(Pos, String), Diag> {
        let pos = self.pos();
        match self.peek().clone() {
            Kind::Name(name) => {
                self.i += 1;
                Ok((pos, name))
            }
            _ => self.unexpected("a name"),
        }
    }

    fn declaration(&mut self) -> Result<Func, Diag> {
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
                "only function declarations are allowed at file scope",
            );
        }
        self.i += 1;
        let (pos, name) = self.name()?;
        self.expect("(")?;
        let mut params = Vec::new();
        let mut variadic = false;
        while !self.accept(")") {
            if external && self.accept("...") {
                variadic = true;
                self.expect(")")?;
                break;
            }
            let (pos, name) = self.name()?;
            self.expect(":")?;
            let ty = self.type_name()?;
            params.push(Param { pos, name, ty });
            if !self.accept(",") {
                self.expect(")")?;
                break;
            }
        }
        let ret = if self.accept("->") {
            Some(self.type_name()?)
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

    fn type_name(&mut self) -> Result<TypeName, Diag> {
        let pos = self.pos();
        let name = match self.peek().clone() {
            Kind::Name(name) => name,
            Kind::Word(w @ ("int" | "float" | "bool" | "str" | "None")) => w.to_string(),
            _ => return self.unexpected("a type"),
        };
        self.i += 1;
        Ok(TypeName { pos, name })
    }

    /// The argument of `__type`, which may name a built-in type that is
    /// otherwise reserved.
    fn descriptor_type(&mut self) -> Result<TypeName, Diag> {
        let pos = self.pos();
        match self.peek().clone() {
            Kind::Word(w @ ("int" | "float" | "bool" | "str" | "list" | "dict")) => {
                self.i += 1;
                Ok(TypeName {
                    pos,
                    name: w.to_string(),
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
        let annotation = if self.peek() == &Kind::Word(":") {
            if !matches!(expr.kind, ExprKind::Name(_)) {
                return self.fail(self.pos(), "only a name can have an annotation");
            }
            self.i += 1;
            let ty = self.type_name()?;
            if self.peek() != &Kind::Word("=") {
                return self.fail(self.pos(), "annotated assignment needs an initializer");
            }
            Some(ty)
        } else {
            None
        };
        if self.accept("=") {
            let ExprKind::Name(target) = expr.kind else {
                return self.fail(expr.pos, "cannot assign to this expression");
            };
            let value = self.expr()?;
            if self.peek() == &Kind::Word("=") {
                return self.fail(self.pos(), "chained assignment is not supported");
            }
            self.end_of_line()?;
            return Ok(StmtKind::Assign {
                target,
                annotation,
                value,
            });
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
            let pos = left.pos;
            left = Expr {
                pos,
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
        let Some((op, op_pos)) = self.binary_op(COMPARISONS) else {
            return Ok(left);
        };
        let right = self.sum()?;
        if matches!(self.peek(), Kind::Word(w) if COMPARISONS.contains(w)) {
            return self.fail(self.pos(), "comparison chains are not supported");
        }
        let pos = left.pos;
        Ok(Expr {
            pos,
            kind: ExprKind::Binary(op, op_pos, Box::new(left), Box::new(right)),
        })
    }

    fn sum(&mut self) -> Result<Expr, Diag> {
        let mut left = self.term()?;
        while let Some((op, op_pos)) = self.binary_op(&["+", "-"]) {
            let right = self.term()?;
            let pos = left.pos;
            left = Expr {
                pos,
                kind: ExprKind::Binary(op, op_pos, Box::new(left), Box::new(right)),
            };
        }
        Ok(left)
    }

    fn term(&mut self) -> Result<Expr, Diag> {
        let mut left = self.unary()?;
        while let Some((op, op_pos)) = self.binary_op(&["*", "/", "//", "%"]) {
            let right = self.unary()?;
            let pos = left.pos;
            left = Expr {
                pos,
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
                let (name_pos, name) = self.name()?;
                let pos = expr.pos;
                expr = Expr {
                    pos,
                    kind: ExprKind::Attr(Box::new(expr), name_pos, name),
                };
                continue;
            }
            if !self.accept("(") {
                break;
            }
            let mut args = Vec::new();
            while !self.accept(")") {
                args.push(self.expr()?);
                if !self.accept(",") {
                    self.expect(")")?;
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

    fn primary(&mut self) -> Result<Expr, Diag> {
        let pos = self.pos();
        let kind = match self.peek().clone() {
            Kind::Int(value) => ExprKind::Int(value),
            Kind::Float(value) => ExprKind::Float(value),
            // Conversions are called by their reserved type names.
            Kind::Word(w @ ("int" | "float")) => ExprKind::Name(w.to_string()),
            Kind::Str(text) => ExprKind::Str(text),
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
