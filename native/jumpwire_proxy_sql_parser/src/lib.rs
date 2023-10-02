use rustler::{Atom, Binary, Env, NifUnitEnum, ResourceArc, Term};
use serde_rustler::prefixed_to_term;
use sqlparser::ast::Statement;
use sqlparser::dialect::{GenericDialect, MySqlDialect, PostgreSqlDialect};
use sqlparser::parser::{Parser, ParserError};
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        tokenizer_error,
        parser_error,
        recursion_limit_exceeded,
    }
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
fn to_sql(resource: ResourceArc<StatementResource>) -> Result<String, (Atom, String)> {
    let statement = resource.statement.try_lock().unwrap();
    let sql = format!("{}", statement);
    Ok(sql)
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
    [parse_postgresql, debug_parse, to_sql],
    load = load
);
