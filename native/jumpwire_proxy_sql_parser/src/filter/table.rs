use crate::matcher::TableMatch;
use sqlparser::ast::{
    Assignment, BinaryOperator, CopySource, Cte, Expr, Function, FunctionArg, FunctionArgExpr,
    GroupByExpr, Join, ListAggOnOverflow, OnConflictAction, OnInsert, OrderByExpr, Query, Select,
    SelectItem, SetExpr, Statement, TableFactor, TableWithJoins, WildcardAdditionalOptions,
    WindowType, With,
};

/// Trait to recusrively visit all elements of a query looking for a
/// particular table. When the table is found, a filter expression will
/// be added to it. For example, `SELECT * FROM foo` becomes
/// `SELECT * FROM foo WHERE id = 'abc'`
pub trait TableFilterVisit {
    fn visit(&mut self, _: &Vec<String>, _: &Expr) -> ();
}

impl TableFilterVisit for Expr {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        match *self {
            Expr::JsonAccess {
                ref mut left,
                ref mut right,
                ..
            } => {
                left.visit(table, clause);
                right.visit(table, clause)
            }
            Expr::CompositeAccess { ref mut expr, .. } => expr.visit(table, clause),
            Expr::IsFalse(ref mut expr) => expr.visit(table, clause),
            Expr::IsNotFalse(ref mut expr) => expr.visit(table, clause),
            Expr::IsTrue(ref mut expr) => expr.visit(table, clause),
            Expr::IsNotTrue(ref mut expr) => expr.visit(table, clause),
            Expr::IsNull(ref mut expr) => expr.visit(table, clause),
            Expr::IsNotNull(ref mut expr) => expr.visit(table, clause),
            Expr::IsUnknown(ref mut expr) => expr.visit(table, clause),
            Expr::IsNotUnknown(ref mut expr) => expr.visit(table, clause),
            Expr::IsDistinctFrom(ref mut left, ref mut right) => {
                left.visit(table, clause);
                right.visit(table, clause)
            }
            Expr::IsNotDistinctFrom(ref mut left, ref mut right) => {
                left.visit(table, clause);
                right.visit(table, clause)
            }
            Expr::InList {
                ref mut expr,
                ref mut list,
                ..
            } => {
                expr.visit(table, clause);
                list.visit(table, clause)
            }
            Expr::InSubquery {
                ref mut expr,
                ref mut subquery,
                ..
            } => {
                expr.visit(table, clause);
                subquery.visit(table, clause)
            }
            Expr::InUnnest {
                ref mut expr,
                ref mut array_expr,
                ..
            } => {
                expr.visit(table, clause);
                array_expr.visit(table, clause)
            }
            Expr::Between {
                ref mut expr,
                ref mut low,
                ref mut high,
                ..
            } => {
                expr.visit(table, clause);
                low.visit(table, clause);
                high.visit(table, clause)
            }
            Expr::BinaryOp {
                ref mut left,
                ref mut right,
                ..
            } => {
                left.visit(table, clause);
                right.visit(table, clause)
            }
            Expr::Like {
                ref mut expr,
                ref mut pattern,
                ..
            } => {
                expr.visit(table, clause);
                pattern.visit(table, clause)
            }
            Expr::ILike {
                ref mut expr,
                ref mut pattern,
                ..
            } => {
                expr.visit(table, clause);
                pattern.visit(table, clause)
            }
            Expr::SimilarTo {
                ref mut expr,
                ref mut pattern,
                ..
            } => {
                expr.visit(table, clause);
                pattern.visit(table, clause)
            }
            Expr::AnyOp {
                ref mut left,
                ref mut right,
                ..
            } => {
                left.visit(table, clause);
                right.visit(table, clause)
            }
            Expr::AllOp {
                ref mut left,
                ref mut right,
                ..
            } => {
                left.visit(table, clause);
                right.visit(table, clause)
            }
            Expr::UnaryOp { ref mut expr, .. } => expr.visit(table, clause),
            Expr::Cast { ref mut expr, .. } => expr.visit(table, clause),
            Expr::TryCast { ref mut expr, .. } => expr.visit(table, clause),
            Expr::SafeCast { ref mut expr, .. } => expr.visit(table, clause),
            Expr::AtTimeZone {
                ref mut timestamp, ..
            } => timestamp.visit(table, clause),
            Expr::Extract { ref mut expr, .. } => expr.visit(table, clause),
            Expr::Ceil { ref mut expr, .. } => expr.visit(table, clause),
            Expr::Floor { ref mut expr, .. } => expr.visit(table, clause),
            Expr::Position {
                ref mut expr,
                ref mut r#in,
            } => {
                expr.visit(table, clause);
                r#in.visit(table, clause)
            }
            Expr::Substring {
                ref mut expr,
                ref mut substring_from,
                ref mut substring_for,
                ..
            } => {
                substring_from.visit(table, clause);
                substring_for.visit(table, clause);
                expr.visit(table, clause)
            }
            Expr::Trim {
                ref mut expr,
                ref mut trim_what,
                ..
            } => {
                trim_what.visit(table, clause);
                expr.visit(table, clause)
            }
            Expr::Overlay {
                ref mut expr,
                ref mut overlay_what,
                ref mut overlay_from,
                ref mut overlay_for,
                ..
            } => {
                overlay_for.visit(table, clause);
                overlay_from.visit(table, clause);
                overlay_what.visit(table, clause);
                expr.visit(table, clause)
            }
            Expr::Collate { ref mut expr, .. } => expr.visit(table, clause),
            Expr::Nested(ref mut expr) => expr.visit(table, clause),
            Expr::MapAccess {
                ref mut column,
                ref mut keys,
                ..
            } => {
                column.visit(table, clause);
                keys.visit(table, clause)
            }
            Expr::AggregateExpressionWithFilter {
                ref mut expr,
                ref mut filter,
            } => {
                expr.visit(table, clause);
                filter.visit(table, clause)
            }
            Expr::Case {
                ref mut operand,
                ref mut conditions,
                ref mut results,
                ref mut else_result,
                ..
            } => {
                operand.visit(table, clause);
                conditions.visit(table, clause);
                results.visit(table, clause);
                else_result.visit(table, clause)
            }
            Expr::Exists {
                ref mut subquery, ..
            } => subquery.visit(table, clause),
            Expr::Subquery(ref mut query) => query.visit(table, clause),
            Expr::ArraySubquery(ref mut query) => query.visit(table, clause),
            Expr::ListAgg(ref mut agg) => {
                agg.expr.visit(table, clause);
                agg.separator.visit(table, clause);
                agg.on_overflow.as_mut().map(|overflow| {
                    if let ListAggOnOverflow::Truncate { filler, .. } = overflow {
                        filler.visit(table, clause);
                    }
                });
                for group in agg.within_group.iter_mut() {
                    group.expr.visit(table, clause);
                }
            }
            Expr::ArrayAgg(ref mut agg) => {
                agg.expr.visit(table, clause);
                agg.limit.visit(table, clause);
                agg.order_by.as_mut().map(|order| {
                    for o in order.iter_mut() {
                        o.expr.visit(table, clause);
                    }
                });
            }
            Expr::GroupingSets(ref mut exprs) => exprs.visit(table, clause),
            Expr::Cube(ref mut exprs) => exprs.visit(table, clause),
            Expr::Rollup(ref mut exprs) => exprs.visit(table, clause),
            Expr::Tuple(ref mut exprs) => exprs.visit(table, clause),
            Expr::ArrayIndex {
                ref mut obj,
                ref mut indexes,
            } => {
                obj.visit(table, clause);
                indexes.visit(table, clause)
            }
            Expr::Array(ref mut array) => array.elem.visit(table, clause),
            Expr::Interval(ref mut int) => int.value.visit(table, clause),
            Expr::Function(ref mut func) => func.visit(table, clause),
            _ => (),
        }
    }
}

