#ifndef WILLOW0_H
#define WILLOW0_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Strings are immutable byte sequences; allocated strings also end in NUL.
 * A zero-initialized String is empty. Lengths include embedded NUL bytes.
 * STR takes a string literal; str_from_cstr borrows a terminated C string. */
typedef struct String {
    const char *data;
    size_t len;
} String;

#define STR(literal) ((String){(literal), sizeof(literal) - 1})

String str_from_cstr(const char *text);
String str_copy(const char *data, size_t len);
bool str_equal(String left, String right);
int str_compare(String left, String right);
String str_format(const char *format, ...);

void *xmalloc(size_t size);
void *xrealloc(void *data, size_t size);
void *box_copy(const void *value, size_t size);
#define box(T, ...) ((T *)box_copy(&(T){__VA_ARGS__}, sizeof(T)))

/* Vector macros take simple lvalues. Copies share their elements' immutable
 * children; vec_copy allocates independent vector storage. Growth invalidates
 * pointers into the vector. Zero initialization produces an empty vector. */
#define VEC_DECL(T, Name) \
    typedef struct Name { T *data; size_t len; size_t cap; } Name

void *array_grow(void *data, size_t *cap, size_t needed, size_t element_size);
void *array_copy(const void *data, size_t len, size_t element_size);

#define vec_reserve(v, needed) \
    ((v).data = array_grow((v).data, &(v).cap, (needed), sizeof(*(v).data)))
#define vec_push(v, ...) do { \
    vec_reserve((v), (v).len + 1); \
    (v).data[(v).len] = (__VA_ARGS__); \
    (v).len++; \
} while (0)
#define vec_copy(dst, src) do { \
    (dst).data = array_copy((src).data, (src).len, sizeof(*(src).data)); \
    (dst).len = (src).len; \
    (dst).cap = (src).len; \
} while (0)

VEC_DECL(String, StringVec);
VEC_DECL(size_t, SizeVec);
VEC_DECL(uint32_t, CharVec);

/* sb_finish transfers the buffer and resets the builder. sb_append uses byte
 * lengths; sb_printf uses ordinary C printf arguments, not String values.
 * sb_push_char accepts a Unicode scalar value. utf8_decode advances *at only
 * on success; false means end of input or an invalid sequence at *at. */
typedef struct StringBuilder {
    char *data;
    size_t len;
    size_t cap;
} StringBuilder;

void sb_append(StringBuilder *out, String text);
void sb_push_byte(StringBuilder *out, unsigned char byte);
void sb_push_char(StringBuilder *out, uint32_t code);
void sb_printf(StringBuilder *out, const char *format, ...);
String sb_finish(StringBuilder *out);
bool utf8_decode(String text, size_t *at, uint32_t *code);

/* Keys are immutable, borrowed Strings. Values must be nonnull; wrap optional
 * values in an allocated object. map_insert returns true for a new key and
 * false when replacing one. Iterate occupied entries below cap, without
 * inserting during iteration. map_clone copies buckets and shares values;
 * callers must copy mutable values separately. Use a nonnull value for sets. */
typedef struct MapEntry {
    bool occupied;
    String key;
    void *value;
} MapEntry;

typedef struct Map {
    MapEntry *entries;
    size_t len;
    size_t cap;
} Map;

void *map_get(const Map *map, String key);
bool map_contains(const Map *map, String key);
bool map_insert(Map *map, String key, void *value);
Map map_clone(const Map *map);

/* Nullable object pointers represent optional values; a nonnull pointer to an
 * empty vector is distinct from NULL. C's default keyword is spelled default_. */
typedef struct OptionSize {
    bool some;
    size_t value;
} OptionSize;

typedef struct Pos {
    uint32_t line;
    uint32_t col;
} Pos;

/// A compile-time error in the spec §13 format.
typedef struct Diag {
    String path;
    Pos pos;
    String message;
} Diag;

_Noreturn void fail(String path, Pos pos, String message);
/* Prints an already formatted driver error, followed by a newline, and exits 1.
 * io_error appends " (os error N)"; module-load errors instead use
 * strerror(error) alone. Capture errno before formatting an error. */
_Noreturn void fatal(String message);
String io_error(int error);

