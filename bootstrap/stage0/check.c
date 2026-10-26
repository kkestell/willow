/* Binds names, checks types and flow, and lowers to the emitter's IR. */
#include "willow0.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>

#define FMT "%.*s"
#define S(s) (int)(s).len, (s).data
#define TY(t) ((Type){.tag = TYPE_##t})
#define VAL(t, ...) ((Value){.tag = VALUE_##t, .as.t = __VA_ARGS__})
#define OP(t, ...) ((Op){.tag = OP_##t, .as.t = __VA_ARGS__})
#define VALUES(...)                                                                                \
    ((ValueVec){                                                                                   \
        .data = (Value[]){__VA_ARGS__}, .len = sizeof((Value[]){__VA_ARGS__}) / sizeof(Value)})
#define TYPES(...)                                                                                 \
    ((TypeVec){.data = (Type[]){__VA_ARGS__}, .len = sizeof((Type[]){__VA_ARGS__}) / sizeof(Type)})

VEC_DECL(const char *, CTypeVec);
VEC_DECL(int64_t, IntVec);
VEC_DECL(const Alias *, AliasStack);

typedef enum TargetTag {
    TARGET_Willow,
    TARGET_Extern
} TargetTag;

typedef struct Target {
    TargetTag tag;

    union {
        String Willow;

        struct {
            CTypeVec cparams;
            bool variadic;
            const char *cret;
        } Extern;
    } as;
} Target;

typedef struct Sig {
    TypeVec params;
    Type ret;
    Target target;
} Sig;

typedef struct Strings {
    StringVec list;
    Map index;
} Strings;

typedef enum TypeDeclTag {
    DECL_Class,
    DECL_Enum,
    DECL_Alias
} TypeDeclTag;

typedef struct TypeDecl {
    TypeDeclTag tag;
    Type ty;
} TypeDecl;

typedef struct Namespace {
    Map declared;
    Map funcs;
    Map types;
    bool host;
} Namespace;

typedef struct ClassInfo {
    const Class *decl;
    TypeVec fields;
    Map methods;
} ClassInfo;

typedef struct Names {
    Map modules;
    Map sources;
    Map classes;
    Map enums;
} Names;

typedef Map State;

typedef struct OptionalType {
    bool some;
    Type ty;
} OptionalType;

typedef struct Scope {
    const Module *module;
    const Namespace *globals;
    const Map *imported;
    const Names *names;
} Scope;

typedef struct Checker {
    const Module *module;
    const Namespace *globals;
    const Map *imported;
    const Names *names;
    bool intrinsics;
    Strings *strings;
    Type ret;
    Map locals;
    Map params;
    StringVec order;
    uint32_t loops;
} Checker;

typedef struct TypedValue {
    Value value;
    Type ty;
} TypedValue;

typedef struct CheckedArg {
    Pos pos;
    Value value;
    Type ty;
} CheckedArg;

VEC_DECL(CheckedArg, CheckedArgs);

typedef struct Fact {
    String name;
    Type ty;
} Fact;

VEC_DECL(Fact, Facts);

typedef struct FactPair {
    Facts yes;
    Facts no;
} FactPair;

typedef struct Block {
    OpVec ops;
    bool transfers;
} Block;

typedef enum ForSourceTag {
    FOR_Range,
    FOR_List,
    FOR_Str,
    FOR_Dict
} ForSourceTag;

typedef struct ForSource {
    ForSourceTag tag;

    union {
        struct {
            Value start;
            Value stop;
            Value step;
        } Range;

        struct {
            Value value;
            Type element;
        } List;

        Value Str;

        struct {
            Value dict;
            Type key;
            Type value;
            const char *part;
        } Dict;
    } as;
} ForSource;

typedef struct ForItem {
    size_t slot;
    Type ty;
} ForItem;

VEC_DECL(ForItem, ForItems);

typedef struct DictCall {
    Value dict;
    const Type *key;
    const Type *value;
    Pos pos;
    String name;
} DictCall;

typedef struct MethodSignature {
    const char *function;
    TypeVec params;
    IntVec defaults;
    Type ret;
} MethodSignature;

/* Lookup errors remain values so narrowing and module-name probes can ignore them. */
typedef enum NsTag {
    NS_None,
    NS_Module,
    NS_Prefix,
    NS_Error
} NsTag;

typedef struct Ns {
    NsTag tag;
    String name;
    Diag *error;
} Ns;

typedef enum DeclTag {
    D_None,
    D_Func,
    D_Type,
    D_Error
} DeclTag;

typedef struct Decl {
    DeclTag tag;
    String written;

    union {
        const Sig *func;
        const TypeDecl *type;
        Diag *error;
    } as;
} Decl;

typedef struct TestedType {
    bool some;
    String written;
    const Type *member;
    Diag *error;
} TestedType;

typedef struct LookupType {
    String owner;
    const TypeDecl *decl;
} LookupType;

typedef struct ExternType {
    Type ty;
    const char *ctype;
} ExternType;

typedef struct FieldType {
    int64_t offset;
    Type ty;
} FieldType;

static const char *const BUILTINS[] = {"print", "input", "len", "range", "int", "float", "str",
    "bytes", "ord", "chr", "sorted", "abs", "round", "min", "max", "sum", "any",
    "all", "list", "enumerate", "zip", "iter", "next"};

typedef struct Intrinsic {
    const char *name;
    TypeTag params[3];
    size_t len;
    TypeTag ret;
} Intrinsic;

static const Intrinsic INTRINSICS[] = {{"__alloc", {TYPE_Int}, 1, TYPE_Ptr},
    {"__alloc_atomic", {TYPE_Int}, 1, TYPE_Ptr}, {"__load1", {TYPE_Ptr, TYPE_Int}, 2, TYPE_Int},
    {"__store1", {TYPE_Ptr, TYPE_Int, TYPE_Int}, 3, TYPE_None},
    {"__load8", {TYPE_Ptr, TYPE_Int}, 2, TYPE_Word},
    {"__store8", {TYPE_Ptr, TYPE_Int, TYPE_Word}, 3, TYPE_None},
    {"__int", {TYPE_Word}, 1, TYPE_Int}, {"__ptr", {TYPE_Word}, 1, TYPE_Ptr},
    {"__str", {TYPE_Word}, 1, TYPE_Str}, {"__float", {TYPE_Word}, 1, TYPE_Float},
    {"__bool", {TYPE_Word}, 1, TYPE_Bool}, {"__load4", {TYPE_Ptr, TYPE_Int}, 2, TYPE_Int},
    {"__store4", {TYPE_Ptr, TYPE_Int, TYPE_Int}, 3, TYPE_None},
    {"__addr_is_null", {TYPE_Ptr}, 1, TYPE_Bool}, {"__dtosi", {TYPE_Float}, 1, TYPE_Int},
    {"__offset", {TYPE_Ptr, TYPE_Int}, 2, TYPE_Ptr}};
static const char *const BUILTIN_TYPES[] = {
    "int", "float", "bool", "str", "bytes", "list", "dict", "tuple"};

static bool eq(String text, const char *other) {
    return str_equal(text, str_from_cstr(other));
}

static bool starts_with(String text, String prefix) {
    return text.len >= prefix.len &&
           (!prefix.len || memcmp(text.data, prefix.data, prefix.len) == 0);
}

static String last_name(String text) {
    size_t at = text.len;
    while (at && text.data[at - 1] != '.') {
        at--;
    }
    return (String){text.data + at, text.len - at};
}

static String first_name(String text) {
    size_t at = 0;
    while (at < text.len && text.data[at] != '.') {
        at++;
    }
    return (String){text.data, at};
}

static bool listed(String name, const char *const *list, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (eq(name, list[i])) {
            return true;
        }
    }
    return false;
}

#define LISTED(name, list) listed((name), (list), sizeof(list) / sizeof(*(list)))

static const char *target_os(void) {
#ifdef __APPLE__
    return "darwin";
#else
    return "linux";
#endif
}

static bool is_intrinsic(String name) {
    if (eq(name, "__word") || eq(name, "__type") || eq(name, "__os")) {
        return true;
    }
    for (size_t i = 0; i < sizeof(INTRINSICS) / sizeof(*INTRINSICS); i++) {
        if (eq(name, INTRINSICS[i].name)) {
            return true;
        }
    }
    return false;
}

static String count(size_t n) {
    return str_format("%zu argument%s", n, n == 1 ? "" : "s");
}

static bool set_insert(Map *set, String key) {
    return map_insert(set, key, (void *)1);
}

static void put_type(Map *map, String name, Type ty) {
    map_insert(map, name, box_copy(&ty, sizeof(ty)));
}

static Type list_type(Type element) {
    return (Type){.tag = TYPE_List, .as.List = box_copy(&element, sizeof(element))};
}

static Type dict_type(Type key, Type value) {
    return (Type){.tag = TYPE_Dict,
        .as.Dict = {box_copy(&key, sizeof(key)), box_copy(&value, sizeof(value))}};
}

static Type union_two(Type a, Type b) {
    return type_union(TYPES(a, b));
}

static Value constant(int64_t n) {
    return VAL(Const, n);
}

static Value binary_value(const char *instr, Value left, Value right) {
    return VAL(Binary, {instr, box_copy(&left, sizeof(left)), box_copy(&right, sizeof(right))});
}

static TypedValue typed(Value value, Type ty) {
    return (TypedValue){value, ty};
}

static size_t index_of(Strings *self, String text) {
    size_t *n = map_get(&self->index, text);
    if (n) {
        return *n;
    }
    vec_push(self->list, text);
    size_t index = self->list.len - 1;
    map_insert(&self->index, text, box_copy(&index, sizeof(index)));
    return index;
}

static Value intern(Strings *self, String text) {
    return VAL(Global, str_format("W.str.%zu", index_of(self, text)));
}

static Type resolve_in(const Names *, const Module *, const TypeExpr *, AliasStack *);
static Type resolve_name(const Names *, const Module *, const TypeName *, AliasStack *);
static TypedValue expr(Checker *, const Expr *, const State *);
static TypedValue expr_expect(Checker *, const Expr *, const State *, const Type *);
static Block block(Checker *, StmtVec, State *);
static bool statement(Checker *, const Stmt *, State *, OpVec *);
static TypedValue call(Checker *, const Expr *, ExprVec, const State *);
static FactPair facts(const Checker *, const Expr *, const State *);
static Ns namespace_of(const Checker *, const Expr *);
static Decl decl_of(const Checker *, const Expr *);
static TestedType tested_type(const Checker *, const Expr *, const Type *);
static bool is_builtin(const Checker *, const Expr *, const char *);
static Ns module_of(const Checker *, const Expr *);
static Value fail_call(Checker *, const char *, Value);
static TypedValue binary(Checker *, const char *, Pos, Value, Type, Value, Type);
static bool to_str(Checker *, Value, const Type *, Value *);
static FieldType field(const Checker *, const Type *, Pos, String);
static TypedValue method(Checker *, const Expr *, Pos, String, ExprVec, const State *);
static CheckedArgs args(Checker *, ExprVec, const State *, TypeVec);
static TypedValue construct(Checker *, Pos, const Type *, ExprVec, const State *);
static TypedValue call_sig(const Checker *, Pos, String, String, const Sig *, CheckedArgs);
static TypedValue type_test(Checker *, const Expr *, const Expr *, const State *);
static TypedValue dict_get(Checker *, DictCall, ExprVec, const State *);
static bool is_sys_exit(const Checker *, const Expr *);
static int os_test(const Checker *, const Expr *);
/* Resolve locals in declaration order. Each child block copies the visible
 * bindings, while generated slot names remain unique within the function. */
static String source_name(String slot) {
    for (size_t i = 0; i < slot.len; i++) {
        if (slot.data[i] == '.') return (String){slot.data, i};
    }
    return slot;
}

static String bind_local(const Module *module, Map *visible, String name, Pos pos, size_t *next) {
    if (map_contains(visible, name)) {
        fail(module->path, pos, str_format("cannot redeclare visible name '" FMT "'", S(name)));
    }
    String slot = str_format(FMT ".%zu", S(name), ++*next);
    map_insert(visible, name, box_copy(&slot, sizeof(slot)));
    return slot;
}

static void bind_expr(Expr *expression, const Map *visible) {
    if (!expression) return;
    ExprKind *kind = &expression->kind;
    switch (kind->tag) {
    case EXPR_Name: {
        const String *slot = map_get(visible, kind->as.Name);
        if (slot) kind->as.Name = *slot;
        break;
    }
    case EXPR_Call:
        bind_expr(kind->as.Call.callee, visible);
        for (size_t i = 0; i < kind->as.Call.args.len; i++) bind_expr(&kind->as.Call.args.data[i], visible);
        break;
    case EXPR_FStr:
    case EXPR_List: {
        ExprVec elements = kind->tag == EXPR_List ? kind->as.List : kind->as.FStr;
        for (size_t i = 0; i < elements.len; i++) bind_expr(&elements.data[i], visible);
        break;
    }
    case EXPR_Dict:
        for (size_t i = 0; i < kind->as.Dict.len; i++) {
            bind_expr(&kind->as.Dict.data[i].key, visible);
            bind_expr(&kind->as.Dict.data[i].value, visible);
        }
        break;
    case EXPR_Index:
        bind_expr(kind->as.Index.object, visible);
        bind_expr(kind->as.Index.index, visible);
        break;
    case EXPR_Slice:
        bind_expr(kind->as.Slice.object, visible);
        bind_expr(kind->as.Slice.start, visible);
        bind_expr(kind->as.Slice.stop, visible);
        break;
    case EXPR_Attr: bind_expr(kind->as.Attr.object, visible); break;
    case EXPR_Unary: bind_expr(kind->as.Unary.operand, visible); break;
    case EXPR_Binary:
        bind_expr(kind->as.Binary.left, visible);
        bind_expr(kind->as.Binary.right, visible);
        break;
    case EXPR_TypeTest: bind_expr(kind->as.TypeTest.operand, visible); break;
    case EXPR_Int: case EXPR_Float: case EXPR_Str: case EXPR_Bool:
    case EXPR_None: case EXPR_TypeOf: break;
    }
}