impl TableFilterVisit for Statement {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        match *self {
            Statement::Query(ref mut query) => query.visit(table, clause),
            Statement::Insert {
                ref mut source,
                ref mut partitioned,
                ref mut on,
                ref mut returning,
                ..
            } => {
                source.visit(table, clause);
                partitioned.visit(table, clause);
                on.visit(table, clause);
                returning.visit(table, clause)
            }
            Statement::Copy { ref mut source, .. } => source.visit(table, clause),
            Statement::Update {
                table: ref mut update_table,
                ref mut assignments,
                ref mut from,
                ref mut selection,
                ref mut returning,
            } => {
                assignments.visit(table, clause);
                returning.visit(table, clause);
                update_table.visit(table, clause);
                from.visit(table, clause);

                if update_table.matches(table) || from.matches(table) {
                    let updated = match selection {
                        None => Some(clause.clone()),
                        Some(existing) => Some(Expr::BinaryOp {
                            op: BinaryOperator::And,
                            left: Box::new(existing.clone()),
                            right: Box::new(clause.clone()),
                        }),
                    };
                    *selection = updated;
                }

                selection.visit(table, clause)
            }
            Statement::Delete {
                ref tables,
                ref mut from,
                ref mut using,
                ref mut selection,
                ref mut returning,
            } => {
                returning.visit(table, clause);
                from.visit(table, clause);
                using.visit(table, clause);

                if tables.matches(table) || from.matches(table) || using.matches(table) {
                    let updated = match selection {
                        None => Some(clause.clone()),
                        Some(existing) => Some(Expr::BinaryOp {
                            op: BinaryOperator::And,
                            left: Box::new(existing.clone()),
                            right: Box::new(clause.clone()),
                        }),
                    };
                    *selection = updated;
                }

                selection.visit(table, clause)
            }
            Statement::CreateView { ref mut query, .. } => query.visit(table, clause),
            _ => (),
        }
    }
}

