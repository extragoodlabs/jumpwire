use crate::filter::TableFilterVisit;
use rustler::{Atom, Binary, Env, Error, NifResult, NifUnitEnum, ResourceArc, Term, TermType};
use serde_rustler::prefixed_to_term;
use sqlparser::ast::{visit_statements_mut, BinaryOperator, Expr, Ident, Statement, Value};
use sqlparser::dialect::{GenericDialect, MySqlDialect, PostgreSqlDialect};
use sqlparser::parser::{Parser, ParserError};
use std::ops::ControlFlow;
use std::sync::Mutex;

mod filter;
mod matcher;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        tokenizer_error,
        parser_error,
        recursion_limit_exceeded,
        mutex_locked,
    }
}

#[derive(NifUnitEnum)]
enum BinaryOp {
    Eq,
    Gt,
    Lt,
}

#[derive(NifUnitEnum)]
enum Dialect {
    Postgresql,
    Mysql,
    Generic,
}

#[rustler::nif]
fn debug_parse(query: Binary, dialect: Dialect) -> String {
    let dialect: Box<dyn sqlparser::dialect::Dialect> = match dialect {
        Dialect::Postgresql => Box::new(PostgreSqlDialect {}),
        Dialect::Mysql => Box::new(MySqlDialect {}),
        Dialect::Generic => Box::new(GenericDialect {}),
    };

    let sql = std::str::from_utf8(query.as_slice()).unwrap();
    let parsed = Parser::parse_sql(&*dialect, sql).unwrap();
    format!("{parsed:?}")
}

#[rustler::nif]
fn parse_postgresql<'a>(
    env: Env<'a>,
    query: Binary,
) -> Result<Vec<(Term<'a>, ResourceArc<StatementResource>)>, (Atom, String)> {
    let sql = std::str::from_utf8(query.as_slice()).unwrap();
    let parsed_result = parse(sql);
    let statements = match parsed_result {
        Ok(s) => s,
        Err(err) => {
            let err = match err {
                ParserError::TokenizerError(err) => (atoms::tokenizer_error(), err),
                ParserError::ParserError(err) => (atoms::parser_error(), err),
                ParserError::RecursionLimitExceeded => {
                    (atoms::recursion_limit_exceeded(), String::from(""))
                }
            };
            return Err(err);
        }
    };

    let prefix = "Elixir.JumpWire.Proxy.SQL.Statement.";

    match prefixed_to_term(env, &statements, prefix) {
        Ok(term) => {
            let resources = statements.into_iter().map(|s| {
                let resource = StatementResource {
                    statement: Mutex::new(s),
                };
                ResourceArc::new(resource)
            });
            let res = term.into_list_iterator().unwrap().zip(resources).collect();
            Ok(res)
        }
        Err(err) => {
            let msg: String = err.into();
            Err((atoms::error(), msg))
        }
    }
}

struct StatementResource {
    pub statement: Mutex<Statement>,
}

#[rustler::nif]
fn to_sql(resource: ResourceArc<StatementResource>) -> NifResult<(Atom, String)> {
    let statement = resource
        .statement
        .try_lock()
        .map_err(|_| Error::Atom("mutex_lock_failure"))?;
    let sql = format!("{}", statement);
    Ok((atoms::ok(), sql))
}

#[rustler::nif]
fn add_table_selection<'a>(
    resource: ResourceArc<StatementResource>,
    table: String,
    left: String,
    op: BinaryOp,
    right: Term<'a>,
) -> NifResult<Atom> {
    let left = Expr::Identifier(Ident {
        value: left,
        quote_style: None,
    });
    let right = match right.get_type() {
        TermType::Integer | TermType::Float => {
            let term: i32 = right.decode()?;
            Expr::Value(Value::Number(term.to_string(), false))
        }
        TermType::Binary => Expr::Value(Value::SingleQuotedString(right.decode()?)),
        _ => return Err(Error::Atom("invalid_value")),
    };

    let selection = match op {
        BinaryOp::Eq => Expr::BinaryOp {
            left: Box::new(left),
            op: BinaryOperator::Eq,
            right: Box::new(right),
        },
        _ => return Err(Error::Atom("unknown_operator")),
    };

    let mut statement = resource
        .statement
        .try_lock()
        .map_err(|_| Error::Atom("mutex_lock_failure"))?;

    // TODO: better matching for the Ident, allow table name to have a specified namespace
    let table_ident = vec![table.to_lowercase()];

    // find all selections, create a where clause or modify it if possible
    visit_statements_mut(&mut *statement, |stmt| {
        stmt.visit(&table_ident, &selection);
        ControlFlow::<()>::Continue(())
    });
    Ok(atoms::ok())
}

fn parse(sql: &str) -> Result<Vec<Statement>, ParserError> {
    let dialect = PostgreSqlDialect {};
    Parser::parse_sql(&dialect, sql)
}

fn load(env: Env, _: Term) -> bool {
    rustler::resource!(StatementResource, env);
    true
}

rustler::init!(
    "Elixir.JumpWire.Proxy.SQL.Parser",
    [parse_postgresql, debug_parse, to_sql, add_table_selection],
    load = load
);
