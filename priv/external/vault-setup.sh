#!/usr/bin/env bash

vault secrets enable database

vault write database/config/storefront \
    plugin_name="postgresql-database-plugin" \
    allowed_roles="jumpwire" \
    connection_url="postgresql://{{username}}:{{password}}@localhost:5432/storefront" \
    username="postgres" \
    password="postgres"

vault write database/roles/jumpwire \
    db_name="storefront" \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
GRANT ALL ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"