impl TableFilterVisit for Function {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        self.args.visit(table, clause);
        self.over.visit(table, clause);
        self.order_by.visit(table, clause)
    }
}

impl TableFilterVisit for FunctionArg {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        let expr = match *self {
            FunctionArg::Named {
                name: _,
                ref mut arg,
            } => arg,
            FunctionArg::Unnamed(ref mut arg) => arg,
        };

        if let FunctionArgExpr::Expr(ref mut expr) = expr {
            expr.visit(table, clause)
        }
    }
}

impl TableFilterVisit for WindowType {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        if let WindowType::WindowSpec(ref mut spec) = *self {
            spec.partition_by.visit(table, clause);
            spec.order_by.visit(table, clause)
        }
    }
}

impl TableFilterVisit for OrderByExpr {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        self.expr.visit(table, clause)
    }
}

impl TableFilterVisit for OnInsert {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        match *self {
            OnInsert::DuplicateKeyUpdate(ref mut assignments) => {
                for a in assignments.iter_mut() {
                    a.visit(table, clause);
                }
            }
            OnInsert::OnConflict(ref mut conflict) => {
                if let OnConflictAction::DoUpdate(ref mut update) = conflict.action {
                    update.selection.visit(table, clause);
                    update.assignments.visit(table, clause)
                }
            }
            _ => (),
        }
    }
}

impl TableFilterVisit for SelectItem {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        match *self {
            SelectItem::UnnamedExpr(ref mut expr) => expr.visit(table, clause),
            SelectItem::ExprWithAlias {
                ref mut expr,
                alias: _,
            } => expr.visit(table, clause),
            _ => (),
        }
    }
}

impl TableFilterVisit for Assignment {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        self.value.visit(table, clause)
    }
}

impl TableFilterVisit for SetExpr {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        match *self {
            SetExpr::Select(ref mut select) => select.visit(table, clause),
            SetExpr::Query(ref mut query) => query.visit(table, clause),
            SetExpr::Insert(ref mut statement) => statement.visit(table, clause),
            SetExpr::Update(ref mut statement) => statement.visit(table, clause),
            SetExpr::SetOperation {
                ref mut left,
                ref mut right,
                ..
            } => {
                left.visit(table, clause);
                right.visit(table, clause)
            }
            _ => (),
        }
    }
}

