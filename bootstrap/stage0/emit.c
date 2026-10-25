/* Writes the checked program as QBE intermediate language. */
#include "willow0.h"

#include <assert.h>
#include <inttypes.h>
#include <string.h>

#define S(s) (int)(s).len, (s).data

typedef struct Loop {
    String next;
    String end;
} Loop;
VEC_DECL(Loop, LoopVec);

typedef struct Emitter {
    StringBuilder *out;
    uint32_t temps;
    uint32_t labels;
    bool ended;
    String block;
    LoopVec loops;
    String item[2];
} Emitter;

static void function(Emitter *self, const Function *func);
static void ops(Emitter *self, const OpVec *operations);
static void op(Emitter *self, const Op *operation);
static String value(Emitter *self, const Value *v);
static String int_quotient(Emitter *self, String l, String r);
static String overflow(Emitter *self, const char *instr, String l, String r, String t);
static String float_value(Emitter *self, const Value *v);
static String float_bits(Emitter *self, String d);
static void guard(Emitter *self, String cond, const Value *fail);
static String address(Emitter *self, const Value *ptr, const Value *offset);
static String call(Emitter *self, const Call *callee);

static String join(const StringVec *items) {
    StringBuilder out = {0};
    for (size_t i = 0; i < items->len; i++) {
        if (i) {
            sb_append(&out, STR(", "));
        }
        sb_append(&out, items->data[i]);
    }
    return sb_finish(&out);
}

/* Each data item ends in a comma and a space. QBE passes quoted text to the
 * assembler, so quotes contain only printable ASCII without escapes. */
static String bytes(String text) {
    StringBuilder out = {0};
    bool quoted = false;
    for (size_t i = 0; i < text.len; i++) {
        unsigned char b = (unsigned char)text.data[i];
        bool plain = b >= 0x20 && b < 0x7f && b != '"' && b != '\\';
        if (plain && !quoted) {
            sb_append(&out, STR("b \""));
            quoted = true;
        } else if (!plain && quoted) {
            sb_append(&out, STR("\", "));
            quoted = false;
        }
        if (plain) {
            sb_push_byte(&out, b);
        } else {
            sb_printf(&out, "b %u, ", (unsigned)b);
        }
    }
    if (quoted) {
        sb_append(&out, STR("\", "));
    }
    return sb_finish(&out);
}

static void emit_ascii_characters(StringBuilder *out) {
    /* Each aligned string has an empty hash cache and a 32-byte stride. */
    sb_append(out, STR("data $W.ascii.characters = align 8 { "));
    for (unsigned code = 0; code < 128; code++) {
        if (code) {
            sb_append(out, STR(", "));
        }
        sb_printf(out, "l $W.str.type, l 1, l 0, b %u, b 0, z 6", code);
    }
    sb_append(out, STR(" }\n"));
}

static void emit_ascii_character(Emitter *self) {
    sb_append(self->out, STR("\t%offset =l mul %p.code, 32\n"
                             "\t%result =l add $W.ascii.characters, %offset\n"
                             "\tret %result\n"
                             "}\n"));
}

String emit(const Program *program) {
    StringBuilder out = {0};
    for (size_t i = 0; i < program->funcs.len; i++) {
        Emitter emitter = {.out = &out, .block = STR(""), .item = {STR(""), STR("")}};
        function(&emitter, &program->funcs.data[i]);
    }
    sb_append(&out, STR("export function w $main(w %argc, l %argv) {\n"
                        "@start\n"
                        "\tcall $GC_init()\n"
                        "\t%argc.l =l extsw %argc\n"
                        "\tstorel %argc.l, $W.argc\n"
                        "\tstorel %argv, $W.argv\n"
                        "\tcall $W.core.init()\n"));
    sb_printf(&out, "\tcall $%.*s()\n", S(program->main));
    sb_append(&out, STR("\tret 0\n"
                        "}\n"
                        "data $W.argc = { l 0 }\n"
                        "data $W.argv = { l 0 }\n"
                        "data $W.stdin.buffer = { z 4120 }\n"));
    for (size_t i = 0; i < program->descriptors.len; i++) {
        const Descriptor *descriptor = &program->descriptors.data[i];
        StringVec items = {0};
        for (size_t j = 0; j < descriptor->texts.len; j++) {
            vec_push(items, str_format("l $W.str.%zu", descriptor->texts.data[j]));
        }
        String joined = join(&items);
        sb_printf(&out, "data $%.*s = { %.*s }\n", S(descriptor->symbol), S(joined));
    }
    for (size_t n = 0; n < program->strings.len; n++) {
        String text = program->strings.data[n];
        String data = bytes(text);
        sb_printf(&out, "data $W.str.%zu = { l $W.str.type, l %zu, l 0, %.*sb 0 }\n",
                  n, text.len, S(data));
    }
    emit_ascii_characters(&out);
    return sb_finish(&out);
}

static void line(Emitter *self, String text) {
    sb_push_byte(self->out, '\t');
    sb_append(self->out, text);
    sb_push_byte(self->out, '\n');
}