static void bind_block(const Module *module, StmtVec body, Map visible, size_t *next) {
    visible = map_clone(&visible);
    for (size_t i = 0; i < body.len; i++) {
        Stmt *stmt = &body.data[i];
        StmtKind *kind = &stmt->kind;
        switch (kind->tag) {
        case STMT_Assign: {
            String name = kind->as.Assign.target;
            bind_expr(kind->as.Assign.value, &visible);
            if (kind->as.Assign.declaration) {
                kind->as.Assign.target = bind_local(module, &visible, name, stmt->pos, next);
            } else {
                const String *slot = map_get(&visible, name);
                if (!slot) {
                    fail(module->path, stmt->pos, str_format("unknown variable '" FMT "'; use 'var' to declare it", S(name)));
                }
                kind->as.Assign.target = *slot;
            }
            break;
        }
        case STMT_If:
            for (size_t j = 0; j < kind->as.If.arms.len; j++) {
                IfArm *arm = &kind->as.If.arms.data[j];
                bind_expr(&arm->cond, &visible);
                bind_block(module, arm->body, visible, next);
            }
            if (kind->as.If.otherwise) bind_block(module, *kind->as.If.otherwise, visible, next);
            break;
        case STMT_While:
            bind_expr(&kind->as.While.cond, &visible);
            bind_block(module, kind->as.While.body, visible, next);
            break;
        case STMT_For: {
            bind_expr(&kind->as.For.iterable, &visible);
            Map loop = map_clone(&visible);
            for (size_t j = 0; j < kind->as.For.targets.len; j++) {
                PosName *target = &kind->as.For.targets.data[j];
                target->name = bind_local(module, &loop, target->name, target->pos, next);
            }
            bind_block(module, kind->as.For.body, loop, next);
            break;
        }
        case STMT_Expr: bind_expr(&kind->as.Expr, &visible); break;
        case STMT_SetField:
            bind_expr(&kind->as.SetField.object, &visible);
            bind_expr(&kind->as.SetField.value, &visible);
            break;
        case STMT_SetIndex:
            bind_expr(&kind->as.SetIndex.object, &visible);
            bind_expr(&kind->as.SetIndex.index, &visible);
            bind_expr(&kind->as.SetIndex.value, &visible);
            break;
        case STMT_Assert:
            bind_expr(&kind->as.Assert.cond, &visible);
            bind_expr(kind->as.Assert.message, &visible);
            break;
        case STMT_Return: bind_expr(kind->as.Return, &visible); break;
        case STMT_Pass: case STMT_Break: case STMT_Continue: break;
        }
    }
}

static Function check_function(Scope, Strings *, const Func *, const Sig *, StmtVec, bool);

static Map host_tables(void) {
    Map tables = {0};
    const char *modules[] = {"sys", "fs", "fs", "fs", "fs"};
    const char *names[] = {"exit", "read_file", "write_file", "exists", "realpath"};
    const char *targets[] = {
        "sys_exit", "fs_read_file", "fs_write_file", "fs_exists", "fs_realpath"};
    TypeTag returns[] = {TYPE_None, TYPE_Str, TYPE_None, TYPE_Bool, TYPE_Str};
    for (size_t i = 0; i < 5; i++) {
        String owner = str_from_cstr(modules[i]);
        Map *table = map_get(&tables, owner);
        if (!table) {
            table = box(Map, 0);
            map_insert(&tables, owner, table);
        }
        Sig sig = {.ret = {.tag = returns[i]},
            .target = {.tag = TARGET_Willow, .as.Willow = str_format("W.core.%s", targets[i])}};
        vec_push(sig.params, i == 0 ? TY(Int) : TY(Str));
        if (i == 2) {
            vec_push(sig.params, TY(Str));
        }
        map_insert(table, str_from_cstr(names[i]), box_copy(&sig, sizeof(sig)));
    }
    return tables;
}

typedef struct Declaration {
    Pos pos;
    const char *kind;
    String name;
} Declaration;

VEC_DECL(Declaration, Declarations);

static Namespace declare_types(const Module *module, String entry, Names *names) {
    Declarations decls = {0};
    for (size_t i = 0; i < module->funcs.len; i++) {
        const Func *f = &module->funcs.data[i];
        vec_push(decls, (Declaration){f->pos, "function", f->name});
    }
    for (size_t i = 0; i < module->classes.len; i++) {
        const Class *c = &module->classes.data[i];
        vec_push(decls, (Declaration){c->pos, "class", c->name});
    }
    for (size_t i = 0; i < module->enums.len; i++) {
        const Enum *e = &module->enums.data[i];
        vec_push(decls, (Declaration){e->pos, "enum", e->name});
    }
    for (size_t i = 0; i < module->aliases.len; i++) {
        const Alias *a = &module->aliases.data[i];
        vec_push(decls, (Declaration){a->pos, "alias", a->name});
    }
    /* Preserve declaration order at equal positions. */
    for (size_t i = 1; i < decls.len; i++) {
        Declaration item = decls.data[i];
        size_t j = i;
        while (j && (decls.data[j - 1].pos.line > item.pos.line ||
                        (decls.data[j - 1].pos.line == item.pos.line &&
                            decls.data[j - 1].pos.col > item.pos.col))) {
            decls.data[j] = decls.data[j - 1];
            j--;
        }
        decls.data[j] = item;
    }
    Namespace result = {0};
    Map seen = {0};
    for (size_t i = 0; i < decls.len; i++) {
        set_insert(&result.declared, decls.data[i].name);
    }
    for (size_t i = 0; i < module->imports.len; i++) {
        set_insert(&seen, first_name(module->imports.data[i].name));
    }
    for (size_t i = 0; i < decls.len; i++) {
        Declaration d = decls.data[i];
        if (LISTED(d.name, BUILTINS)) {
            fail(module->path, d.pos,
                str_format("cannot redefine built-in function '" FMT "'", S(d.name)));
        }
        if (!set_insert(&seen, d.name)) {
            fail(module->path, d.pos, str_format("duplicate %s '" FMT "'", d.kind, S(d.name)));
        }
    }
    for (size_t i = 0; i < module->classes.len; i++) {
        String name = module->classes.data[i].name;
        Named named = {str_equal(module->name, entry)
                           ? name
                           : str_format(FMT "." FMT, S(module->name), S(name)),
            str_format("W." FMT "." FMT, S(module->name), S(name))};
        map_insert(&result.types, name,
            box(TypeDecl, .tag = DECL_Class, .ty = {.tag = TYPE_Class, .as.Class = named}));
    }
    for (size_t i = 0; i < module->enums.len; i++) {
        const Enum *decl = &module->enums.data[i];
        Map members = {0};
        for (size_t j = 0; j < decl->members.len; j++) {
            PosName member = decl->members.data[j];
            if (!set_insert(&members, member.name)) {
                fail(module->path, member.pos,
                    str_format("duplicate enum member '" FMT "'", S(member.name)));
            }
        }
        Named named = {str_equal(module->name, entry)
                           ? decl->name
                           : str_format(FMT "." FMT, S(module->name), S(decl->name)),
            str_format("W." FMT "." FMT, S(module->name), S(decl->name))};
        map_insert(&names->enums, named.symbol, (void *)&decl->members);
        map_insert(&result.types, decl->name,
            box(TypeDecl, .tag = DECL_Enum, .ty = {.tag = TYPE_Enum, .as.Enum = named}));
    }
    for (size_t i = 0; i < module->aliases.len; i++) {
        map_insert(&result.types, module->aliases.data[i].name, box(TypeDecl, .tag = DECL_Alias));
    }
    return result;
}

static LookupType lookup_type(const Names *names, const Module *module, const TypeName *ty) {
    String owner = module->name, name = last_name(ty->name);
    if (name.len != ty->name.len) {
        owner = (String){ty->name.data, ty->name.len - name.len - 1};
        bool imported = false;
        for (size_t i = 0; i < module->imports.len; i++) {
            if (str_equal(module->imports.data[i].name, owner)) {
                imported = true;
            }
        }
        if (!imported) {
            fail(module->path, ty->pos, str_format("unknown module '" FMT "'", S(owner)));
        }
    }
    const Namespace *namespace = map_get(&names->modules, owner);
    assert(namespace);
    if (!str_equal(owner, module->name)) {
        if (!map_contains(&namespace->declared, name)) {
            fail(module->path, ty->pos,
                str_format("module '" FMT "' has no function, class, enum, or alias '" FMT "'",
                    S(owner), S(name)));
        }
        if (starts_with(name, STR("_"))) {
            fail(module->path, ty->pos,
                str_format("'" FMT "' is private to module '" FMT "'", S(name), S(owner)));
        }
    }
    return (LookupType){owner, map_get(&namespace->types, name)};
}

static bool is_key_type(const Type *ty) {
    return ty->tag == TYPE_Int || ty->tag == TYPE_Str || ty->tag == TYPE_Enum;
}

static Type resolve_name(
    const Names *names, const Module *module, const TypeName *ty, AliasStack *expanding) {
    size_t expected = eq(ty->name, "list") ? 1 : eq(ty->name, "dict") ? 2 : 0;
    if (ty->args.len != expected) {
        fail(module->path, ty->pos,
            str_format("'" FMT "' expects %zu type argument%s, received %zu", S(ty->name), expected,
                expected == 1 ? "" : "s", ty->args.len));
    }
    if (eq(ty->name, "list")) {
        vec_push(*expanding, NULL);
        Type element = resolve_in(names, module, &ty->args.data[0], expanding);
        expanding->len--;
        if (element.tag == TYPE_Ptr || element.tag == TYPE_Word) {
            fail(module->path, ty->pos,
                str_format(FMT " cannot be a list element", S(type_name(&element))));
        }
        return list_type(element);
    }
    if (eq(ty->name, "dict")) {
        vec_push(*expanding, NULL);
        Type key = resolve_in(names, module, &ty->args.data[0], expanding);
        Type value = resolve_in(names, module, &ty->args.data[1], expanding);
        expanding->len--;
        if (!is_key_type(&key)) {
            fail(module->path, ty->args.data[0].pos,
                STR("dictionary keys must be int, str, or an enum"));
        }
        if (value.tag == TYPE_Ptr || value.tag == TYPE_Word) {
            fail(module->path, ty->pos,
                str_format(FMT " cannot be a dict value", S(type_name(&value))));
        }
        return dict_type(key, value);
    }
    if (eq(ty->name, "int")) {
        return TY(Int);
    }
    if (eq(ty->name, "float")) {
        return TY(Float);
    }
    if (eq(ty->name, "bool")) {
        return TY(Bool);
    }
    if (eq(ty->name, "str")) {
        return TY(Str);
    }
    if (eq(ty->name, "none")) {
        return TY(None);
    }
    if (eq(ty->name, "ptr") && eq(module->name, "core")) {
        return TY(Ptr);
    }
    if (eq(ty->name, "word") && eq(module->name, "core")) {
        return TY(Word);
    }
    LookupType found = lookup_type(names, module, ty);
    if (!found.decl) {
        fail(module->path, ty->pos, str_format("unknown type '" FMT "'", S(ty->name)));
    }
    if (found.decl->tag != DECL_Alias) {
        return found.decl->ty;
    }
    const Module *source = map_get(&names->sources, found.owner);
    String alias_name = last_name(ty->name);
    const Alias *alias = NULL;
    for (size_t i = 0; i < source->aliases.len; i++) {
        if (str_equal(source->aliases.data[i].name, alias_name)) {
            alias = &source->aliases.data[i];
            break;
        }
    }
    assert(alias);
    for (size_t at = 0; at < expanding->len; at++) {
        if (expanding->data[at] != alias) {
            continue;
        }
        for (size_t i = at; i < expanding->len; i++) {
            if (!expanding->data[i]) {
                fail(module->path, ty->pos, STR("recursive type aliases are not supported"));
            }
        }
        fail(module->path, ty->pos, str_format("alias '" FMT "' expands to itself", S(ty->name)));
    }
    vec_push(*expanding, alias);
    Type resolved = resolve_in(names, source, &alias->ty, expanding);
    expanding->len--;
    return resolved;
}

static Type resolve_in(
    const Names *names, const Module *module, const TypeExpr *ty, AliasStack *expanding) {
    if (ty->members.len == 1) {
        return resolve_name(names, module, &ty->members.data[0], expanding);
    }
    TypeVec members = {0};
    for (size_t i = 0; i < ty->members.len; i++) {
        const TypeName *name = &ty->members.data[i];
        Type resolved = resolve_name(names, module, name, expanding);
        TypeSlice parts = type_members(&resolved);
        for (size_t j = 0; j < parts.len; j++) {
            Type member = parts.data[j];
            if (member.tag == TYPE_Ptr || member.tag == TYPE_Word) {
                fail(module->path, name->pos,
                    str_format(FMT " cannot be a union member", S(type_name(&member))));
            }
            for (size_t k = 0; k < members.len; k++) {
                if (type_equal(&member, &members.data[k])) {
                    fail(module->path, name->pos,
                        str_format("union members " FMT " and " FMT " overlap",
                            S(type_name(&member)), S(type_name(&member))));
                }
            }
            for (size_t k = 0; k < members.len; k++) {
                if (member.tag == TYPE_List && members.data[k].tag == TYPE_List) {
                    fail(module->path, name->pos, STR("a union can have only one list member"));
                }
            }
            for (size_t k = 0; k < members.len; k++) {
                if (member.tag == TYPE_Dict && members.data[k].tag == TYPE_Dict) {
                    fail(module->path, name->pos, STR("a union can have only one dict member"));
                }
            }
            vec_push(members, member);
        }
    }
    return type_union(members);
}

static Type resolve(const Names *names, const Module *module, const TypeExpr *ty) {
    AliasStack expanding = {0};
    return resolve_in(names, module, ty, &expanding);
}

static ExternType resolve_extern(const Names *names, const Module *module, const TypeExpr *ty) {
    if (ty->members.len == 1 && eq(ty->members.data[0].name, "cint")) {
        return (ExternType){TY(Int), "w"};
    }
    Type t = resolve(names, module, ty);
    switch (t.tag) {
    case TYPE_Int:
    case TYPE_Ptr:
        return (ExternType){t, "l"};
    case TYPE_Float:
        return (ExternType){t, "d"};
    case TYPE_None:
        return (ExternType){t, NULL};
    default:
        fail(module->path, ty->pos,
            STR("extern functions take and return only int, float, ptr, and cint"));
    }
}

static Sig signature(const Names *names, const Module *module, const Func *func, String symbol,
    const Type *receiver) {
    Map seen = {0};
    if (receiver) {
        set_insert(&seen, STR("self"));
    }
    for (size_t i = 0; i < func->params.len; i++) {
        const Param *param = &func->params.data[i];
        if (!set_insert(&seen, param->name)) {
            fail(module->path, param->pos,
                str_format("duplicate parameter '" FMT "'", S(param->name)));
        }
    }
    Sig sig = {.target = {.tag = TARGET_Willow, .as.Willow = symbol}};
    if (receiver) {
        vec_push(sig.params, *receiver);
    }
    for (size_t i = 0; i < func->params.len; i++) {
        Type param = resolve(names, module, &func->params.data[i].ty);
        vec_push(sig.params, param);
    }
    sig.ret = func->ret ? resolve(names, module, func->ret) : TY(None);
    return sig;
}

