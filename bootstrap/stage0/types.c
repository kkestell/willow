#include "willow0.h"

#include <stdlib.h>

int named_compare(const Named *left, const Named *right) {
    int cmp = str_compare(left->display, right->display);
    return cmp ? cmp : str_compare(left->symbol, right->symbol);
}

int type_compare(const Type *left, const Type *right) {
    if (left->tag != right->tag) {
        return (left->tag > right->tag) - (left->tag < right->tag);
    }
    switch (left->tag) {
    case TYPE_Class:
        return named_compare(&left->as.Class, &right->as.Class);
    case TYPE_Enum:
        return named_compare(&left->as.Enum, &right->as.Enum);
    case TYPE_Int:
    case TYPE_Float:
    case TYPE_Bool:
    case TYPE_Str:
    case TYPE_None:
    case TYPE_Ptr:
    case TYPE_Word:
        return 0;
    case TYPE_List:
        return type_compare(left->as.List, right->as.List);
    case TYPE_Dict: {
        int cmp = type_compare(left->as.Dict.key, right->as.Dict.key);
        return cmp ? cmp : type_compare(left->as.Dict.value, right->as.Dict.value);
    }
    case TYPE_Union: {
        TypeVec a = left->as.Union;
        TypeVec b = right->as.Union;
        size_t len = a.len < b.len ? a.len : b.len;
        for (size_t i = 0; i < len; i++) {
            int cmp = type_compare(&a.data[i], &b.data[i]);
            if (cmp) {
                return cmp;
            }
        }
        return (a.len > b.len) - (a.len < b.len);
    }
    }
    abort();
}

bool type_equal(const Type *left, const Type *right) {
    return type_compare(left, right) == 0;
}

static int compare(const void *left, const void *right) {
    return type_compare(left, right);
}

Type type_union(TypeVec members) {
    TypeVec flat = {0};
    for (size_t i = 0; i < members.len; i++) {
        TypeSlice part = type_members(&members.data[i]);
        for (size_t j = 0; j < part.len; j++) {
            vec_push(flat, part.data[j]);
        }
    }
    if (flat.len > 1) {
        qsort(flat.data, flat.len, sizeof(Type), compare);
    }
    size_t distinct = 0;
    for (size_t i = 0; i < flat.len; i++) {
        if (!distinct || !type_equal(&flat.data[distinct - 1], &flat.data[i])) {
            flat.data[distinct++] = flat.data[i];
        }
    }
    flat.len = distinct;
    if (flat.len == 1) {
        return flat.data[0];
    }
    return (Type){.tag = TYPE_Union, .as.Union = flat};
}

TypeSlice type_members(const Type *self) {
    if (self->tag == TYPE_Union) {
        return (TypeSlice){self->as.Union.data, self->as.Union.len};
    }
    return (TypeSlice){self, 1};
}

const Type *type_list_element(const Type *self) {
    TypeSlice members = type_members(self);
    for (size_t i = 0; i < members.len; i++) {
        if (members.data[i].tag == TYPE_List) {
            return members.data[i].as.List;
        }
    }
    return NULL;
}

TypeRefs type_dict_entry(const Type *self) {
    TypeSlice members = type_members(self);
    for (size_t i = 0; i < members.len; i++) {
        if (members.data[i].tag == TYPE_Dict) {
            return (TypeRefs){members.data[i].as.Dict.key, members.data[i].as.Dict.value};
        }
    }
    return (TypeRefs){0};
}

bool type_is_comparable(const Type *self) {
    TypeSlice members = type_members(self);
    for (size_t i = 0; i < members.len; i++) {
        switch (members.data[i].tag) {
        case TYPE_Int:
        case TYPE_Float:
        case TYPE_Bool:
        case TYPE_Str:
        case TYPE_None:
        case TYPE_Enum:
            break;
        default:
            return false;
        }
    }
    return true;
}

int64_t type_equality_kind(const Type *self) {
    switch (self->tag) {
    case TYPE_Float:
        return 1;
    case TYPE_Str:
        return 2;
    case TYPE_Union:
        return 3;
    default:
        return 0;
    }
}