static String temp(Emitter *self) {
    self->temps++;
    return str_format("%%.%" PRIu32, self->temps);
}

static String new_label(Emitter *self) {
    self->labels++;
    return str_format("@L.%" PRIu32, self->labels);
}

static void label(Emitter *self, String name) {
    sb_append(self->out, name);
    sb_push_byte(self->out, '\n');
    self->ended = false;
    self->block = name;
}

static void jump(Emitter *self, String text) {
    if (!self->ended) {
        line(self, text);
        self->ended = true;
    }
}

static void function(Emitter *self, const Function *func) {
    StringVec params = {0};
    for (size_t i = 0; i < func->params.len; i++) {
        vec_push(params, str_format("l %%p.%.*s", S(func->params.data[i])));
    }
    String joined = join(&params);
    const char *ret = func->returns ? "l " : "";
    sb_printf(self->out, "function %s$%.*s(%.*s) {\n", ret, S(func->symbol), S(joined));
    label(self, STR("@start"));
    if (str_equal(func->symbol, STR("W.core.ascii_character"))) {
        emit_ascii_character(self);
        return;
    }
    if (str_equal(func->symbol, STR("W.core.stdin_buffer"))) {
        line(self, STR("ret $W.stdin.buffer"));
        sb_append(self->out, STR("}\n"));
        return;
    }
    /* Locals live in stack slots; QBE promotes them to registers. */
    for (size_t i = 0; i < func->params.len; i++) {
        String p = func->params.data[i];
        line(self, str_format("%%v.%.*s =l alloc8 8", S(p)));
        line(self, str_format("storel %%p.%.*s, %%v.%.*s", S(p), S(p)));
    }
    for (size_t i = 0; i < func->locals.len; i++) {
        line(self, str_format("%%v.%.*s =l alloc8 8", S(func->locals.data[i])));
    }
    ops(self, &func->body);
    jump(self, func->returns ? STR("hlt") : STR("ret"));
    sb_append(self->out, STR("}\n"));
}

static void loop_body(Emitter *self, String first, String second, const OpVec *stores,
                      const OpVec *body, String next, String end) {
    self->item[0] = first;
    self->item[1] = second;
    ops(self, stores);
    vec_push(self->loops, ((Loop){next, end}));
    ops(self, body);
    self->loops.len--;
}

static void ops(Emitter *self, const OpVec *operations) {
    for (size_t i = 0; i < operations->len; i++) {
        /* A kept __os arm can transfer control before the other platform's
         * code, which must not be emitted. */
        if (self->ended) {
            break;
        }
        op(self, &operations->data[i]);
    }
}

