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
            block: String::new(),
            loops: Vec::new(),
            item: String::new(),
        };
        emitter.function(func);
    }
    writeln!(out, "export function w $main(w %argc, l %argv) {{").unwrap();
    writeln!(out, "@start").unwrap();
    writeln!(out, "\tcall $GC_init()").unwrap();
    writeln!(out, "\t%argc.l =l extsw %argc").unwrap();
    writeln!(out, "\tstorel %argc.l, $W.argc").unwrap();
    writeln!(out, "\tstorel %argv, $W.argv").unwrap();
    writeln!(out, "\tcall $W.core.init()").unwrap();
    writeln!(out, "\tcall ${}()", program.main).unwrap();
    writeln!(out, "\tret 0").unwrap();
    writeln!(out, "}}").unwrap();
    // The entry saves the arguments for sys.args (core/API.md).
    writeln!(out, "data $W.argc = {{ l 0 }}").unwrap();
    writeln!(out, "data $W.argv = {{ l 0 }}").unwrap();
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
    /// The label of the current block, for `phi`.
    block: String,
    /// The `continue` and `break` targets of the enclosing loops.
    loops: Vec<(String, String)>,
    /// The operand holding the current item of a `for` loop while its
    /// variable is stored.
    item: String,
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
        self.block = label.to_string();
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

    /// Stores `item` in the loop variable and emits the body of a loop
    /// whose `continue` goes to `next` and `break` to `end`.
    fn loop_body(&mut self, item: &str, store: &Op, body: &[Op], next: &str, end: &str) {
        self.item = item.to_string();
        self.op(store);
        self.loops.push((next.to_string(), end.to_string()));
        self.ops(body);
        self.loops.pop();
    }

    fn ops(&mut self, ops: &[Op]) {
        for op in ops {
            // Ops after a jump or return cannot run. The checker rejects
            // them, except after a kept `__os` arm that transfers control,
            // where they are the other platform's code and must not be
            // emitted.
            if self.ended {
                break;
            }
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
                self.loops.push((test.clone(), end.clone()));
                self.ops(body);
                self.loops.pop();
                self.jump(format!("jmp {test}"));
                self.label(&end);
            }
            Op::SetItem {
                function,
                object,
                index,
                value,
            } => {
                let v = self.value(value);
                let o = self.value(object);
                let i = self.value(index);
                self.line(format!("call ${function}(l {o}, l {i}, l {v})"));
            }
            Op::ForList { list, store, body } => {
                let xs = self.value(list);
                let index = self.temp();
                self.line(format!("{index} =l copy 0"));
                let (test, body_label, end) =
                    (self.new_label(), self.new_label(), self.new_label());
                // The length is read at every step, so elements appended
                // during the loop are visited (spec §8). The index advances
                // before the body, so `continue` goes straight to the test.
                self.label(&test);
                let [length, more, item] = std::array::from_fn(|_| self.temp());
                self.line(format!("{length} =l call $W.core.list_len(l {xs})"));
                self.line(format!("{more} =l csltl {index}, {length}"));
                self.jump(format!("jnz {more}, {body_label}, {end}"));
                self.label(&body_label);
                self.line(format!(
                    "{item} =l call $W.core.list_get(l {xs}, l {index})"
                ));
                self.line(format!("{index} =l add {index}, 1"));
                self.loop_body(&item, store, body, &test, &end);
                self.jump(format!("jmp {test}"));
                self.label(&end);
            }
            Op::ForRange {
                start,
                stop,
                step,
                fail,
                store,
                body,
            } => {
                let current = self.temp();
                let first = self.value(start);
                let last = self.value(stop);
                let by = self.value(step);
                let zero = self.temp();
                self.line(format!("{zero} =l ceql {by}, 0"));
                self.guard(&zero, fail);
                self.line(format!("{current} =l copy {first}"));
                let [test, body_label, next, advance, end] =
                    std::array::from_fn(|_| self.new_label());
                self.label(&test);
                let [up, below, above, down, more, item] = std::array::from_fn(|_| self.temp());
                self.line(format!("{up} =l csgtl {by}, 0"));
                self.line(format!("{below} =l csltl {current}, {last}"));
                self.line(format!("{above} =l csgtl {current}, {last}"));
                self.line(format!("{below} =l and {up}, {below}"));
                self.line(format!("{down} =l ceql {up}, 0"));
                self.line(format!("{above} =l and {down}, {above}"));
                self.line(format!("{more} =l or {below}, {above}"));
                self.jump(format!("jnz {more}, {body_label}, {end}"));
                self.label(&body_label);
                self.line(format!("{item} =l copy {current}"));
                self.loop_body(&item, store, body, &next, &end);
                // A step that overflows passes the stop, so it ends the loop.
                self.label(&next);
                let [stepped, a, b] = std::array::from_fn(|_| self.temp());
                self.line(format!("{stepped} =l add {current}, {by}"));
                self.line(format!("{a} =l xor {current}, {stepped}"));
                self.line(format!("{b} =l xor {by}, {stepped}"));
                self.line(format!("{a} =l and {a}, {b}"));
                self.line(format!("{a} =l csltl {a}, 0"));
                self.jump(format!("jnz {a}, {end}, {advance}"));
                self.label(&advance);
                self.line(format!("{current} =l copy {stepped}"));
                self.jump(format!("jmp {test}"));
                self.label(&end);
            }
            Op::Break => {
                let target = self.loops.last().unwrap().1.clone();
                self.jump(format!("jmp {target}"));
            }
            Op::Continue => {
                let target = self.loops.last().unwrap().0.clone();
                self.jump(format!("jmp {target}"));
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
            Value::IntToFloat(value) => {
                let v = self.value(value);
                let d = self.temp();
                self.line(format!("{d} =d sltof {v}"));
                self.float_bits(&d)
            }
            Value::FloatBinary(instr, left, right) => {
                let l = self.float(left);
                let r = self.float(right);
                let d = self.temp();
                self.line(format!("{d} =d {instr} {l}, {r}"));
                self.float_bits(&d)
            }
            Value::FloatCompare(instr, left, right) => {
                let l = self.float(left);
                let r = self.float(right);
                let t = self.temp();
                self.line(format!("{t} =l {instr} {l}, {r}"));
                t
            }
            Value::FloatNeg(value) => {
                let v = self.float(value);
                let d = self.temp();
                self.line(format!("{d} =d neg {v}"));
                self.float_bits(&d)
            }
            Value::Logic { and, left, right } => {
                // The left operand decides when it is false for `and` and
                // true for `or`, and is then the result.
                let l = self.value(left);
                let left_block = self.block.clone();
                let (rhs, end) = (self.new_label(), self.new_label());
                if *and {
                    self.jump(format!("jnz {l}, {rhs}, {end}"));
                } else {
                    self.jump(format!("jnz {l}, {end}, {rhs}"));
                }
                self.label(&rhs);
                let r = self.value(right);
                let right_block = self.block.clone();
                self.jump(format!("jmp {end}"));
                self.label(&end);
                let t = self.temp();
                self.line(format!("{t} =l phi {left_block} {l}, {right_block} {r}"));
                t
            }
            Value::CheckedInt {
                instr,
                left,
                right,
                fail,
            } => {
                let l = self.value(left);
                let r = self.value(right);
                let t = self.temp();
                self.line(format!("{t} =l {instr} {l}, {r}"));
                let overflow = self.overflow(instr, &l, &r, &t);
                self.guard(&overflow, fail);
                t
            }
            Value::FloorDivide {
                modulo,
                left,
                right,
                fail,
            } => {
                let l = self.value(left);
                let r = self.value(right);
                let zero = self.temp();
                self.line(format!("{zero} =l ceql {r}, 0"));
                self.guard(&zero, fail);
                // QBE truncates; a nonzero remainder whose sign differs from
                // the divisor's moves the quotient down one and the remainder
                // up by the divisor. Checked arithmetic never produces -2^63,
                // so dividing by -1 cannot overflow, and cannot trap on amd64.
                let [q, m, signs, differ, nonzero, adjust] = [(); 6].map(|_| self.temp());
                self.line(format!("{q} =l div {l}, {r}"));
                self.line(format!("{m} =l rem {l}, {r}"));
                self.line(format!("{signs} =l xor {m}, {r}"));
                self.line(format!("{differ} =l csltl {signs}, 0"));
                self.line(format!("{nonzero} =l cnel {m}, 0"));
                self.line(format!("{adjust} =l and {differ}, {nonzero}"));
                let t = self.temp();
                if *modulo {
                    let step = self.temp();
                    self.line(format!("{step} =l mul {r}, {adjust}"));
                    self.line(format!("{t} =l add {m}, {step}"));
                } else {
                    self.line(format!("{t} =l sub {q}, {adjust}"));
                }
                t
            }
            Value::Divide {
                ints,
                left,
                right,
                fail,
            } => {
                let (l, r) = if *ints {
                    let l = self.value(left);
                    let r = self.value(right);
                    let zero = self.temp();
                    self.line(format!("{zero} =l ceql {r}, 0"));
                    self.guard(&zero, fail);
                    let d = self.int_quotient(&l, &r);
                    return self.float_bits(&d);
                } else {
                    let l = self.float(left);
                    let r = self.float(right);
                    // Equal to zero includes -0.0.
                    let zero = self.temp();
                    self.line(format!("{zero} =l ceqd {r}, d_0"));
                    self.guard(&zero, fail);
                    (l, r)
                };
                let d = self.temp();
                self.line(format!("{d} =d div {l}, {r}"));
                self.float_bits(&d)
            }
            Value::Item => self.item.clone(),
            Value::ListDisplay(items) => {
                let list = self.temp();
                let count = items.len();
                self.line(format!("{list} =l call $W.core.list_new(l {count})"));
                for item in items {
                    let v = self.value(item);
                    self.line(format!("call $W.core.list_append(l {list}, l {v})"));
                }
                list
            }
            Value::In {
                function,
                item,
                container,
                extra,
            } => {
                let i = self.value(item);
                let c = self.value(container);
                let mut args = vec![format!("l {c}"), format!("l {i}")];
                for value in extra {
                    args.push(format!("l {}", self.value(value)));
                }
                let t = self.temp();
                self.line(format!("{t} =l call ${function}({})", args.join(", ")));
                t
            }
            Value::Seq(first, second) => {
                self.value(first);
                self.value(second)
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

    /// The correctly rounded quotient of the nonzero-divisor ints `l` and `r`
    /// as a `d` operand. Converting each operand to a float first would round
    /// twice once either exceeds 2^53, so those quotients are found by long
    /// division to 56 bits, with the last bit set when any remainder is
    /// left, which makes the one conversion round correctly. QBE accepts the
    /// temporaries assigned more than once here.
    fn int_quotient(&mut self, l: &str, r: &str) -> String {
        const EXACT: &str = "9007199254740992"; // 2^53
        let labels: [String; 14] = std::array::from_fn(|_| self.new_label());
        let [
            fast,
            slow,
            shr_test,
            shr,
            shl_test,
            shl,
            round,
            up_test,
            up,
            down_test,
            down,
            sign,
            negate,
            done,
        ] = labels;
        let [
            result,
            abs_l,
            abs_r,
            cond,
            q,
            rem,
            e,
            lost,
            bit,
            t,
            d,
            divisor,
        ] = std::array::from_fn(|_| self.temp());
        // Magnitudes are exact: the int range is symmetric.
        for (abs, x) in [(&abs_l, l), (&abs_r, r)] {
            self.line(format!("{t} =l sar {x}, 63"));
            self.line(format!("{abs} =l xor {x}, {t}"));
            self.line(format!("{abs} =l sub {abs}, {t}"));
        }
        self.line(format!("{cond} =l culel {abs_l}, {EXACT}"));
        self.line(format!("{t} =l culel {abs_r}, {EXACT}"));
        self.line(format!("{cond} =l and {cond}, {t}"));
        self.line(format!("{t} =l ceql {l}, 0"));
        self.line(format!("{cond} =l or {cond}, {t}"));
        self.jump(format!("jnz {cond}, {fast}, {slow}"));
        self.label(&fast);
        self.line(format!("{d} =d sltof {l}"));
        self.line(format!("{divisor} =d sltof {r}"));
        self.line(format!("{result} =d div {d}, {divisor}"));
        self.jump(format!("jmp {done}"));
        self.label(&slow);
        self.line(format!("{q} =l udiv {abs_l}, {abs_r}"));
        self.line(format!("{rem} =l urem {abs_l}, {abs_r}"));
        self.line(format!("{e} =l copy 0"));
        self.line(format!("{lost} =l copy 0"));
        // A quotient of 2^56 or more drops its low bits into `lost`.
        self.label(&shr_test);
        self.line(format!("{cond} =l cugel {q}, 72057594037927936"));
        self.jump(format!("jnz {cond}, {shr}, {shl_test}"));
        self.label(&shr);
        self.line(format!("{bit} =l and {q}, 1"));
        self.line(format!("{lost} =l or {lost}, {bit}"));
        self.line(format!("{q} =l shr {q}, 1"));
        self.line(format!("{e} =l add {e}, 1"));
        self.jump(format!("jmp {shr_test}"));
        // A quotient below 2^55 takes the next bit of the division. Doubling
        // the remainder may pass 2^63, but subtracting the divisor brings it
        // back, and the arithmetic is modulo 2^64.
        self.label(&shl_test);
        self.line(format!("{cond} =l cultl {q}, 36028797018963968"));
        self.jump(format!("jnz {cond}, {shl}, {round}"));
        self.label(&shl);
        self.line(format!("{t} =l sub {abs_r}, {rem}"));
        self.line(format!("{bit} =l cugel {rem}, {t}"));
        self.line(format!("{q} =l shl {q}, 1"));
        self.line(format!("{q} =l or {q}, {bit}"));
        self.line(format!("{rem} =l shl {rem}, 1"));
        self.line(format!("{t} =l mul {bit}, {abs_r}"));
        self.line(format!("{rem} =l sub {rem}, {t}"));
        self.line(format!("{e} =l sub {e}, 1"));
        self.jump(format!("jmp {shl_test}"));
        self.label(&round);
        self.line(format!("{t} =l cnel {rem}, 0"));
        self.line(format!("{lost} =l or {lost}, {t}"));
        self.line(format!("{q} =l or {q}, {lost}"));
        self.line(format!("{d} =d sltof {q}"));
        // Scaling by two is exact: the quotient's magnitude is between 2^-63
        // and 2^63.
        self.label(&up_test);
        self.line(format!("{cond} =l csgtl {e}, 0"));
        self.jump(format!("jnz {cond}, {up}, {down_test}"));
        self.label(&up);
        self.line(format!("{d} =d mul {d}, d_2"));
        self.line(format!("{e} =l sub {e}, 1"));
        self.jump(format!("jmp {up_test}"));
        self.label(&down_test);
        self.line(format!("{cond} =l csltl {e}, 0"));
        self.jump(format!("jnz {cond}, {down}, {sign}"));
        self.label(&down);
        self.line(format!("{d} =d mul {d}, d_0.5"));
        self.line(format!("{e} =l add {e}, 1"));
        self.jump(format!("jmp {down_test}"));
        self.label(&sign);
        self.line(format!("{t} =l xor {l}, {r}"));
        self.line(format!("{cond} =l csltl {t}, 0"));
        self.line(format!("{result} =d copy {d}"));
        self.jump(format!("jnz {cond}, {negate}, {done}"));
        self.label(&negate);
        self.line(format!("{result} =d neg {d}"));
        self.label(&done);
        result
    }

    /// A temporary that is 1 when `t`, the wrapped result of `l instr r`, is
    /// not the exact result or is -2^63, which the symmetric int range treats
    /// as overflow too.
    fn overflow(&mut self, instr: &str, l: &str, r: &str, t: &str) -> String {
        let [a, b, wrapped, min] = std::array::from_fn(|_| self.temp());
        match instr {
            // The sum wrapped when its sign differs from both operands'; the
            // difference, when the operands' signs differ and its sign
            // differs from the left operand's.
            "add" | "sub" => {
                if instr == "add" {
                    self.line(format!("{a} =l xor {l}, {t}"));
                    self.line(format!("{b} =l xor {r}, {t}"));
                } else {
                    self.line(format!("{a} =l xor {l}, {r}"));
                    self.line(format!("{b} =l xor {l}, {t}"));
                }
                self.line(format!("{a} =l and {a}, {b}"));
                self.line(format!("{wrapped} =l csltl {a}, 0"));
            }
            // The product wrapped when dividing it by a nonzero left operand
            // does not give the right one back. The divisor becomes 1 when
            // that operand is 0 or the product is -2^63, so the division can
            // neither fail nor trap.
            _ => {
                let [zero, skip, divisor] = std::array::from_fn(|_| self.temp());
                self.line(format!("{zero} =l ceql {l}, 0"));
                self.line(format!("{min} =l ceql {t}, -9223372036854775808"));
                self.line(format!("{skip} =l or {zero}, {min}"));
                self.line(format!("{a} =l sub 0, {skip}"));
                self.line(format!("{b} =l xor {l}, 1"));
                self.line(format!("{b} =l and {b}, {a}"));
                self.line(format!("{divisor} =l xor {l}, {b}"));
                self.line(format!("{a} =l div {t}, {divisor}"));
                self.line(format!("{a} =l cnel {a}, {r}"));
                self.line(format!("{b} =l ceql {zero}, 0"));
                self.line(format!("{wrapped} =l and {a}, {b}"));
            }
        }
        self.line(format!("{min} =l ceql {t}, -9223372036854775808"));
        self.line(format!("{wrapped} =l or {wrapped}, {min}"));
        wrapped
    }

    /// Computes a float value and returns it as a QBE `d` operand.
    fn float(&mut self, value: &Value) -> String {
        let v = self.value(value);
        let d = self.temp();
        self.line(format!("{d} =d cast {v}"));
        d
    }

    /// The bits of the `d` operand `d` in an `l` temporary, as slots hold them.
    fn float_bits(&mut self, d: &str) -> String {
        let t = self.temp();
        self.line(format!("{t} =l cast {d}"));
        t
    }

    /// Runs `fail` when `cond` is nonzero. In L0 a failure does not return.
    fn guard(&mut self, cond: &str, fail: &Value) {
        let (failed, ok) = (self.new_label(), self.new_label());
        self.jump(format!("jnz {cond}, {failed}, {ok}"));
        self.label(&failed);
        self.value(fail);
        self.jump("hlt".into());
        self.label(&ok);
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
