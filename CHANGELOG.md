# Changelog

## 3.1.0

### Enhancements

#### Core

- Optionally track anonymous usage information
- Update certificate bundle for verifying TLS connections to AWS RDS instances
- Make PostgreSQL benchmark script runnable as a mix task

#### PostgreSQL

- Parse queries containing multiple statements
- Parse `SET` statements for variables and time zones

## 3.0.1

### Bug fixes

#### PostgreSQL

- Parse namespace for `pg_catalog` tables
- Reduce log noise for tables with no schemas/labels

## 3.0.0

The first open-source release of JumpWire! 🥳