static void op(Emitter *self, const Op *operation) {
    switch (operation->tag) {
    case OP_Assign: {
        String v = value(self, &operation->as.Assign.value);
        line(self, str_format("storel %.*s, %%v.%.*s", S(v), S(operation->as.Assign.target)));
        break;
    }
    case OP_Eval:
        value(self, &operation->as.Eval);
        break;
    case OP_If: {
        String c = value(self, &operation->as.If.cond);
        String then_label = new_label(self);
        String else_label = new_label(self);
        String end = new_label(self);
        jump(self, str_format("jnz %.*s, %.*s, %.*s", S(c), S(then_label), S(else_label)));
        label(self, then_label);
        ops(self, &operation->as.If.then);
        jump(self, str_format("jmp %.*s", S(end)));
        label(self, else_label);
        ops(self, &operation->as.If.otherwise);
        label(self, end);
        break;
    }
    case OP_While: {
        String test = new_label(self);
        String body_label = new_label(self);
        String end = new_label(self);
        label(self, test);
        String c = value(self, &operation->as.While.cond);
        jump(self, str_format("jnz %.*s, %.*s, %.*s", S(c), S(body_label), S(end)));
        label(self, body_label);
        vec_push(self->loops, ((Loop){test, end}));
        ops(self, &operation->as.While.body);
        self->loops.len--;
        jump(self, str_format("jmp %.*s", S(test)));
        label(self, end);
        break;
    }
    case OP_SetField: {
        String v = value(self, &operation->as.SetField.value);
        String o = value(self, &operation->as.SetField.object);
        String addr = temp(self);
        line(self, str_format("%.*s =l add %.*s, %" PRId64, S(addr), S(o), operation->as.SetField.offset));
        line(self, str_format("storel %.*s, %.*s", S(v), S(addr)));
        break;
    }
    case OP_SetItem: {
        String v = value(self, &operation->as.SetItem.value);
        String o = value(self, &operation->as.SetItem.object);
        String i = value(self, &operation->as.SetItem.index);
        line(self, str_format("call $%s(l %.*s, l %.*s, l %.*s)",
                              operation->as.SetItem.function, S(o), S(i), S(v)));
        break;
    }
    case OP_ForList: {
        String xs = value(self, &operation->as.ForList.list);
        String index = temp(self);
        line(self, str_format("%.*s =l copy 0", S(index)));
        String test = new_label(self);
        String body_label = new_label(self);
        String end = new_label(self);
        /* Read length each step to visit appended elements. Advance before
         * the body so continue goes straight to the test. */
        label(self, test);
        String length = temp(self);
        String more = temp(self);
        String item = temp(self);
        line(self, str_format("%.*s =l call $W.core.list_len(l %.*s)", S(length), S(xs)));
        line(self, str_format("%.*s =l csltl %.*s, %.*s", S(more), S(index), S(length)));
        jump(self, str_format("jnz %.*s, %.*s, %.*s", S(more), S(body_label), S(end)));
        label(self, body_label);
        line(self, str_format("%.*s =l call $W.core.list_get(l %.*s, l %.*s)", S(item), S(xs), S(index)));
        line(self, str_format("%.*s =l add %.*s, 1", S(index), S(index)));
        loop_body(self, item, STR(""), &operation->as.ForList.stores, &operation->as.ForList.body, test, end);
        jump(self, str_format("jmp %.*s", S(test)));
        label(self, end);
        break;
    }
    case OP_ForRange: {
        String current = temp(self);
        String first = value(self, &operation->as.ForRange.start);
        String last = value(self, &operation->as.ForRange.stop);
        String by = value(self, &operation->as.ForRange.step);
        String zero = temp(self);
        line(self, str_format("%.*s =l ceql %.*s, 0", S(zero), S(by)));
        guard(self, zero, &operation->as.ForRange.fail);
        line(self, str_format("%.*s =l copy %.*s", S(current), S(first)));
        String test = new_label(self);
        String body_label = new_label(self);
        String next = new_label(self);
        String advance = new_label(self);
        String end = new_label(self);
        label(self, test);
        String up = temp(self);
        String below = temp(self);
        String above = temp(self);
        String down = temp(self);
        String more = temp(self);
        String item = temp(self);
        line(self, str_format("%.*s =l csgtl %.*s, 0", S(up), S(by)));
        line(self, str_format("%.*s =l csltl %.*s, %.*s", S(below), S(current), S(last)));
        line(self, str_format("%.*s =l csgtl %.*s, %.*s", S(above), S(current), S(last)));
        line(self, str_format("%.*s =l and %.*s, %.*s", S(below), S(up), S(below)));
        line(self, str_format("%.*s =l ceql %.*s, 0", S(down), S(up)));
        line(self, str_format("%.*s =l and %.*s, %.*s", S(above), S(down), S(above)));
        line(self, str_format("%.*s =l or %.*s, %.*s", S(more), S(below), S(above)));
        jump(self, str_format("jnz %.*s, %.*s, %.*s", S(more), S(body_label), S(end)));
        label(self, body_label);
        line(self, str_format("%.*s =l copy %.*s", S(item), S(current)));
        loop_body(self, item, STR(""), &operation->as.ForRange.stores, &operation->as.ForRange.body, next, end);
        /* A step that overflows passes the stop and ends the loop. */
        label(self, next);
        String stepped = temp(self);
        String a = temp(self);
        String b = temp(self);
        line(self, str_format("%.*s =l add %.*s, %.*s", S(stepped), S(current), S(by)));
        line(self, str_format("%.*s =l xor %.*s, %.*s", S(a), S(current), S(stepped)));
        line(self, str_format("%.*s =l xor %.*s, %.*s", S(b), S(by), S(stepped)));
        line(self, str_format("%.*s =l and %.*s, %.*s", S(a), S(a), S(b)));
        line(self, str_format("%.*s =l csltl %.*s, 0", S(a), S(a)));
        jump(self, str_format("jnz %.*s, %.*s, %.*s", S(a), S(end), S(advance)));
        label(self, advance);
        line(self, str_format("%.*s =l copy %.*s", S(current), S(stepped)));
        jump(self, str_format("jmp %.*s", S(test)));
        label(self, end);
        break;
    }
    case OP_ForStr: {
        String s = value(self, &operation->as.ForStr.text);
        String at = temp(self);
        line(self, str_format("%.*s =l copy 0", S(at)));
        String test = new_label(self);
        String body_label = new_label(self);
        String end = new_label(self);
        label(self, test);
        String size = temp(self);
        String more = temp(self);
        String item = temp(self);
        String width = temp(self);
        line(self, str_format("%.*s =l call $W.core.str_size(l %.*s)", S(size), S(s)));
        line(self, str_format("%.*s =l csltl %.*s, %.*s", S(more), S(at), S(size)));
        jump(self, str_format("jnz %.*s, %.*s, %.*s", S(more), S(body_label), S(end)));
        label(self, body_label);
        line(self, str_format("%.*s =l call $W.core.str_char_at(l %.*s, l %.*s)", S(item), S(s), S(at)));
        line(self, str_format("%.*s =l call $W.core.str_size(l %.*s)", S(width), S(item)));
        line(self, str_format("%.*s =l add %.*s, %.*s", S(at), S(at), S(width)));
        loop_body(self, item, STR(""), &operation->as.ForStr.stores, &operation->as.ForStr.body, test, end);
        jump(self, str_format("jmp %.*s", S(test)));
        label(self, end);
        break;
    }
    case OP_ForDict: {
        /* Each step checks the version recorded before the loop. */
        String d = value(self, &operation->as.ForDict.dict);
        String version = temp(self);
        String entry = temp(self);
        String live = temp(self);
        String key = temp(self);
        String val = temp(self);
        String after = temp(self);
        line(self, str_format("%.*s =l call $W.core.dict_version(l %.*s)", S(version), S(d)));
        line(self, str_format("%.*s =l call $W.core.dict_next(l %.*s, l 0, l %.*s)", S(entry), S(d), S(version)));
        String test = new_label(self);
        String body_label = new_label(self);
        String next = new_label(self);
        String end = new_label(self);
        label(self, test);
        line(self, str_format("%.*s =l csgel %.*s, 0", S(live), S(entry)));
        jump(self, str_format("jnz %.*s, %.*s, %.*s", S(live), S(body_label), S(end)));
        label(self, body_label);
        line(self, str_format("%.*s =l call $W.core.dict_key_at(l %.*s, l %.*s)", S(key), S(d), S(entry)));
        line(self, str_format("%.*s =l call $W.core.dict_value_at(l %.*s, l %.*s)", S(val), S(d), S(entry)));
        loop_body(self, key, val, &operation->as.ForDict.stores, &operation->as.ForDict.body, next, end);
        label(self, next);
        line(self, str_format("%.*s =l add %.*s, 1", S(after), S(entry)));
        line(self, str_format("%.*s =l call $W.core.dict_next(l %.*s, l %.*s, l %.*s)", S(entry), S(d), S(after), S(version)));
        jump(self, str_format("jmp %.*s", S(test)));
        label(self, end);
        break;
    }
    case OP_Break: {
        assert(self->loops.len);
        String target = self->loops.data[self->loops.len - 1].end;
        jump(self, str_format("jmp %.*s", S(target)));
        break;
    }
    case OP_Continue: {
        assert(self->loops.len);
        String target = self->loops.data[self->loops.len - 1].next;
        jump(self, str_format("jmp %.*s", S(target)));
        break;
    }
    case OP_Return: {
        String text = STR("ret");
        if (operation->as.Return) {
            String v = value(self, operation->as.Return);
            text = str_format("ret %.*s", S(v));
        }
        jump(self, text);
        break;
    }
    }
}