static Map declare_funcs(const Names *names, const Module *module) {
    Map table = {0};
    for (size_t i = 0; i < module->funcs.len; i++) {
        const Func *func = &module->funcs.data[i];
        Sig sig = {0};
        if (func->body) {
            String symbol = str_format("W." FMT "." FMT, S(module->name), S(func->name));
            sig = signature(names, module, func, symbol, NULL);
        } else {
            if (!eq(module->name, "core")) {
                fail(module->path, func->pos, STR("extern functions are only allowed in core"));
            }
            sig.target.tag = TARGET_Extern;
            sig.target.as.Extern.variadic = func->variadic;
            for (size_t j = 0; j < func->params.len; j++) {
                const Param *param = &func->params.data[j];
                ExternType t = resolve_extern(names, module, &param->ty);
                if (!t.ctype) {
                    fail(module->path, param->ty.pos, STR("an extern parameter cannot be none"));
                }
                vec_push(sig.params, t.ty);
                vec_push(sig.target.as.Extern.cparams, t.ctype);
            }
            ExternType ret =
                func->ret ? resolve_extern(names, module, func->ret) : (ExternType){TY(None), NULL};
            sig.ret = ret.ty;
            sig.target.as.Extern.cret = ret.ctype;
        }
        map_insert(&table, func->name, box_copy(&sig, sizeof(sig)));
    }
    return table;
}

static Type literal_type(const Expr *expr) {
    switch (expr->kind.tag) {
    case EXPR_Int:
        return TY(Int);
    case EXPR_Float:
        return TY(Float);
    case EXPR_Str:
        return TY(Str);
    case EXPR_Bool:
        return TY(Bool);
    case EXPR_Unary:
        return literal_type(expr->kind.as.Unary.operand);
    default:
        return TY(None);
    }
}

static ClassInfo declare_class(const Names *names, const Module *module, const Class *class) {
    const Namespace *namespace = map_get(&names->modules, module->name);
    const TypeDecl *decl = map_get(&namespace->types, class->name);
    assert(decl && decl->tag == DECL_Class);
    ClassInfo info = {.decl = class};
    bool defaulted = false;
    for (size_t i = 0; i < class->fields.len; i++) {
        const Field *field = &class->fields.data[i];
        for (size_t j = 0; j < i; j++) {
            if (str_equal(class->fields.data[j].name, field->name)) {
                fail(module->path, field->pos,
                    str_format("duplicate field '" FMT "'", S(field->name)));
            }
        }
        Type field_ty = resolve(names, module, &field->ty);
        if (field->default_) {
            Type default_ty = literal_type(field->default_);
            if (!type_assignable_to(&default_ty, &field_ty)) {
                fail(module->path, field->default_->pos,
                    str_format("expected " FMT ", received " FMT, S(type_name(&field_ty)),
                        S(type_name(&default_ty))));
            }
            defaulted = true;
        } else if (defaulted) {
            fail(module->path, field->pos,
                str_format("field '" FMT "' without a default follows one with a default",
                    S(field->name)));
        }
        vec_push(info.fields, field_ty);
    }
    for (size_t i = 0; i < class->methods.len; i++) {
        const Func *method = &class->methods.data[i];
        for (size_t j = 0; j < class->fields.len; j++) {
            if (str_equal(class->fields.data[j].name, method->name)) {
                fail(module->path, method->pos,
                    str_format("method '" FMT "' has the same name as a field", S(method->name)));
            }
        }
        if (map_contains(&info.methods, method->name)) {
            fail(module->path, method->pos,
                str_format("duplicate method '" FMT "'", S(method->name)));
        }
        String symbol =
            str_format("W." FMT "." FMT "." FMT, S(module->name), S(class->name), S(method->name));
        Sig sig = signature(names, module, method, symbol, &decl->ty);
        map_insert(&info.methods, method->name, box_copy(&sig, sizeof(sig)));
    }
    return info;
}

static void assigned_names(StmtVec stmts, Map *names) {
    for (size_t i = 0; i < stmts.len; i++) {
        const StmtKind *kind = &stmts.data[i].kind;
        switch (kind->tag) {
        case STMT_Assign:
            set_insert(names, kind->as.Assign.target);
            break;
        case STMT_If:
            for (size_t j = 0; j < kind->as.If.arms.len; j++) {
                assigned_names(kind->as.If.arms.data[j].body, names);
            }
            if (kind->as.If.otherwise) {
                assigned_names(*kind->as.If.otherwise, names);
            }
            break;
        case STMT_While:
            assigned_names(kind->as.While.body, names);
            break;
        case STMT_For:
            for (size_t j = 0; j < kind->as.For.targets.len; j++) {
                set_insert(names, kind->as.For.targets.data[j].name);
            }
            assigned_names(kind->as.For.body, names);
            break;
        case STMT_Expr:
        case STMT_SetField:
        case STMT_SetIndex:
        case STMT_Assert:
        case STMT_Return:
        case STMT_Pass:
        case STMT_Break:
        case STMT_Continue:
            break;
        }
    }
}

static ForItems items(const ForSource *self) {
    ForItems result = {0};
    switch (self->tag) {
    case FOR_Range:
        vec_push(result, (ForItem){0, TY(Int)});
        break;
    case FOR_List:
        vec_push(result, (ForItem){0, self->as.List.element});
        break;
    case FOR_Str:
        vec_push(result, (ForItem){0, TY(Str)});
        break;
    case FOR_Dict:
        if (strcmp(self->as.Dict.part, "keys") == 0) {
            vec_push(result, (ForItem){0, self->as.Dict.key});
        } else if (strcmp(self->as.Dict.part, "values") == 0) {
            vec_push(result, (ForItem){1, self->as.Dict.value});
        } else {
            vec_push(result, (ForItem){0, self->as.Dict.key});
            vec_push(result, (ForItem){1, self->as.Dict.value});
        }
        break;
    }
    return result;
}

static State narrow(const State *state, const Facts *facts) {
    /* State Type values and their children are immutable. Updates allocate
     * a new value, so sharing them across cloned bucket arrays is safe. */
    State result = map_clone(state);
    for (size_t i = 0; i < facts->len; i++) {
        put_type(&result, facts->data[i].name, facts->data[i].ty);
    }
    return result;
}

static State join(const State *a, const State *b) {
    State result = {0};
    /* Iteration only builds a lookup table; it cannot order diagnostics or IR. */
    for (size_t i = 0; i < a->cap; i++) {
        const MapEntry *entry = &a->entries[i];
        if (!entry->occupied) {
            continue;
        }
        const Type *other = map_get(b, entry->key);
        if (other) {
            put_type(&result, entry->key, union_two(*(Type *)entry->value, *other));
        }
    }
    return result;
}

static Value core_call(const char *name, ValueVec args, bool returns) {
    Call call = {.symbol = str_format("W.core.%s", name), .ret = returns ? "l" : NULL};
    for (size_t i = 0; i < args.len; i++) {
        vec_push(call.args, (CallArg){"l", args.data[i]});
    }
    return VAL(Call, call);
}

static Value widen(Value value, const Type *from, const Type *to) {
    String *descriptor = type_box_descriptor(from);
    if (descriptor && type_is_union(to)) {
        return core_call("box", VALUES(VAL(Global, *descriptor), value), true);
    }
    return value;
}

static Value narrowed(Value value, const Type *declared, const Type *current) {
    if (type_is_union(declared) && type_box_descriptor(current)) {
        return core_call("unbox", VALUES(value), true);
    }
    return value;
}

static Function check_function(
    Scope scope, Strings *strings, const Func *func, const Sig *sig, StmtVec body, bool method) {
    Map visible = {0};
    if (method) {
        String self = STR("self");
        map_insert(&visible, self, box_copy(&self, sizeof(self)));
    }
    for (size_t i = 0; i < func->params.len; i++) {
        String param = func->params.data[i].name;
        map_insert(&visible, param, box_copy(&param, sizeof(param)));
    }
    size_t next = 0;
    bind_block(scope.module, body, visible, &next);
    Map names = {0};
    assigned_names(body, &names);
    Checker checker = {.module = scope.module,
        .globals = scope.globals,
        .imported = scope.imported,
        .names = scope.names,
        .intrinsics = eq(scope.module->name, "core"),
        .strings = strings,
        .ret = sig->ret};
    /* These iterations only initialize local lookup slots. */
    for (size_t i = 0; i < names.cap; i++) {
        if (names.entries[i].occupied) {
            map_insert(&checker.locals, names.entries[i].key, box(OptionalType, .some = false));
        }
    }
    State state = {0};
    StringVec params = {0};
    if (method) {
        vec_push(params, STR("self"));
    }
    for (size_t i = 0; i < func->params.len; i++) {
        vec_push(params, func->params.data[i].name);
    }
    for (size_t i = 0; i < params.len; i++) {
        map_insert(&checker.locals, params.data[i],
            box(OptionalType, .some = true, .ty = sig->params.data[i]));
        put_type(&state, params.data[i], sig->params.data[i]);
        set_insert(&checker.params, params.data[i]);
    }
    Block checked = block(&checker, body, &state);
    if (sig->ret.tag != TYPE_None && !checked.transfers) {
        String name = method ? str_format("method '" FMT "." FMT "'",
                                   S(type_name(&sig->params.data[0])), S(func->name))
                             : str_format("function '" FMT "'", S(func->name));
        fail(checker.module->path, func->pos,
            str_format(FMT " must return a value on every path", S(name)));
    }
    assert(sig->target.tag == TARGET_Willow);
    return (Function){.symbol = sig->target.as.Willow,
        .params = params,
        .locals = checker.order,
        .returns = sig->ret.tag != TYPE_None,
        .body = checked.ops};
}

static MethodSignature method_signature(const Type *ty, String name) {
    MethodSignature sig = {0};
    if (ty->tag == TYPE_List) {
        if (eq(name, "append")) {
            sig.function = "list_append";
            vec_push(sig.params, *ty->as.List);
            sig.ret = TY(None);
        } else if (eq(name, "pop")) {
            sig.function = "list_pop";
            sig.ret = *ty->as.List;
        } else if (eq(name, "extend")) {
            sig.function = "list_extend";
            vec_push(sig.params, *ty);
            sig.ret = TY(None);
        } else if (eq(name, "reverse")) {
            sig.function = "list_reverse";
            sig.ret = TY(None);
        }
    } else if (ty->tag == TYPE_Dict && eq(name, "pop")) {
        sig.function = "dict_pop";
        vec_push(sig.params, *ty->as.Dict.key);
        sig.ret = *ty->as.Dict.value;
    } else if (ty->tag == TYPE_Str) {
        sig.ret = TY(Str);
        if (eq(name, "find")) {
            sig.function = "str_find";
            vec_push(sig.params, TY(Str));
            sig.ret = union_two(TY(Int), TY(None));
        } else if (eq(name, "startswith")) {
            sig.function = "str_startswith";
            vec_push(sig.params, TY(Str));
            sig.ret = TY(Bool);
        } else if (eq(name, "endswith")) {
            sig.function = "str_endswith";
            vec_push(sig.params, TY(Str));
            sig.ret = TY(Bool);
        } else if (eq(name, "replace")) {
            sig.function = "str_replace";
            vec_push(sig.params, TY(Str));
            vec_push(sig.params, TY(Str));
        } else if (eq(name, "strip")) {
            sig.function = "str_strip";
        } else if (eq(name, "removeprefix")) {
            sig.function = "str_removeprefix";
            vec_push(sig.params, TY(Str));
        } else if (eq(name, "removesuffix")) {
            sig.function = "str_removesuffix";
            vec_push(sig.params, TY(Str));
        } else if (eq(name, "isdigit")) {
            sig.function = "str_isdigit";
            sig.ret = TY(Bool);
        } else if (eq(name, "isalpha")) {
            sig.function = "str_isalpha";
            sig.ret = TY(Bool);
        } else if (eq(name, "isalnum")) {
            sig.function = "str_isalnum";
            sig.ret = TY(Bool);
        } else if (eq(name, "isspace")) {
            sig.function = "str_isspace";
            sig.ret = TY(Bool);
        } else if (eq(name, "ljust")) {
            sig.function = "str_ljust";
            vec_push(sig.params, TY(Int));
        } else if (eq(name, "rjust")) {
            sig.function = "str_rjust";
            vec_push(sig.params, TY(Int));
        } else if (eq(name, "join")) {
            sig.function = "str_join";
            vec_push(sig.params, list_type(TY(Str)));
        } else if (eq(name, "split")) {
            sig.function = "str_split";
            vec_push(sig.params, union_two(TY(Str), TY(None)));
            vec_push(sig.params, TY(Int));
            vec_push(sig.defaults, 0);
            vec_push(sig.defaults, -1);
            sig.ret = list_type(TY(Str));
        }
    }
    return sig;
}

static String describe(const TypeDecl *decl, String written) {
    switch (decl->tag) {
    case DECL_Class:
        return str_format("class '" FMT "'", S(type_name(&decl->ty)));
    case DECL_Enum:
        return str_format("enum '" FMT "'", S(type_name(&decl->ty)));
    case DECL_Alias:
        return str_format("alias '" FMT "'", S(written));
    }
    abort();
}

static const Expr *root(const Expr *expr) {
    return expr->kind.tag == EXPR_Attr ? root(expr->kind.as.Attr.object) : expr;
}

static Diag *diagnostic(const Checker *self, Pos pos, String message) {
    return box(Diag, .path = self->module->path, .pos = pos, .message = message);
}

static _Noreturn void raise_diag(const Diag *error) {
    fail(error->path, error->pos, error->message);
}

static _Noreturn void module_as_value(const Checker *self, const Expr *expr) {
    const Expr *first = root(expr);
    assert(first->kind.tag == EXPR_Name);
    fail(self->module->path, first->pos,
        str_format("module '" FMT "' cannot be used as a value", S(first->kind.as.Name)));
}

static Ns must_namespace(const Checker *self, const Expr *expr) {
    Ns result = namespace_of(self, expr);
    if (result.tag == NS_Error) {
        raise_diag(result.error);
    }
    return result;
}

static Decl must_decl(const Checker *self, const Expr *expr) {
    Decl result = decl_of(self, expr);
    if (result.tag == D_Error) {
        raise_diag(result.as.error);
    }
    return result;
}

static void expect(const Checker *self, Pos pos, const Type *expected, const Type *actual) {
    if (!type_equal(expected, actual)) {
        fail(self->module->path, pos,
            str_format(
                "expected " FMT ", received " FMT, S(type_name(expected)), S(type_name(actual))));
    }
}

static Value coerce(const Checker *self, Pos pos, Value value, const Type *from, const Type *to) {
    if (!type_assignable_to(from, to)) {
        fail(self->module->path, pos,
            str_format("expected " FMT ", received " FMT, S(type_name(to)), S(type_name(from))));
    }
    return widen(value, from, to);
}

static Block block(Checker *self, StmtVec stmts, State *state) {
    Block result = {0};
    for (size_t i = 0; i < stmts.len; i++) {
        if (result.transfers) {
            fail(self->module->path, stmts.data[i].pos, STR("unreachable statement"));
        }
        result.transfers = statement(self, &stmts.data[i], state, &result.ops);
    }
    return result;
}

static Value condition(Checker *self, const Expr *cond, const State *state) {
    TypedValue checked = expr(self, cond, state);
    expect(self, cond->pos, &TY(Bool), &checked.ty);
    return checked.value;
}

