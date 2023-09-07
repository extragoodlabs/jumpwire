# Changelog

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