/* Writes the instructions computing v and returns its operand. */
static String value(Emitter *self, const Value *v) {
    switch (v->tag) {
    case VALUE_Const:
        return str_format("%" PRId64, v->as.Const);
    case VALUE_Global:
        return str_format("$%.*s", S(v->as.Global));
    case VALUE_Local: {
        String t = temp(self);
        line(self, str_format("%.*s =l loadl %%v.%.*s", S(t), S(v->as.Local)));
        return t;
    }
    case VALUE_Call:
        return call(self, &v->as.Call);
    case VALUE_Binary: {
        String l = value(self, v->as.Binary.left);
        String r = value(self, v->as.Binary.right);
        String t = temp(self);
        line(self, str_format("%.*s =l %s %.*s, %.*s", S(t), v->as.Binary.instr, S(l), S(r)));
        return t;
    }
    case VALUE_FloatToInt: {
        String val = value(self, v->as.FloatToInt);
        String d = temp(self);
        line(self, str_format("%.*s =d cast %.*s", S(d), S(val)));
        String t = temp(self);
        line(self, str_format("%.*s =l dtosi %.*s", S(t), S(d)));
        return t;
    }
    case VALUE_IntToFloat: {
        String val = value(self, v->as.IntToFloat);
        String d = temp(self);
        line(self, str_format("%.*s =d sltof %.*s", S(d), S(val)));
        return float_bits(self, d);
    }
    case VALUE_FloatBinary: {
        String l = float_value(self, v->as.FloatBinary.left);
        String r = float_value(self, v->as.FloatBinary.right);
        String d = temp(self);
        line(self, str_format("%.*s =d %s %.*s, %.*s", S(d), v->as.FloatBinary.instr, S(l), S(r)));
        return float_bits(self, d);
    }
    case VALUE_FloatCompare: {
        String l = float_value(self, v->as.FloatCompare.left);
        String r = float_value(self, v->as.FloatCompare.right);
        String t = temp(self);
        line(self, str_format("%.*s =l %s %.*s, %.*s", S(t), v->as.FloatCompare.instr, S(l), S(r)));
        return t;
    }
    case VALUE_FloatNeg: {
        String val = float_value(self, v->as.FloatNeg);
        String d = temp(self);
        line(self, str_format("%.*s =d neg %.*s", S(d), S(val)));
        return float_bits(self, d);
    }
    case VALUE_Logic: {
        String l = value(self, v->as.Logic.left);
        String left_block = self->block;
        String rhs = new_label(self);
        String end = new_label(self);
        if (v->as.Logic.and) {
            jump(self, str_format("jnz %.*s, %.*s, %.*s", S(l), S(rhs), S(end)));
        } else {
            jump(self, str_format("jnz %.*s, %.*s, %.*s", S(l), S(end), S(rhs)));
        }
        label(self, rhs);
        String r = value(self, v->as.Logic.right);
        String right_block = self->block;
        jump(self, str_format("jmp %.*s", S(end)));
        label(self, end);
        String t = temp(self);
        line(self, str_format("%.*s =l phi %.*s %.*s, %.*s %.*s", S(t), S(left_block), S(l), S(right_block), S(r)));
        return t;
    }
    case VALUE_CheckedInt: {
        String l = value(self, v->as.CheckedInt.left);
        String r = value(self, v->as.CheckedInt.right);
        String t = temp(self);
        line(self, str_format("%.*s =l %s %.*s, %.*s", S(t), v->as.CheckedInt.instr, S(l), S(r)));
        String overflowed = overflow(self, v->as.CheckedInt.instr, l, r, t);
        guard(self, overflowed, v->as.CheckedInt.fail);
        return t;
    }
    case VALUE_FloorDivide: {
        String l = value(self, v->as.FloorDivide.left);
        String r = value(self, v->as.FloorDivide.right);
        String zero = temp(self);
        line(self, str_format("%.*s =l ceql %.*s, 0", S(zero), S(r)));
        guard(self, zero, v->as.FloorDivide.fail);
        /* QBE truncates; adjust when a nonzero remainder's sign differs
         * from the divisor's. The symmetric int range excludes -2^63. */
        String q = temp(self);
        String m = temp(self);
        String signs = temp(self);
        String differ = temp(self);
        String nonzero = temp(self);
        String adjust = temp(self);
        line(self, str_format("%.*s =l div %.*s, %.*s", S(q), S(l), S(r)));
        line(self, str_format("%.*s =l rem %.*s, %.*s", S(m), S(l), S(r)));
        line(self, str_format("%.*s =l xor %.*s, %.*s", S(signs), S(m), S(r)));
        line(self, str_format("%.*s =l csltl %.*s, 0", S(differ), S(signs)));
        line(self, str_format("%.*s =l cnel %.*s, 0", S(nonzero), S(m)));
        line(self, str_format("%.*s =l and %.*s, %.*s", S(adjust), S(differ), S(nonzero)));
        String t = temp(self);
        if (v->as.FloorDivide.modulo) {
            String step = temp(self);
            line(self, str_format("%.*s =l mul %.*s, %.*s", S(step), S(r), S(adjust)));
            line(self, str_format("%.*s =l add %.*s, %.*s", S(t), S(m), S(step)));
        } else {
            line(self, str_format("%.*s =l sub %.*s, %.*s", S(t), S(q), S(adjust)));
        }
        return t;
    }
    case VALUE_Divide: {
        String l;
        String r;
        if (v->as.Divide.ints) {
            l = value(self, v->as.Divide.left);
            r = value(self, v->as.Divide.right);
            String zero = temp(self);
            line(self, str_format("%.*s =l ceql %.*s, 0", S(zero), S(r)));
            guard(self, zero, v->as.Divide.fail);
            String d = int_quotient(self, l, r);
            return float_bits(self, d);
        } else {
            l = float_value(self, v->as.Divide.left);
            r = float_value(self, v->as.Divide.right);
            String zero = temp(self);
            line(self, str_format("%.*s =l ceqd %.*s, d_0", S(zero), S(r)));
            guard(self, zero, v->as.Divide.fail);
        }
        String d = temp(self);
        line(self, str_format("%.*s =d div %.*s, %.*s", S(d), S(l), S(r)));
        return float_bits(self, d);
    }
    case VALUE_Item:
        assert(v->as.Item < 2);
        return self->item[v->as.Item];
    case VALUE_DictDisplay: {
        String d = temp(self);
        line(self, str_format("%.*s =l call $W.core.dict_new(l %" PRId64 ")", S(d), v->as.DictDisplay.kind));
        for (size_t i = 0; i < v->as.DictDisplay.entries.len; i++) {
            const ValueEntry *entry = &v->as.DictDisplay.entries.data[i];
            String k = value(self, &entry->key);
            String val = value(self, &entry->value);
            line(self, str_format("call $W.core.dict_set(l %.*s, l %.*s, l %.*s)", S(d), S(k), S(val)));
        }
        return d;
    }
    case VALUE_DictGet: {
        String d = value(self, v->as.DictGet.dict);
        String k = value(self, v->as.DictGet.key);
        String otherwise = value(self, v->as.DictGet.default_);
        String entry = temp(self);
        String missing = temp(self);
        String found = temp(self);
        String result = temp(self);
        String have = new_label(self);
        String lack = new_label(self);
        String done = new_label(self);
        line(self, str_format("%.*s =l call $W.core.dict_find(l %.*s, l %.*s)", S(entry), S(d), S(k)));
        line(self, str_format("%.*s =l csltl %.*s, 0", S(missing), S(entry)));
        jump(self, str_format("jnz %.*s, %.*s, %.*s", S(missing), S(lack), S(have)));
        label(self, have);
        line(self, str_format("%.*s =l call $W.core.dict_value_at(l %.*s, l %.*s)", S(found), S(d), S(entry)));
        self->item[0] = found;
        String val = value(self, v->as.DictGet.present);
        line(self, str_format("%.*s =l copy %.*s", S(result), S(val)));
        jump(self, str_format("jmp %.*s", S(done)));
        label(self, lack);
        line(self, str_format("%.*s =l copy %.*s", S(result), S(otherwise)));
        label(self, done);
        return result;
    }
    case VALUE_Construct: {
        StringVec values = {0};
        for (size_t i = 0; i < v->as.Construct.fields.len; i++) {
            String field = value(self, &v->as.Construct.fields.data[i]);
            vec_push(values, field);
        }
        String object = temp(self);
        line(self, str_format("%.*s =l call $W.core.object_new(l $%.*s, l %zu)", S(object), S(v->as.Construct.descriptor), values.len));
        for (size_t i = 0; i < values.len; i++) {
            String addr = temp(self);
            line(self, str_format("%.*s =l add %.*s, %zu", S(addr), S(object), 8 + 8 * i));
            line(self, str_format("storel %.*s, %.*s", S(values.data[i]), S(addr)));
        }
        return object;
    }
    case VALUE_ListDisplay: {
        String list = temp(self);
        size_t count = v->as.ListDisplay.len;
        line(self, str_format("%.*s =l call $W.core.list_new(l %zu)", S(list), count));
        for (size_t i = 0; i < v->as.ListDisplay.len; i++) {
            String val = value(self, &v->as.ListDisplay.data[i]);
            line(self, str_format("call $W.core.list_append(l %.*s, l %.*s)", S(list), S(val)));
        }
        return list;
    }
    case VALUE_In: {
        String i = value(self, v->as.In.item);
        String c = value(self, v->as.In.container);
        StringVec args = {0};
        vec_push(args, str_format("l %.*s", S(c)));
        vec_push(args, str_format("l %.*s", S(i)));
        for (size_t j = 0; j < v->as.In.extra.len; j++) {
            String val = value(self, &v->as.In.extra.data[j]);
            vec_push(args, str_format("l %.*s", S(val)));
        }
        String t = temp(self);
        String joined = join(&args);
        line(self, str_format("%.*s =l call $%s(%.*s)", S(t), v->as.In.function, S(joined)));
        return t;
    }
    case VALUE_Seq:
        value(self, v->as.Seq.first);
        return value(self, v->as.Seq.second);
    case VALUE_Load: {
        String addr = address(self, v->as.Load.pointer, v->as.Load.offset);
        String t = temp(self);
        line(self, str_format("%.*s =l %s %.*s", S(t), v->as.Load.instr, S(addr)));
        return t;
    }
    case VALUE_Store: {
        String addr = address(self, v->as.Store.pointer, v->as.Store.offset);
        String val = value(self, v->as.Store.value);
        line(self, str_format("%s %.*s, %.*s", v->as.Store.instr, S(val), S(addr)));
        return STR("0");
    }
    }
    assert(false);
    return STR("");
}