static Op assign(Checker *self, String target, Pos pos, Value value, const Type *ty,
    const Type *annotated, State *state) {
    const OptionalType *local = map_get(&self->locals, target);
    assert(local);
    Type declared;
    if (local->some) {
        declared = local->ty;
    } else {
        declared = annotated ? *annotated : *ty;
        map_insert(&self->locals, target, box(OptionalType, .some = true, .ty = declared));
        vec_push(self->order, target);
    }
    value = coerce(self, pos, value, ty, &declared);
    Type current =
        type_is_union(&declared) && !type_is_union(ty) && ty->tag != TYPE_None ? *ty : declared;
    put_type(state, target, current);
    return OP(Assign, {target, value});
}

static void forget_narrowing(const Checker *self, const Map *assigned, State *state) {
    /* Order has no effect: each name independently replaces a map value. */
    for (size_t i = 0; i < assigned->cap; i++) {
        const MapEntry *entry = &assigned->entries[i];
        if (!entry->occupied) {
            continue;
        }
        const OptionalType *declared = map_get(&self->locals, entry->key);
        if (declared && declared->some && map_contains(state, entry->key)) {
            put_type(state, entry->key, declared->ty);
        }
    }
}

static void arity(const Checker *self, Pos pos, String name, size_t expected, size_t received) {
    if (expected != received) {
        fail(self->module->path, pos,
            str_format(
                "'" FMT "' expects " FMT ", received %zu", S(name), S(count(expected)), received));
    }
}

static ForSource for_source(Checker *self, const Expr *iterable, const State *state) {
    if (iterable->kind.tag == EXPR_Call) {
        const Expr *callee = iterable->kind.as.Call.callee;
        ExprVec arguments = iterable->kind.as.Call.args;
        if (is_builtin(self, callee, "range")) {
            if (arguments.len == 0 || arguments.len > 3) {
                fail(self->module->path, callee->pos,
                    str_format("'range' expects 1 to 3 arguments, received %zu", arguments.len));
            }
            ValueVec bounds = {0};
            for (size_t i = 0; i < arguments.len; i++) {
                TypedValue bound = expr(self, &arguments.data[i], state);
                expect(self, arguments.data[i].pos, &TY(Int), &bound.ty);
                vec_push(bounds, bound.value);
            }
            Value start = bounds.len > 1 ? bounds.data[0] : constant(0);
            Value stop = bounds.len > 1 ? bounds.data[1] : bounds.data[0];
            Value step = bounds.len > 2 ? bounds.data[2] : constant(1);
            return (ForSource){.tag = FOR_Range, .as.Range = {start, stop, step}};
        }
    }
    if (iterable->kind.tag == EXPR_Call) {
        const Expr *callee = iterable->kind.as.Call.callee;
        ExprVec arguments = iterable->kind.as.Call.args;
        if (callee->kind.tag == EXPR_Attr) {
            const Expr *object = callee->kind.as.Attr.object;
            Pos name_pos = callee->kind.as.Attr.name_pos;
            String name = callee->kind.as.Attr.name;
            if ((eq(name, "keys") || eq(name, "values") || eq(name, "items")) &&
                module_of(self, object).tag != NS_Module) {
                TypedValue dict = expr(self, object, state);
                if (dict.ty.tag != TYPE_Dict) {
                    fail(self->module->path, name_pos,
                        str_format("type " FMT " has no method '" FMT "'", S(type_name(&dict.ty)),
                            S(name)));
                }
                arity(self, name_pos, name, 0, arguments.len);
                const char *part = eq(name, "keys")     ? "keys"
                                   : eq(name, "values") ? "values"
                                                        : "items";
                return (ForSource){.tag = FOR_Dict,
                    .as.Dict = {dict.value, *dict.ty.as.Dict.key, *dict.ty.as.Dict.value, part}};
            }
        }
    }
    TypedValue value = expr(self, iterable, state);
    switch (value.ty.tag) {
    case TYPE_List:
        return (ForSource){.tag = FOR_List, .as.List = {value.value, *value.ty.as.List}};
    case TYPE_Str:
        return (ForSource){.tag = FOR_Str, .as.Str = value.value};
    case TYPE_Dict:
        return (ForSource){.tag = FOR_Dict,
            .as.Dict = {value.value, *value.ty.as.Dict.key, *value.ty.as.Dict.value, "keys"}};
    default:
        fail(self->module->path, iterable->pos,
            str_format("cannot iterate over " FMT, S(type_name(&value.ty))));
    }
}

static TypedValue list_display(
    Checker *self, ExprVec items, Pos pos, const State *state, const Type *expected) {
    ValueVec values = {0};
    const Type *expected_element = expected ? type_list_element(expected) : NULL;
    Type element;
    if (expected_element) {
        element = *expected_element;
    } else {
        if (!items.len) {
            fail(self->module->path, pos, STR("cannot infer the element type of an empty list"));
        }
        TypedValue first = expr(self, &items.data[0], state);
        vec_push(values, first.value);
        element = first.ty;
    }
    for (size_t i = values.len; i < items.len; i++) {
        const Expr *item = &items.data[i];
        TypedValue checked = expr_expect(self, item, state, &element);
        Value value = coerce(self, item->pos, checked.value, &checked.ty, &element);
        vec_push(values, value);
    }
    return typed(VAL(ListDisplay, values), list_type(element));
}

static TypedValue dict_display(
    Checker *self, ExprEntryVec entries, Pos pos, const State *state, const Type *expected) {
    ValueEntryVec values = {0};
    TypeRefs expected_entry = expected ? type_dict_entry(expected) : (TypeRefs){0};
    Type key, value;
    if (expected_entry.key) {
        key = *expected_entry.key;
        value = *expected_entry.value;
    } else {
        if (!entries.len) {
            fail(self->module->path, pos,
                STR("cannot infer the key and value types of an empty dict"));
        }
        const ExprEntry *first = &entries.data[0];
        TypedValue k = expr(self, &first->key, state);
        TypedValue v = expr(self, &first->value, state);
        if (!is_key_type(&k.ty)) {
            fail(self->module->path, first->key.pos,
                STR("dictionary keys must be int, str, or an enum"));
        }
        vec_push(values, (ValueEntry){k.value, v.value});
        key = k.ty;
        value = v.ty;
    }
    for (size_t i = values.len; i < entries.len; i++) {
        const ExprEntry *entry = &entries.data[i];
        TypedValue k = expr(self, &entry->key, state);
        Value key_ir = coerce(self, entry->key.pos, k.value, &k.ty, &key);
        TypedValue v = expr_expect(self, &entry->value, state, &value);
        Value value_ir = coerce(self, entry->value.pos, v.value, &v.ty, &value);
        vec_push(values, (ValueEntry){key_ir, value_ir});
    }
    return typed(VAL(DictDisplay, {type_equality_kind(&key), values}), dict_type(key, value));
}

static TypedValue expr_expect(
    Checker *self, const Expr *expression, const State *state, const Type *expected) {
    switch (expression->kind.tag) {
    case EXPR_List:
        return list_display(self, expression->kind.as.List, expression->pos, state, expected);
    case EXPR_Dict:
        return dict_display(self, expression->kind.as.Dict, expression->pos, state, expected);
    default:
        return expr(self, expression, state);
    }
}

static const Type *narrowable(const Expr *expression, const State *state) {
    return expression->kind.tag == EXPR_Name ? map_get(state, expression->kind.as.Name) : NULL;
}

static FactPair facts(const Checker *self, const Expr *cond, const State *state) {
    FactPair result = {0};
    const ExprKind *kind = &cond->kind;
    switch (kind->tag) {
    case EXPR_TypeTest: {
        const Expr *operand = kind->as.TypeTest.operand;
        const Type *ty = narrowable(operand, state);
        if (kind->as.TypeTest.target) {
            if (!ty || !type_is_union(ty)) {
                return result;
            }
            TestedType tested = tested_type(self, kind->as.TypeTest.target, ty);
            if (tested.error || !tested.some || !tested.member) {
                return result;
            }
            String name = operand->kind.as.Name;
            vec_push(result.yes, (Fact){name, *tested.member});
            Type other = type_without(ty, tested.member);
            if (type_members(&other).len) {
                vec_push(result.no, (Fact){name, other});
            }
            if (kind->as.TypeTest.negated) {
                return (FactPair){result.no, result.yes};
            }
            return result;
        }
        if (!ty || !type_is_optional(ty)) {
            return result;
        }
        Fact some = {operand->kind.as.Name, type_without(ty, &TY(None))};
        Fact absent = {operand->kind.as.Name, TY(None)};
        if (kind->as.TypeTest.negated) {
            vec_push(result.yes, some);
            vec_push(result.no, absent);
        } else {
            vec_push(result.yes, absent);
            vec_push(result.no, some);
        }
        return result;
    }
    case EXPR_Unary:
        if (strcmp(kind->as.Unary.op, "not") == 0) {
            FactPair inner = facts(self, kind->as.Unary.operand, state);
            return (FactPair){inner.no, inner.yes};
        }
        return result;
    case EXPR_Binary:
        if (strcmp(kind->as.Binary.op, "and") == 0 || strcmp(kind->as.Binary.op, "or") == 0) {
            bool and = strcmp(kind->as.Binary.op, "and") == 0;
            FactPair left = facts(self, kind->as.Binary.left, state);
            Facts selected = and ? left.yes : left.no;
            State narrowed_state = narrow(state, &selected);
            FactPair right = facts(self, kind->as.Binary.right, &narrowed_state);
            Facts more = and ? right.yes : right.no;
            for (size_t i = 0; i < more.len; i++) {
                vec_push(selected, more.data[i]);
            }
            if (and) {
                result.yes = selected;
            } else {
                result.no = selected;
            }
        }
        return result;
    default:
        return result;
    }
}

static bool is_builtin(const Checker *self, const Expr *callee, const char *name) {
    return callee->kind.tag == EXPR_Name && eq(callee->kind.as.Name, name) &&
           !map_contains(&self->locals, callee->kind.as.Name);
}

typedef struct LoweredArm {
    Value cond;
    OpVec body;
    int os_test;
} LoweredArm;

VEC_DECL(LoweredArm, LoweredArms);

static void merge_branch(
    State branch, bool transfers, State *after, bool *has_after, bool *all_transfer) {
    if (!transfers) {
        *all_transfer = false;
        *after = *has_after ? join(after, &branch) : branch;
        *has_after = true;
    }
}

static bool statement(Checker *self, const Stmt *stmt, State *state, OpVec *ops) {
    const StmtKind *kind = &stmt->kind;
    switch (kind->tag) {
    case STMT_Assign: {
        String target = kind->as.Assign.target;
        const TypeExpr *annotation = kind->as.Assign.annotation;
        const Expr *value = kind->as.Assign.value;
        const OptionalType *local = map_get(&self->locals, target);
        assert(local);
        Type annotated = annotation ? resolve(self->names, self->module, annotation) : TY(None);
        if (annotation) {
            map_insert(&self->locals, target, box(OptionalType, .some = true, .ty = annotated));
            vec_push(self->order, target);
        }
        if (!value) {
            return false;
        }
        const Type *expected = annotation ? &annotated : local->some ? &local->ty : NULL;
        TypedValue checked = expr_expect(self, value, state, expected);
        Op op = assign(self, target, value->pos, checked.value, &checked.ty,
            annotation ? &annotated : NULL, state);
        vec_push(*ops, op);
        return false;
    }
    case STMT_SetField: {
        const Expr *object = &kind->as.SetField.object;
        Pos name_pos = kind->as.SetField.name_pos;
        String name = kind->as.SetField.name;
        const Expr *value = &kind->as.SetField.value;
        Decl decl = must_decl(self, object);
        if (decl.tag == D_Type && decl.as.type->tag == DECL_Enum) {
            fail(self->module->path, name_pos,
                str_format("cannot assign to a member of enum '" FMT "'",
                    S(type_name(&decl.as.type->ty))));
        }
        TypedValue obj = expr(self, object, state);
        FieldType field_ty = field(self, &obj.ty, name_pos, name);
        TypedValue val = expr_expect(self, value, state, &field_ty.ty);
        Value value_ir = coerce(self, value->pos, val.value, &val.ty, &field_ty.ty);
        vec_push(*ops, OP(SetField, {obj.value, field_ty.offset, value_ir}));
        return false;
    }
    case STMT_SetIndex: {
        const Expr *object = &kind->as.SetIndex.object;
        const Expr *index = &kind->as.SetIndex.index;
        const Expr *value = &kind->as.SetIndex.value;
        TypedValue obj = expr(self, object, state);
        Type index_type;
        const Type *element;
        const char *function;
        switch (obj.ty.tag) {
        case TYPE_List:
            index_type = TY(Int);
            element = obj.ty.as.List;
            function = "W.core.list_set";
            break;
        case TYPE_Dict:
            index_type = *obj.ty.as.Dict.key;
            element = obj.ty.as.Dict.value;
            function = "W.core.dict_set";
            break;
        default:
            fail(self->module->path, kind->as.SetIndex.bracket,
                str_format(
                    "cannot assign to an index of a value of type " FMT, S(type_name(&obj.ty))));
        }
        TypedValue idx = expr(self, index, state);
        Value index_ir = coerce(self, index->pos, idx.value, &idx.ty, &index_type);
        TypedValue val = expr_expect(self, value, state, element);
        Value value_ir = coerce(self, value->pos, val.value, &val.ty, element);
        vec_push(*ops, OP(SetItem, {function, obj.value, index_ir, value_ir}));
        return false;
    }
    case STMT_For: {
        PosNameVec targets = kind->as.For.targets;
        Map assigned = {0};
        assigned_names(kind->as.For.body, &assigned);
        for (size_t i = 0; i < targets.len; i++) {
            set_insert(&assigned, targets.data[i].name);
        }
        forget_narrowing(self, &assigned, state);
        ForSource source = for_source(self, &kind->as.For.iterable, state);
        ForItems source_items = items(&source);
        if (targets.len != source_items.len) {
            String message = source_items.len == 1
                                 ? str_format("cannot unpack a value of type " FMT,
                                       S(type_name(&source_items.data[0].ty)))
                                 : STR("'items' gives a key and a value, so it needs two targets");
            fail(self->module->path, targets.data[0].pos, message);
        }
        if (targets.len == 2 && str_equal(targets.data[0].name, targets.data[1].name)) {
            fail(self->module->path, targets.data[1].pos,
                str_format("duplicate target '" FMT "'", S(targets.data[1].name)));
        }
        State body_state = map_clone(state);
        OpVec stores = {0};
        for (size_t i = 0; i < targets.len; i++) {
            Op store = assign(self, targets.data[i].name, stmt->pos,
                VAL(Item, source_items.data[i].slot), &source_items.data[i].ty, NULL, &body_state);
            vec_push(stores, store);
        }
        self->loops++;
        Block checked = block(self, kind->as.For.body, &body_state);
        self->loops--;
        Op op;
        switch (source.tag) {
        case FOR_Range: {
            Value message = intern(self->strings, STR("range step must not be zero"));
            Value fail = fail_call(self, "ValueError", message);
            op = OP(ForRange, {source.as.Range.start, source.as.Range.stop, source.as.Range.step,
                                  fail, stores, checked.ops});
            break;
        }
        case FOR_List:
            op = OP(ForList, {source.as.List.value, stores, checked.ops});
            break;
        case FOR_Str:
            op = OP(ForStr, {source.as.Str, stores, checked.ops});
            break;
        case FOR_Dict:
            op = OP(ForDict, {source.as.Dict.dict, stores, checked.ops});
            break;
        default:
            abort();
        }
        vec_push(*ops, op);
        return false;
    }
    case STMT_Expr: {
        TypedValue checked = expr(self, &kind->as.Expr, state);
        vec_push(*ops, OP(Eval, checked.value));
        return is_sys_exit(self, &kind->as.Expr);
    }
    case STMT_Assert: {
        const Expr *cond = &kind->as.Assert.cond;
        Value cond_ir = condition(self, cond, state);
        FactPair known = facts(self, cond, state);
        Value message_ir;
        if (kind->as.Assert.message) {
            const Expr *message = kind->as.Assert.message;
            State no = narrow(state, &known.no);
            TypedValue checked = expr(self, message, &no);
            expect(self, message->pos, &TY(Str), &checked.ty);
            message_ir = checked.value;
        } else {
            message_ir = intern(self->strings, STR("assertion failed"));
        }
        Value fail = fail_call(self, "AssertionError", message_ir);
        OpVec otherwise = {0};
        vec_push(otherwise, OP(Eval, fail));
        vec_push(*ops, OP(If, {.cond = cond_ir, .otherwise = otherwise}));
        *state = narrow(state, &known.yes);
        return false;
    }
    case STMT_If: {
        State after = {0};
        bool has_after = false, all_transfer = true;
        State base = map_clone(state);
        LoweredArms lowered = {0};
        for (size_t i = 0; i < kind->as.If.arms.len; i++) {
            const IfArm *arm = &kind->as.If.arms.data[i];
            Value cond_ir = condition(self, &arm->cond, &base);
            FactPair known = facts(self, &arm->cond, &base);
            State branch = narrow(&base, &known.yes);
            Block checked = block(self, arm->body, &branch);
            merge_branch(branch, checked.transfers, &after, &has_after, &all_transfer);
            vec_push(lowered, (LoweredArm){cond_ir, checked.ops, os_test(self, &arm->cond)});
            base = narrow(&base, &known.no);
        }
        OpVec tail = {0};
        if (kind->as.If.otherwise) {
            Block checked = block(self, *kind->as.If.otherwise, &base);
            merge_branch(base, checked.transfers, &after, &has_after, &all_transfer);
            tail = checked.ops;
        } else {
            merge_branch(base, false, &after, &has_after, &all_transfer);
        }
        while (lowered.len) {
            LoweredArm arm = lowered.data[--lowered.len];
            if (arm.os_test == 1) {
                tail = arm.body;
            } else if (arm.os_test == -1) {
                OpVec nested = {0};
                vec_push(nested, OP(If, {arm.cond, arm.body, tail}));
                tail = nested;
            }
        }
        for (size_t i = 0; i < tail.len; i++) {
            vec_push(*ops, tail.data[i]);
        }
        if (has_after) {
            *state = after;
        }
        return all_transfer;
    }
    case STMT_While: {
        Map assigned = {0};
        assigned_names(kind->as.While.body, &assigned);
        forget_narrowing(self, &assigned, state);
        Value cond_ir = condition(self, &kind->as.While.cond, state);
        FactPair known = facts(self, &kind->as.While.cond, state);
        self->loops++;
        State body_state = narrow(state, &known.yes);
        Block checked = block(self, kind->as.While.body, &body_state);
        self->loops--;
        vec_push(*ops, OP(While, {cond_ir, checked.ops}));
        return false;
    }
    case STMT_Return: {
        Type ret = self->ret;
        Value *value_ir = NULL;
        if (kind->as.Return) {
            const Expr *value = kind->as.Return;
            TypedValue checked = expr_expect(self, value, state, &ret);
            Value coerced = coerce(self, value->pos, checked.value, &checked.ty, &ret);
            value_ir = box_copy(&coerced, sizeof(coerced));
        } else {
            coerce(self, stmt->pos, constant(0), &TY(None), &ret);
        }
        if (value_ir && self->ret.tag == TYPE_None) {
            vec_push(*ops, OP(Eval, *value_ir));
            vec_push(*ops, OP(Return, NULL));
        } else {
            vec_push(*ops, OP(Return, value_ir));
        }
        return true;
    }
    case STMT_Pass:
        return false;
    case STMT_Break:
    case STMT_Continue: {
        bool is_break = kind->tag == STMT_Break;
        if (!self->loops) {
            fail(self->module->path, stmt->pos,
                str_format("'%s' outside of a loop", is_break ? "break" : "continue"));
        }
        vec_push(*ops, (Op){.tag = is_break ? OP_Break : OP_Continue});
        return true;
    }
    }
    abort();
}

