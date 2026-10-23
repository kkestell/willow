//! The static types stage 0 checks.

/// A type. A union's members are sorted and distinct, and a union has at
/// least two members; `Type::union` builds one.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Type {
    Int,
    Float,
    Bool,
    Str,
    None,
    Ptr,
    Word,
    List(Box<Type>),
    Union(Vec<Type>),
}

impl Type {
    /// The union of `members`, which may themselves be unions, or the single
    /// member that remains.
    pub fn union(members: impl IntoIterator<Item = Type>) -> Type {
        let mut flat: Vec<Type> = members
            .into_iter()
            .flat_map(|m| m.members().to_vec())
            .collect();
        flat.sort();
        flat.dedup();
        if flat.len() == 1 {
            flat.pop().unwrap()
        } else {
            Type::Union(flat)
        }
    }

    pub fn members(&self) -> &[Type] {
        match self {
            Type::Union(members) => members,
            _ => std::slice::from_ref(self),
        }
    }

    /// The element type of a list, or of a union's list member.
    pub fn list_element(&self) -> Option<&Type> {
        self.members().iter().find_map(|m| match m {
            Type::List(element) => Some(&**element),
            _ => None,
        })
    }

    /// Whether `==` applies: a scalar, or a union of scalars.
    pub fn is_comparable(&self) -> bool {
        self.members().iter().all(|m| {
            matches!(
                m,
                Type::Int | Type::Float | Type::Bool | Type::Str | Type::None
            )
        })
    }

    /// The equality kind core's list and dict functions compare elements of
    /// this type with (core/API.md), for a comparable type.
    pub fn equality_kind(&self) -> i64 {
        match self {
            Type::Float => 1,
            Type::Str => 2,
            Type::Union(_) => 3,
            _ => 0,
        }
    }

    pub fn is_union(&self) -> bool {
        matches!(self, Type::Union(_))
    }

    pub fn is_optional(&self) -> bool {
        self.is_union() && self.members().contains(&Type::None)
    }

    /// `self` without `member`.
    pub fn without(&self, member: &Type) -> Type {
        Type::union(self.members().iter().filter(|m| *m != member).cloned())
    }

    /// Whether every value of `self` is a value of `to`. Willow has no
    /// implicit conversions, so this is membership.
    pub fn assignable_to(&self, to: &Type) -> bool {
        self.members().iter().all(|m| to.members().contains(m))
    }

    /// The descriptor of a scalar that a union holds in a box; `str` is
    /// already an object and `None` is 0.
    pub fn box_descriptor(&self) -> Option<&'static str> {
        match self {
            Type::Int => Some("W.int.type"),
            Type::Float => Some("W.float.type"),
            Type::Bool => Some("W.bool.type"),
            _ => None,
        }
    }

    pub fn name(&self) -> String {
        match self {
            Type::Int => "int".into(),
            Type::Float => "float".into(),
            Type::Bool => "bool".into(),
            Type::Str => "str".into(),
            Type::None => "None".into(),
            Type::Ptr => "ptr".into(),
            Type::Word => "word".into(),
            Type::List(element) => format!("list[{}]", element.name()),
            Type::Union(members) => {
                let names: Vec<String> = members.iter().map(Type::name).collect();
                names.join(" | ")
            }
        }
    }
}