/* Long division to 56 bits with a sticky last bit gives one correctly rounded
 * conversion for operands above 2^53. QBE allows reassigned temporaries. */
static String int_quotient(Emitter *self, String l, String r) {
    String fast = new_label(self);
    String slow = new_label(self);
    String shr_test = new_label(self);
    String shr = new_label(self);
    String shl_test = new_label(self);
    String shl = new_label(self);
    String round = new_label(self);
    String up_test = new_label(self);
    String up = new_label(self);
    String down_test = new_label(self);
    String down = new_label(self);
    String sign = new_label(self);
    String negate = new_label(self);
    String done = new_label(self);
    String result = temp(self);
    String abs_l = temp(self);
    String abs_r = temp(self);
    String cond = temp(self);
    String q = temp(self);
    String rem = temp(self);
    String e = temp(self);
    String lost = temp(self);
    String bit = temp(self);
    String t = temp(self);
    String d = temp(self);
    String divisor = temp(self);
    /* Magnitudes are exact: the int range is symmetric. */
    String magnitudes[] = {abs_l, abs_r};
    String operands[] = {l, r};
    for (size_t i = 0; i < 2; i++) {
        String abs = magnitudes[i];
        String x = operands[i];
        line(self, str_format("%.*s =l sar %.*s, 63", S(t), S(x)));
        line(self, str_format("%.*s =l xor %.*s, %.*s", S(abs), S(x), S(t)));
        line(self, str_format("%.*s =l sub %.*s, %.*s", S(abs), S(abs), S(t)));
    }
    line(self, str_format("%.*s =l culel %.*s, 9007199254740992", S(cond), S(abs_l)));
    line(self, str_format("%.*s =l culel %.*s, 9007199254740992", S(t), S(abs_r)));
    line(self, str_format("%.*s =l and %.*s, %.*s", S(cond), S(cond), S(t)));
    line(self, str_format("%.*s =l ceql %.*s, 0", S(t), S(l)));
    line(self, str_format("%.*s =l or %.*s, %.*s", S(cond), S(cond), S(t)));
    jump(self, str_format("jnz %.*s, %.*s, %.*s", S(cond), S(fast), S(slow)));
    label(self, fast);
    line(self, str_format("%.*s =d sltof %.*s", S(d), S(l)));
    line(self, str_format("%.*s =d sltof %.*s", S(divisor), S(r)));
    line(self, str_format("%.*s =d div %.*s, %.*s", S(result), S(d), S(divisor)));
    jump(self, str_format("jmp %.*s", S(done)));
    label(self, slow);
    line(self, str_format("%.*s =l udiv %.*s, %.*s", S(q), S(abs_l), S(abs_r)));
    line(self, str_format("%.*s =l urem %.*s, %.*s", S(rem), S(abs_l), S(abs_r)));
    line(self, str_format("%.*s =l copy 0", S(e)));
    line(self, str_format("%.*s =l copy 0", S(lost)));
    /* Drop a quotient's bits above 56 into lost. */
    label(self, shr_test);
    line(self, str_format("%.*s =l cugel %.*s, 72057594037927936", S(cond), S(q)));
    jump(self, str_format("jnz %.*s, %.*s, %.*s", S(cond), S(shr), S(shl_test)));
    label(self, shr);
    line(self, str_format("%.*s =l and %.*s, 1", S(bit), S(q)));
    line(self, str_format("%.*s =l or %.*s, %.*s", S(lost), S(lost), S(bit)));
    line(self, str_format("%.*s =l shr %.*s, 1", S(q), S(q)));
    line(self, str_format("%.*s =l add %.*s, 1", S(e), S(e)));
    jump(self, str_format("jmp %.*s", S(shr_test)));
    /* Below 2^55, take the next division bit. Remainder arithmetic is
     * modulo 2^64, including doubling past 2^63. */
    label(self, shl_test);
    line(self, str_format("%.*s =l cultl %.*s, 36028797018963968", S(cond), S(q)));
    jump(self, str_format("jnz %.*s, %.*s, %.*s", S(cond), S(shl), S(round)));
    label(self, shl);
    line(self, str_format("%.*s =l sub %.*s, %.*s", S(t), S(abs_r), S(rem)));
    line(self, str_format("%.*s =l cugel %.*s, %.*s", S(bit), S(rem), S(t)));
    line(self, str_format("%.*s =l shl %.*s, 1", S(q), S(q)));
    line(self, str_format("%.*s =l or %.*s, %.*s", S(q), S(q), S(bit)));
    line(self, str_format("%.*s =l shl %.*s, 1", S(rem), S(rem)));
    line(self, str_format("%.*s =l mul %.*s, %.*s", S(t), S(bit), S(abs_r)));
    line(self, str_format("%.*s =l sub %.*s, %.*s", S(rem), S(rem), S(t)));
    line(self, str_format("%.*s =l sub %.*s, 1", S(e), S(e)));
    jump(self, str_format("jmp %.*s", S(shl_test)));
    label(self, round);
    line(self, str_format("%.*s =l cnel %.*s, 0", S(t), S(rem)));
    line(self, str_format("%.*s =l or %.*s, %.*s", S(lost), S(lost), S(t)));
    line(self, str_format("%.*s =l or %.*s, %.*s", S(q), S(q), S(lost)));
    line(self, str_format("%.*s =d sltof %.*s", S(d), S(q)));
    /* Scaling by two is exact for the quotient's magnitude, 2^-63..2^63. */
    label(self, up_test);
    line(self, str_format("%.*s =l csgtl %.*s, 0", S(cond), S(e)));
    jump(self, str_format("jnz %.*s, %.*s, %.*s", S(cond), S(up), S(down_test)));
    label(self, up);
    line(self, str_format("%.*s =d mul %.*s, d_2", S(d), S(d)));
    line(self, str_format("%.*s =l sub %.*s, 1", S(e), S(e)));
    jump(self, str_format("jmp %.*s", S(up_test)));
    label(self, down_test);
    line(self, str_format("%.*s =l csltl %.*s, 0", S(cond), S(e)));
    jump(self, str_format("jnz %.*s, %.*s, %.*s", S(cond), S(down), S(sign)));
    label(self, down);
    line(self, str_format("%.*s =d mul %.*s, d_0.5", S(d), S(d)));
    line(self, str_format("%.*s =l add %.*s, 1", S(e), S(e)));
    jump(self, str_format("jmp %.*s", S(down_test)));
    label(self, sign);
    line(self, str_format("%.*s =l xor %.*s, %.*s", S(t), S(l), S(r)));
    line(self, str_format("%.*s =l csltl %.*s, 0", S(cond), S(t)));
    line(self, str_format("%.*s =d copy %.*s", S(result), S(d)));
    jump(self, str_format("jnz %.*s, %.*s, %.*s", S(cond), S(negate), S(done)));
    label(self, negate);
    line(self, str_format("%.*s =d neg %.*s", S(result), S(d)));
    label(self, done);
    return result;
}

