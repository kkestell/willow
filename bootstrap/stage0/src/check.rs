//! Binds names, checks types and flow, and lowers the checked program to the
//! small IR the emitter writes out. Built-in operations become calls into
//! `core` here, so the emitter only knows QBE.

use std::collections::{HashMap, HashSet};

use crate::parser::{Expr, ExprKind, Func, Module, Stmt, StmtKind, TypeExpr, TypeName};
use crate::types::Type;
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
    /// `object[index] = value` through core's `function`, evaluating the
    /// value first, then the object, then the index.
    SetItem {
        function: &'static str,
        object: Value,
        index: Value,
        value: Value,
    },
    /// A loop over a list; `stores` assign `Value::Item(0)` to the loop
    /// variable.
    ForList {
        list: Value,
        stores: Vec<Op>,
        body: Vec<Op>,
    },
    /// A loop over the code points of a string, each as a string.
    ForStr {
        text: Value,
        stores: Vec<Op>,
        body: Vec<Op>,
    },
    /// A loop over a dict's live entries; `Value::Item(0)` is the key and
    /// `Value::Item(1)` the value. A change to the dict's keys fails the
    /// next step.
    ForDict {
        dict: Value,
        stores: Vec<Op>,
        body: Vec<Op>,
    },
    /// A loop over `range(start, stop, step)`, which calls `fail` for a zero
    /// step.
    ForRange {
        start: Value,
        stop: Value,
        step: Value,
        fail: Value,
        stores: Vec<Op>,
        body: Vec<Op>,
    },
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
    /// Integer `add`, `sub`, or `mul`, which calls `fail` when the result is
    /// outside the symmetric int range.
    CheckedInt {
        instr: &'static str,
        left: Box<Value>,
        right: Box<Value>,
        fail: Box<Value>,
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
    /// A new list holding the values.
    ListDisplay(Vec<Value>),
    /// A new dict with keys of the equality kind, holding the entries.
    DictDisplay {
        kind: i64,
        entries: Vec<(Value, Value)>,
    },
    /// `d.get(key, default)`: `present`, built from the found value as
    /// `Value::Item(0)`, or `default`, which is evaluated first.
    DictGet {
        dict: Box<Value>,
        key: Box<Value>,
        default: Box<Value>,
        present: Box<Value>,
    },
    /// An item of the innermost `for` loop or `get`: 0 for an element, a
    /// key, or a found value, and 1 for a dict entry's value.
    Item(usize),
    /// The first value, evaluated for its effects, then the second.
    Seq(Box<Value>, Box<Value>),
    /// Core's `function(container, item, extra...)`, evaluating `item` first
    /// as the source order requires.
    In {
        function: &'static str,
        item: Box<Value>,
        container: Box<Value>,
        extra: Vec<Value>,
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
    ("__offset", &[Type::Ptr, Type::Int], Type::Ptr),
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
    if !main.params.is_empty()
        || main
            .ret
            .as_ref()
            .is_some_and(|r| r.members.len() != 1 || r.members[0].name != "None")
    {
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
            // Only core can be imported so far. Core's tests import it to call
            // its functions; nothing stops another program from doing so.
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

fn resolve_name(module: &Module, ty: &TypeName) -> Result<Type, Diag> {
    let fail = |message: String| Err(Diag::new(&module.path, ty.pos, message));
    let expected = match ty.name.as_str() {
        "list" => 1,
        "dict" => 2,
        _ => 0,
    };
    if ty.args.len() != expected {
        let plural = if expected == 1 { "" } else { "s" };
        return fail(format!(
            "'{}' expects {expected} type argument{plural}, received {}",
            ty.name,
            ty.args.len()
        ));
    }
    if ty.name == "list" {
        let element = resolve(module, &ty.args[0])?;
        if matches!(element, Type::Ptr | Type::Word) {
            return fail(format!("{} cannot be a list element", element.name()));
        }
        return Ok(Type::List(Box::new(element)));
    }
    if ty.name == "dict" {
        let key = resolve(module, &ty.args[0])?;
        let value = resolve(module, &ty.args[1])?;
        if !is_key_type(&key) {
            return Err(Diag::new(
                &module.path,
                ty.args[0].pos,
                "dictionary keys must be int, str, or an enum",
            ));
        }
        if matches!(value, Type::Ptr | Type::Word) {
            return fail(format!("{} cannot be a dict value", value.name()));
        }
        return Ok(Type::Dict(Box::new(key), Box::new(value)));
    }
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

/// Dict keys hash by kind, which core knows for int and str (and enums).
fn is_key_type(ty: &Type) -> bool {
    matches!(ty, Type::Int | Type::Str)
}

fn resolve(module: &Module, ty: &TypeExpr) -> Result<Type, Diag> {
    if let [only] = ty.members.as_slice() {
        return resolve_name(module, only);
    }
    let mut members = Vec::new();
    for name in &ty.members {
        let member = resolve_name(module, name)?;
        let fail = |message: String| Err(Diag::new(&module.path, name.pos, message));
        if matches!(member, Type::Ptr | Type::Word) {
            return fail(format!("{} cannot be a union member", member.name()));
        }
        if members.contains(&member) {
            let name = member.name();
            return fail(format!("union members {name} and {name} overlap"));
        }
        if matches!(member, Type::List(_)) && members.iter().any(|m| matches!(m, Type::List(_))) {
            return fail("a union can have only one list member".into());
        }
        if matches!(member, Type::Dict(..)) && members.iter().any(|m| matches!(m, Type::Dict(..))) {
            return fail("a union can have only one dict member".into());
        }
        members.push(member);
    }
    Ok(Type::union(members))
}

/// The Willow type and QBE type of an extern parameter or return type.
fn resolve_extern(module: &Module, ty: &TypeExpr) -> Result<(Type, Option<&'static str>), Diag> {
    if let [only] = ty.members.as_slice() {
        if only.name == "cint" {
            return Ok((Type::Int, Some("w")));
        }
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
            StmtKind::For { targets, body, .. } => {
                names.extend(targets.iter().cloned());
                assigned_names(body, names);
            }
            StmtKind::Expr(_)
            | StmtKind::SetIndex { .. }
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

/// The locals definitely assigned at a point, each with the type narrowing
/// gives it there: its declared type, or some of its members.
type State = HashMap<String, Type>;

/// What a `for` loop iterates: range bounds, or a list and its element type.
enum ForSource {
    Range(Value, Value, Value),
    List(Value, Type),
    Str(Value),
    /// A dict, its key and value types, and which of them each step gives:
    /// the keys, the values, or both.
    Dict(Value, Type, Type, &'static str),
}

impl ForSource {
    /// Each item a step gives, as the `Value::Item` slot and its type.
    fn items(&self) -> Vec<(usize, Type)> {
        match self {
            ForSource::Range(..) => vec![(0, Type::Int)],
            ForSource::List(_, element) => vec![(0, element.clone())],
            ForSource::Str(_) => vec![(0, Type::Str)],
            ForSource::Dict(_, key, _, "keys") => vec![(0, key.clone())],
            ForSource::Dict(_, _, value, "values") => vec![(1, value.clone())],
            ForSource::Dict(_, key, value, _) => vec![(0, key.clone()), (1, value.clone())],
        }
    }
}

/// Narrowed types a condition proves for locals, applied in order.
type Facts = Vec<(String, Type)>;

fn narrow(state: &State, facts: &Facts) -> State {
    let mut result = state.clone();
    for (name, ty) in facts {
        result.insert(name.clone(), ty.clone());
    }
    result
}

/// The state after two paths meet: the locals both assign, with the members
/// either path allows.
fn join(a: &State, b: &State) -> State {
    a.iter()
        .filter_map(|(name, ty)| {
            let other = b.get(name)?;
            Some((name.clone(), Type::union([ty.clone(), other.clone()])))
        })
        .collect()
}

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
    for (param, ty) in func.params.iter().zip(&sig.params) {
        locals.insert(param.name.clone(), Some(ty.clone()));
        state.insert(param.name.clone(), ty.clone());
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
        ret: sig.ret.clone(),
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

/// `value` of type `from` as a value of `to`, boxed when a scalar enters a
/// union. A sub-union and `str` have the same representation as the union.
fn widen(value: Value, from: &Type, to: &Type) -> Value {
    match from.box_descriptor() {
        Some(descriptor) if to.is_union() => {
            core_call("box", vec![Value::Global(descriptor.into()), value], true)
        }
        _ => value,
    }
}

/// The value of a local declared `declared` that narrowing has made
/// `current`, unboxed when it is a single boxed member of a union.
fn narrowed(value: Value, declared: &Type, current: &Type) -> Value {
    if declared.is_union() && current.box_descriptor().is_some() {
        core_call("unbox", vec![value], true)
    } else {
        value
    }
}

/// The scalar type `expr` names as the class of an isinstance test.
/// A call of a dict method: the dict, its key and value types, and where
/// and how the call names the method.
struct DictCall<'a> {
    dict: Value,
    key: &'a Type,
    value: &'a Type,
    pos: Pos,
    display: &'a str,
}

/// The core function, parameter types, defaults for the trailing optional
/// parameters, and result type of the method `name` of a value of `ty`.
fn method_signature(ty: &Type, name: &str) -> Option<(&'static str, Vec<Type>, Vec<i64>, Type)> {
    let str_list = Type::List(Box::new(Type::Str));
    let text = |function, params: Vec<Type>, ret| (function, params, Vec::new(), ret);
    Some(match (ty, name) {
        (Type::List(element), "append") => {
            text("list_append", vec![(**element).clone()], Type::None)
        }
        (Type::List(element), "pop") => text("list_pop", vec![], (**element).clone()),
        (Type::List(_), "extend") => text("list_extend", vec![ty.clone()], Type::None),
        (Type::List(_), "reverse") => text("list_reverse", vec![], Type::None),
        (Type::Dict(key, value), "pop") => {
            text("dict_pop", vec![(**key).clone()], (**value).clone())
        }
        (Type::Str, "find") => text("str_find", vec![Type::Str], Type::Int),
        (Type::Str, "startswith") => text("str_startswith", vec![Type::Str], Type::Bool),
        (Type::Str, "endswith") => text("str_endswith", vec![Type::Str], Type::Bool),
        (Type::Str, "replace") => text("str_replace", vec![Type::Str, Type::Str], Type::Str),
        (Type::Str, "strip") => text("str_strip", vec![], Type::Str),
        (Type::Str, "removeprefix") => text("str_removeprefix", vec![Type::Str], Type::Str),
        (Type::Str, "removesuffix") => text("str_removesuffix", vec![Type::Str], Type::Str),
        (Type::Str, "isdigit") => text("str_isdigit", vec![], Type::Bool),
        (Type::Str, "isalpha") => text("str_isalpha", vec![], Type::Bool),
        (Type::Str, "isalnum") => text("str_isalnum", vec![], Type::Bool),
        (Type::Str, "isspace") => text("str_isspace", vec![], Type::Bool),
        (Type::Str, "ljust") => text("str_ljust", vec![Type::Int], Type::Str),
        (Type::Str, "rjust") => text("str_rjust", vec![Type::Int], Type::Str),
        (Type::Str, "join") => text("str_join", vec![str_list], Type::Str),
        // An omitted separator is None, and an omitted maxsplit -1.
        (Type::Str, "split") => (
            "str_split",
            vec![Type::union([Type::Str, Type::None]), Type::Int],
            vec![0, -1],
            str_list,
        ),
        _ => return None,
    })
}

/// The class an isinstance test names, as written, and the member of `ty`
/// it selects, if any; `list` selects the list member.
fn isinstance_type<'e>(expr: &'e Expr, ty: &Type) -> Option<(&'e str, Option<Type>)> {
    let ExprKind::Name(name) = &expr.kind else {
        return None;
    };
    let class = match name.as_str() {
        "int" => Type::Int,
        "float" => Type::Float,
        "bool" => Type::Bool,
        "str" => Type::Str,
        "list" => {
            let member = ty.members().iter().find(|m| matches!(m, Type::List(_)));
            return Some((name, member.cloned()));
        }
        "dict" => {
            let member = ty.members().iter().find(|m| matches!(m, Type::Dict(..)));
            return Some((name, member.cloned()));
        }
        _ => return None,
    };
    let member = ty.members().contains(&class).then_some(class);
    Some((name, member))
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

    fn expect(&self, pos: Pos, expected: &Type, actual: &Type) -> Result<(), Diag> {
        if expected == actual {
            Ok(())
        } else {
            self.fail(
                pos,
                format!("expected {}, received {}", expected.name(), actual.name()),
            )
        }
    }

    /// `value` of type `from` at a point that needs a `to`, boxed when a
    /// scalar enters a union.
    fn coerce(&self, pos: Pos, value: Value, from: &Type, to: &Type) -> Result<Value, Diag> {
        if !from.assignable_to(to) {
            return self.fail(
                pos,
                format!("expected {}, received {}", to.name(), from.name()),
            );
        }
        Ok(widen(value, from, to))
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
        self.expect(cond.pos, &Type::Bool, &ty)?;
        Ok(value)
    }

    /// Assigns `value` of type `ty` to the local `target`, whose first
    /// assignment sets its type to `annotated` or `ty`.
    fn assign(
        &mut self,
        target: &str,
        pos: Pos,
        value: Value,
        ty: &Type,
        annotated: Option<Type>,
        state: &mut State,
    ) -> Result<Op, Diag> {
        let declared = match &self.locals[target] {
            Some(declared) => declared.clone(),
            None => {
                let declared = annotated.unwrap_or_else(|| ty.clone());
                self.locals
                    .insert(target.to_string(), Some(declared.clone()));
                self.order.push(target.to_string());
                declared
            }
        };
        let value = self.coerce(pos, value, ty, &declared)?;
        // A single member other than None narrows the local to it.
        let current = if declared.is_union() && !ty.is_union() && *ty != Type::None {
            ty.clone()
        } else {
            declared
        };
        state.insert(target.to_string(), current);
        Ok(Op::Assign(target.to_string(), value))
    }

    /// Narrowing from before a loop holds in and after it only for the
    /// locals its body does not assign.
    fn forget_narrowing(&self, assigned: &HashSet<String>, state: &mut State) {
        for name in assigned {
            if let (Some(Some(declared)), true) = (self.locals.get(name), state.contains_key(name))
            {
                state.insert(name.clone(), declared.clone());
            }
        }
    }

    fn for_source(&mut self, iterable: &Expr, state: &State) -> Result<ForSource, Diag> {
        if let ExprKind::Call(callee, args) = &iterable.kind {
            if self.is_builtin(callee, "range") {
                if args.is_empty() || args.len() > 3 {
                    return self.fail(
                        callee.pos,
                        format!("'range' expects 1 to 3 arguments, received {}", args.len()),
                    );
                }
                let mut bounds = Vec::new();
                for arg in args {
                    let (value, ty) = self.expr(arg, state)?;
                    self.expect(arg.pos, &Type::Int, &ty)?;
                    bounds.push(value);
                }
                let mut bounds = bounds.into_iter();
                let first = bounds.next().unwrap();
                let (start, stop) = match bounds.next() {
                    Some(stop) => (first, stop),
                    None => (Value::Const(0), first),
                };
                let step = bounds.next().unwrap_or(Value::Const(1));
                return Ok(ForSource::Range(start, stop, step));
            }
        }
        if let ExprKind::Call(callee, args) = &iterable.kind {
            if let ExprKind::Attr(object, name_pos, name) = &callee.kind {
                if matches!(name.as_str(), "keys" | "values" | "items")
                    && self.module_of(object).is_none()
                {
                    let (dict, ty) = self.expr(object, state)?;
                    let display = format!("{}.{name}", ty.name());
                    let Type::Dict(key, value) = ty else {
                        return self.fail(
                            *name_pos,
                            format!("type {} has no method '{name}'", ty.name()),
                        );
                    };
                    self.arity(*name_pos, &display, 0, args.len())?;
                    let part = match name.as_str() {
                        "keys" => "keys",
                        "values" => "values",
                        _ => "items",
                    };
                    return Ok(ForSource::Dict(dict, *key, *value, part));
                }
            }
        }
        let (value, ty) = self.expr(iterable, state)?;
        match ty {
            Type::List(element) => Ok(ForSource::List(value, *element)),
            Type::Str => Ok(ForSource::Str(value)),
            Type::Dict(key, element) => Ok(ForSource::Dict(value, *key, *element, "keys")),
            _ => self.fail(iterable.pos, format!("cannot iterate over {}", ty.name())),
        }
    }

    /// Checks `expr`, giving a display `expected` as its type when there is
    /// one (spec §7, Displays).
    fn expr_expect(
        &mut self,
        expr: &Expr,
        state: &State,
        expected: Option<&Type>,
    ) -> Result<(Value, Type), Diag> {
        match &expr.kind {
            ExprKind::List(items) => self.list_display(items, expr.pos, state, expected),
            ExprKind::Dict(entries) => self.dict_display(entries, expr.pos, state, expected),
            _ => self.expr(expr, state),
        }
    }

    fn list_display(
        &mut self,
        items: &[Expr],
        pos: Pos,
        state: &State,
        expected: Option<&Type>,
    ) -> Result<(Value, Type), Diag> {
        let mut values = Vec::new();
        let element = match expected.and_then(Type::list_element) {
            Some(element) => element.clone(),
            None => {
                let Some(first) = items.first() else {
                    return self.fail(pos, "cannot infer the element type of an empty list");
                };
                let (value, ty) = self.expr(first, state)?;
                values.push(value);
                ty
            }
        };
        for item in &items[values.len()..] {
            let (value, ty) = self.expr_expect(item, state, Some(&element))?;
            values.push(self.coerce(item.pos, value, &ty, &element)?);
        }
        Ok((Value::ListDisplay(values), Type::List(Box::new(element))))
    }

    fn dict_display(
        &mut self,
        entries: &[(Expr, Expr)],
        pos: Pos,
        state: &State,
        expected: Option<&Type>,
    ) -> Result<(Value, Type), Diag> {
        let mut values = Vec::new();
        let (key, value) = match expected.and_then(Type::dict_entry) {
            Some((key, value)) => (key.clone(), value.clone()),
            None => {
                let Some((key, value)) = entries.first() else {
                    return self.fail(pos, "cannot infer the key and value types of an empty dict");
                };
                let (key_ir, key_ty) = self.expr(key, state)?;
                let (value_ir, value_ty) = self.expr(value, state)?;
                if !is_key_type(&key_ty) {
                    return self.fail(key.pos, "dictionary keys must be int, str, or an enum");
                }
                values.push((key_ir, value_ir));
                (key_ty, value_ty)
            }
        };
        for (k, v) in &entries[values.len()..] {
            let (key_ir, key_ty) = self.expr(k, state)?;
            let key_ir = self.coerce(k.pos, key_ir, &key_ty, &key)?;
            let (value_ir, value_ty) = self.expr_expect(v, state, Some(&value))?;
            let value_ir = self.coerce(v.pos, value_ir, &value_ty, &value)?;
            values.push((key_ir, value_ir));
        }
        let display = Value::DictDisplay {
            kind: key.equality_kind(),
            entries: values,
        };
        Ok((display, Type::Dict(Box::new(key), Box::new(value))))
    }

    /// The facts `cond` proves when it is true and when it is false (spec
    /// §9, Narrowing).
    fn facts(&self, cond: &Expr, state: &State) -> (Facts, Facts) {
        match &cond.kind {
            ExprKind::IsNone {
                operand, negated, ..
            } => {
                let Some((name, ty)) = self.narrowable(operand, state) else {
                    return (Vec::new(), Vec::new());
                };
                if !ty.is_optional() {
                    return (Vec::new(), Vec::new());
                }
                // Only the outcome that rules out None narrows.
                let some = vec![(name, ty.without(&Type::None))];
                if *negated {
                    (some, Vec::new())
                } else {
                    (Vec::new(), some)
                }
            }
            ExprKind::Call(callee, args) if self.is_builtin(callee, "isinstance") => {
                let [value, class] = args.as_slice() else {
                    return (Vec::new(), Vec::new());
                };
                let Some((name, ty)) = self.narrowable(value, state) else {
                    return (Vec::new(), Vec::new());
                };
                let Some((_, Some(class))) = isinstance_type(class, &ty) else {
                    return (Vec::new(), Vec::new());
                };
                if !ty.is_union() {
                    return (Vec::new(), Vec::new());
                }
                let other = ty.without(&class);
                (vec![(name.clone(), class)], vec![(name, other)])
            }
            ExprKind::Unary("not", operand) => {
                let (yes, no) = self.facts(operand, state);
                (no, yes)
            }
            ExprKind::Binary("and", _, left, right) => {
                let (mut yes, _) = self.facts(left, state);
                let (right_yes, _) = self.facts(right, &narrow(state, &yes));
                yes.extend(right_yes);
                (yes, Vec::new())
            }
            ExprKind::Binary("or", _, left, right) => {
                let (_, mut no) = self.facts(left, state);
                let (_, right_no) = self.facts(right, &narrow(state, &no));
                no.extend(right_no);
                (Vec::new(), no)
            }
            _ => (Vec::new(), Vec::new()),
        }
    }

    /// A local that a condition can narrow, with its type at this point.
    fn narrowable(&self, expr: &Expr, state: &State) -> Option<(String, Type)> {
        match &expr.kind {
            ExprKind::Name(name) => state.get(name).map(|ty| (name.clone(), ty.clone())),
            _ => None,
        }
    }

    /// Whether `callee` names the built-in `name`, which no local hides.
    fn is_builtin(&self, callee: &Expr, name: &str) -> bool {
        matches!(&callee.kind, ExprKind::Name(n) if n == name && !self.locals.contains_key(n))
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
                let annotated = match annotation {
                    Some(a) => Some(resolve(self.module, a)?),
                    None => None,
                };
                let expected = self.locals[target].clone().or(annotated.clone());
                let (value_ir, ty) = self.expr_expect(value, state, expected.as_ref())?;
                let op = self.assign(target, value.pos, value_ir, &ty, annotated, state)?;
                ops.push(op);
                Ok(false)
            }
            StmtKind::SetIndex {
                bracket,
                object,
                index,
                value,
            } => {
                let (object_ir, object_ty) = self.expr(object, state)?;
                let (index_type, element, function) = match &object_ty {
                    Type::List(element) => (Type::Int, &**element, "W.core.list_set"),
                    Type::Dict(key, value) => ((**key).clone(), &**value, "W.core.dict_set"),
                    _ => {
                        return self.fail(
                            *bracket,
                            format!(
                                "cannot assign to an index of a value of type {}",
                                object_ty.name()
                            ),
                        );
                    }
                };
                let (index_ir, index_ty) = self.expr(index, state)?;
                let index_ir = self.coerce(index.pos, index_ir, &index_ty, &index_type)?;
                let (value_ir, value_ty) = self.expr_expect(value, state, Some(element))?;
                let value_ir = self.coerce(value.pos, value_ir, &value_ty, element)?;
                ops.push(Op::SetItem {
                    function,
                    object: object_ir,
                    index: index_ir,
                    value: value_ir,
                });
                Ok(false)
            }
            StmtKind::For {
                targets,
                iterable,
                body,
            } => {
                let mut assigned = HashSet::new();
                assigned_names(body, &mut assigned);
                assigned.extend(targets.iter().cloned());
                self.forget_narrowing(&assigned, state);
                let source = self.for_source(iterable, state)?;
                let items = source.items();
                if targets.len() != items.len() {
                    let message = match items.as_slice() {
                        [(_, item)] => format!("cannot unpack a value of type {}", item.name()),
                        _ => "'items' gives a key and a value, so it needs two targets".into(),
                    };
                    return self.fail(stmt.pos, message);
                }
                if targets.len() == 2 && targets[0] == targets[1] {
                    return self.fail(stmt.pos, format!("duplicate target '{}'", targets[0]));
                }
                let mut body_state = state.clone();
                let mut stores = Vec::new();
                for (target, (slot, ty)) in targets.iter().zip(items) {
                    let item = Value::Item(slot);
                    stores.push(self.assign(
                        target,
                        iterable.pos,
                        item,
                        &ty,
                        None,
                        &mut body_state,
                    )?);
                }
                self.loops += 1;
                let (body, _) = self.block(body, &mut body_state)?;
                self.loops -= 1;
                ops.push(match source {
                    ForSource::Range(start, stop, step) => {
                        let message = self.strings.intern("range step must not be zero");
                        let fail = self.fail_call("ValueError", message);
                        Op::ForRange {
                            start,
                            stop,
                            step,
                            fail,
                            stores,
                            body,
                        }
                    }
                    ForSource::List(list, _) => Op::ForList { list, stores, body },
                    ForSource::Str(text) => Op::ForStr { text, stores, body },
                    ForSource::Dict(dict, ..) => Op::ForDict { dict, stores, body },
                });
                Ok(false)
            }
            StmtKind::Expr(expr) => {
                ops.push(Op::Eval(self.expr(expr, state)?.0));
                Ok(false)
            }
            StmtKind::Assert { cond, message } => {
                let cond_ir = self.condition(cond, state)?;
                let (yes, no) = self.facts(cond, state);
                let message_ir = match message {
                    Some(message) => {
                        let (message_ir, ty) = self.expr(message, &narrow(state, &no))?;
                        self.expect(message.pos, &Type::Str, &ty)?;
                        message_ir
                    }
                    None => self.strings.intern("assertion failed"),
                };
                let fail = self.fail_call("AssertionError", message_ir);
                ops.push(Op::If(cond_ir, Vec::new(), vec![Op::Eval(fail)]));
                *state = narrow(state, &yes);
                Ok(false)
            }
            StmtKind::If { arms, otherwise } => {
                // Lower the arms from the last, so each `elif` nests in the
                // `else` of the arm before it.
                // Each arm starts with its condition's true facts and the
                // false facts of the conditions before it.
                let mut after: Option<State> = None;
                let mut all_transfer = true;
                let mut merge = |branch: State, transfers: bool| {
                    if !transfers {
                        all_transfer = false;
                        after = Some(match after.take() {
                            None => branch,
                            Some(prev) => join(&prev, &branch),
                        });
                    }
                };
                let mut base = state.clone();
                let mut lowered = Vec::new();
                for (cond, body) in arms {
                    let cond_ir = self.condition(cond, &base)?;
                    let (yes, no) = self.facts(cond, &base);
                    let mut branch = narrow(&base, &yes);
                    let (body_ops, transfers) = self.block(body, &mut branch)?;
                    merge(branch, transfers);
                    lowered.push((cond_ir, body_ops, self.os_test(cond)));
                    base = narrow(&base, &no);
                }
                let mut tail = match otherwise {
                    Some(body) => {
                        let (body_ops, transfers) = self.block(body, &mut base)?;
                        merge(base, transfers);
                        body_ops
                    }
                    None => {
                        merge(base, false);
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
                // Narrowing from before the loop holds in and after it only
                // for the locals its body does not assign.
                let mut assigned = HashSet::new();
                assigned_names(body, &mut assigned);
                self.forget_narrowing(&assigned, state);
                let cond_ir = self.condition(cond, state)?;
                let (yes, _) = self.facts(cond, state);
                self.loops += 1;
                let (body_ops, _) = self.block(body, &mut narrow(state, &yes))?;
                self.loops -= 1;
                ops.push(Op::While(cond_ir, body_ops));
                Ok(false)
            }
            StmtKind::Return(value) => {
                let ret = self.ret.clone();
                let value_ir = match value {
                    Some(value) => {
                        let (value_ir, ty) = self.expr_expect(value, state, Some(&ret))?;
                        Some(self.coerce(value.pos, value_ir, &ty, &ret)?)
                    }
                    None => {
                        self.coerce(stmt.pos, Value::Const(0), &Type::None, &ret)?;
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
            ExprKind::None => Ok((Value::Const(0), Type::None)),
            ExprKind::IsNone {
                operand,
                negated,
                op_pos,
            } => {
                let (value, ty) = self.expr(operand, state)?;
                if !ty.is_optional() {
                    let op = if *negated { "is not" } else { "is" };
                    return self.fail(
                        *op_pos,
                        format!("operator '{op}' cannot be applied to {}", ty.name()),
                    );
                }
                let instr = if *negated { "cnel" } else { "ceql" };
                Ok((
                    Value::Binary(instr, Box::new(value), Box::new(Value::Const(0))),
                    Type::Bool,
                ))
            }
            ExprKind::Str(text) => Ok((self.strings.intern(text), Type::Str)),
            ExprKind::Name(name) => {
                if let Some(declared) = self.locals.get(name) {
                    let (Some(declared), Some(current)) = (declared, state.get(name)) else {
                        return self.fail(
                            expr.pos,
                            format!("variable '{name}' may be used before assignment"),
                        );
                    };
                    let value = narrowed(Value::Local(name.clone()), declared, current);
                    return Ok((value, current.clone()));
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
            ExprKind::List(items) => self.list_display(items, expr.pos, state, None),
            ExprKind::Dict(entries) => self.dict_display(entries, expr.pos, state, None),
            ExprKind::Index(object, index) => {
                let (object_ir, object_ty) = self.expr(object, state)?;
                let (index_ir, index_ty) = self.expr(index, state)?;
                if let Type::Dict(key, value) = object_ty {
                    let key_ir = self.coerce(index.pos, index_ir, &index_ty, &key)?;
                    return Ok((core_call("dict_get", vec![object_ir, key_ir], true), *value));
                }
                self.expect(index.pos, &Type::Int, &index_ty)?;
                let args = vec![object_ir, index_ir];
                match object_ty {
                    Type::List(element) => Ok((core_call("list_get", args, true), *element)),
                    Type::Str => Ok((core_call("str_index", args, true), Type::Str)),
                    _ => self.fail(
                        expr.pos,
                        format!("cannot index a value of type {}", object_ty.name()),
                    ),
                }
            }
            ExprKind::Slice(object, start, stop) => {
                let (object_ir, object_ty) = self.expr(object, state)?;
                // An omitted stop is the largest int, which clamping makes
                // the length (core/API.md).
                let mut bounds = vec![object_ir];
                for (bound, omitted) in [(start, 0), (stop, i64::MAX)] {
                    match bound {
                        Some(bound) => {
                            let (value, ty) = self.expr(bound, state)?;
                            self.expect(bound.pos, &Type::Int, &ty)?;
                            bounds.push(value);
                        }
                        None => bounds.push(Value::Const(omitted)),
                    }
                }
                let function = match &object_ty {
                    Type::List(_) => "list_slice",
                    Type::Str => "str_slice",
                    _ => {
                        return self.fail(
                            expr.pos,
                            format!("cannot slice a value of type {}", object_ty.name()),
                        );
                    }
                };
                Ok((core_call(function, bounds, true), object_ty))
            }
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
                match (*op, &ty) {
                    ("+", Type::Int | Type::Float) => Ok((value, ty.clone())),
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
                // The right operand of `and` and `or` sees the facts that hold
                // when it is evaluated.
                let right_state = match *op {
                    "and" => narrow(state, &self.facts(left, state).0),
                    "or" => narrow(state, &self.facts(left, state).1),
                    _ => state.clone(),
                };
                let (r, rt) = self.expr(right, &right_state)?;
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
        if matches!(op, "in" | "not in") {
            return self.contains(op, pos, l, &lt, r, &rt);
        }
        let union_operands = |t: &Type| t.is_union() || *t == Type::None;
        if matches!(op, "==" | "!=")
            && (union_operands(&lt) || union_operands(&rt))
            && lt.is_comparable()
            && rt.is_comparable()
        {
            let target = if lt.assignable_to(&rt) {
                rt.clone()
            } else if rt.assignable_to(&lt) {
                lt.clone()
            } else {
                return self.fail(
                    pos,
                    format!(
                        "operator '{op}' cannot be applied to {} and {}",
                        lt.name(),
                        rt.name()
                    ),
                );
            };
            let args = vec![widen(l, &lt, &target), widen(r, &rt, &target)];
            let equal = core_call("union_eq", args, true);
            if op == "==" {
                return Ok((equal, Type::Bool));
            }
            let unequal = Value::Binary("ceql", Box::new(equal), Box::new(Value::Const(0)));
            return Ok((unequal, Type::Bool));
        }
        let (l, r) = (Box::new(l), Box::new(r));
        let (instr, ty) = match (op, &lt, &rt) {
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
            ("+" | "-" | "*", Type::Int, Type::Int) => {
                let message = self.strings.intern("integer overflow");
                let fail = Box::new(self.fail_call("OverflowError", message));
                let instr = match op {
                    "+" => "add",
                    "-" => "sub",
                    _ => "mul",
                };
                let checked = Value::CheckedInt {
                    instr,
                    left: l,
                    right: r,
                    fail,
                };
                return Ok((checked, Type::Int));
            }
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

    /// `item in container`, or `not in`.
    fn contains(
        &mut self,
        op: &str,
        pos: Pos,
        item: Value,
        item_ty: &Type,
        container: Value,
        container_ty: &Type,
    ) -> Result<(Value, Type), Diag> {
        let found = match container_ty {
            Type::List(element) if element.is_comparable() && item_ty.assignable_to(element) => {
                let kind = Value::Const(element.equality_kind());
                Value::In {
                    function: "W.core.list_contains",
                    item: Box::new(widen(item, item_ty, element)),
                    container: Box::new(container),
                    extra: vec![kind],
                }
            }
            Type::Dict(key, _) if item_ty.assignable_to(key) => Value::In {
                function: "W.core.dict_contains",
                item: Box::new(item),
                container: Box::new(container),
                extra: Vec::new(),
            },
            Type::Str if *item_ty == Type::Str => Value::In {
                function: "W.core.str_contains",
                item: Box::new(item),
                container: Box::new(container),
                extra: Vec::new(),
            },
            _ => {
                return self.fail(
                    pos,
                    format!(
                        "operator '{op}' cannot be applied to {} and {}",
                        item_ty.name(),
                        container_ty.name()
                    ),
                );
            }
        };
        if op == "in" {
            return Ok((found, Type::Bool));
        }
        let missing = Value::Binary("ceql", Box::new(found), Box::new(Value::Const(0)));
        Ok((missing, Type::Bool))
    }

    /// The text `print` and `str` give a value of type `ty`, if it is
    /// printable.
    fn to_str(&mut self, value: Value, ty: &Type) -> Option<Value> {
        Some(match ty {
            Type::Int => core_call("int_to_str", vec![value], true),
            Type::Float => core_call("float_to_str", vec![value], true),
            Type::Bool => core_call("bool_to_str", vec![value], true),
            Type::Str => value,
            Type::None => {
                let text = self.strings.intern("None");
                Value::Seq(Box::new(value), Box::new(text))
            }
            Type::Union(_) if ty.is_comparable() => core_call("union_to_str", vec![value], true),
            _ => return None,
        })
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
                return self.method(object, *name_pos, name, args, state);
            };
            let table = self.imported[module];
            let Some(sig) = table.get(name) else {
                return self.fail(
                    *name_pos,
                    format!("module '{module}' has no function '{name}'"),
                );
            };
            let display = format!("{module}.{name}");
            let checked = self.args(args, state, &sig.params)?;
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
        if name == "isinstance" && !globals.contains_key(name) {
            return self.isinstance(pos, args, state);
        }
        if name == "range" && !globals.contains_key(name) {
            return self.fail(pos, "'range' can only be the source of a for loop");
        }
        if !globals.contains_key(name)
            && !matches!(
                name,
                "print" | "int" | "float" | "str" | "len" | "ord" | "chr"
            )
        {
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
        if let Some(sig) = globals.get(name) {
            let checked = self.args(args, state, &sig.params)?;
            return self.call_sig(pos, name, name, sig, checked);
        }
        let mut checked = self.args(args, state, &[])?;
        if name == "print" || name == "str" {
            self.arity(pos, name, 1, checked.len())?;
            let (arg_pos, value, ty) = checked.pop().unwrap();
            let Some(text) = self.to_str(value, &ty) else {
                let message = if name == "print" {
                    format!("cannot print a value of type {}", ty.name())
                } else {
                    format!("cannot convert a value of type {} to str", ty.name())
                };
                return self.fail(arg_pos, message);
            };
            if name == "str" {
                return Ok((text, Type::Str));
            }
            return Ok((core_call("print_str", vec![text], false), Type::None));
        }
        if name == "ord" || name == "chr" {
            self.arity(pos, name, 1, checked.len())?;
            let (arg_pos, value, ty) = checked.pop().unwrap();
            let (param, ret, function) = if name == "ord" {
                (Type::Str, Type::Int, "str_ord")
            } else {
                (Type::Int, Type::Str, "str_chr")
            };
            self.expect(arg_pos, &param, &ty)?;
            return Ok((core_call(function, vec![value], true), ret));
        }
        if name == "len" {
            self.arity(pos, name, 1, checked.len())?;
            let (_, value, ty) = checked.pop().unwrap();
            let function = match ty {
                Type::List(_) => "list_len",
                Type::Dict(..) => "dict_len",
                Type::Str => "str_len",
                _ => {
                    return self.fail(pos, format!("'len' cannot be applied to {}", ty.name()));
                }
            };
            return Ok((core_call(function, vec![value], true), Type::Int));
        }
        if name == "int" || name == "float" {
            self.arity(pos, name, 1, checked.len())?;
            let (arg_pos, value, ty) = checked.pop().unwrap();
            return match (name, &ty) {
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
                Type::Int | Type::Float | Type::Bool | Type::Ptr | Type::Str | Type::Union(_)
            ) {
                return self.fail(
                    arg_pos,
                    format!("cannot convert a value of type {} to word", ty.name()),
                );
            }
            return Ok((value, Type::Word));
        }
        let (_, params, ret) = INTRINSICS.iter().find(|i| i.0 == name).unwrap();
        self.arity(pos, name, params.len(), checked.len())?;
        for ((arg_pos, _, ty), param) in checked.iter().zip(params.iter()) {
            self.expect(*arg_pos, param, ty)?;
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
            // Addresses are not ints, so their arithmetic is not checked.
            "__offset" => Value::Binary("add", next(), next()),
            // Reinterpretations change only the static type.
            _ => *next(),
        };
        Ok((value, ret.clone()))
    }

    fn isinstance(
        &mut self,
        pos: Pos,
        args: &[Expr],
        state: &State,
    ) -> Result<(Value, Type), Diag> {
        self.arity(pos, "isinstance", 2, args.len())?;
        let (value, ty) = self.expr(&args[0], state)?;
        let Some((class_name, member)) = isinstance_type(&args[1], &ty) else {
            let found = match &args[1].kind {
                ExprKind::Name(name) => {
                    return self.fail(args[1].pos, format!("unknown type '{name}'"));
                }
                ExprKind::None => "'None'",
                ExprKind::Bool(true) => "'True'",
                ExprKind::Bool(false) => "'False'",
                ExprKind::Int(_) => "integer",
                ExprKind::Float(_) => "float",
                ExprKind::Str(_) => "string",
                _ => "an expression",
            };
            return self.fail(args[1].pos, format!("expected a class name, found {found}"));
        };
        if member.is_none() {
            return self.fail(
                args[1].pos,
                format!("type {} has no member {class_name}", ty.name()),
            );
        }
        if !ty.is_union() {
            return Ok((
                Value::Seq(Box::new(value), Box::new(Value::Const(1))),
                Type::Bool,
            ));
        }
        let descriptor = Value::Global(format!("W.{class_name}.type"));
        Ok((
            core_call("is_instance", vec![value, descriptor], true),
            Type::Bool,
        ))
    }
    /// The arguments, each display given its parameter's type.
    fn args(
        &mut self,
        args: &[Expr],
        state: &State,
        params: &[Type],
    ) -> Result<Vec<(Pos, Value, Type)>, Diag> {
        let mut checked = Vec::new();
        for (i, arg) in args.iter().enumerate() {
            let (value, ty) = self.expr_expect(arg, state, params.get(i))?;
            checked.push((arg.pos, value, ty));
        }
        Ok(checked)
    }

    /// A call of the method `name` of `object`.
    fn method(
        &mut self,
        object: &Expr,
        name_pos: Pos,
        name: &str,
        args: &[Expr],
        state: &State,
    ) -> Result<(Value, Type), Diag> {
        let (object_ir, object_ty) = self.expr(object, state)?;
        let display = format!("{}.{name}", object_ty.name());
        if let Type::Dict(key, value) = &object_ty {
            match name {
                "get" => {
                    let call = DictCall {
                        dict: object_ir,
                        key,
                        value,
                        pos: name_pos,
                        display: &display,
                    };
                    return self.dict_get(call, args, state);
                }
                "keys" | "values" | "items" => {
                    return self.fail(
                        name_pos,
                        format!("'{display}' can only be the source of a for loop"),
                    );
                }
                _ => {}
            }
        }
        let Some((function, params, defaults, ret)) = method_signature(&object_ty, name) else {
            return self.fail(
                name_pos,
                format!("type {} has no method '{name}'", object_ty.name()),
            );
        };
        let required = params.len() - defaults.len();
        if defaults.is_empty() {
            self.arity(name_pos, &display, params.len(), args.len())?;
        } else if args.len() < required || args.len() > params.len() {
            return self.fail(
                name_pos,
                format!(
                    "'{display}' expects {required} to {}, received {}",
                    count(params.len()),
                    args.len()
                ),
            );
        }
        let mut call_args = vec![object_ir];
        for (i, param) in params.iter().enumerate() {
            let Some(arg) = args.get(i) else {
                call_args.push(Value::Const(defaults[i - required]));
                continue;
            };
            let (value, ty) = self.expr_expect(arg, state, Some(param))?;
            // extend takes only a list of the same type in L0, since core
            // copies its slots as they are.
            let value = if function == "list_extend" {
                self.expect(arg.pos, param, &ty)?;
                value
            } else {
                self.coerce(arg.pos, value, &ty, param)?
            };
            call_args.push(value);
        }
        Ok((core_call(function, call_args, ret != Type::None), ret))
    }

    /// `d.get(key)` or `d.get(key, default)` (spec §7). The result is the
    /// value type when the default is assignable to it, and otherwise the
    /// value type or None.
    fn dict_get(
        &mut self,
        call: DictCall,
        args: &[Expr],
        state: &State,
    ) -> Result<(Value, Type), Diag> {
        let DictCall {
            dict,
            key,
            value,
            pos,
            display,
        } = call;
        if args.is_empty() || args.len() > 2 {
            return self.fail(
                pos,
                format!(
                    "'{display}' expects 1 to 2 arguments, received {}",
                    args.len()
                ),
            );
        }
        let (key_ir, key_ty) = self.expr(&args[0], state)?;
        let key_ir = self.coerce(args[0].pos, key_ir, &key_ty, key)?;
        let (default, default_ty) = match args.get(1) {
            Some(arg) => self.expr_expect(arg, state, Some(value))?,
            None => (Value::Const(0), Type::None),
        };
        let result = if default_ty.assignable_to(value) {
            value.clone()
        } else if default_ty == Type::None {
            Type::union([value.clone(), Type::None])
        } else {
            let allowed = Type::union([value.clone(), Type::None]);
            return self.fail(
                args[1].pos,
                format!(
                    "expected {}, received {}",
                    allowed.name(),
                    default_ty.name()
                ),
            );
        };
        let get = Value::DictGet {
            dict: Box::new(dict),
            key: Box::new(key_ir),
            default: Box::new(widen(default, &default_ty, &result)),
            present: Box::new(widen(Value::Item(0), value, &result)),
        };
        Ok((get, result))
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
        let call = match &sig.target {
            Target::Willow(symbol) => {
                let mut args = Vec::new();
                for ((arg_pos, value, ty), param) in checked.into_iter().zip(&sig.params) {
                    args.push(("l", self.coerce(arg_pos, value, &ty, param)?));
                }
                Call {
                    symbol: symbol.clone(),
                    args,
                    variadic_at: None,
                    ret: if sig.ret == Type::None {
                        None
                    } else {
                        Some("l")
                    },
                }
            }
            Target::Extern {
                cparams,
                variadic,
                cret,
            } => {
                for ((arg_pos, _, ty), param) in checked.iter().zip(&sig.params) {
                    self.expect(*arg_pos, param, ty)?;
                }
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
        Ok((Value::Call(call), sig.ret.clone()))
    }
}
