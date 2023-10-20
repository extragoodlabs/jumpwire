use sqlparser::ast::*;

/// Trait for matching against a table name
pub trait TableMatch<Rhs>
where
    Rhs: ?Sized,
{
    fn matches(&self, other: &Rhs) -> bool;
}

impl TableMatch<Vec<String>> for TableFactor {
    fn matches(&self, other: &Vec<String>) -> bool {
        match self {
            TableFactor::Table { name, .. } => name.matches(other),
            TableFactor::NestedJoin {
                table_with_joins, ..
            } => table_with_joins.matches(other),
            _ => false,
        }
    }
}

impl TableMatch<Vec<String>> for TableWithJoins {
    fn matches(&self, other: &Vec<String>) -> bool {
        self.relation.matches(other) || self.joins.iter().any(|join| join.relation.matches(other))
    }
}

impl TableMatch<Vec<String>> for ObjectName {
    fn matches(&self, other: &Vec<String>) -> bool {
        self.0.matches(other)
    }
}

impl TableMatch<Vec<String>> for Select {
    fn matches(&self, other: &Vec<String>) -> bool {
        self.from.matches(other)
    }
}

impl TableMatch<Vec<String>> for Vec<Ident> {
    fn matches(&self, other: &Vec<String>) -> bool {
        let ident: Vec<String> = self.iter().map(|i| i.value.to_lowercase()).collect();
        ident == *other
    }
}

impl<T: TableMatch<Vec<String>>> TableMatch<Vec<String>> for Vec<T> {
    fn matches(&self, other: &Vec<String>) -> bool {
        self.iter().any(|x| x.matches(other))
    }
}

impl<T: TableMatch<Vec<String>>> TableMatch<Vec<String>> for Option<T> {
    fn matches(&self, other: &Vec<String>) -> bool {
        match self {
            None => false,
            Some(x) => x.matches(other),
        }
    }
}