static TypedValue expr(Checker *self, const Expr *expression, const State *state) {
    const ExprKind *kind = &expression->kind;
    switch (kind->tag) {
    case EXPR_Int:
        return typed(constant(kind->as.Int), TY(Int));
    case EXPR_Float: {
        int64_t bits;
        memcpy(&bits, &kind->as.Float, sizeof(bits));
        return typed(constant(bits), TY(Float));
    }
    case EXPR_Bool:
        return typed(constant(kind->as.Bool), TY(Bool));
    case EXPR_None:
        return typed(constant(0), TY(None));
    case EXPR_TypeTest: {
        if (kind->as.TypeTest.target) {
            TypedValue tested = type_test(self, kind->as.TypeTest.operand, kind->as.TypeTest.target, state);
            if (kind->as.TypeTest.negated) {
                tested.value = binary_value("ceql", tested.value, constant(0));
            }
            return tested;
        }
        TypedValue checked = expr(self, kind->as.TypeTest.operand, state);
        if (!type_is_optional(&checked.ty) && checked.ty.tag != TYPE_None) {
            fail(self->module->path, kind->as.TypeTest.op_pos,
                str_format("operator '%s' cannot be applied to " FMT,
                    kind->as.TypeTest.negated ? "is not" : "is", S(type_name(&checked.ty))));
        }
        const char *instr = kind->as.TypeTest.negated ? "cnel" : "ceql";
        return typed(binary_value(instr, checked.value, constant(0)), TY(Bool));
    }
    case EXPR_Str:
        return typed(intern(self->strings, kind->as.Str), TY(Str));
    case EXPR_FStr: {
        Value text = {0};
        bool has_text = false;
        for (size_t i = 0; i < kind->as.FStr.len; i++) {
            const Expr *part = &kind->as.FStr.data[i];
            TypedValue checked = expr(self, part, state);
            Value value;
            if (!to_str(self, checked.value, &checked.ty, &value)) {
                fail(self->module->path, part->pos,
                    str_format("cannot format a value of type " FMT, S(type_name(&checked.ty))));
            }
            text = has_text ? core_call("str_concat", VALUES(text, value), true) : value;
            has_text = true;
        }
        if (!has_text) {
            text = intern(self->strings, STR(""));
        }
        return typed(text, TY(Str));
    }
    case EXPR_Name: {
        String name = kind->as.Name;
        const OptionalType *declared = map_get(&self->locals, name);
        if (declared) {
            const Type *current = map_get(state, name);
            if (!declared->some || !current) {
                fail(self->module->path, expression->pos,
                    str_format("variable '" FMT "' may be used before assignment", S(source_name(name))));
            }
            Value value = narrowed(VAL(Local, name), &declared->ty, current);
            return typed(value, *current);
        }
        if (eq(name, "self")) {
            fail(self->module->path, expression->pos, STR("'self' is only available inside methods"));
        }
        if (is_intrinsic(name) && !self->intrinsics) {
            fail(self->module->path, expression->pos,
                str_format("intrinsic '" FMT "' is only available in core", S(name)));
        }
        if (eq(name, "__os")) {
            return typed(intern(self->strings, str_from_cstr(target_os())), TY(Str));
        }
        const TypeDecl *decl = map_get(&self->globals->types, name);
        if (decl) {
            fail(self->module->path, expression->pos,
                str_format(FMT " cannot be used as a value", S(describe(decl, name))));
        }
        if (must_namespace(self, expression).tag != NS_None) {
            fail(self->module->path, expression->pos,
                str_format("module '" FMT "' cannot be used as a value", S(name)));
        }
        if (map_contains(&self->globals->funcs, name) || LISTED(name, BUILTINS) ||
            is_intrinsic(name)) {
            fail(self->module->path, expression->pos,
                str_format("cannot use function '" FMT "' as a value", S(name)));
        }
        fail(self->module->path, expression->pos, str_format("unknown name '" FMT "'", S(name)));
    }
    case EXPR_Call:
        return call(self, kind->as.Call.callee, kind->as.Call.args, state);
    case EXPR_List:
        return list_display(self, kind->as.List, expression->pos, state, NULL);
    case EXPR_Dict:
        return dict_display(self, kind->as.Dict, expression->pos, state, NULL);
    case EXPR_Index: {
        const Expr *index = kind->as.Index.index;
        TypedValue object = expr(self, kind->as.Index.object, state);
        TypedValue idx = expr(self, index, state);
        if (object.ty.tag == TYPE_Dict) {
            Value key_ir = coerce(self, index->pos, idx.value, &idx.ty, object.ty.as.Dict.key);
            return typed(core_call("dict_get", VALUES(object.value, key_ir), true),
                *object.ty.as.Dict.value);
        }
        expect(self, index->pos, &TY(Int), &idx.ty);
        if (object.ty.tag == TYPE_List) {
            return typed(
                core_call("list_get", VALUES(object.value, idx.value), true), *object.ty.as.List);
        }
        if (object.ty.tag == TYPE_Str) {
            return typed(core_call("str_index", VALUES(object.value, idx.value), true), TY(Str));
        }
        fail(self->module->path, expression->pos,
            str_format("cannot index a value of type " FMT, S(type_name(&object.ty))));
    }
    case EXPR_Slice: {
        TypedValue object = expr(self, kind->as.Slice.object, state);
        ValueVec bounds = {0};
        vec_push(bounds, object.value);
        const Expr *bound_exprs[] = {kind->as.Slice.start, kind->as.Slice.stop};
        int64_t omitted[] = {0, INT64_MAX};
        for (size_t i = 0; i < 2; i++) {
            if (bound_exprs[i]) {
                TypedValue bound = expr(self, bound_exprs[i], state);
                expect(self, bound_exprs[i]->pos, &TY(Int), &bound.ty);
                vec_push(bounds, bound.value);
            } else {
                vec_push(bounds, constant(omitted[i]));
            }
        }
        const char *function;
        switch (object.ty.tag) {
        case TYPE_List:
            function = "list_slice";
            break;
        case TYPE_Str:
            function = "str_slice";
            break;
        default:
            fail(self->module->path, expression->pos,
                str_format("cannot slice a value of type " FMT, S(type_name(&object.ty))));
        }
        return typed(core_call(function, bounds, true), object.ty);
    }
    case EXPR_Attr: {
        const Expr *object = kind->as.Attr.object;
        Pos name_pos = kind->as.Attr.name_pos;
        String name = kind->as.Attr.name;
        if (must_namespace(self, expression).tag != NS_None) {
            module_as_value(self, expression);
        }
        Decl decl = must_decl(self, expression);
        if (decl.tag == D_Func) {
            fail(self->module->path, expression->pos,
                str_format("cannot use function '" FMT "' as a value", S(decl.written)));
        }
        if (decl.tag == D_Type) {
            fail(self->module->path, name_pos,
                str_format(
                    FMT " cannot be used as a value", S(describe(decl.as.type, decl.written))));
        }
        Ns module = module_of(self, object);
        if (module.tag == NS_Module) {
            fail(self->module->path, expression->pos,
                str_format(
                    "cannot use function '" FMT "." FMT "' as a value", S(module.name), S(name)));
        }
        decl = must_decl(self, object);
        if (decl.tag == D_Type && decl.as.type->tag == DECL_Enum) {
            const Type *ty = &decl.as.type->ty;
            assert(ty->tag == TYPE_Enum);
            const PosNameVec *members = map_get(&self->names->enums, ty->as.Enum.symbol);
            for (size_t i = 0; i < members->len; i++) {
                if (str_equal(members->data[i].name, name)) {
                    return typed(constant((int64_t)i), *ty);
                }
            }
            fail(self->module->path, name_pos,
                str_format("enum '" FMT "' has no member '" FMT "'", S(type_name(ty)), S(name)));
        }
        TypedValue obj = expr(self, object, state);
        FieldType member = field(self, &obj.ty, name_pos, name);
        Value offset = constant(member.offset);
        return typed(VAL(Load, {"loadl", box_copy(&obj.value, sizeof(Value)),
                                   box_copy(&offset, sizeof(offset))}),
            member.ty);
    }
    case EXPR_TypeOf: {
        const TypeName *ty = &kind->as.TypeOf;
        if (!self->intrinsics) {
            fail(self->module->path, expression->pos,
                STR("intrinsic '__type' is only available in core"));
        }
        if (!LISTED(ty->name, BUILTIN_TYPES)) {
            fail(self->module->path, ty->pos,
                STR("'__type' takes int, float, bool, str, bytes, list, dict, or tuple"));
        }
        return typed(VAL(Global, str_format("W." FMT ".type", S(ty->name))), TY(Ptr));
    }
    case EXPR_Unary: {
        const char *op = kind->as.Unary.op;
        TypedValue checked = expr(self, kind->as.Unary.operand, state);
        if (strcmp(op, "+") == 0 && (checked.ty.tag == TYPE_Int || checked.ty.tag == TYPE_Float)) {
            return checked;
        }
        if (strcmp(op, "-") == 0 && checked.ty.tag == TYPE_Int) {
            return typed(binary_value("sub", constant(0), checked.value), TY(Int));
        }
        if (strcmp(op, "~") == 0 && checked.ty.tag == TYPE_Int) {
            Value message = intern(self->strings, STR("integer overflow"));
            Value fail = fail_call(self, "OverflowError", message);
            Value *left = box_copy(&checked.value, sizeof(Value));
            Value right = constant(-1);
            return typed(VAL(CheckedInt, {"xor", left, box_copy(&right, sizeof(right)), box_copy(&fail, sizeof(fail))}), TY(Int));
        }
        if (strcmp(op, "-") == 0 && checked.ty.tag == TYPE_Float) {
            return typed(VAL(FloatNeg, box_copy(&checked.value, sizeof(Value))), TY(Float));
        }
        if (strcmp(op, "not") == 0 && checked.ty.tag == TYPE_Bool) {
            return typed(binary_value("ceql", checked.value, constant(0)), TY(Bool));
        }
        fail(self->module->path, expression->pos,
            str_format("operator '%s' cannot be applied to " FMT, op, S(type_name(&checked.ty))));
    }
    case EXPR_Binary: {
        const char *op = kind->as.Binary.op;
        TypedValue left = expr(self, kind->as.Binary.left, state);
        State right_state;
        if (strcmp(op, "and") == 0 || strcmp(op, "or") == 0) {
            FactPair known = facts(self, kind->as.Binary.left, state);
            right_state = narrow(state, strcmp(op, "and") == 0 ? &known.yes : &known.no);
        } else {
            right_state = map_clone(state);
        }
        TypedValue right = expr(self, kind->as.Binary.right, &right_state);
        return binary(self, op, kind->as.Binary.op_pos, left.value, left.ty, right.value, right.ty);
    }
    }
    abort();
}