typedef struct Kind Kind;
typedef struct FPart FPart;
typedef struct Token Token;
VEC_DECL(FPart, FPartVec);
VEC_DECL(Token, TokenVec);

typedef enum KindTag {
    KIND_Name,
    KIND_Int,
    KIND_Float,
    KIND_Str,
    KIND_FStr,
    KIND_Word,
    KIND_Newline,
    KIND_Indent,
    KIND_Dedent,
    KIND_Eof
} KindTag;

struct Kind {
    KindTag tag;
    union {
        String Name;
        int64_t Int;
        double Float;
        String Str;
        /// An f-string's literal text and fields, in order, without empty text.
        FPartVec FStr;
        /// A reserved word or an operator.
        const char *Word;
    } as;
};

typedef enum FPartTag {
    FPART_Text,
    FPART_Field
} FPartTag;

struct FPart {
    FPartTag tag;
    union {
        String Text;
        /// The tokens of a field's expression, followed by its `}` and an end of
        /// file.
        TokenVec Field;
    } as;
};

struct Token {
    Kind kind;
    Pos pos;
};

typedef struct Module Module;
typedef struct Import Import;
typedef struct Func Func;
typedef struct Class Class;
typedef struct Field Field;
typedef struct Enum Enum;
typedef struct Alias Alias;
typedef struct Param Param;
typedef struct TypeExpr TypeExpr;
typedef struct TypeName TypeName;
typedef struct Stmt Stmt;
typedef struct StmtKind StmtKind;
typedef struct Expr Expr;
typedef struct ExprKind ExprKind;
typedef struct PosName PosName;
typedef struct ExprEntry ExprEntry;
typedef struct IfArm IfArm;

VEC_DECL(Module, ModuleVec);
VEC_DECL(Import, ImportVec);
VEC_DECL(Func, FuncVec);
VEC_DECL(Class, ClassVec);
VEC_DECL(Field, FieldVec);
VEC_DECL(Enum, EnumVec);
VEC_DECL(Alias, AliasVec);
VEC_DECL(Param, ParamVec);
VEC_DECL(TypeExpr, TypeExprVec);
VEC_DECL(TypeName, TypeNameVec);
VEC_DECL(Stmt, StmtVec);
VEC_DECL(Expr, ExprVec);
VEC_DECL(PosName, PosNameVec);
VEC_DECL(ExprEntry, ExprEntryVec);
VEC_DECL(IfArm, IfArmVec);

struct Module {
    String name;
    String path;
    ImportVec imports;
    FuncVec funcs;
    ClassVec classes;
    EnumVec enums;
    AliasVec aliases;
};

struct Import {
    Pos pos;
    /// The module's full name, as in `app.util`.
    String name;
};

struct Class {
    Pos pos;
    String name;
    FieldVec fields;
    /// The methods, whose `params` leave out `self`.
    FuncVec methods;
};

struct TypeName {
    Pos pos;
    /// The name, qualified with a module name as in `app.util.Item`.
    String name;
    /// The arguments of a generic type, as in `list[int]`.
    TypeExprVec args;
};

/// An annotation: one type name, or the members of a union.
struct TypeExpr {
    Pos pos;
    TypeNameVec members;
};

struct Field {
    Pos pos;
    String name;
    TypeExpr ty;
    /// A literal default.
    Expr *default_;
};

struct Enum {
    Pos pos;
    String name;
    PosNameVec members;
};

/// A `type` declaration.
struct Alias {
    Pos pos;
    String name;
    TypeExpr ty;
};

/// A `def`, or an `extern def` when `body` is NULL.
struct Func {
    Pos pos;
    String name;
    ParamVec params;
    bool variadic;
    TypeExpr *ret;
    StmtVec *body;
};

struct Param {
    Pos pos;
    String name;
    TypeExpr ty;
};

struct PosName {
    Pos pos;
    String name;
};

typedef enum ExprTag {
    EXPR_Int,
    EXPR_Float,
    EXPR_Str,
    EXPR_FStr,
    EXPR_Bool,
    EXPR_Name,
    EXPR_Call,
    EXPR_List,
    EXPR_Dict,
    EXPR_Index,
    EXPR_Slice,
    EXPR_Attr,
    EXPR_Unary,
    EXPR_Binary,
    EXPR_TypeOf,
    EXPR_None,
    EXPR_IsNone
} ExprTag;

