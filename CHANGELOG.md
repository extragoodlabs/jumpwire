# Changelog

## 4.0.0

### Enhancements

#### PostgreSQL

- Load column information of PostgreSQL views

#### SQL

- Support UNNEST for PostgreSQL queries
- Parse FILTERs on SQL aggregations
- Parse OVERLAY SQL statement
- Parse MySQL MATCH AGAINST statement
- Parse composite access in SQL statements
- Parse INTERVAL SQL statement
- Parse SIMILAR TO in SQL queries
- Parse ON CONFLICT for SQL INSERT statements
- Parse JSON and hstore access in SQL statements
- Parse SQL arrays
- Parse wildcards in SQL functions
- Parse SQL statements with multiple UNION SELECTs
- Parse COLLATE and CAST SQL statements
- Improve parsing of ambiguous table names for SQL fields
- Parse SQL ANY and ALL statements
- Parse SQL derived tables
- Parse SQL nested join syntax
- Parse SQL TABLE function
- Parse SQL EXTRACT, CEIL, FLOOR, and POSITION statements
- Parse SQL SUBSTRING statements
- Parse TRIM SQL statements
- Parse SQL statements for subquery membership and union joins
- All tables are now tracked for matching wildcards in SQL joins

#### TLS

- Wrap ACME certificate ordering with retry logic
- Add a configurable delay for requesting an ACME certificate

#### API

- Create a simple response for HTTP requests to /
- Add the ability to override SSO base URL

### Fixes

#### Core

- Handle messages from supervised tasks started in a DB process

#### SQL

- Handle `nil` order_by in array aggregation parsing
- Fix struct for SQL Substring

#### TLS

- Fix CA/intermediate cert chain for SNI with ACME certs
- Fix ACME domain validation to check the size of each domain part
- Disable SNI for HTTPS when explicitly providing a cert/key

### BREAKING

- Replace the environmental variable JUMPWIRE_SSO_GENERATED_CERTNAME with JUMPWIRE_DOMAIN
- Database credentials no longer show up in logs

## 3.2.0

### Enhancements

#### API

- Return all connection info when generating a client token

#### ACME

- Generate a fallback TLS certificate without requiring ACME

### Bug fixes

#### SSO

- Default groups from SAML assertions to an empty list

#### TLS

- Disable SNI based certificate lookup when explicitly specifying a TLS key and certificate file

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