static TypedValue contains(Checker *self, const char *op, Pos pos, Value item, const Type *item_ty,
    Value container, const Type *container_ty) {
    Value found = {.tag = VALUE_In};
    switch (container_ty->tag) {
    case TYPE_List: {
        const Type *element = container_ty->as.List;
        if (!type_is_comparable(element) || !type_assignable_to(item_ty, element)) {
            goto invalid;
        }
        found.as.In.function = "W.core.list_contains";
        Value widened = widen(item, item_ty, element);
        found.as.In.item = box_copy(&widened, sizeof(widened));
        found.as.In.container = box_copy(&container, sizeof(container));
        vec_push(found.as.In.extra, constant(type_equality_kind(element)));
        break;
    }
    case TYPE_Dict:
        if (!type_assignable_to(item_ty, container_ty->as.Dict.key)) {
            goto invalid;
        }
        found.as.In.function = "W.core.dict_contains";
        found.as.In.item = box_copy(&item, sizeof(item));
        found.as.In.container = box_copy(&container, sizeof(container));
        break;
    case TYPE_Str:
        if (item_ty->tag != TYPE_Str) {
            goto invalid;
        }
        found.as.In.function = "W.core.str_contains";
        found.as.In.item = box_copy(&item, sizeof(item));
        found.as.In.container = box_copy(&container, sizeof(container));
        break;
    default:
        goto invalid;
    }
    if (strcmp(op, "in") == 0) {
        return typed(found, TY(Bool));
    }
    return typed(binary_value("ceql", found, constant(0)), TY(Bool));
invalid:
    fail(self->module->path, pos,
        str_format("operator '%s' cannot be applied to " FMT " and " FMT, op, S(type_name(item_ty)),
            S(type_name(container_ty))));
}

static TypedValue binary(
    Checker *self, const char *op, Pos pos, Value l, Type lt, Value r, Type rt) {
    const char *compare = strcmp(op, "==") == 0   ? "ceql"
                          : strcmp(op, "!=") == 0 ? "cnel"
                          : strcmp(op, "<") == 0  ? "csltl"
                          : strcmp(op, "<=") == 0 ? "cslel"
                          : strcmp(op, ">") == 0  ? "csgtl"
                          : strcmp(op, ">=") == 0 ? "csgel"
                                                  : "";
    const char *float_op = strcmp(op, "+") == 0   ? "add"
                           : strcmp(op, "-") == 0 ? "sub"
                           : strcmp(op, "*") == 0 ? "mul"
                                                  : "";
    const char *float_compare = strcmp(op, "==") == 0   ? "ceqd"
                                : strcmp(op, "!=") == 0 ? "cned"
                                : strcmp(op, "<") == 0  ? "cltd"
                                : strcmp(op, "<=") == 0 ? "cled"
                                : strcmp(op, ">") == 0  ? "cgtd"
                                : strcmp(op, ">=") == 0 ? "cged"
                                                        : "";
    if (strcmp(op, "in") == 0 || strcmp(op, "not in") == 0) {
        return contains(self, op, pos, l, &lt, r, &rt);
    }
    bool equality = strcmp(op, "==") == 0 || strcmp(op, "!=") == 0;
    if (equality && (lt.tag == TYPE_None || rt.tag == TYPE_None)) {
        fail(self->module->path, pos,
            str_format("operator '%s' cannot take a none operand; use 'is none'", op));
    }
    if (equality &&
        (type_is_union(&lt) || lt.tag == TYPE_None || type_is_union(&rt) || rt.tag == TYPE_None) &&
        type_is_comparable(&lt) && type_is_comparable(&rt)) {
        Type target;
        if (type_assignable_to(&lt, &rt)) {
            target = rt;
        } else if (type_assignable_to(&rt, &lt)) {
            target = lt;
        } else {
            goto invalid;
        }
        Value left = widen(l, &lt, &target), right = widen(r, &rt, &target);
        Value equal = core_call("union_eq", VALUES(left, right), true);
        return typed(
            strcmp(op, "==") == 0 ? equal : binary_value("ceql", equal, constant(0)), TY(Bool));
    }
    Value *left = box_copy(&l, sizeof(l)), *right = box_copy(&r, sizeof(r));
    if ((strcmp(op, "and") == 0 || strcmp(op, "or") == 0) && lt.tag == TYPE_Bool &&
        rt.tag == TYPE_Bool) {
        return typed(VAL(Logic, {strcmp(op, "and") == 0, left, right}), TY(Bool));
    }
    if (lt.tag == TYPE_Int && rt.tag == TYPE_Int &&
        (strcmp(op, "&") == 0 || strcmp(op, "|") == 0 || strcmp(op, "^") == 0 ||
         strcmp(op, "<<") == 0 || strcmp(op, ">>") == 0)) {
        Value message = intern(self->strings, STR("integer overflow"));
        Value fail = fail_call(self, "OverflowError", message);
        if (strcmp(op, "<<") == 0 || strcmp(op, ">>") == 0) {
            Value negative = fail_call(self, "ValueError", intern(self->strings, STR("negative shift count")));
            return typed(VAL(Shift, {strcmp(op, ">>") == 0, left, right,
                box_copy(&negative, sizeof(negative)), box_copy(&fail, sizeof(fail))}), TY(Int));
        }
        const char *instr = strcmp(op, "&") == 0 ? "and" : strcmp(op, "|") == 0 ? "or" : "xor";
        return typed(VAL(CheckedInt, {instr, left, right, box_copy(&fail, sizeof(fail))}), TY(Int));
    }
    if ((strcmp(op, "//") == 0 || strcmp(op, "%") == 0) && lt.tag == TYPE_Int &&
        rt.tag == TYPE_Int) {
        Value message = intern(self->strings, STR("division by zero"));
        Value fail = fail_call(self, "ZeroDivisionError", message);
        return typed(
            VAL(FloorDivide, {strcmp(op, "%") == 0, left, right, box_copy(&fail, sizeof(fail))}),
            TY(Int));
    }
    if ((strcmp(op, "//") == 0 || strcmp(op, "%") == 0) && lt.tag == TYPE_Float &&
        rt.tag == TYPE_Float) {
        return typed(
            core_call(strcmp(op, "%") == 0 ? "float_mod" : "float_floordiv", VALUES(l, r), true),
            TY(Float));
    }
    if (strcmp(op, "/") == 0 && ((lt.tag == TYPE_Int && rt.tag == TYPE_Int) ||
                                    (lt.tag == TYPE_Float && rt.tag == TYPE_Float))) {
        Value message = intern(self->strings, STR("division by zero"));
        Value fail = fail_call(self, "ZeroDivisionError", message);
        return typed(VAL(Divide, {lt.tag == TYPE_Int, left, right, box_copy(&fail, sizeof(fail))}),
            TY(Float));
    }
    if (lt.tag == TYPE_Float && rt.tag == TYPE_Float && *float_op) {
        return typed(VAL(FloatBinary, {float_op, left, right}), TY(Float));
    }
    if (lt.tag == TYPE_Float && rt.tag == TYPE_Float && *float_compare) {
        return typed(VAL(FloatCompare, {float_compare, left, right}), TY(Bool));
    }
    if (*float_op && lt.tag == TYPE_Int && rt.tag == TYPE_Int) {
        Value message = intern(self->strings, STR("integer overflow"));
        Value fail = fail_call(self, "OverflowError", message);
        return typed(
            VAL(CheckedInt, {float_op, left, right, box_copy(&fail, sizeof(fail))}), TY(Int));
    }
    if ((lt.tag == TYPE_Int && rt.tag == TYPE_Int && *compare) ||
        (equality && ((lt.tag == TYPE_Bool && rt.tag == TYPE_Bool) ||
                         (lt.tag == TYPE_Ptr && rt.tag == TYPE_Ptr))) ||
        (equality && lt.tag == TYPE_Enum && rt.tag == TYPE_Enum &&
            named_compare(&lt.as.Enum, &rt.as.Enum) == 0)) {
        return typed(VAL(Binary, {compare, left, right}), TY(Bool));
    }
    if (strcmp(op, "+") == 0 && lt.tag == TYPE_Str && rt.tag == TYPE_Str) {
        return typed(core_call("str_concat", VALUES(l, r), true), TY(Str));
    }
    if (lt.tag == TYPE_Str && rt.tag == TYPE_Str && *compare) {
        Value order = core_call("str_compare", VALUES(l, r), true);
        return typed(binary_value(compare, order, constant(0)), TY(Bool));
    }
invalid:
    fail(self->module->path, pos,
        str_format("operator '%s' cannot be applied to " FMT " and " FMT, op, S(type_name(&lt)),
            S(type_name(&rt))));
}

static int os_test(const Checker *self, const Expr *cond) {
    if (cond->kind.tag != EXPR_Binary) {
        return -1;
    }
    const char *op = cond->kind.as.Binary.op;
    if (strcmp(op, "==") != 0 && strcmp(op, "!=") != 0) {
        return -1;
    }
    const Expr *left = cond->kind.as.Binary.left, *right = cond->kind.as.Binary.right;
    String name, text;
    if (left->kind.tag == EXPR_Name && right->kind.tag == EXPR_Str) {
        name = left->kind.as.Name;
        text = right->kind.as.Str;
    } else if (left->kind.tag == EXPR_Str && right->kind.tag == EXPR_Name) {
        name = right->kind.as.Name;
        text = left->kind.as.Str;
    } else {
        return -1;
    }
    if (!eq(name, "__os") || !self->intrinsics || map_contains(&self->locals, name)) {
        return -1;
    }
    return eq(text, target_os()) == (strcmp(op, "==") == 0);
}

static bool to_str(Checker *self, Value value, const Type *ty, Value *result) {
    switch (ty->tag) {
    case TYPE_Int:
        *result = core_call("int_to_str", VALUES(value), true);
        break;
    case TYPE_Float:
        *result = core_call("float_to_str", VALUES(value), true);
        break;
    case TYPE_Bool:
        *result = core_call("bool_to_str", VALUES(value), true);
        break;
    case TYPE_Str:
        *result = value;
        break;
    case TYPE_None: {
        Value text = intern(self->strings, STR("none"));
        *result = VAL(Seq, {box_copy(&value, sizeof(value)), box_copy(&text, sizeof(text))});
        break;
    }
    case TYPE_Enum: {
        Value descriptor = VAL(Global, type_descriptor(ty));
        *result = core_call("enum_to_str", VALUES(descriptor, value), true);
        break;
    }
    case TYPE_Union:
        if (!type_is_comparable(ty)) {
            return false;
        }
        *result = core_call("union_to_str", VALUES(value), true);
        break;
    default:
        return false;
    }
    return true;
}

static Value fail_call(Checker *self, const char *class, Value message) {
    Value name = intern(self->strings, str_from_cstr(class));
    return core_call("fail", VALUES(name, message), false);
}

static Ns module_of(const Checker *self, const Expr *expression) {
    Ns result = namespace_of(self, expression);
    return result.tag == NS_Module ? result : (Ns){0};
}

static Ns namespace_of(const Checker *self, const Expr *expression) {
    String path;
    switch (expression->kind.tag) {
    case EXPR_Name:
        if (map_contains(&self->locals, expression->kind.as.Name)) {
            return (Ns){0};
        }
        path = expression->kind.as.Name;
        break;
    case EXPR_Attr: {
        Ns object = namespace_of(self, expression->kind.as.Attr.object);
        if (object.tag == NS_Error) {
            return object;
        }
        if (object.tag != NS_Prefix) {
            return (Ns){0};
        }
        path = str_format(FMT "." FMT, S(object.name), S(expression->kind.as.Attr.name));
        break;
    }
    default:
        return (Ns){0};
    }
    if (map_contains(self->imported, path)) {
        return (Ns){.tag = NS_Module, .name = path};
    }
    String prefix = str_format(FMT ".", S(path));
    /* Only existence is observed, not the order of matching imported names. */
    for (size_t i = 0; i < self->imported->cap; i++) {
        const MapEntry *entry = &self->imported->entries[i];
        if (entry->occupied && starts_with(entry->key, prefix)) {
            return (Ns){.tag = NS_Prefix, .name = path};
        }
    }
    if (expression->kind.tag == EXPR_Attr) {
        return (Ns){.tag = NS_Error,
            .error = diagnostic(self, expression->kind.as.Attr.name_pos,
                str_format("unknown module '" FMT "'", S(path)))};
    }
    return (Ns){0};
}

static Decl decl_of(const Checker *self, const Expr *expression) {
    const Namespace *namespace;
    String written, name;
    switch (expression->kind.tag) {
    case EXPR_Name:
        name = expression->kind.as.Name;
        if (map_contains(&self->locals, name)) {
            return (Decl){0};
        }
        namespace = self->globals;
        written = name;
        break;
    case EXPR_Attr: {
        name = expression->kind.as.Attr.name;
        Ns object = namespace_of(self, expression->kind.as.Attr.object);
        if (object.tag == NS_Error) {
            return (Decl){.tag = D_Error, .as.error = object.error};
        }
        if (object.tag != NS_Module) {
            return (Decl){0};
        }
        namespace = map_get(self->imported, object.name);
        if (!map_contains(&namespace->declared, name)) {
            return (Decl){.tag = D_Error,
                .as.error = diagnostic(self, expression->kind.as.Attr.name_pos,
                    str_format("module '" FMT "' has no function, class, enum, or alias '" FMT "'",
                        S(object.name), S(name)))};
        }
        if (starts_with(name, STR("_")) && !str_equal(object.name, self->module->name)) {
            return (Decl){.tag = D_Error,
                .as.error = diagnostic(self, expression->kind.as.Attr.name_pos,
                    str_format(
                        "'" FMT "' is private to module '" FMT "'", S(name), S(object.name)))};
        }
        written = str_format(FMT "." FMT, S(object.name), S(name));
        break;
    }
    default:
        return (Decl){0};
    }
    const Sig *sig = map_get(&namespace->funcs, name);
    if (sig) {
        return (Decl){.tag = D_Func, .written = written, .as.func = sig};
    }
    const TypeDecl *type = map_get(&namespace->types, name);
    return type ? (Decl){.tag = D_Type, .written = written, .as.type = type} : (Decl){0};
}