struct ExprKind {
    ExprTag tag;
    union {
        int64_t Int;
        double Float;
        String Str;
        /// An f-string's parts in order: `Str` for literal text, and fields.
        ExprVec FStr;
        bool Bool;
        String Name;
        struct { Expr *callee; ExprVec args; } Call;
        /// A list display.
        ExprVec List;
        /// A dict display's entries.
        ExprEntryVec Dict;
        struct { Expr *object; Expr *index; } Index;
        /// `object[start:stop]`, either bound omitted.
        struct { Expr *object; Expr *start; Expr *stop; } Slice;
        /// `object.name`, with the position of the name.
        struct { Expr *object; Pos name_pos; String name; } Attr;
        struct { const char *op; Expr *operand; } Unary;
        /// The operator, its position, and the operands.
        struct { const char *op; Pos op_pos; Expr *left; Expr *right; } Binary;
        /// The `__type(T)` intrinsic, whose argument is a type.
        TypeName TypeOf;
        /// `operand is None`, or `operand is not None` when negated, with the
        /// position of `is`.
        struct { Expr *operand; bool negated; Pos op_pos; } IsNone;
    } as;
};

struct Expr {
    Pos pos;
    ExprKind kind;
};

struct ExprEntry {
    Expr key;
    Expr value;
};

typedef enum StmtTag {
    STMT_Assert,
    STMT_Assign,
    STMT_Expr,
    STMT_If,
    STMT_For,
    STMT_SetField,
    STMT_SetIndex,
    STMT_While,
    STMT_Return,
    STMT_Pass,
    STMT_Break,
    STMT_Continue
} StmtTag;

struct StmtKind {
    StmtTag tag;
    union {
        struct { Expr cond; Expr *message; } Assert;
        struct { String target; TypeExpr *annotation; Expr value; } Assign;
        Expr Expr;
        /// `if`/`elif` arms in order, then the `else` block.
        struct { IfArmVec arms; StmtVec *otherwise; } If;
        /// `for target in iterable:`, or `for key, value in d.items():`.
        struct {
            /// Each target's position and name.
            PosNameVec targets;
            Expr iterable;
            StmtVec body;
        } For;
        /// `object.name = value`.
        struct { Expr object; Pos name_pos; String name; Expr value; } SetField;
        /// `object[index] = value`, with the position of `[`.
        struct { Pos bracket; Expr object; Expr index; Expr value; } SetIndex;
        struct { Expr cond; StmtVec body; } While;
        Expr *Return;
    } as;
};

struct Stmt {
    Pos pos;
    StmtKind kind;
};

struct IfArm {
    Expr cond;
    StmtVec body;
};

typedef struct Type Type;
VEC_DECL(Type, TypeVec);

/// A declared class or enum: the name diagnostics give it, which is
/// qualified by its module outside the entry module, and its symbol
/// `W.<module>.<Name>`, which its descriptor and methods extend.
typedef struct Named {
    String display;
    String symbol;
} Named;

typedef enum TypeTag {
    TYPE_Class,
    TYPE_Enum,
    TYPE_Int,
    TYPE_Float,
    TYPE_Bool,
    TYPE_Str,
    TYPE_None,
    TYPE_Ptr,
    TYPE_Word,
    TYPE_List,
    TYPE_Dict,
    TYPE_Union
} TypeTag;

/// A type. A union's members are sorted and distinct, and a union has at
/// least two members; `type_union` builds one.
struct Type {
    TypeTag tag;
    union {
        Named Class;
        Named Enum;
        Type *List;
        /// A dict's key and value types.
        struct { Type *key; Type *value; } Dict;
        TypeVec Union;
    } as;
};

/* TypeSlice borrows storage from its input. TypeRefs has two null pointers
 * for None. type_box_descriptor returns NULL for None. Type children and
 * union storage are immutable; copying a Type by value shares these safely. */
typedef struct TypeSlice {
    const Type *data;
    size_t len;
} TypeSlice;

typedef struct TypeRefs {
    const Type *key;
    const Type *value;
} TypeRefs;

