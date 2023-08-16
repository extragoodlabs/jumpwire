use rustler::{Atom, Binary, Env, Term};
use serde_rustler::prefixed_to_term;
use sqlparser::ast::Statement;
use sqlparser::dialect::PostgreSqlDialect;
use sqlparser::parser::{Parser, ParserError};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        tokenizer_error,
        parser_error,
        recursion_limit_exceeded,
    }
}

#[rustler::nif]
fn parse_postgresql<'a>(env: Env<'a>, query: Binary) -> Result<Term<'a>, (Atom, String)> {
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

    prefixed_to_term(env, statements, prefix).map_err(|err| {
        let msg: String = err.into();
        (atoms::error(), msg)
    })
}

fn parse(sql: &str) -> Result<Vec<Statement>, ParserError> {
    let dialect = PostgreSqlDialect {};
    Parser::parse_sql(&dialect, sql)
}

rustler::init!("Elixir.JumpWire.Proxy.SQL.Parser", [parse_postgresql]);