static FieldType field(const Checker *self, const Type *ty, Pos pos, String name) {
    if (ty->tag != TYPE_Class) {
        fail(self->module->path, pos,
            str_format("type " FMT " has no field '" FMT "'", S(type_name(ty)), S(name)));
    }
    const ClassInfo *info = map_get(&self->names->classes, ty->as.Class.symbol);
    for (size_t i = 0; i < info->decl->fields.len; i++) {
        if (str_equal(info->decl->fields.data[i].name, name)) {
            return (FieldType){8 + 8 * (int64_t)i, info->fields.data[i]};
        }
    }
    if (map_contains(&info->methods, name)) {
        fail(self->module->path, pos,
            str_format(
                "cannot use method '" FMT "." FMT "' as a value", S(type_name(ty)), S(name)));
    }
    fail(self->module->path, pos,
        str_format("class " FMT " has no field '" FMT "'", S(type_name(ty)), S(name)));
}

/* Runtime classes ignore collection arguments. L0 has no inheritance. */
static bool same_runtime_class(const Type *a, const Type *b) {
    if (a->tag != b->tag) {
        return false;
    }
    return a->tag == TYPE_List || a->tag == TYPE_Dict || type_equal(a, b);
}

static TestedType tested_type(const Checker *self, const Expr *expression, const Type *ty) {
    String written;
    Type target;
    if (expression->kind.tag == EXPR_Name &&
        (eq(expression->kind.as.Name, "list") || eq(expression->kind.as.Name, "dict"))) {
        written = expression->kind.as.Name;
        target = eq(written, "list") ? TY(List) : TY(Dict);
    } else if (expression->kind.tag == EXPR_Name &&
        (eq(expression->kind.as.Name, "int") || eq(expression->kind.as.Name, "float") ||
            eq(expression->kind.as.Name, "bool") || eq(expression->kind.as.Name, "str"))) {
        written = expression->kind.as.Name;
        target = eq(written, "int")     ? TY(Int)
                : eq(written, "float") ? TY(Float)
                : eq(written, "bool")  ? TY(Bool)
                                       : TY(Str);
    } else {
        if (expression->kind.tag == EXPR_Attr) {
            Decl owner = decl_of(self, expression->kind.as.Attr.object);
            if (owner.tag == D_Type && owner.as.type->tag == DECL_Enum) {
                return (TestedType){.error = diagnostic(self, root(expression)->pos,
                    STR("an enum member cannot be used in a type test; use '=='"))};
            }
        }
        Decl decl = decl_of(self, expression);
        if (decl.tag == D_Error) {
            return (TestedType){.error = decl.as.error};
        }
        if (decl.tag != D_Type) {
            return (TestedType){0};
        }
        written = decl.written;
        target = decl.as.type->ty;
        if (decl.as.type->tag == DECL_Alias) {
            TypeName ref = {root(expression)->pos, written, {0}};
            AliasStack expanding = {0};
            target = resolve_name(self->names, self->module, &ref, &expanding);
        }
    }
    TypeVec kept = {0};
    TypeSlice members = type_members(ty);
    TypeSlice targets = type_members(&target);
    for (size_t i = 0; i < members.len; i++) {
        for (size_t j = 0; j < targets.len; j++) {
            if (same_runtime_class(&members.data[i], &targets.data[j])) {
                vec_push(kept, members.data[i]);
                break;
            }
        }
    }
    Type selected = type_union(kept);
    return (TestedType){.some = true, .written = written,
        .member = kept.len ? box_copy(&selected, sizeof(Type)) : NULL};
}

static bool is_sys_exit(const Checker *self, const Expr *expression) {
    if (expression->kind.tag != EXPR_Call) {
        return false;
    }
    const Expr *callee = expression->kind.as.Call.callee;
    if (callee->kind.tag != EXPR_Attr || !eq(callee->kind.as.Attr.name, "exit")) {
        return false;
    }
    Ns module = module_of(self, callee->kind.as.Attr.object);
    if (module.tag != NS_Module || !eq(module.name, "sys")) {
        return false;
    }
    const Namespace *namespace = map_get(self->imported, STR("sys"));
    return namespace->host;
}

static TypedValue call(Checker *self, const Expr *callee, ExprVec arguments, const State *state) {
    Pos pos = callee->pos;
    if (callee->kind.tag == EXPR_Attr) {
        const Expr *object = callee->kind.as.Attr.object;
        Pos name_pos = callee->kind.as.Attr.name_pos;
        String name = callee->kind.as.Attr.name;
        Ns namespace = must_namespace(self, object);
        if (namespace.tag == NS_None) {
            return method(self, object, name_pos, name, arguments, state);
        }
        if (namespace.tag == NS_Prefix) {
            must_namespace(self, callee);
            module_as_value(self, callee);
        }
        const Namespace *owner = map_get(self->imported, namespace.name);
        bool sys = owner->host && eq(namespace.name, "sys");
        if (sys && eq(name, "eprint")) {
            CheckedArgs checked = args(self, arguments, state, (TypeVec){0});
            arity(self, pos, STR("sys.eprint"), 1, checked.len);
            CheckedArg arg = checked.data[checked.len - 1];
            Value text;
            if (!to_str(self, arg.value, &arg.ty, &text)) {
                fail(self->module->path, arg.pos,
                    str_format("cannot print a value of type " FMT, S(type_name(&arg.ty))));
            }
            return typed(core_call("eprint_str", VALUES(text), false), TY(None));
        }
        if (sys && eq(name, "args")) {
            arity(self, pos, STR("sys.args"), 0, arguments.len);
            Value argc = VAL(Global, STR("W.argc")), argv = VAL(Global, STR("W.argv")),
                  zero = constant(0);
            Value argc_load =
                VAL(Load, {"loadl", box_copy(&argc, sizeof(argc)), box_copy(&zero, sizeof(zero))});
            Value argv_load =
                VAL(Load, {"loadl", box_copy(&argv, sizeof(argv)), box_copy(&zero, sizeof(zero))});
            return typed(
                core_call("sys_args", VALUES(argc_load, argv_load), true), list_type(TY(Str)));
        }
    }
    Decl decl = must_decl(self, callee);
    if (decl.tag == D_Func) {
        const Sig *sig = decl.as.func;
        CheckedArgs checked = args(self, arguments, state, sig->params);
        return call_sig(self, pos, decl.written, last_name(decl.written), sig, checked);
    }
    if (decl.tag == D_Type) {
        if (decl.as.type->tag == DECL_Class) {
            return construct(self, pos, &decl.as.type->ty, arguments, state);
        }
        fail(self->module->path, pos,
            str_format(FMT " cannot be called", S(describe(decl.as.type, decl.written))));
    }
    String name;
    if (callee->kind.tag == EXPR_Name && !map_contains(&self->locals, callee->kind.as.Name)) {
        name = callee->kind.as.Name;
    } else {
        TypedValue checked = expr(self, callee, state);
        fail(self->module->path, pos,
            str_format("cannot call a value of type " FMT, S(type_name(&checked.ty))));
    }
    if (eq(name, "range")) {
        fail(self->module->path, pos, STR("'range' can only be the source of a for loop"));
    }
    if (!eq(name, "print") && !eq(name, "int") && !eq(name, "float") && !eq(name, "str") &&
        !eq(name, "len") && !eq(name, "ord") && !eq(name, "chr")) {
        if (!is_intrinsic(name)) {
            if (LISTED(name, BUILTINS)) {
                fail(self->module->path, pos, str_format("'" FMT "' is not supported", S(name)));
            }
            fail(self->module->path, pos, str_format("unknown function '" FMT "'", S(name)));
        }
        if (!self->intrinsics) {
            fail(self->module->path, pos,
                str_format("intrinsic '" FMT "' is only available in core", S(name)));
        }
    }
    CheckedArgs checked = args(self, arguments, state, (TypeVec){0});
    if (eq(name, "print") || eq(name, "str")) {
        arity(self, pos, name, 1, checked.len);
        CheckedArg arg = checked.data[checked.len - 1];
        Value text;
        if (!to_str(self, arg.value, &arg.ty, &text)) {
            String message =
                eq(name, "print")
                    ? str_format("cannot print a value of type " FMT, S(type_name(&arg.ty)))
                    : str_format(
                          "cannot convert a value of type " FMT " to str", S(type_name(&arg.ty)));
            fail(self->module->path, arg.pos, message);
        }
        if (eq(name, "str")) {
            return typed(text, TY(Str));
        }
        return typed(core_call("print_str", VALUES(text), false), TY(None));
    }
    if (eq(name, "ord") || eq(name, "chr")) {
        arity(self, pos, name, 1, checked.len);
        CheckedArg arg = checked.data[checked.len - 1];
        Type param = eq(name, "ord") ? TY(Str) : TY(Int), ret = eq(name, "ord") ? TY(Int) : TY(Str);
        const char *function = eq(name, "ord") ? "str_ord" : "str_chr";
        expect(self, arg.pos, &param, &arg.ty);
        return typed(core_call(function, VALUES(arg.value), true), ret);
    }
    if (eq(name, "len")) {
        arity(self, pos, name, 1, checked.len);
        CheckedArg arg = checked.data[checked.len - 1];
        const char *function;
        switch (arg.ty.tag) {
        case TYPE_List:
            function = "list_len";
            break;
        case TYPE_Dict:
            function = "dict_len";
            break;
        case TYPE_Str:
            function = "str_len";
            break;
        default:
            fail(self->module->path, pos,
                str_format("'len' cannot be applied to " FMT, S(type_name(&arg.ty))));
        }
        return typed(core_call(function, VALUES(arg.value), true), TY(Int));
    }
    if (eq(name, "int") || eq(name, "float")) {
        arity(self, pos, name, 1, checked.len);
        CheckedArg arg = checked.data[checked.len - 1];
        if (eq(name, "int") && arg.ty.tag == TYPE_Float) {
            return typed(core_call("float_to_int", VALUES(arg.value), true), TY(Int));
        }
        if (eq(name, "int") && arg.ty.tag == TYPE_Str) {
            return typed(core_call("str_to_int", VALUES(arg.value), true), TY(Int));
        }
        if (eq(name, "float") && arg.ty.tag == TYPE_Int) {
            return typed(VAL(IntToFloat, box_copy(&arg.value, sizeof(Value))), TY(Float));
        }
        if (eq(name, "float") && arg.ty.tag == TYPE_Str) {
            return typed(core_call("str_to_float", VALUES(arg.value), true), TY(Float));
        }
        fail(self->module->path, arg.pos,
            str_format(
                "cannot convert a value of type " FMT " to " FMT, S(type_name(&arg.ty)), S(name)));
    }
    if (eq(name, "__os")) {
        fail(self->module->path, pos, STR("cannot call a value of type str"));
    }
    if (eq(name, "__word")) {
        arity(self, pos, name, 1, checked.len);
        CheckedArg arg = checked.data[checked.len - 1];
        switch (arg.ty.tag) {
        case TYPE_Int:
        case TYPE_Float:
        case TYPE_Bool:
        case TYPE_Ptr:
        case TYPE_Str:
        case TYPE_Union:
            break;
        default:
            fail(self->module->path, arg.pos,
                str_format(
                    "cannot convert a value of type " FMT " to word", S(type_name(&arg.ty))));
        }
        return typed(arg.value, TY(Word));
    }
    const Intrinsic *intrinsic = NULL;
    for (size_t i = 0; i < sizeof(INTRINSICS) / sizeof(*INTRINSICS); i++) {
        if (eq(name, INTRINSICS[i].name)) {
            intrinsic = &INTRINSICS[i];
            break;
        }
    }
    assert(intrinsic);
    arity(self, pos, name, intrinsic->len, checked.len);
    for (size_t i = 0; i < checked.len; i++) {
        Type param = {.tag = intrinsic->params[i]};
        expect(self, checked.data[i].pos, &param, &checked.data[i].ty);
    }
    Value *values[3] = {0};
    for (size_t i = 0; i < checked.len; i++) {
        values[i] = box_copy(&checked.data[i].value, sizeof(Value));
    }
    Value value;
    if (eq(name, "__alloc") || eq(name, "__alloc_atomic")) {
        Call alloc = {
            .symbol = eq(name, "__alloc") ? STR("GC_malloc") : STR("GC_malloc_atomic"), .ret = "l"};
        vec_push(alloc.args, (CallArg){"l", *values[0]});
        value = VAL(Call, alloc);
    } else if (eq(name, "__load1")) {
        value = VAL(Load, {"loadub", values[0], values[1]});
    } else if (eq(name, "__load4")) {
        value = VAL(Load, {"loadsw", values[0], values[1]});
    } else if (eq(name, "__load8")) {
        value = VAL(Load, {"loadl", values[0], values[1]});
    } else if (eq(name, "__store1")) {
        value = VAL(Store, {"storeb", values[0], values[1], values[2]});
    } else if (eq(name, "__store4")) {
        value = VAL(Store, {"storew", values[0], values[1], values[2]});
    } else if (eq(name, "__store8")) {
        value = VAL(Store, {"storel", values[0], values[1], values[2]});
    } else if (eq(name, "__addr_is_null")) {
        value = binary_value("ceql", *values[0], constant(0));
    } else if (eq(name, "__dtosi")) {
        value = VAL(FloatToInt, values[0]);
    } else if (eq(name, "__offset")) {
        value = VAL(Binary, {"add", values[0], values[1]});
    } else {
        value = *values[0];
    }
    return typed(value, (Type){.tag = intrinsic->ret});
}

static TypedValue type_test(Checker *self, const Expr *operand, const Expr *class, const State *state) {
    TypedValue checked = expr(self, operand, state);
    TestedType found_type = tested_type(self, class, &checked.ty);
    if (found_type.error) {
        raise_diag(found_type.error);
    }
    if (!found_type.some) {
        String name = class->kind.tag == EXPR_Name ? class->kind.as.Name : class->kind.as.Attr.name;
        fail(self->module->path, class->pos, str_format("unknown type '" FMT "'", S(name)));
    }
    if (!found_type.member) {
        fail(self->module->path, root(class)->pos,
            str_format("type " FMT " has no member " FMT, S(type_name(&checked.ty)),
                S(found_type.written)));
    }
    if (!type_is_union(&checked.ty)) {
        Value one = constant(1);
        return typed(
            VAL(Seq, {box_copy(&checked.value, sizeof(Value)), box_copy(&one, sizeof(one))}),
            TY(Bool));
    }
    StringVec descriptors = {0};
    TypeSlice members = type_members(found_type.member);
    for (size_t i = 0; i < members.len; i++) {
        vec_push(descriptors, members.data[i].tag == TYPE_None ? STR("") : type_descriptor(&members.data[i]));
    }
    return typed(VAL(TypeTest, {box_copy(&checked.value, sizeof(Value)), descriptors}), TY(Bool));
}

static CheckedArgs args(Checker *self, ExprVec arguments, const State *state, TypeVec params) {
    CheckedArgs checked = {0};
    for (size_t i = 0; i < arguments.len; i++) {
        const Expr *arg = &arguments.data[i];
        TypedValue value = expr_expect(self, arg, state, i < params.len ? &params.data[i] : NULL);
        vec_push(checked, (CheckedArg){arg->pos, value.value, value.ty});
    }
    return checked;
}