int named_compare(const Named *left, const Named *right);
int type_compare(const Type *left, const Type *right);
bool type_equal(const Type *left, const Type *right);

/// The union of `members`, which may themselves be unions, or the single
/// member that remains.
Type type_union(TypeVec members);
TypeSlice type_members(const Type *self);
/// The element type of a list, or of a union's list member.
const Type *type_list_element(const Type *self);
/// The key and value types of a dict, or of a union's dict member.
TypeRefs type_dict_entry(const Type *self);
/// Whether `==` applies and the value is printable: a scalar, or a
/// union of scalars.
bool type_is_comparable(const Type *self);
/// The equality kind core's list and dict functions compare elements of
/// this type with (core/API.md), for a comparable type.
int64_t type_equality_kind(const Type *self);
bool type_is_union(const Type *self);
bool type_is_optional(const Type *self);
/// `self` without `member`.
Type type_without(const Type *self, const Type *member);
/// Whether every value of `self` is a value of `to`. Willow has no
/// implicit conversions, so this is membership.
bool type_assignable_to(const Type *self, const Type *to);
/// The descriptor of a scalar that a union holds in a box; `str` is
/// already an object and `None` is 0.
String *type_box_descriptor(const Type *self);
/// The symbol of the descriptor in the header of this type's objects and
/// boxes, for a type that is not a union or None.
String type_descriptor(const Type *self);
String type_name(const Type *self);

typedef struct Program Program;
typedef struct Function Function;
typedef struct Op Op;
typedef struct Value Value;
typedef struct Call Call;
typedef struct CallArg CallArg;
typedef struct ValueEntry ValueEntry;
typedef struct Descriptor Descriptor;
VEC_DECL(Function, FunctionVec);
VEC_DECL(Op, OpVec);
VEC_DECL(Value, ValueVec);
VEC_DECL(CallArg, CallArgVec);
VEC_DECL(ValueEntry, ValueEntryVec);
VEC_DECL(Descriptor, DescriptorVec);

struct Program {
    FunctionVec funcs;
    /// String literal contents; literal `n` is the data symbol `$W.str.n`.
    StringVec strings;
    /// Each descriptor's symbol and the literals it holds: its type's name,
    /// then an enum's member texts.
    DescriptorVec descriptors;
    /// The symbol of the entry module's `main`.
    String main;
};

struct Function {
    String symbol;
    StringVec params;
    /// Every local that is not a parameter, in order of first assignment.
    StringVec locals;
    bool returns;
    OpVec body;
};

struct Call {
    /// The callee's symbol, without its `$`.
    String symbol;
    /// Each argument with its QBE type: `l`, `w`, or `d`.
    CallArgVec args;
    /// The number of fixed arguments of a variadic callee.
    OptionSize variadic_at;
    /// The QBE return type, or `None` for no result.
    const char *ret;
};

typedef enum ValueTag {
    VALUE_Const,
    VALUE_Global,
    VALUE_Local,
    VALUE_Call,
    VALUE_Binary,
    VALUE_FloatToInt,
    VALUE_IntToFloat,
    VALUE_FloatBinary,
    VALUE_FloatCompare,
    VALUE_FloatNeg,
    VALUE_Logic,
    VALUE_CheckedInt,
    VALUE_FloorDivide,
    VALUE_Divide,
    VALUE_ListDisplay,
    VALUE_Construct,
    VALUE_DictDisplay,
    VALUE_DictGet,
    VALUE_Item,
    VALUE_Seq,
    VALUE_In,
    VALUE_Load,
    VALUE_Store
} ValueTag;