bool type_is_union(const Type *self) {
    return self->tag == TYPE_Union;
}

bool type_is_optional(const Type *self) {
    if (!type_is_union(self)) {
        return false;
    }
    TypeSlice members = type_members(self);
    for (size_t i = 0; i < members.len; i++) {
        if (members.data[i].tag == TYPE_None) {
            return true;
        }
    }
    return false;
}

Type type_without(const Type *self, const Type *member) {
    TypeVec kept = {0};
    TypeSlice members = type_members(self);
    for (size_t i = 0; i < members.len; i++) {
        bool removed = false;
        TypeSlice remove = type_members(member);
        for (size_t j = 0; j < remove.len; j++) {
            if (type_equal(&members.data[i], &remove.data[j])) {
                removed = true;
            }
        }
        if (!removed) {
            vec_push(kept, members.data[i]);
        }
    }
    return type_union(kept);
}

bool type_assignable_to(const Type *self, const Type *to) {
    TypeSlice members = type_members(self);
    TypeSlice allowed = type_members(to);
    for (size_t i = 0; i < members.len; i++) {
        bool found = false;
        for (size_t j = 0; j < allowed.len; j++) {
            if (type_equal(&members.data[i], &allowed.data[j])) {
                found = true;
                break;
            }
        }
        if (!found) {
            return false;
        }
    }
    return true;
}

String *type_box_descriptor(const Type *self) {
    switch (self->tag) {
    case TYPE_Int:
    case TYPE_Float:
    case TYPE_Bool:
    case TYPE_Enum: {
        String descriptor = type_descriptor(self);
        return box_copy(&descriptor, sizeof(descriptor));
    }
    default:
        return NULL;
    }
}

String type_descriptor(const Type *self) {
    switch (self->tag) {
    case TYPE_Int:
        return STR("W.int.type");
    case TYPE_Float:
        return STR("W.float.type");
    case TYPE_Bool:
        return STR("W.bool.type");
    case TYPE_Str:
        return STR("W.str.type");
    case TYPE_List:
        return STR("W.list.type");
    case TYPE_Dict:
        return STR("W.dict.type");
    case TYPE_Class:
    case TYPE_Enum: {
        String symbol = self->tag == TYPE_Class ? self->as.Class.symbol : self->as.Enum.symbol;
        StringBuilder out = {0};
        sb_append(&out, symbol);
        sb_append(&out, STR(".type"));
        return sb_finish(&out);
    }
    default: {
        StringBuilder out = {0};
        sb_append(&out, type_name(self));
        sb_append(&out, STR(" has no descriptor"));
        fatal(sb_finish(&out));
    }
    }
}

String type_name(const Type *self) {
    switch (self->tag) {
    case TYPE_Int:
        return STR("int");
    case TYPE_Float:
        return STR("float");
    case TYPE_Bool:
        return STR("bool");
    case TYPE_Str:
        return STR("str");
    case TYPE_None:
        return STR("none");
    case TYPE_Ptr:
        return STR("ptr");
    case TYPE_Word:
        return STR("word");
    case TYPE_List: {
        StringBuilder out = {0};
        sb_append(&out, STR("list["));
        sb_append(&out, type_name(self->as.List));
        sb_append(&out, STR("]"));
        return sb_finish(&out);
    }
    case TYPE_Dict: {
        StringBuilder out = {0};
        sb_append(&out, STR("dict["));
        sb_append(&out, type_name(self->as.Dict.key));
        sb_append(&out, STR(", "));
        sb_append(&out, type_name(self->as.Dict.value));
        sb_append(&out, STR("]"));
        return sb_finish(&out);
    }
    case TYPE_Class:
        return self->as.Class.display;
    case TYPE_Enum:
        return self->as.Enum.display;
    case TYPE_Union: {
        StringBuilder out = {0};
        for (size_t i = 0; i < self->as.Union.len; i++) {
            if (i) {
                sb_append(&out, STR(" | "));
            }
            sb_append(&out, type_name(&self->as.Union.data[i]));
        }
        return sb_finish(&out);
    }
    }
    abort();
}