static TypedValue method(Checker *self, const Expr *object, Pos name_pos, String name,
    ExprVec arguments, const State *state) {
    TypedValue obj = expr(self, object, state);
    if (obj.ty.tag == TYPE_Class) {
        const ClassInfo *info = map_get(&self->names->classes, obj.ty.as.Class.symbol);
        const Sig *sig = map_get(&info->methods, name);
        if (!sig) {
            fail(self->module->path, name_pos,
                str_format("type " FMT " has no method '" FMT "'", S(type_name(&obj.ty)), S(name)));
        }
        CheckedArgs checked = {0};
        vec_push(checked, (CheckedArg){object->pos, obj.value, obj.ty});
        TypeVec params = {.data = sig->params.data + 1, .len = sig->params.len - 1};
        CheckedArgs more = args(self, arguments, state, params);
        for (size_t i = 0; i < more.len; i++) {
            vec_push(checked, more.data[i]);
        }
        arity(self, name_pos, name, sig->params.len - 1, checked.len - 1);
        return call_sig(self, name_pos, name, name, sig, checked);
    }
    String display = str_format(FMT "." FMT, S(type_name(&obj.ty)), S(name));
    if (obj.ty.tag == TYPE_Dict) {
        if (eq(name, "get")) {
            return dict_get(self,
                (DictCall){obj.value, obj.ty.as.Dict.key, obj.ty.as.Dict.value, name_pos, name},
                arguments, state);
        }
        if (eq(name, "keys") || eq(name, "values") || eq(name, "items")) {
            fail(self->module->path, name_pos,
                str_format("'" FMT "' can only be the source of a for loop", S(display)));
        }
    }
    MethodSignature sig = method_signature(&obj.ty, name);
    if (!sig.function) {
        fail(self->module->path, name_pos,
            str_format("type " FMT " has no method '" FMT "'", S(type_name(&obj.ty)), S(name)));
    }
    size_t required = sig.params.len - sig.defaults.len;
    if (!sig.defaults.len) {
        arity(self, name_pos, name, sig.params.len, arguments.len);
    } else if (arguments.len < required || arguments.len > sig.params.len) {
        fail(self->module->path, name_pos,
            str_format("'" FMT "' expects %zu to " FMT ", received %zu", S(name), required,
                S(count(sig.params.len)), arguments.len));
    }
    ValueVec call_args = {0};
    vec_push(call_args, obj.value);
    for (size_t i = 0; i < sig.params.len; i++) {
        const Type *param = &sig.params.data[i];
        if (i >= arguments.len) {
            vec_push(call_args, constant(sig.defaults.data[i - required]));
            continue;
        }
        const Expr *arg = &arguments.data[i];
        TypedValue checked = expr_expect(self, arg, state, param);
        Value value;
        if (strcmp(sig.function, "list_extend") == 0) {
            if (!type_equal(&checked.ty, param)) {
                fail(self->module->path, arg->pos,
                    str_format("expected Iterable[" FMT "], received " FMT,
                        S(type_name(type_list_element(param))), S(type_name(&checked.ty))));
            }
            value = checked.value;
        } else {
            value = coerce(self, arg->pos, checked.value, &checked.ty, param);
        }
        vec_push(call_args, value);
    }
    return typed(core_call(sig.function, call_args, sig.ret.tag != TYPE_None), sig.ret);
}

static TypedValue construct(
    Checker *self, Pos pos, const Type *ty, ExprVec arguments, const State *state) {
    assert(ty->tag == TYPE_Class);
    const ClassInfo *info = map_get(&self->names->classes, ty->as.Class.symbol);
    FieldVec fields = info->decl->fields;
    size_t required = 0;
    for (size_t i = 0; i < fields.len; i++) {
        if (!fields.data[i].default_) {
            required++;
        }
    }
    String display = type_name(ty);
    if (required == fields.len) {
        arity(self, pos, display, fields.len, arguments.len);
    } else if (arguments.len < required || arguments.len > fields.len) {
        fail(self->module->path, pos,
            str_format("'" FMT "' expects %zu to " FMT ", received %zu", S(display), required,
                S(count(fields.len)), arguments.len));
    }
    ValueVec values = {0};
    for (size_t i = 0; i < fields.len; i++) {
        const Type *field_ty = &info->fields.data[i];
        Pos value_pos;
        TypedValue checked;
        if (i < arguments.len) {
            const Expr *arg = &arguments.data[i];
            checked = expr_expect(self, arg, state, field_ty);
            value_pos = arg->pos;
        } else {
            const Expr *default_ = fields.data[i].default_;
            assert(default_);
            State empty = {0};
            checked = expr(self, default_, &empty);
            value_pos = default_->pos;
        }
        Value value = coerce(self, value_pos, checked.value, &checked.ty, field_ty);
        vec_push(values, value);
    }
    return typed(VAL(Construct, {type_descriptor(ty), values}), *ty);
}

static TypedValue dict_get(Checker *self, DictCall call, ExprVec arguments, const State *state) {
    if (!arguments.len || arguments.len > 2) {
        fail(self->module->path, call.pos,
            str_format(
                "'" FMT "' expects 1 to 2 arguments, received %zu", S(call.name), arguments.len));
    }
    TypedValue key = expr(self, &arguments.data[0], state);
    Value key_ir = coerce(self, arguments.data[0].pos, key.value, &key.ty, call.key);
    TypedValue default_;
    Type result;
    if (arguments.len > 1) {
        default_ = expr_expect(self, &arguments.data[1], state, call.value);
        default_ = typed(coerce(self, arguments.data[1].pos, default_.value, &default_.ty,
                           call.value),
            *call.value);
        result = *call.value;
    } else {
        default_ = typed(constant(0), TY(None));
        result = union_two(*call.value, TY(None));
    }
    Value present = widen(VAL(Item, 0), call.value, &result);
    Value get =
        VAL(DictGet, {box_copy(&call.dict, sizeof(Value)), box_copy(&key_ir, sizeof(key_ir)),
                         box_copy(&default_.value, sizeof(default_.value)),
                         box_copy(&present, sizeof(present))});
    return typed(get, result);
}

static TypedValue call_sig(const Checker *self, Pos pos, String display, String name,
    const Sig *sig, CheckedArgs checked) {
    bool variadic = sig->target.tag == TARGET_Extern && sig->target.as.Extern.variadic;
    if (!variadic || checked.len < sig->params.len) {
        arity(self, pos, display, sig->params.len, checked.len);
    }
    Call call = {0};
    switch (sig->target.tag) {
    case TARGET_Willow:
        call.symbol = sig->target.as.Willow;
        for (size_t i = 0; i < checked.len && i < sig->params.len; i++) {
            CheckedArg arg = checked.data[i];
            Value value = coerce(self, arg.pos, arg.value, &arg.ty, &sig->params.data[i]);
            vec_push(call.args, (CallArg){"l", value});
        }
        call.ret = sig->ret.tag == TYPE_None ? NULL : "l";
        break;
    case TARGET_Extern: {
        CTypeVec cparams = sig->target.as.Extern.cparams;
        for (size_t i = 0; i < checked.len && i < sig->params.len; i++) {
            expect(self, checked.data[i].pos, &sig->params.data[i], &checked.data[i].ty);
        }
        for (size_t i = 0; i < checked.len; i++) {
            CheckedArg arg = checked.data[i];
            const char *extra;
            switch (arg.ty.tag) {
            case TYPE_Int:
            case TYPE_Ptr:
                extra = "l";
                break;
            case TYPE_Float:
                extra = "d";
                break;
            default:
                if (i >= cparams.len) {
                    fail(self->module->path, arg.pos,
                        STR("variadic arguments must be int, float, or ptr"));
                }
                extra = "l";
                break;
            }
            vec_push(call.args, (CallArg){i < cparams.len ? cparams.data[i] : extra, arg.value});
        }
        call.symbol = name;
        call.variadic_at = (OptionSize){variadic, cparams.len};
        call.ret = sig->target.as.Extern.cret;
        break;
    }
    }
    return typed(VAL(Call, call), sig->ret);
}

Program check(ModuleVec modules) {
    assert(modules.len);
    const Module *entry = &modules.data[0];
    Names names = {0};
    Map hosts = host_tables();
    /* Host table order only initializes namespaces; no output or checks depend
     * on it. Function bodies and descriptors use syntax order below. */
    for (size_t i = 0; i < hosts.cap; i++) {
        const MapEntry *host = &hosts.entries[i];
        if (!host->occupied) {
            continue;
        }
        bool provided = false;
        for (size_t j = 0; j < modules.len; j++) {
            if (str_equal(modules.data[j].name, host->key)) {
                provided = true;
            }
        }
        if (provided) {
            continue;
        }
        Namespace namespace = {.funcs = *(Map *)host->value, .host = true};
        for (size_t j = 0; j < namespace.funcs.cap; j++) {
            if (namespace.funcs.entries[j].occupied) {
                set_insert(&namespace.declared, namespace.funcs.entries[j].key);
            }
        }
        if (eq(host->key, "sys")) {
            set_insert(&namespace.declared, STR("eprint"));
            set_insert(&namespace.declared, STR("args"));
        }
        map_insert(&names.modules, host->key, box_copy(&namespace, sizeof(namespace)));
    }
    for (size_t i = 0; i < modules.len; i++) {
        const Module *module = &modules.data[i];
        Namespace namespace = declare_types(module, entry->name, &names);
        map_insert(&names.modules, module->name, box_copy(&namespace, sizeof(namespace)));
        map_insert(&names.sources, module->name, (void *)module);
    }
    for (size_t i = 0; i < modules.len; i++) {
        const Module *module = &modules.data[i];
        for (size_t j = 0; j < module->aliases.len; j++) {
            const Alias *alias = &module->aliases.data[j];
            AliasStack expanding = {0};
            vec_push(expanding, alias);
            resolve_in(&names, module, &alias->ty, &expanding);
        }
    }
    for (size_t i = 0; i < modules.len; i++) {
        const Module *module = &modules.data[i];
        Map funcs = declare_funcs(&names, module);
        Namespace *namespace = map_get(&names.modules, module->name);
        namespace->funcs = funcs;
    }
    for (size_t i = 0; i < modules.len; i++) {
        const Module *module = &modules.data[i];
        for (size_t j = 0; j < module->classes.len; j++) {
            const Class *class = &module->classes.data[j];
            ClassInfo info = declare_class(&names, module, class);
            String symbol = str_format("W." FMT "." FMT, S(module->name), S(class->name));
            map_insert(&names.classes, symbol, box_copy(&info, sizeof(info)));
        }
    }
    const Func *main = NULL;
    for (size_t i = 0; i < entry->funcs.len; i++) {
        if (eq(entry->funcs.data[i].name, "main")) {
            main = &entry->funcs.data[i];
            break;
        }
    }
    if (!main) {
        fail(entry->path, (Pos){1, 1}, STR("program has no main function"));
    }
    const Namespace *entry_namespace = map_get(&names.modules, entry->name);
    const Sig *main_sig = map_get(&entry_namespace->funcs, STR("main"));
    if (main->params.len || main_sig->ret.tag != TYPE_None) {
        fail(entry->path, main->pos, STR("main must take no parameters and return none"));
    }
    Strings strings = {0};
    DescriptorVec descriptors = {0};
    for (size_t i = 0; i < sizeof(BUILTIN_TYPES) / sizeof(*BUILTIN_TYPES); i++) {
        Descriptor descriptor = {.symbol = str_format("W.%s.type", BUILTIN_TYPES[i])};
        size_t text = index_of(&strings, str_from_cstr(BUILTIN_TYPES[i]));
        vec_push(descriptor.texts, text);
        vec_push(descriptors, descriptor);
    }
    for (size_t i = 0; i < modules.len; i++) {
        const Module *module = &modules.data[i];
        for (size_t j = 0; j < module->classes.len; j++) {
            const Class *class = &module->classes.data[j];
            Descriptor descriptor = {
                .symbol = str_format("W." FMT "." FMT ".type", S(module->name), S(class->name))};
            size_t text = index_of(&strings, class->name);
            vec_push(descriptor.texts, text);
            vec_push(descriptors, descriptor);
        }
        for (size_t j = 0; j < module->enums.len; j++) {
            const Enum *decl = &module->enums.data[j];
            SizeVec texts = {0};
            size_t text = index_of(&strings, decl->name);
            vec_push(texts, text);
            for (size_t k = 0; k < decl->members.len; k++) {
                String member =
                    str_format(FMT "." FMT, S(decl->name), S(decl->members.data[k].name));
                size_t index = index_of(&strings, member);
                vec_push(texts, index);
            }
            vec_push(descriptors,
                (Descriptor){
                    str_format("W." FMT "." FMT ".type", S(module->name), S(decl->name)), texts});
        }
    }
    FunctionVec funcs = {0};
    for (size_t i = 0; i < modules.len; i++) {
        const Module *module = &modules.data[i];
        Map imported = {0};
        for (size_t j = 0; j < module->imports.len; j++) {
            const Import *import = &module->imports.data[j];
            Namespace *namespace = map_get(&names.modules, import->name);
            if (!namespace) {
                fail(module->path, import->pos,
                    str_format("unknown module '" FMT "'", S(import->name)));
            }
            /* A previously valid import set cannot contain nested names. All
             * clashes with this name therefore have the same shorter prefix. */
            for (size_t k = 0; k < imported.cap; k++) {
                const MapEntry *other = &imported.entries[k];
                if (!other->occupied) {
                    continue;
                }
                String shorter = other->key.len < import->name.len ? other->key : import->name;
                String longer = other->key.len < import->name.len ? import->name : other->key;
                String prefix = str_format(FMT ".", S(shorter));
                if (starts_with(longer, prefix)) {
                    fail(module->path, import->pos,
                        str_format(
                            "'" FMT "' is imported as a module and as a namespace", S(shorter)));
                }
            }
            if (!map_insert(&imported, import->name, namespace)) {
                fail(module->path, import->pos,
                    str_format("duplicate import '" FMT "'", S(import->name)));
            }
        }
        const Namespace *globals = map_get(&names.modules, module->name);
        Scope scope = {module, globals, &imported, &names};
        for (size_t j = 0; j < module->funcs.len; j++) {
            const Func *func = &module->funcs.data[j];
            if (func->body) {
                const Sig *sig = map_get(&globals->funcs, func->name);
                Function checked = check_function(scope, &strings, func, sig, *func->body, false);
                vec_push(funcs, checked);
            }
        }
        for (size_t j = 0; j < module->classes.len; j++) {
            const Class *class = &module->classes.data[j];
            String symbol = str_format("W." FMT "." FMT, S(module->name), S(class->name));
            const ClassInfo *info = map_get(&names.classes, symbol);
            for (size_t k = 0; k < class->methods.len; k++) {
                const Func *method = &class->methods.data[k];
                const Sig *sig = map_get(&info->methods, method->name);
                assert(method->body);
                Function checked =
                    check_function(scope, &strings, method, sig, *method->body, true);
                vec_push(funcs, checked);
            }
        }
    }
    return (Program){
        funcs, strings.list, descriptors, str_format("W." FMT ".main", S(entry->name))};
}
