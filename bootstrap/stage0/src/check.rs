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
    /// A QBE load instruction, the pointer, and the byte offset.
    Load(&'static str, Box<Value>, Box<Value>),
    /// A QBE store instruction, the pointer, the byte offset, and the value.
    Store(&'static str, Box<Value>, Box<Value>, Box<Value>),
}

pub struct Call {
    /// The callee's symbol, without its `$`.
    pub symbol: String,
    /// Each argument with its QBE type, `l` or `w`.
    pub args: Vec<(&'static str, Value)>,
    /// The number of fixed arguments of a variadic callee.
    pub variadic_at: Option<usize>,
    /// The QBE return type, or `None` for no result.
    pub ret: Option<&'static str>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Type {
    Int,
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
];

fn is_intrinsic(name: &str) -> bool {
    name == "__word" || name == "__str_type" || INTRINSICS.iter().any(|i| i.0 == name)
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
        let n = match self.index.get(text) {
            Some(&n) => n,
            None => {
                self.list.push(text.to_string());
                self.index.insert(text.to_string(), self.list.len() - 1);
                self.list.len() - 1
            }
        };
        Value::Global(format!("W.str.{n}"))
    }
}

pub fn check(modules: &[Module]) -> Result<Program, Diag> {
    let mut tables = Vec::new();
    for module in modules {
        tables.push(declare(module)?);
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
    let mut funcs = Vec::new();
    for (module, globals) in modules.iter().zip(&tables) {
        for func in &module.funcs {
            if let Some(body) = &func.body {
                let sig = &globals[&func.name];
                funcs.push(check_function(
                    module,
                    globals,
                    &mut strings,
                    func,
                    sig,
                    body,
                )?);
            }
        }
    }
    Ok(Program {
        funcs,
        strings: strings.list,
        main: format!("W.{}.main", entry.name),
    })
}

fn resolve(module: &Module, ty: &TypeName) -> Result<Type, Diag> {
    Ok(match ty.name.as_str() {
        "int" => Type::Int,
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
        Type::None => Ok((Type::None, None)),
        _ => Err(Diag::new(
            &module.path,
            ty.pos,
            "extern functions take and return only int, ptr, and cint",
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
            StmtKind::Expr(_) | StmtKind::Return(_) | StmtKind::Pass => {}
        }
    }
}

struct Checker<'a> {
    module: &'a Module,
    globals: &'a HashMap<String, Sig>,
    strings: &'a mut Strings,
    ret: Type,
    /// Every name that is local to the function, with its type once its
    /// first assignment has been checked.
    locals: HashMap<String, Option<Type>>,
    params: HashSet<String>,
    order: Vec<String>,
}

/// The locals definitely assigned at a point.
type State = HashSet<String>;

fn check_function(
    module: &Module,
    globals: &HashMap<String, Sig>,
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
        module,
        globals,
        strings,
        ret: sig.ret,
        locals,
        params: params.iter().cloned().collect(),
        order: Vec::new(),
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
                    lowered.push((cond_ir, body_ops));
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
                while let Some((cond_ir, body_ops)) = lowered.pop() {
                    tail = vec![Op::If(cond_ir, body_ops, tail)];
                }
                ops.extend(tail);
                if let Some(after) = after {
                    *state = after;
                }
                Ok(all_transfer)
            }
            StmtKind::While { cond, body } => {
                let cond_ir = self.condition(cond, state)?;
                let (body_ops, _) = self.block(body, &mut state.clone())?;
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
        }
    }

    fn expr(&mut self, expr: &Expr, state: &State) -> Result<(Value, Type), Diag> {
        match &expr.kind {
            ExprKind::Int(n) => Ok((Value::Const(*n), Type::Int)),
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
                if name == "__str_type" && self.module.name == "core" {
                    return Ok((Value::Global("W.str.type".into()), Type::Ptr));
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
            ExprKind::Unary(op, operand) => {
                let (value, ty) = self.expr(operand, state)?;
                if ty != Type::Int {
                    return self.fail(
                        expr.pos,
                        format!("operator '{op}' cannot be applied to {}", ty.name()),
                    );
                }
                if *op == "+" {
                    return Ok((value, ty));
                }
                Ok((
                    Value::Binary("sub", Box::new(Value::Const(0)), Box::new(value)),
                    Type::Int,
                ))
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
        let (instr, ty) = match (op, lt, rt) {
            ("+", Type::Int, Type::Int) => ("add", Type::Int),
            ("-", Type::Int, Type::Int) => ("sub", Type::Int),
            ("*", Type::Int, Type::Int) => ("mul", Type::Int),
            (_, Type::Int, Type::Int) if !compare.is_empty() => (compare, Type::Bool),
            ("==" | "!=", Type::Bool, Type::Bool) => (compare, Type::Bool),
            ("+", Type::Str, Type::Str) => {
                return Ok((core_call("str_concat", vec![l, r], true), Type::Str));
            }
            (_, Type::Str, Type::Str) if !compare.is_empty() => {
                // Strings compare by the sign of core's three-way comparison.
                let order = core_call("str_compare", vec![l, r], true);
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
        Ok((Value::Binary(instr, Box::new(l), Box::new(r)), ty))
    }

    fn call(&mut self, callee: &Expr, args: &[Expr], state: &State) -> Result<(Value, Type), Diag> {
        let pos = callee.pos;
        let name = match &callee.kind {
            ExprKind::Name(name) if !self.locals.contains_key(name) => name,
            _ => {
                let (_, ty) = self.expr(callee, state)?;
                return self.fail(pos, format!("cannot call a value of type {}", ty.name()));
            }
        };
        if !self.globals.contains_key(name) && name != "print" {
            if !is_intrinsic(name) || name == "__str_type" {
                if BUILTINS.contains(&name.as_str()) {
                    return self.fail(pos, format!("'{name}' is not supported"));
                }
                return self.fail(pos, format!("unknown name '{name}'"));
            }
            if self.module.name != "core" {
                return self.fail(pos, format!("intrinsic '{name}' is only available in core"));
            }
        }
        let mut checked = Vec::new();
        for arg in args {
            let (value, ty) = self.expr(arg, state)?;
            checked.push((arg.pos, value, ty));
        }
        let arity = |n: usize| -> Result<(), Diag> {
            if checked.len() == n {
                Ok(())
            } else {
                self.fail(
                    pos,
                    format!("'{name}' expects {}, received {}", count(n), checked.len()),
                )
            }
        };
        if let Some(sig) = self.globals.get(name) {
            let variadic = matches!(sig.target, Target::Extern { variadic: true, .. });
            if !variadic || checked.len() < sig.params.len() {
                arity(sig.params.len())?;
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
                        if i >= cparams.len() && !matches!(ty, Type::Int | Type::Ptr) {
                            return self.fail(arg_pos, "variadic arguments must be int or ptr");
                        }
                        call_args.push((cparams.get(i).copied().unwrap_or("l"), value));
                    }
                    Call {
                        symbol: name.clone(),
                        args: call_args,
                        variadic_at: variadic.then_some(cparams.len()),
                        ret: *cret,
                    }
                }
            };
            return Ok((Value::Call(call), sig.ret));
        }
        if name == "print" {
            arity(1)?;
            let (arg_pos, value, ty) = checked.pop().unwrap();
            let function = match ty {
                Type::Int => "print_int",
                Type::Str => "print_str",
                Type::Bool => "print_bool",
                _ => {
                    return self.fail(
                        arg_pos,
                        format!("cannot print a value of type {}", ty.name()),
                    );
                }
            };
            return Ok((core_call(function, vec![value], false), Type::None));
        }
        if name == "__word" {
            arity(1)?;
            let (arg_pos, value, ty) = checked.pop().unwrap();
            if !matches!(ty, Type::Int | Type::Ptr | Type::Str) {
                return self.fail(
                    arg_pos,
                    format!("cannot convert a value of type {} to word", ty.name()),
                );
            }
            return Ok((value, Type::Word));
        }
        let &(_, params, ret) = INTRINSICS.iter().find(|i| i.0 == name).unwrap();
        arity(params.len())?;
        for ((arg_pos, _, ty), &param) in checked.iter().zip(params) {
            self.expect(*arg_pos, param, *ty)?;
        }
        let mut values = checked.into_iter().map(|(_, v, _)| Box::new(v));
        let mut next = || values.next().unwrap();
        let value = match name.as_str() {
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
            "__load8" => Value::Load("loadl", next(), next()),
            "__store1" => Value::Store("storeb", next(), next(), next()),
            "__store8" => Value::Store("storel", next(), next(), next()),
            // Reinterpretations change only the static type.
            _ => *next(),
        };
        Ok((value, ret))
    }
}
