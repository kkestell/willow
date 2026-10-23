//! Writes the checked program as QBE intermediate language.

use std::fmt::Write;

use crate::check::{Call, Function, Op, Program, Value};

pub fn emit(program: &Program) -> String {
    let mut out = String::new();
    for func in &program.funcs {
        let mut emitter = Emitter {
            out: &mut out,
            temps: 0,
            labels: 0,
            ended: false,
        };
        emitter.function(func);
    }
    writeln!(out, "export function w $main(w %argc, l %argv) {{").unwrap();
    writeln!(out, "@start").unwrap();
    writeln!(out, "\tcall $GC_init()").unwrap();
    writeln!(out, "\tcall $W.core.init()").unwrap();
    writeln!(out, "\tcall ${}()", program.main).unwrap();
    writeln!(out, "\tret 0").unwrap();
    writeln!(out, "}}").unwrap();
    // Every heap object's header points at a descriptor holding its type's name.
    for (symbol, name) in &program.descriptors {
        writeln!(out, "data ${symbol} = {{ l $W.str.{name} }}").unwrap();
    }
    for (n, text) in program.strings.iter().enumerate() {
        writeln!(
            out,
            "data $W.str.{n} = {{ l $W.str.type, l {}, {}b 0 }}",
            text.len(),
            bytes(text)
        )
        .unwrap();
    }
    out
}

/// The bytes of `text` as QBE data items, each followed by a comma and a space.
/// Only printable ASCII other than quotes and backslashes goes inside quotes,
/// because QBE passes quoted text to the assembler, which reads escapes in it.
fn bytes(text: &str) -> String {
    let mut out = String::new();
    let mut quoted = false;
    for &b in text.as_bytes() {
        let plain = (0x20..0x7f).contains(&b) && b != b'"' && b != b'\\';
        if plain && !quoted {
            out.push_str("b \"");
            quoted = true;
        } else if !plain && quoted {
            out.push_str("\", ");
            quoted = false;
        }
        if plain {
            out.push(b as char);
        } else {
            write!(out, "b {b}, ").unwrap();
        }
    }
    if quoted {
        out.push_str("\", ");
    }
    out
}

struct Emitter<'a> {
    out: &'a mut String,
    temps: u32,
    labels: u32,
    /// Whether the current block has ended with a jump or return.
    ended: bool,
}

