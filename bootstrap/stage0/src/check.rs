//! Binds names, checks types and flow, and lowers the checked program to the
//! small IR the emitter writes out. Built-in operations become calls into
//! `core` here, so the emitter only knows QBE.

use std::collections::{HashMap, HashSet};

use crate::parser::{Expr, ExprKind, Func, Module, Stmt, StmtKind, TypeName};
use crate::{Diag, Pos};

pub struct Program {
    pub funcs: Vec<Function>,
    /// String literal contents; literal `n` is the data symbol `$W.str.n`.
    pub strings: Vec<String>,
    /// Each descriptor's symbol and the literal holding its type's name.
    pub descriptors: Vec<(String, usize)>,
    /// The symbol of the entry module's `main`.
    pub main: String,
}

pub struct Function {
    pub symbol: String,
    pub params: Vec<String>,
    /// Every local that is not a parameter, in order of first assignment.
    pub locals: Vec<String>,
    pub returns: bool,
    pub body: Vec<Op>,
}

pub enum Op {
    Assign(String, Value),
    Eval(Value),
    If(Value, Vec<Op>, Vec<Op>),
    While(Value, Vec<Op>),
    Break,
    Continue,
    Return(Option<Value>),
}

pub enum Value {
    Const(i64),
    /// The address of a data symbol, without its `$`.
    Global(String),
    Local(String),
    Call(Call),
    /// A QBE instruction on two `l` operands.
    Binary(&'static str, Box<Value>, Box<Value>),
    /// QBE `dtosi` on a float's bits.
    FloatToInt(Box<Value>),
    /// QBE `sltof`, giving a float's bits.
    IntToFloat(Box<Value>),
    /// A QBE arithmetic instruction on two floats' bits.
    FloatBinary(&'static str, Box<Value>, Box<Value>),
    /// A QBE comparison on two floats' bits.
    FloatCompare(&'static str, Box<Value>, Box<Value>),
    FloatNeg(Box<Value>),
    /// Short-circuit `and`, or `or` when `and` is false.
    Logic {
        and: bool,
        left: Box<Value>,
        right: Box<Value>,
    },
    /// Integer `//`, or `%` when `modulo`, which calls `fail` for a zero divisor.
    FloorDivide {
        modulo: bool,
        left: Box<Value>,
        right: Box<Value>,
        fail: Box<Value>,
    },
    /// `/`, on two ints when `ints`, which calls `fail` for a zero divisor.
    Divide {
        ints: bool,
        left: Box<Value>,
        right: Box<Value>,
        fail: Box<Value>,
    },
    /// A QBE load instruction, the pointer, and the byte offset.
    Load(&'static str, Box<Value>, Box<Value>),
    /// A QBE store instruction, the pointer, the byte offset, and the value.
    Store(&'static str, Box<Value>, Box<Value>, Box<Value>),
}

pub struct Call {
    /// The callee's symbol, without its `$`.
    pub symbol: String,
    /// Each argument with its QBE type: `l`, `w`, or `d`.
    pub args: Vec<(&'static str, Value)>,
    /// The number of fixed arguments of a variadic callee.
    pub variadic_at: Option<usize>,
    /// The QBE return type, or `None` for no result.
    pub ret: Option<&'static str>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Type {
    Int,
    Float,
    Bool,
    Str,
    None,
    Ptr,
    Word,
}

impl Type {
    fn name(self) -> &'static str {
        match self {
            Type::Int => "int",
            Type::Float => "float",
            Type::Bool => "bool",
            Type::Str => "str",
            Type::None => "None",
            Type::Ptr => "ptr",
            Type::Word => "word",
        }
    }
}

struct Sig {
    params: Vec<Type>,
    ret: Type,
    target: Target,
}

enum Target {
    Willow(String),
    Extern {
        cparams: Vec<&'static str>,
        variadic: bool,
        cret: Option<&'static str>,
    },
}

const BUILTINS: &[&str] = &[
    "print",
    "input",
    "len",
    "range",
    "int",
    "float",
    "str",
    "bytes",
    "ord",
    "chr",
    "isinstance",
    "sorted",
    "abs",
    "round",
    "min",
    "max",
    "sum",
    "any",
    "all",
    "list",
    "enumerate",
    "zip",
    "iter",
    "next",
];

/// Intrinsics with ordinary signatures; `__word` takes several types and is
/// handled separately.
const INTRINSICS: &[(&str, &[Type], Type)] = &[
    ("__alloc", &[Type::Int], Type::Ptr),
    ("__alloc_atomic", &[Type::Int], Type::Ptr),
    ("__load1", &[Type::Ptr, Type::Int], Type::Int),
    ("__store1", &[Type::Ptr, Type::Int, Type::Int], Type::None),
    ("__load8", &[Type::Ptr, Type::Int], Type::Word),
    ("__store8", &[Type::Ptr, Type::Int, Type::Word], Type::None),
    ("__int", &[Type::Word], Type::Int),
    ("__ptr", &[Type::Word], Type::Ptr),
    ("__str", &[Type::Word], Type::Str),
    ("__float", &[Type::Word], Type::Float),
    ("__bool", &[Type::Word], Type::Bool),
    ("__load4", &[Type::Ptr, Type::Int], Type::Int),
    ("__store4", &[Type::Ptr, Type::Int, Type::Int], Type::None),
    ("__addr_is_null", &[Type::Ptr], Type::Bool),
    ("__dtosi", &[Type::Float], Type::Int),
];

/// The value of `__os`. The host is the target, since stage 0 does not
/// cross-compile.
fn target_os() -> &'static str {
    if cfg!(target_os = "macos") {
        "darwin"
    } else {
        "linux"
    }
}

/// The built-in types with descriptors, which every program emits.
const BUILTIN_TYPES: &[&str] = &["int", "float", "bool", "str", "list", "dict"];

fn is_intrinsic(name: &str) -> bool {
    name == "__word" || name == "__type" || name == "__os" || INTRINSICS.iter().any(|i| i.0 == name)
}

fn count(n: usize) -> String {
    format!("{n} argument{}", if n == 1 { "" } else { "s" })
}

#[derive(Default)]
struct Strings {
    list: Vec<String>,
    index: HashMap<String, usize>,
}

impl Strings {
    fn intern(&mut self, text: &str) -> Value {
        Value::Global(format!("W.str.{}", self.index_of(text)))
    }

    fn index_of(&mut self, text: &str) -> usize {
        match self.index.get(text) {
            Some(&n) => n,
            None => {
                self.list.push(text.to_string());
                self.index.insert(text.to_string(), self.list.len() - 1);
                self.list.len() - 1
            }
        }
    }
}

pub fn check(modules: &[Module]) -> Result<Program, Diag> {
    let mut tables = HashMap::new();
    for module in modules {
        tables.insert(module.name.as_str(), declare(module)?);
    }
    let entry = &modules[0];
    let main = match entry.funcs.iter().find(|f| f.name == "main") {
        None => {
            return Err(Diag::new(
                &entry.path,
                Pos { line: 1, col: 1 },
                "program has no main function",
            ));
        }
        Some(f) => f,
    };
    if !main.params.is_empty() || main.ret.as_ref().is_some_and(|r| r.name != "None") {
        return Err(Diag::new(
            &entry.path,
            main.pos,
            "main must take no parameters and return None",
        ));
    }
    let mut strings = Strings::default();
    let descriptors = BUILTIN_TYPES
        .iter()
        .map(|t| (format!("W.{t}.type"), strings.index_of(t)))
        .collect();
    let mut funcs = Vec::new();
    for module in modules {
        let mut imported = HashMap::new();
        for import in &module.imports {
            // Only core can be imported so far, and only by core's tests.
            let Some(table) = tables
                .get(import.name.as_str())
                .filter(|_| import.name == "core")
            else {
                let message = format!("unknown module '{}'", import.name);
                return Err(Diag::new(&module.path, import.pos, message));
            };
            if imported.insert(import.name.as_str(), table).is_some() {
                let message = format!("duplicate import '{}'", import.name);
                return Err(Diag::new(&module.path, import.pos, message));
            }
        }
        let globals = &tables[module.name.as_str()];
        for func in &module.funcs {
            if let Some(body) = &func.body {
                let sig = &globals[&func.name];
                let scope = Scope {
                    module,
                    globals,
                    imported: &imported,
                };
                funcs.push(check_function(scope, &mut strings, func, sig, body)?);
            }
        }
    }
    Ok(Program {
        funcs,
        strings: strings.list,
        descriptors,
        main: format!("W.{}.main", entry.name),
    })
}

fn resolve(module: &Module, ty: &TypeName) -> Result<Type, Diag> {
    Ok(match ty.name.as_str() {
        "int" => Type::Int,
        "float" => Type::Float,
        "bool" => Type::Bool,
        "str" => Type::Str,
        "None" => Type::None,
        "ptr" if module.name == "core" => Type::Ptr,
        "word" if module.name == "core" => Type::Word,
        name => {
            return Err(Diag::new(
                &module.path,
                ty.pos,
                format!("unknown type '{name}'"),
            ));
        }
    })
}

/// The Willow type and QBE type of an extern parameter or return type.
fn resolve_extern(module: &Module, ty: &TypeName) -> Result<(Type, Option<&'static str>), Diag> {
    if ty.name == "cint" {
        return Ok((Type::Int, Some("w")));
    }
    match resolve(module, ty)? {
        t @ (Type::Int | Type::Ptr) => Ok((t, Some("l"))),
        Type::Float => Ok((Type::Float, Some("d"))),
        Type::None => Ok((Type::None, None)),
        _ => Err(Diag::new(
            &module.path,
            ty.pos,
            "extern functions take and return only int, float, ptr, and cint",
        )),
    }
}

/// The signatures of the functions `module` declares.
fn declare(module: &Module) -> Result<HashMap<String, Sig>, Diag> {
    let mut table = HashMap::new();
    let fail = |pos, message: String| Err(Diag::new(&module.path, pos, message));
    for func in &module.funcs {
        if BUILTINS.contains(&func.name.as_str()) {
            return fail(
                func.pos,
                format!("cannot redefine built-in function '{}'", func.name),
            );
        }
        if table.contains_key(&func.name) {
            return fail(func.pos, format!("duplicate declaration '{}'", func.name));
        }
        let mut seen = HashSet::new();
        for param in &func.params {
            if !seen.insert(&param.name) {
                return fail(param.pos, format!("duplicate parameter '{}'", param.name));
            }
        }
        let sig = if func.body.is_some() {
            let params = func
                .params
                .iter()
                .map(|p| resolve(module, &p.ty))
                .collect::<Result<_, _>>()?;
            let ret = match &func.ret {
                Some(ty) => resolve(module, ty)?,
                None => Type::None,
            };
            let target = Target::Willow(format!("W.{}.{}", module.name, func.name));
            Sig {
                params,
                ret,
                target,
            }
        } else {
            if module.name != "core" {
                return fail(func.pos, "extern functions are only allowed in core".into());
            }
            let mut params = Vec::new();
            let mut cparams = Vec::new();
            for param in &func.params {
                match resolve_extern(module, &param.ty)? {
                    (t, Some(c)) => {
                        params.push(t);
                        cparams.push(c);
                    }
                    (_, None) => {
                        return fail(param.ty.pos, "an extern parameter cannot be None".into());
                    }
                }
            }
            let (ret, cret) = match &func.ret {
                Some(ty) => resolve_extern(module, ty)?,
                None => (Type::None, None),
            };
            Sig {
                params,
                ret,
                target: Target::Extern {
                    cparams,
                    variadic: func.variadic,
                    cret,
                },
            }
        };
        table.insert(func.name.clone(), sig);
    }
    Ok(table)
}

/// The names `stmts` assign to, at any depth.
fn assigned_names(stmts: &[Stmt], names: &mut HashSet<String>) {
    for stmt in stmts {
        match &stmt.kind {
            StmtKind::Assign { target, .. } => {
                names.insert(target.clone());
            }
            StmtKind::If { arms, otherwise } => {
                for (_, body) in arms {
                    assigned_names(body, names);
                }
                if let Some(body) = otherwise {
                    assigned_names(body, names);
                }
            }
            StmtKind::While { body, .. } => assigned_names(body, names),
            StmtKind::Expr(_)
            | StmtKind::Assert { .. }
            | StmtKind::Return(_)
            | StmtKind::Pass
            | StmtKind::Break
            | StmtKind::Continue => {}
        }
    }
}

/// The names a function body can see besides its locals.
#[derive(Clone, Copy)]
struct Scope<'a> {
    module: &'a Module,
    globals: &'a HashMap<String, Sig>,
    /// The function tables of the modules this module imports.
    imported: &'a HashMap<&'a str, &'a HashMap<String, Sig>>,
}

struct Checker<'a> {
    module: &'a Module,
    globals: &'a HashMap<String, Sig>,
    imported: &'a HashMap<&'a str, &'a HashMap<String, Sig>>,
    intrinsics: bool,
    strings: &'a mut Strings,
    ret: Type,
    /// Every name that is local to the function, with its type once its
    /// first assignment has been checked.
    locals: HashMap<String, Option<Type>>,
    params: HashSet<String>,
    order: Vec<String>,
    /// The number of loops around the statement being checked.
    loops: u32,
}

/// The locals definitely assigned at a point.
type State = HashSet<String>;

fn check_function(
    scope: Scope,
    strings: &mut Strings,
    func: &Func,
    sig: &Sig,
    body: &[Stmt],
) -> Result<Function, Diag> {
    let mut names = HashSet::new();
    assigned_names(body, &mut names);
    let mut locals: HashMap<String, Option<Type>> = names.into_iter().map(|n| (n, None)).collect();
    let mut state = State::new();
    for (param, &ty) in func.params.iter().zip(&sig.params) {
        locals.insert(param.name.clone(), Some(ty));
        state.insert(param.name.clone());
    }
    let params = func
        .params
        .iter()
        .map(|p| p.name.clone())
        .collect::<Vec<_>>();
    let mut checker = Checker {
        module: scope.module,
        globals: scope.globals,
        imported: scope.imported,
        intrinsics: scope.module.name == "core",
        strings,
        ret: sig.ret,
        locals,
        params: params.iter().cloned().collect(),
        order: Vec::new(),
        loops: 0,
    };
    let (ops, transfers) = checker.block(body, &mut state)?;
    if sig.ret != Type::None && !transfers {
        return checker.fail(
            func.pos,
            format!("function '{}' must return a value on every path", func.name),
        );
    }
    let Target::Willow(symbol) = &sig.target else {
        unreachable!()
    };
    Ok(Function {
        symbol: symbol.clone(),
        params,
        locals: checker.order,
        returns: sig.ret != Type::None,
        body: ops,
    })
}

fn core_call(name: &str, args: Vec<Value>, returns: bool) -> Value {
    Value::Call(Call {
        symbol: format!("W.core.{name}"),
        args: args.into_iter().map(|a| ("l", a)).collect(),
        variadic_at: None,
        ret: if returns { Some("l") } else { None },
    })
}

impl Checker<'_> {
    fn fail<T>(&self, pos: Pos, message: impl Into<String>) -> Result<T, Diag> {
        Err(Diag::new(&self.module.path, pos, message))
    }

    fn expect(&self, pos: Pos, expected: Type, actual: Type) -> Result<(), Diag> {
        if expected == actual {
            Ok(())
        } else {
            self.fail(
                pos,
                format!("expected {}, received {}", expected.name(), actual.name()),
            )
        }
    }

    /// Checks `stmts` and reports whether the block transfers control.
    fn block(&mut self, stmts: &[Stmt], state: &mut State) -> Result<(Vec<Op>, bool), Diag> {
        let mut ops = Vec::new();
        let mut transfers = false;
        for stmt in stmts {
            if transfers {
                return self.fail(stmt.pos, "unreachable statement");
            }
            transfers = self.statement(stmt, state, &mut ops)?;
        }
        Ok((ops, transfers))
    }

    fn condition(&mut self, cond: &Expr, state: &State) -> Result<Value, Diag> {
        let (value, ty) = self.expr(cond, state)?;
        self.expect(cond.pos, Type::Bool, ty)?;
        Ok(value)
    }

    fn statement(
        &mut self,
        stmt: &Stmt,
        state: &mut State,
        ops: &mut Vec<Op>,
    ) -> Result<bool, Diag> {
        match &stmt.kind {
            StmtKind::Assign {
                target,
                annotation,
                value,
            } => {
                let (value_ir, ty) = self.expr(value, state)?;
                if annotation.is_some() {
                    if self.params.contains(target) {
                        return self
                            .fail(stmt.pos, format!("cannot annotate parameter '{target}'"));
                    }
                    if self.locals[target].is_some() {
                        return self.fail(
                            stmt.pos,
                            format!(
                                "only the first assignment to '{target}' can have an annotation"
                            ),
                        );
                    }
                }
                let declared = match self.locals[target] {
                    Some(declared) => declared,
                    None => {
                        let declared = match annotation {
                            Some(a) => resolve(self.module, a)?,
                            None => ty,
                        };
                        self.locals.insert(target.clone(), Some(declared));
                        self.order.push(target.clone());
                        declared
                    }
                };
                self.expect(value.pos, declared, ty)?;
                state.insert(target.clone());
                ops.push(Op::Assign(target.clone(), value_ir));
                Ok(false)
            }
            StmtKind::Expr(expr) => {
                ops.push(Op::Eval(self.expr(expr, state)?.0));
                Ok(false)
            }
            StmtKind::Assert { cond, message } => {
                let cond_ir = self.condition(cond, state)?;
                let message_ir = match message {
                    Some(message) => {
                        let (message_ir, ty) = self.expr(message, state)?;
                        self.expect(message.pos, Type::Str, ty)?;
                        message_ir
                    }
                    None => self.strings.intern("assertion failed"),
                };
                let fail = self.fail_call("AssertionError", message_ir);
                ops.push(Op::If(cond_ir, Vec::new(), vec![Op::Eval(fail)]));
                Ok(false)
            }
            StmtKind::If { arms, otherwise } => {
                // Lower the arms from the last, so each `elif` nests in the
                // `else` of the arm before it.
                let mut after: Option<State> = None;
                let mut all_transfer = true;
                let mut join = |branch: State, transfers: bool| {
                    if !transfers {
                        all_transfer = false;
                        after = Some(match after.take() {
                            None => branch,
                            Some(prev) => prev.intersection(&branch).cloned().collect(),
                        });
                    }
                };
                let mut lowered = Vec::new();
                for (cond, body) in arms {
                    let cond_ir = self.condition(cond, state)?;
                    let mut branch = state.clone();
                    let (body_ops, transfers) = self.block(body, &mut branch)?;
                    join(branch, transfers);
                    lowered.push((cond_ir, body_ops, self.os_test(cond)));
                }
                let mut tail = match otherwise {
                    Some(body) => {
                        let mut branch = state.clone();
                        let (body_ops, transfers) = self.block(body, &mut branch)?;
                        join(branch, transfers);
                        body_ops
                    }
                    None => {
                        join(state.clone(), false);
                        Vec::new()
                    }
                };
                // Every arm is checked, but an `__os` test emits only the arm
                // it selects, so core can call functions that exist on only
                // one platform.
                while let Some((cond_ir, body_ops, os_test)) = lowered.pop() {
                    tail = match os_test {
                        Some(true) => body_ops,
                        Some(false) => tail,
                        None => vec![Op::If(cond_ir, body_ops, tail)],
                    };
                }
                ops.extend(tail);
                if let Some(after) = after {
                    *state = after;
                }
                Ok(all_transfer)
            }
            StmtKind::While { cond, body } => {
                let cond_ir = self.condition(cond, state)?;
                self.loops += 1;
                let (body_ops, _) = self.block(body, &mut state.clone())?;
                self.loops -= 1;
                ops.push(Op::While(cond_ir, body_ops));
                Ok(false)
            }
            StmtKind::Return(value) => {
                let value_ir = match value {
                    Some(value) => {
                        let (value_ir, ty) = self.expr(value, state)?;
                        self.expect(value.pos, self.ret, ty)?;
                        Some(value_ir)
                    }
                    None => {
                        self.expect(stmt.pos, self.ret, Type::None)?;
                        None
                    }
                };
                match value_ir {
                    // A None function returns no QBE value, but still
                    // evaluates the expression it returns.
                    Some(value_ir) if self.ret == Type::None => {
                        ops.push(Op::Eval(value_ir));
                        ops.push(Op::Return(None));
                    }
                    value_ir => ops.push(Op::Return(value_ir)),
                }
                Ok(true)
            }
            StmtKind::Pass => Ok(false),
            StmtKind::Break | StmtKind::Continue => {
                let is_break = matches!(stmt.kind, StmtKind::Break);
                if self.loops == 0 {
                    let word = if is_break { "break" } else { "continue" };
                    return self.fail(stmt.pos, format!("'{word}' outside of a loop"));
                }
                ops.push(if is_break { Op::Break } else { Op::Continue });
                Ok(true)
            }
        }
    }

    fn expr(&mut self, expr: &Expr, state: &State) -> Result<(Value, Type), Diag> {
        match &expr.kind {
            ExprKind::Int(n) => Ok((Value::Const(*n), Type::Int)),
            ExprKind::Float(x) => Ok((Value::Const(x.to_bits() as i64), Type::Float)),
            ExprKind::Bool(b) => Ok((Value::Const(*b as i64), Type::Bool)),
            ExprKind::Str(text) => Ok((self.strings.intern(text), Type::Str)),
            ExprKind::Name(name) => {
                if let Some(&ty) = self.locals.get(name) {
                    return match ty {
                        Some(ty) if state.contains(name) => Ok((Value::Local(name.clone()), ty)),
                        _ => self.fail(
                            expr.pos,
                            format!("variable '{name}' may be used before assignment"),
                        ),
                    };
                }
                if is_intrinsic(name) && !self.intrinsics {
                    return self.fail(
                        expr.pos,
                        format!("intrinsic '{name}' is only available in core"),
                    );
                }
                if name == "__os" {
                    return Ok((self.strings.intern(target_os()), Type::Str));
                }
                if self.globals.contains_key(name)
                    || BUILTINS.contains(&name.as_str())
                    || is_intrinsic(name)
                {
                    return self.fail(expr.pos, format!("cannot use function '{name}' as a value"));
                }
                self.fail(expr.pos, format!("unknown name '{name}'"))
            }
            ExprKind::Call(callee, args) => self.call(callee, args, state),
            ExprKind::Attr(object, _, name) => match self.module_of(object) {
                Some(module) => self.fail(
                    expr.pos,
                    format!("cannot use function '{module}.{name}' as a value"),
                ),
                None => self.fail(expr.pos, "field access is not supported"),
            },
            ExprKind::TypeOf(ty) => {
                if !self.intrinsics {
                    return self.fail(expr.pos, "intrinsic '__type' is only available in core");
                }
                if !BUILTIN_TYPES.contains(&ty.name.as_str()) {
                    return self.fail(
                        ty.pos,
                        "'__type' takes int, float, bool, str, list, or dict",
                    );
                }
                Ok((Value::Global(format!("W.{}.type", ty.name)), Type::Ptr))
            }
            ExprKind::Unary(op, operand) => {
                let (value, ty) = self.expr(operand, state)?;
                match (*op, ty) {
                    ("+", Type::Int | Type::Float) => Ok((value, ty)),
                    ("-", Type::Int) => Ok((
                        Value::Binary("sub", Box::new(Value::Const(0)), Box::new(value)),
                        Type::Int,
                    )),
                    ("-", Type::Float) => Ok((Value::FloatNeg(Box::new(value)), Type::Float)),
                    ("not", Type::Bool) => Ok((
                        Value::Binary("ceql", Box::new(value), Box::new(Value::Const(0))),
                        Type::Bool,
                    )),
                    _ => self.fail(
                        expr.pos,
                        format!("operator '{op}' cannot be applied to {}", ty.name()),
                    ),
                }
            }
            ExprKind::Binary(op, op_pos, left, right) => {
                let (l, lt) = self.expr(left, state)?;
                let (r, rt) = self.expr(right, state)?;
                self.binary(op, *op_pos, l, lt, r, rt)
            }
        }
    }

    fn binary(
        &mut self,
        op: &str,
        pos: Pos,
        l: Value,
        lt: Type,
        r: Value,
        rt: Type,
    ) -> Result<(Value, Type), Diag> {
        let compare = match op {
            "==" => "ceql",
            "!=" => "cnel",
            "<" => "csltl",
            "<=" => "cslel",
            ">" => "csgtl",
            ">=" => "csgel",
            _ => "",
        };
        let float_op = match op {
            "+" => "add",
            "-" => "sub",
            "*" => "mul",
            _ => "",
        };
        let float_compare = match op {
            "==" => "ceqd",
            "!=" => "cned",
            "<" => "cltd",
            "<=" => "cled",
            ">" => "cgtd",
            ">=" => "cged",
            _ => "",
        };
        let (l, r) = (Box::new(l), Box::new(r));
        let (instr, ty) = match (op, lt, rt) {
            ("and" | "or", Type::Bool, Type::Bool) => {
                let logic = Value::Logic {
                    and: op == "and",
                    left: l,
                    right: r,
                };
                return Ok((logic, Type::Bool));
            }
            ("//" | "%", Type::Int, Type::Int) => {
                let message = self.strings.intern("division by zero");
                let fail = Box::new(self.fail_call("ZeroDivisionError", message));
                let divide = Value::FloorDivide {
                    modulo: op == "%",
                    left: l,
                    right: r,
                    fail,
                };
                return Ok((divide, Type::Int));
            }
            ("//" | "%", Type::Float, Type::Float) => {
                let function = if op == "%" {
                    "float_mod"
                } else {
                    "float_floordiv"
                };
                return Ok((core_call(function, vec![*l, *r], true), Type::Float));
            }
            ("/", Type::Int, Type::Int) | ("/", Type::Float, Type::Float) => {
                let message = self.strings.intern("division by zero");
                let fail = Box::new(self.fail_call("ZeroDivisionError", message));
                let ints = lt == Type::Int;
                let divide = Value::Divide {
                    ints,
                    left: l,
                    right: r,
                    fail,
                };
                return Ok((divide, Type::Float));
            }
            (_, Type::Float, Type::Float) if !float_op.is_empty() => {
                return Ok((Value::FloatBinary(float_op, l, r), Type::Float));
            }
            (_, Type::Float, Type::Float) if !float_compare.is_empty() => {
                return Ok((Value::FloatCompare(float_compare, l, r), Type::Bool));
            }
            ("+", Type::Int, Type::Int) => ("add", Type::Int),
            ("-", Type::Int, Type::Int) => ("sub", Type::Int),
            ("*", Type::Int, Type::Int) => ("mul", Type::Int),
            (_, Type::Int, Type::Int) if !compare.is_empty() => (compare, Type::Bool),
            ("==" | "!=", Type::Bool, Type::Bool) | ("==" | "!=", Type::Ptr, Type::Ptr) => {
                (compare, Type::Bool)
            }
            ("+", Type::Str, Type::Str) => {
                return Ok((core_call("str_concat", vec![*l, *r], true), Type::Str));
            }
            (_, Type::Str, Type::Str) if !compare.is_empty() => {
                // Strings compare by the sign of core's three-way comparison.
                let order = core_call("str_compare", vec![*l, *r], true);
                return Ok((
                    Value::Binary(compare, Box::new(order), Box::new(Value::Const(0))),
                    Type::Bool,
                ));
            }
            _ => {
                return self.fail(
                    pos,
                    format!(
                        "operator '{op}' cannot be applied to {} and {}",
                        lt.name(),
                        rt.name()
                    ),
                );
            }
        };
        Ok((Value::Binary(instr, l, r), ty))
    }

    /// The value of `cond` when it compares `__os` with a string literal
    /// using `==` or `!=`.
    fn os_test(&self, cond: &Expr) -> Option<bool> {
        let ExprKind::Binary(op @ ("==" | "!="), _, left, right) = &cond.kind else {
            return None;
        };
        let text = match (&left.kind, &right.kind) {
            (ExprKind::Name(name), ExprKind::Str(text))
            | (ExprKind::Str(text), ExprKind::Name(name))
                if name == "__os" && self.intrinsics && !self.locals.contains_key(name) =>
            {
                text
            }
            _ => return None,
        };
        Some((text == target_os()) == (*op == "=="))
    }

    /// A call to `core.fail` with a class name and a message.
    fn fail_call(&mut self, class: &str, message: Value) -> Value {
        let class = self.strings.intern(class);
        core_call("fail", vec![class, message], false)
    }

    /// The name of the imported module `expr` names, unless a local hides it.
    fn module_of(&self, expr: &Expr) -> Option<&str> {
        match &expr.kind {
            ExprKind::Name(name) if !self.locals.contains_key(name) => self
                .imported
                .get_key_value(name.as_str())
                .map(|(module, _)| *module),
            _ => None,
        }
    }

    fn arity(&self, pos: Pos, name: &str, expected: usize, received: usize) -> Result<(), Diag> {
        if expected == received {
            Ok(())
        } else {
            self.fail(
                pos,
                format!("'{name}' expects {}, received {received}", count(expected)),
            )
        }
    }

    fn call(&mut self, callee: &Expr, args: &[Expr], state: &State) -> Result<(Value, Type), Diag> {
        let pos = callee.pos;
        if let ExprKind::Attr(object, name_pos, name) = &callee.kind {
            let Some(module) = self.module_of(object) else {
                return self.fail(pos, "field access is not supported");
            };
            let table = self.imported[module];
            let Some(sig) = table.get(name) else {
                return self.fail(
                    *name_pos,
                    format!("module '{module}' has no function '{name}'"),
                );
            };
            let display = format!("{module}.{name}");
            let checked = self.args(args, state)?;
            return self.call_sig(pos, &display, name, sig, checked);
        }
        let name = match &callee.kind {
            ExprKind::Name(name) if !self.locals.contains_key(name) => name.as_str(),
            _ => {
                let (_, ty) = self.expr(callee, state)?;
                return self.fail(pos, format!("cannot call a value of type {}", ty.name()));
            }
        };
        let globals = self.globals;
        if !globals.contains_key(name) && !matches!(name, "print" | "int" | "float") {
            if !is_intrinsic(name) {
                if BUILTINS.contains(&name) {
                    return self.fail(pos, format!("'{name}' is not supported"));
                }
                return self.fail(pos, format!("unknown name '{name}'"));
            }
            if !self.intrinsics {
                return self.fail(pos, format!("intrinsic '{name}' is only available in core"));
            }
        }
        let mut checked = self.args(args, state)?;
        if let Some(sig) = globals.get(name) {
            return self.call_sig(pos, name, name, sig, checked);
        }
        if name == "print" {
            self.arity(pos, name, 1, checked.len())?;
            let (arg_pos, value, ty) = checked.pop().unwrap();
            let value = match ty {
                Type::Int => core_call("print_int", vec![value], false),
                Type::Bool => core_call("print_bool", vec![value], false),
                Type::Str => core_call("print_str", vec![value], false),
                Type::Float => {
                    let text = core_call("float_to_str", vec![value], true);
                    core_call("print_str", vec![text], false)
                }
                _ => {
                    return self.fail(
                        arg_pos,
                        format!("cannot print a value of type {}", ty.name()),
                    );
                }
            };
            return Ok((value, Type::None));
        }
        if name == "int" || name == "float" {
            self.arity(pos, name, 1, checked.len())?;
            let (arg_pos, value, ty) = checked.pop().unwrap();
            return match (name, ty) {
                ("int", Type::Float) => {
                    Ok((core_call("float_to_int", vec![value], true), Type::Int))
                }
                ("int", Type::Str) => Ok((core_call("str_to_int", vec![value], true), Type::Int)),
                ("float", Type::Int) => Ok((Value::IntToFloat(Box::new(value)), Type::Float)),
                ("float", Type::Str) => {
                    Ok((core_call("str_to_float", vec![value], true), Type::Float))
                }
                _ => self.fail(
                    arg_pos,
                    format!("cannot convert a value of type {} to {name}", ty.name()),
                ),
            };
        }
        if name == "__os" {
            return self.fail(pos, "cannot call a value of type str");
        }
        if name == "__word" {
            self.arity(pos, name, 1, checked.len())?;
            let (arg_pos, value, ty) = checked.pop().unwrap();
            if !matches!(
                ty,
                Type::Int | Type::Float | Type::Bool | Type::Ptr | Type::Str
            ) {
                return self.fail(
                    arg_pos,
                    format!("cannot convert a value of type {} to word", ty.name()),
                );
            }
            return Ok((value, Type::Word));
        }
        let &(_, params, ret) = INTRINSICS.iter().find(|i| i.0 == name).unwrap();
        self.arity(pos, name, params.len(), checked.len())?;
        for ((arg_pos, _, ty), &param) in checked.iter().zip(params) {
            self.expect(*arg_pos, param, *ty)?;
        }
        let mut values = checked.into_iter().map(|(_, v, _)| Box::new(v));
        let mut next = || values.next().unwrap();
        let value = match name {
            "__alloc" | "__alloc_atomic" => Value::Call(Call {
                symbol: if name == "__alloc" {
                    "GC_malloc"
                } else {
                    "GC_malloc_atomic"
                }
                .into(),
                args: vec![("l", *next())],
                variadic_at: None,
                ret: Some("l"),
            }),
            "__load1" => Value::Load("loadub", next(), next()),
            "__load4" => Value::Load("loadsw", next(), next()),
            "__load8" => Value::Load("loadl", next(), next()),
            "__store1" => Value::Store("storeb", next(), next(), next()),
            "__store4" => Value::Store("storew", next(), next(), next()),
            "__store8" => Value::Store("storel", next(), next(), next()),
            "__addr_is_null" => Value::Binary("ceql", next(), Box::new(Value::Const(0))),
            "__dtosi" => Value::FloatToInt(next()),
            // Reinterpretations change only the static type.
            _ => *next(),
        };
        Ok((value, ret))
    }
    fn args(&mut self, args: &[Expr], state: &State) -> Result<Vec<(Pos, Value, Type)>, Diag> {
        let mut checked = Vec::new();
        for arg in args {
            let (value, ty) = self.expr(arg, state)?;
            checked.push((arg.pos, value, ty));
        }
        Ok(checked)
    }

    /// A call to a declared function; `name` is its name in its module and
    /// `display` is how the call names it.
    fn call_sig(
        &self,
        pos: Pos,
        display: &str,
        name: &str,
        sig: &Sig,
        checked: Vec<(Pos, Value, Type)>,
    ) -> Result<(Value, Type), Diag> {
        let variadic = matches!(sig.target, Target::Extern { variadic: true, .. });
        if !variadic || checked.len() < sig.params.len() {
            self.arity(pos, display, sig.params.len(), checked.len())?;
        }
        for ((arg_pos, _, ty), &param) in checked.iter().zip(&sig.params) {
            self.expect(*arg_pos, param, *ty)?;
        }
        let call = match &sig.target {
            Target::Willow(symbol) => Call {
                symbol: symbol.clone(),
                args: checked.into_iter().map(|(_, v, _)| ("l", v)).collect(),
                variadic_at: None,
                ret: if sig.ret == Type::None {
                    None
                } else {
                    Some("l")
                },
            },
            Target::Extern {
                cparams,
                variadic,
                cret,
            } => {
                let mut call_args = Vec::new();
                for (i, (arg_pos, value, ty)) in checked.into_iter().enumerate() {
                    let extra = match ty {
                        Type::Int | Type::Ptr => "l",
                        Type::Float => "d",
                        _ if i >= cparams.len() => {
                            return self
                                .fail(arg_pos, "variadic arguments must be int, float, or ptr");
                        }
                        _ => "l",
                    };
                    call_args.push((cparams.get(i).copied().unwrap_or(extra), value));
                }
                Call {
                    symbol: name.to_string(),
                    args: call_args,
                    variadic_at: variadic.then_some(cparams.len()),
                    ret: *cret,
                }
            }
        };
        Ok((Value::Call(call), sig.ret))
    }
}