/* Detect wrapping and -2^63, which is outside the symmetric int range. */
static String overflow(Emitter *self, const char *instr, String l, String r, String t) {
    String a = temp(self);
    String b = temp(self);
    String wrapped = temp(self);
    String min = temp(self);
    if (strcmp(instr, "add") == 0 || strcmp(instr, "sub") == 0) {
        if (strcmp(instr, "add") == 0) {
            line(self, str_format("%.*s =l xor %.*s, %.*s", S(a), S(l), S(t)));
            line(self, str_format("%.*s =l xor %.*s, %.*s", S(b), S(r), S(t)));
        } else {
            line(self, str_format("%.*s =l xor %.*s, %.*s", S(a), S(l), S(r)));
            line(self, str_format("%.*s =l xor %.*s, %.*s", S(b), S(l), S(t)));
        }
        line(self, str_format("%.*s =l and %.*s, %.*s", S(a), S(a), S(b)));
        line(self, str_format("%.*s =l csltl %.*s, 0", S(wrapped), S(a)));
    } else {
        /* For multiplication, dividing back detects wrapping. Substitute 1
         * for the divisor when the left operand is 0 or the result -2^63. */
        String zero = temp(self);
        String skip = temp(self);
        String divisor = temp(self);
        line(self, str_format("%.*s =l ceql %.*s, 0", S(zero), S(l)));
        line(self, str_format("%.*s =l ceql %.*s, -9223372036854775808", S(min), S(t)));
        line(self, str_format("%.*s =l or %.*s, %.*s", S(skip), S(zero), S(min)));
        line(self, str_format("%.*s =l sub 0, %.*s", S(a), S(skip)));
        line(self, str_format("%.*s =l xor %.*s, 1", S(b), S(l)));
        line(self, str_format("%.*s =l and %.*s, %.*s", S(b), S(b), S(a)));
        line(self, str_format("%.*s =l xor %.*s, %.*s", S(divisor), S(l), S(b)));
        line(self, str_format("%.*s =l div %.*s, %.*s", S(a), S(t), S(divisor)));
        line(self, str_format("%.*s =l cnel %.*s, %.*s", S(a), S(a), S(r)));
        line(self, str_format("%.*s =l ceql %.*s, 0", S(b), S(zero)));
        line(self, str_format("%.*s =l and %.*s, %.*s", S(wrapped), S(a), S(b)));
    }
    line(self, str_format("%.*s =l ceql %.*s, -9223372036854775808", S(min), S(t)));
    line(self, str_format("%.*s =l or %.*s, %.*s", S(wrapped), S(wrapped), S(min)));
    return wrapped;
}