impl TableFilterVisit for Select {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        if self.matches(table) {
            self.selection = match &self.selection {
                None => Some(clause.clone()),
                Some(existing) => Some(Expr::BinaryOp {
                    op: BinaryOperator::And,
                    left: Box::new(existing.clone()),
                    right: Box::new(clause.clone()),
                }),
            };
        }

        self.from.visit(table, clause);
        self.selection.visit(table, clause);
        self.projection.visit(table, clause)
    }
}

impl TableFilterVisit for Query {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        self.with.visit(table, clause);
        self.order_by.visit(table, clause);
        self.limit.visit(table, clause);
        self.body.visit(table, clause)
    }
}

impl TableFilterVisit for With {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        self.cte_tables.visit(table, clause)
    }
}

impl TableFilterVisit for Cte {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        self.query.visit(table, clause)
    }
}

impl TableFilterVisit for TableWithJoins {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        for join in self.joins.iter_mut() {
            join.visit(table, clause)
        }
        self.relation.visit(table, clause)
    }
}

impl TableFilterVisit for Join {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        self.relation.visit(table, clause)
    }
}

impl TableFilterVisit for TableFactor {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        match self {
            TableFactor::Table { with_hints, .. } => with_hints.visit(table, clause),
            TableFactor::Derived { subquery, .. } => subquery.visit(table, clause),
            TableFactor::TableFunction { expr, alias: _ } => expr.visit(table, clause),
            TableFactor::UNNEST { array_exprs, .. } => array_exprs.visit(table, clause),
            TableFactor::NestedJoin {
                table_with_joins,
                alias: _,
            } => table_with_joins.visit(table, clause),
            TableFactor::Pivot {
                aggregate_function, ..
            } => aggregate_function.visit(table, clause),
        }
    }
}

impl TableFilterVisit for CopySource {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        match *self {
            CopySource::Table {
                ref table_name,
                ref columns,
            } => {
                if table_name.matches(table) {
                    let table = TableWithJoins {
                        relation: TableFactor::Table {
                            name: table_name.clone(),
                            alias: None,
                            args: None,
                            with_hints: vec![],
                            version: None,
                            partitions: vec![],
                        },
                        joins: vec![],
                    };
                    let projection = if columns.is_empty() {
                        vec![SelectItem::Wildcard(WildcardAdditionalOptions::default())]
                    } else {
                        columns
                            .iter()
                            .map(|c| SelectItem::UnnamedExpr(Expr::Identifier(c.clone())))
                            .collect()
                    };
                    let select = Select {
                        distinct: None,
                        top: None,
                        projection,
                        into: None,
                        from: vec![table],
                        lateral_views: vec![],
                        selection: Some(clause.clone()),
                        group_by: GroupByExpr::Expressions(vec![]),
                        cluster_by: vec![],
                        distribute_by: vec![],
                        sort_by: vec![],
                        having: None,
                        named_window: vec![],
                        qualify: None,
                    };
                    let body = SetExpr::Select(Box::new(select));
                    let query = Query {
                        with: None,
                        body: Box::new(body),
                        order_by: vec![],
                        limit: None,
                        offset: None,
                        fetch: None,
                        locks: vec![],
                    };
                    *self = CopySource::Query(Box::new(query));
                    ()
                }
            }
            CopySource::Query(ref mut query) => query.visit(table, clause),
        }
    }
}

impl<T: TableFilterVisit> TableFilterVisit for Option<T> {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        match self {
            None => (),
            Some(x) => x.visit(table, clause),
        }
    }
}

impl<T: TableFilterVisit> TableFilterVisit for Box<T> {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        (**self).visit(table, clause)
    }
}

impl<T: TableFilterVisit> TableFilterVisit for Vec<T> {
    fn visit(&mut self, table: &Vec<String>, clause: &Expr) -> () {
        for x in self.iter_mut() {
            x.visit(table, clause)
        }
    }
}