struct Value {
    ValueTag tag;
    union {
        int64_t Const;
        /// The address of a data symbol, without its `$`.
        String Global;
        String Local;
        Call Call;
        /// A QBE instruction on two `l` operands.
        struct { const char *instr; Value *left; Value *right; } Binary;
        /// QBE `dtosi` on a float's bits.
        Value *FloatToInt;
        /// QBE `sltof`, giving a float's bits.
        Value *IntToFloat;
        /// A QBE arithmetic instruction on two floats' bits.
        struct { const char *instr; Value *left; Value *right; } FloatBinary;
        /// A QBE comparison on two floats' bits.
        struct { const char *instr; Value *left; Value *right; } FloatCompare;
        Value *FloatNeg;
        /// Short-circuit `and`, or `or` when `and` is false.
        struct { bool and; Value *left; Value *right; } Logic;
        /// Integer `add`, `sub`, or `mul`, which calls `fail` when the result is
        /// outside the symmetric int range.
        struct {
            const char *instr;
            Value *left;
            Value *right;
            Value *fail;
        } CheckedInt;
        /// Integer `//`, or `%` when `modulo`, which calls `fail` for a zero divisor.
        struct {
            bool modulo;
            Value *left;
            Value *right;
            Value *fail;
        } FloorDivide;
        /// `/`, on two ints when `ints`, which calls `fail` for a zero divisor.
        struct {
            bool ints;
            Value *left;
            Value *right;
            Value *fail;
        } Divide;
        /// A new list holding the values.
        ValueVec ListDisplay;
        /// A new object with the descriptor holding the field values, which are
        /// evaluated first.
        struct { String descriptor; ValueVec fields; } Construct;
        /// A new dict with keys of the equality kind, holding the entries.
        struct { int64_t kind; ValueEntryVec entries; } DictDisplay;
        /// `d.get(key, default)`: `present`, built from the found value as
        /// a `VALUE_Item` with index 0, or `default`, which is evaluated first.
        struct {
            Value *dict;
            Value *key;
            Value *default_;
            Value *present;
        } DictGet;
        /// An item of the innermost `for` loop or `get`: 0 for an element, a
        /// key, or a found value, and 1 for a dict entry's value.
        size_t Item;
        /// The first value, evaluated for its effects, then the second.
        struct { Value *first; Value *second; } Seq;
        /// Core's `function(container, item, extra...)`, evaluating `item` first
        /// as the source order requires.
        struct {
            const char *function;
            Value *item;
            Value *container;
            ValueVec extra;
        } In;
        /// A QBE load instruction, the pointer, and the byte offset.
        struct { const char *instr; Value *pointer; Value *offset; } Load;
        /// A QBE store instruction, the pointer, the byte offset, and the value.
        struct {
            const char *instr;
            Value *pointer;
            Value *offset;
            Value *value;
        } Store;
    } as;
};

struct CallArg {
    const char *ty;
    Value value;
};

struct ValueEntry {
    Value key;
    Value value;
};

struct Descriptor {
    String symbol;
    SizeVec texts;
};

typedef enum OpTag {
    OP_Assign,
    OP_Eval,
    OP_If,
    OP_While,
    OP_SetField,
    OP_SetItem,
    OP_ForList,
    OP_ForStr,
    OP_ForDict,
    OP_ForRange,
    OP_Break,
    OP_Continue,
    OP_Return
} OpTag;

struct Op {
    OpTag tag;
    union {
        struct { String target; Value value; } Assign;
        Value Eval;
        struct { Value cond; OpVec then; OpVec otherwise; } If;
        struct { Value cond; OpVec body; } While;
        /// Stores `value` in the field at byte `offset` of `object`, evaluating
        /// the value first.
        struct { Value object; int64_t offset; Value value; } SetField;
        /// `object[index] = value` through core's `function`, evaluating the
        /// value first, then the object, then the index.
        struct {
            const char *function;
            Value object;
            Value index;
            Value value;
        } SetItem;
        /// A loop over a list; `stores` assign the `VALUE_Item` at index 0
        /// to the loop variable.
        struct { Value list; OpVec stores; OpVec body; } ForList;
        /// A loop over the code points of a string, each as a string.
        struct { Value text; OpVec stores; OpVec body; } ForStr;
        /// A loop over a dict's live entries; `VALUE_Item` indices 0 and 1
        /// are the key and value. A change to the dict's keys fails the next step.
        struct { Value dict; OpVec stores; OpVec body; } ForDict;
        /// A loop over `range(start, stop, step)`, which calls `fail` for a zero
        /// step.
        struct {
            Value start;
            Value stop;
            Value step;
            Value fail;
            OpVec stores;
            OpVec body;
        } ForRange;
        Value *Return;
    } as;
};

TokenVec lex(String path, String source, bool legacy);
Module parse(String name, String path, TokenVec tokens);
Program check(ModuleVec modules);
String emit(const Program *program);

#endif
