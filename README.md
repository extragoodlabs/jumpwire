<div align="center">

[![JumpWire](./images/jumpwire-logo.png)](https://jumpwire.io)

#### Identity Aware Database Gateway

<!-- Nav header - Start -->
[Home Page](https://jumpwire.io)
·
[Documentation](https://docs.jumpwire.io)
·
[Contact](#support-and-bug-reports)
<!-- Nav header - END -->

<!-- Badges - Start -->
[![GitHub Release](https://img.shields.io/github/v/tag/extragoodlabs/jumpwire?style=flat-square&filter=*.*.*&label=Version)](https://github.com/extragoodlabs/jumpwire/pkgs/container/jumpwire)
![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/extragoodlabs/jumpwire/shipit.yaml?style=flat-square&label=CI)
<a href="https://ycombinator.com"><img src="https://img.shields.io/website?color=%23f26522&down_message=Y%20Combinator&label=Backed&logo=ycombinator&style=flat-square&up_message=Y%20Combinator&url=https%3A%2F%2Fwww.ycombinator.com"></a>
<!-- Badges - End -->
</div>

JumpWire is a database gateway that applies security policies based on both the data flowing through it and the identity of the connecting user or application. Connections are proxied through JumpWire so that requests and responses can be inspected and modified. The fields within a database are assigned labels, either automatically or manually, making it easy to separate the control of data from the raw structure of it.

Here are some examples of what JumpWire can do:

- Allow engineers to connect to production databases, but prevent them from seeing any private customer information
- Automatically encrypt PII as it enters your database and decrypt it only for a billing application
- Provide on-call engineers a way to quickly elevate database access when responding to an incident
- Keep an audit trail of access to sensitive data

## Features

Currently, JumpWire supports proxying database clients to both PostgreSQL and MySQL.

Additional information is available in [our documentation](https://docs.jumpwire.io/).

### Privileged access management

Group access policies provide a way to control queries and ensure they will only return data that has been approved for a group member to access. Any query that attempts to access data types that are restricted will be rejected. In addition to controlling access to data types, specific query operations - `SELECT`, `UPDATE`, etc - can also be allowed or restricted.

**Enterprise only**: In addition to controlling group access, JumpWire Enterprise allows additional access to be granted in a just-in-time manner based on what data the user is actively querying for.

### Automatic schema discovery and labeling

JumpWire automatically detects and labels sensitive data in your existing schemas. Extra tools are provided to modify or add labels as needed.

### Field-level encryption

All fields for a configured label are automatically encrypted, either as they pass through the JumpWire proxy gateway or directly in the database. Specific applications can be configured to decrypt the data through JumpWire automatically, without making any code changes or having to perform extra queries.

## How it works

The JumpWire gateway is designed to be deployed in front of your existing database. Client configurations are updated to point to JumpWire instead of directly to the gateway, and JumpWire proxies those connections through to the destination database.

JumpWire directly implements native database protocols. All standard clients work with the gateway without any code changes needed.

When a client attempts to connect through the proxy without credentials, a magic login link is generated. Using the [jwctl CLI](https://github.com/extragoodlabs/jwctl) or an integration available with JumpWire Enterprise, the login attempt can be linked to an SSO user and associated permissions.

![DB Authorization Architecture](/images/DB%20Authorization%20Architecture.png)

## Quick Install

JumpWire is packaged as a Docker image and doesn't have any hard dependencies (besides the database being proxied, of course). The image is hosted on [GitHub Packages](https://github.com/extragoodlabs/jumpwire/pkgs/container/jumpwire)

Create a configuration file called `jumpwire.yaml`. The following example configures JumpWire to proxy through to a PostgreSQL server running on the local host with a database named `test_db` and a table named `users`:

```yaml
# configure a postgresql database
manifests:
  - id: 0779b97a-c04a-48f9-9483-22e8b0487de4
    name: my local db
    root_type: postgresql
    credentials:
      username: postgres
      password: postgres
    configuration:
      type: postgresql
      database: test_db
      hostname: host.docker.internal
      ssl: false
      port: 5432

# set labels on fields
proxy_schemas:
  - id: f764dd5b-fb38-401a-b414-edfa8230fd11
    name: users
    # must match the ID set for PostgreSQL
    manifest_id: 0779b97a-c04a-48f9-9483-22e8b0487de4
    fields:
      name: pii
      address: pii
      favorite_cheese: secret

# create a client for the application connections
client_auth:
  - id: ccf334b5-2d5a-45ee-a6dd-c34caf99e4d4
    name: psql
    manifest_id: 0779b97a-c04a-48f9-9483-22e8b0487de4

groups:
  # Engineers will be able to do anything to data labeled
  # `secret` but all operations involving other labels
  # will be blocked
  Engineers:
    permissions:
    - select:secret
    - update:secret
    - insert:secret
    - delete:secret
```

Start the JumpWire gateway:

``` shell
export ENCRYPTION_KEY=$(openssl rand -base64 32)
export JUMPWIRE_ROOT_TOKEN=$(openssl rand -base64 32)
docker run -d --name jumpwire \
  -p 4004:4004 -p 4443:4443 -p 3307:3307 -p 6432:6432 \
  -v $(pwd)/jumpwire.yaml:/etc/jumpwire/jumpwire.yaml \
  -e JUMPWIRE_CONFIG_PATH=/etc/jumpwire \
  -e JUMPWIRE_ENCRYPTION_KEY="${ENCRYPTION_KEY}" \
  -e JUMPWIRE_POSTGRES_PROXY_PORT=6432 \
  -e JUMPWIRE_ROOT_TOKEN="${JUMPWIRE_ROOT_TOKEN}" \
  -e JUMPWIRE_MYSQL_PROXY_PORT=3307 \
  ghcr.io/extragoodlabs/jumpwire:latest
```

Setting proxy ports depends on whether there are other services running on the same ports on the host. For example, if a PostgreSQL database is running on the same host as the container, it's necessary to map the gateway's proxy port to something other than 5432, since that port is occupied by the local PostgreSQL database. The example above maps proxy ports to a non-standard port number (`6432` and `3307`) to avoid conflicts with locally running databases.

If the gateway starts up correctly, the following message should be printed to the logs:

``` text
************************************************************
The JumpWire engine is up!

Check out our documentation at https://docs.jumpwire.io.

Version: x.x.x
************************************************************
```

JumpWire's CLI, [jwctl](https://github.com/extragoodlabs/jwctl), can be used to validate that the gateway is running.

```shell
jwctl -u http://localhost:4004 -t "${JUMPWIRE_ROOT_TOKEN}" status
# [INFO] Remote status:
# {
#   "clusters_joined": {},
#   "credential_adapters": [],
#   "domain": null,
#   "key_adapters": [
#     "DeltaCrdt"
#   ],
#   "ports": {
#     "http": 4004,
#     "https": 4443,
#     "mysql": 3306,
#     "postgres": 6432
#   },
#   "web_connected": false
# }
```

With the container running, the JumpWire gateway can connect to databases that are also running on the same host as the container, or accessible from the same host.

To connect through the gateway to the database, the only change necessary is to update your application's connection string. JumpWire implements native database protocols, so there are no library or code changes necessary to connect to the gateway. Use `jwctl` to generate credentials that any database client can use:

```shell
jwctl -u http://localhost:4000 -t "${JUMPWIRE_ROOT_TOKEN}" client token ccf334b5-2d5a-45ee-a6dd-c34caf99e4d4
# [INFO] Token generated:

# username: 0779b97a-c04a-48f9-9483-22e8b0487de4
# password: SFMyNTY.g2gDaAJtAAAAC29yZ19nZW5l...
```

Now these credentials can be used to connect through the gateway to the database, using any client.

```shell
psql -h localhost -p 6432 -U 0779b97a-c04a-48f9-9483-22e8b0487de4 -W -d test_db
# Password:
# psql (15.3 (Ubuntu 15.3-1.pgdg22.04+1))
# SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384, compression: off)
# Type "help" for help.

# test_db=#
```

### Kubernetes

A Helm chart is available for deploying JumpWire into Kubernetes. Documentation is available at [https://docs.jumpwire.io/self-hosting-with-helm](https://docs.jumpwire.io/self-hosting-with-helm).

### Ports

The following ports are used by default:

- `4004` - HTTP server for JSON API requests
- `4443` - HTTPS server for JSON API requests
- `9568` - Endpoint that exposes Prometheus telemetry metrics. Useful for reporting on a variety of operations from the gateway container, as well as performance.
- `5432` - Client connections for PostgreSQL.
- `3306` - Client connections for MySQL.
- `4369` - Internal port used for nodes in the same cluster to connect to each other. When running more than one JumpWire node, his must be exposed to other nodes in the cluster but should not be publicly accessible.

These ports can be changed using environmental variables as noted below.

## Installation Guides

Check out these handy installation guides as a reference for configuring or deploying JumpWire in common use-case setups and public clouds.

- [Login to database with Google Single Sign-On](./docs/sso-guide.md)

## Configuration

### Configuration files

Setting up connections to proxied databases and the policies governing those is done with YAML files. The configuration can be broken into multiple files; every YAML file within the configured directory will be loaded and merged together. The env var `JUMPWIRE_CONFIG_PATH` is used to set the directory containing config files.

The available configuration options are detailed in [our documentation](https://docs.jumpwire.io/local-file-configuration).

### Environmental variables

| Name | Default | Description |
| --- | --- | --- |
| JUMPWIRE_ENCRYPTION_KEY | - | Secret used for performing field level AES encryption |
| JUMPWIRE_ROOT_TOKEN | - | Root token for the HTTP API. If not provided, a token will be automatically generated.
| JUMPWIRE_TOKEN_KEY | value of JUMPWIRE_ROOT_TOKEN | Secret key used for signing and verifying tokenized data. |
| LOG_LEVEL | info | Verbosity for logging. |
| RELEASE_COOKIE | - | Shared secret used for distributed connectivity. Must be identical on all nodes in the cluster. |
| JUMPWIRE_TOKEN | - | Token used to authenticate with the web interface. |
| JUMPWIRE_FRONTEND | - | WebSocket URL to connect to when using a web controller |
| JUMPWIRE_DOMAIN| localhost | Domain of the JumpWire gateway |
| JUMPWIRE_HTTP_PORT | 4004 | Port to listen for HTTP request. |
| JUMPWIRE_HTTPS_PORT | 4443 | Port to listen for HTTPS request. |
| JUMPWIRE_PROMETHEUS_PORT | 9568 | Port to serve Prometheus stats on, under the `/metrics` endpoint. |
| JUMPWIRE_POSTGRES_PROXY_PORT | 5432 | Port to listen for incoming postgres clients |
| JUMPWIRE_MYSQL_PROXY_PORT | 3306 | Port to listen for incoming mysql clients. |
| JUMPWIRE_TLS_CERT | - | Public cert to use for HTTPS |
| JUMPWIRE_TLS_KEY | - | Private key to use for HTTPS |
| JUMPWIRE_TLS_CA | [CAStore](https://github.com/elixir-mint/castore) | CA cert bundle to use for HTTPS |
| JUMPWIRE_CONFIG_PATH | priv/config | Directory to load YAML config files from. |
| VAULT_ADDR | http://localhost:8200 | URL of a HashiCorp Vault server to use for key management. |
| VAULT_KV_VERSION | 2 | Whether to use version `1` or `2` of the Vault KV API. |
| VAULT_KV_PATH | secret/jumpwire | Path in Vault to a KV store. The provided token/role should have write access to this. |
| VAULT_DB_PATH | database | Mount point of database secrets in Vault. JumpWire will lookup databases and roles under this path for possible proxy credentials. |
| VAULT_APPROLE_ID | - | ID of an approle to authenticate with Vault. Either a token or an approle must be provided to enable Vault. |
| VAULT_APPROLE_SECRET | - | Secret of an approle to authenticate with Vault. Either a token or an approle must be provided to enable Vault. |
| VAULT_TOKEN | - | Token to use to authenticate with Vault. Either a token or an approle must be provided to enable Vault. |
| VAULT_NAMESPACE | - | Namespace to use with Vault Enterprise. |
| JUMPWIRE_AWS_KMS_ENABLE | - | When set to `true` AWS KMS will be used for generating encryption keys. |
| JUMPWIRE_AWS_KMS_KEY_NAME | jumpwire | A prefix to use for aliases when creating AWS KMS keys.|
| HONEYBADGER_API_KEY | - | API key to enable error reporting to HoneyBadger. |
| SENTRY_DSN | - | DSN to enable error reporting to Sentry. |
| JUMPWIRE_ENV | prod | Environment to use in events for 3rd party error reporting. |
| JUMPWIRE_PARSE_REQUESTS | true | When true, requests being proxied through JumpWire will be inspected and access policies will be applied. |
| JUMPWIRE_PARSE_RESPONSES | true | When true, responses from requests proxied through JumpWire will be inspected and access policies will be applied. |
| ACME_GENERATE_CERT | true | Enables issuance of a TLS certificate using ACME/letsencrypt. |
| ACME_GENERATE_CERT_DELAY | 0 | How to long to wait after startup before attempting to issue a certificate, in seconds. |
| ACME_CERT_DIRECTORY | priv/pki | Disk location to store ACME generated certificates. |
| ACME_EMAIL | - | Email to use in CSRs. |
| JUMPWIRE_SSO_METADATA_PATH | - | Path to an XML file containing metadata for the SSO IdP. |
| JUMPWIRE_SSO_IDP | - | Identifier for the SSO IdP. This will be used in API paths. |
| JUMPWIRE_SSO_SPID | jumpwire | When registering JumpWire as an SSO service provider, this ID will be used. |
| JUMPWIRE_SSO_SIGNED_ENVELOPES | true | Whether to expect the SSO IdP to sign its SAML envelopes. |
| JUMPWIRE_SSO_GENERATED_CERTNAME | localhost | Name of ACME generated TLS certificate to use with SSO requests. Not used if a TLS cert and key are explicitly configured. |
| JUMPWIRE_SSO_GROUPS_ATTRIBUTE | Group | Attribute on SAML assertions listing the groups a user is a member of. |
| JUMPWIRE_SSO_BASE_URL | /sso | Explicitly set the base URL for SSO requests, including scheme and hostname. This is useful when running the gateway behind a load balancer that terminates TLS, to override the scheme of the host. |
| JUMPWIRE_DISABLE_REPORTING | false | Disable reporting of anonymous usage analytics. |

### Encryption keys

By default, JumpWire will use an AES key stored in a local file for any encryption operations. For production usage, we **strongly** recommend configuring a key management service instead. JumpWire will use a master key from this service and derive subkeys from it, greatly improving both security and durability of the encryption keyring.

HashiCorp Vault and AWS KMS are supported as encryption key stores. More information on configuring these is available in [our documentation](https://docs.jumpwire.io/encryption-key-stores).

## CLI

The JumpWire gateway can be interacted with using the [jwctl](https://github.com/extragoodlabs/jwctl) CLI tool. jwctl connects to the API of a running JumpWire cluster to perform administrative tasks and authenticate proxied database connections using SSO credentials.

## Telemetry

Operational metrics are collected by the JumpWire gateway can exported to Prometheus, StatsD, or CloudWatch. A full list of metrics is available in [our documentation](https://docs.jumpwire.io/observability).

## Support and bug reports

**Please disclose security vulnerabilities privately at security@jumpwire.io.**

If you run into an error or unexpected behavior, please [file an issue](https://github.com/extragoodlabs/jumpwire/issues).

All other questions and support requests should be asked in [GitHub discussions](https://github.com/extragoodlabs/jumpwire/discussions).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) to learn about project code style and practices, as well as how to runn JumpWire from source.

## License

This repo is licensed under [Apache 2.0](LICENSE).

An enterprise version of JumpWire is also available with additional features and a web interface for controlling the gateway.

To learn more, visit our [pricing page](https://jumpwire.io/pricing).