static String float_value(Emitter *self, const Value *v) {
    String val = value(self, v);
    String d = temp(self);
    line(self, str_format("%.*s =d cast %.*s", S(d), S(val)));
    return d;
}

static String float_bits(Emitter *self, String d) {
    String t = temp(self);
    line(self, str_format("%.*s =l cast %.*s", S(t), S(d)));
    return t;
}

static void guard(Emitter *self, String cond, const Value *fail) {
    String failed = new_label(self);
    String ok = new_label(self);
    jump(self, str_format("jnz %.*s, %.*s, %.*s", S(cond), S(failed), S(ok)));
    label(self, failed);
    value(self, fail);
    jump(self, STR("hlt"));
    label(self, ok);
}

static String address(Emitter *self, const Value *ptr, const Value *offset) {
    String p = value(self, ptr);
    String o = value(self, offset);
    String t = temp(self);
    line(self, str_format("%.*s =l add %.*s, %.*s", S(t), S(p), S(o)));
    return t;
}

static String call(Emitter *self, const Call *callee) {
    StringVec args = {0};
    for (size_t i = 0; i < callee->args.len; i++) {
        if (callee->variadic_at.some && callee->variadic_at.value == i) {
            vec_push(args, STR("..."));
        }
        const CallArg *arg = &callee->args.data[i];
        String v = value(self, &arg->value);
        if (strcmp(arg->ty, "d") == 0) {
            String d = temp(self);
            line(self, str_format("%.*s =d cast %.*s", S(d), S(v)));
            v = d;
        }
        vec_push(args, str_format("%s %.*s", arg->ty, S(v)));
    }
    if (callee->variadic_at.some && callee->variadic_at.value == callee->args.len) {
        vec_push(args, STR("..."));
    }
    String joined = join(&args);
    String text = str_format("call $%.*s(%.*s)", S(callee->symbol), S(joined));
    if (!callee->ret) {
        line(self, text);
        return STR("0");
    }
    if (strcmp(callee->ret, "w") == 0 || strcmp(callee->ret, "d") == 0) {
        String r = temp(self);
        line(self, str_format("%.*s =%s %.*s", S(r), callee->ret, S(text)));
        String t = temp(self);
        const char *convert = strcmp(callee->ret, "w") == 0 ? "extsw" : "cast";
        line(self, str_format("%.*s =l %s %.*s", S(t), convert, S(r)));
        return t;
    }
    String t = temp(self);
    line(self, str_format("%.*s =%s %.*s", S(t), callee->ret, S(text)));
    return t;
}