impl Emitter<'_> {
    fn line(&mut self, text: String) {
        writeln!(self.out, "\t{text}").unwrap();
    }

    fn temp(&mut self) -> String {
        self.temps += 1;
        format!("%.{}", self.temps)
    }

    fn new_label(&mut self) -> String {
        self.labels += 1;
        format!("@L.{}", self.labels)
    }

    fn label(&mut self, label: &str) {
        writeln!(self.out, "{label}").unwrap();
        self.ended = false;
    }

    /// Writes a jump or return, unless the block has already ended; a
    /// statement after a return is rejected by the checker, but the jumps
    /// that close an `if` or `while` body can still follow one.
    fn jump(&mut self, text: String) {
        if !self.ended {
            self.line(text);
            self.ended = true;
        }
    }

    fn function(&mut self, func: &Function) {
        let params: Vec<String> = func.params.iter().map(|p| format!("l %p.{p}")).collect();
        let ret = if func.returns { "l " } else { "" };
        writeln!(
            self.out,
            "function {ret}${}({}) {{",
            func.symbol,
            params.join(", ")
        )
        .unwrap();
        self.label("@start");
        // Locals live in stack slots; QBE promotes them to registers.
        for p in &func.params {
            self.line(format!("%v.{p} =l alloc8 8"));
            self.line(format!("storel %p.{p}, %v.{p}"));
        }
        for local in &func.locals {
            self.line(format!("%v.{local} =l alloc8 8"));
        }
        self.ops(&func.body);
        // The checker proves a value-returning function never reaches its end.
        self.jump(if func.returns { "hlt" } else { "ret" }.into());
        writeln!(self.out, "}}").unwrap();
    }

    fn ops(&mut self, ops: &[Op]) {
        for op in ops {
            self.op(op);
        }
    }

    fn op(&mut self, op: &Op) {
        match op {
            Op::Assign(name, value) => {
                let v = self.value(value);
                self.line(format!("storel {v}, %v.{name}"));
            }
            Op::Eval(value) => {
                self.value(value);
            }
            Op::If(cond, then, otherwise) => {
                let c = self.value(cond);
                let (then_label, else_label, end) =
                    (self.new_label(), self.new_label(), self.new_label());
                self.jump(format!("jnz {c}, {then_label}, {else_label}"));
                self.label(&then_label);
                self.ops(then);
                self.jump(format!("jmp {end}"));
                self.label(&else_label);
                self.ops(otherwise);
                self.label(&end);
            }
            Op::While(cond, body) => {
                let (test, body_label, end) =
                    (self.new_label(), self.new_label(), self.new_label());
                self.label(&test);
                let c = self.value(cond);
                self.jump(format!("jnz {c}, {body_label}, {end}"));
                self.label(&body_label);
                self.ops(body);
                self.jump(format!("jmp {test}"));
                self.label(&end);
            }
            Op::Return(value) => {
                let text = match value {
                    Some(value) => format!("ret {}", self.value(value)),
                    None => "ret".into(),
                };
                self.jump(text);
            }
        }
    }

    /// Writes the instructions that compute `value` and returns its operand.
    fn value(&mut self, value: &Value) -> String {
        match value {
            Value::Const(n) => n.to_string(),
            Value::Global(symbol) => format!("${symbol}"),
            Value::Local(name) => {
                let t = self.temp();
                self.line(format!("{t} =l loadl %v.{name}"));
                t
            }
            Value::Call(call) => self.call(call),
            Value::Binary(instr, left, right) => {
                let l = self.value(left);
                let r = self.value(right);
                let t = self.temp();
                self.line(format!("{t} =l {instr} {l}, {r}"));
                t
            }
            Value::FloatToInt(value) => {
                let v = self.value(value);
                let d = self.temp();
                self.line(format!("{d} =d cast {v}"));
                let t = self.temp();
                self.line(format!("{t} =l dtosi {d}"));
                t
            }
            Value::Load(instr, ptr, offset) => {
                let address = self.address(ptr, offset);
                let t = self.temp();
                self.line(format!("{t} =l {instr} {address}"));
                t
            }
            Value::Store(instr, ptr, offset, stored) => {
                let address = self.address(ptr, offset);
                let v = self.value(stored);
                self.line(format!("{instr} {v}, {address}"));
                "0".into()
            }
        }
    }

    fn address(&mut self, ptr: &Value, offset: &Value) -> String {
        let p = self.value(ptr);
        let o = self.value(offset);
        let t = self.temp();
        self.line(format!("{t} =l add {p}, {o}"));
        t
    }

    fn call(&mut self, call: &Call) -> String {
        let mut args = Vec::new();
        for (i, (ty, arg)) in call.args.iter().enumerate() {
            if call.variadic_at == Some(i) {
                args.push("...".to_string());
            }
            let mut v = self.value(arg);
            if *ty == "d" {
                // Floats travel as their bits in `l` slots.
                let d = self.temp();
                self.line(format!("{d} =d cast {v}"));
                v = d;
            }
            args.push(format!("{ty} {v}"));
        }
        if call.variadic_at == Some(call.args.len()) {
            args.push("...".to_string());
        }
        let text = format!("call ${}({})", call.symbol, args.join(", "));
        match call.ret {
            None => {
                self.line(text);
                "0".into()
            }
            Some(ty @ ("w" | "d")) => {
                // A C int result is sign-extended to fill its slot, and a
                // float result becomes its bits.
                let r = self.temp();
                self.line(format!("{r} ={ty} {text}"));
                let t = self.temp();
                let convert = if ty == "w" { "extsw" } else { "cast" };
                self.line(format!("{t} =l {convert} {r}"));
                t
            }
            Some(ty) => {
                let t = self.temp();
                self.line(format!("{t} ={ty} {text}"));
                t
            }
        }
    }
}
