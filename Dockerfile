# syntax=docker/dockerfile:1
FROM ghcr.io/extragoodlabs/elixir:1.14.5-erlang-25.3.2.3-nojit-alpine-3.18.2 as build-stage

# install build dependencies
RUN apk add --no-cache build-base git curl wget openssh-client clang lld

# install latest stable Rust version
ENV CARGO_HOME=/
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal

# Set rustflags to allow dynamically linking with musl
# https://github.com/rust-lang/rust/issues/59302
ENV RUSTFLAGS="-C target-feature=-crt-static"

ENV LANG=C.UTF-8
ENV MIX_ENV=prod
WORKDIR /app

RUN mix do local.hex --force, local.rebar --force

COPY mix.exs .
COPY mix.lock .

# Fetch and compile dependencies
RUN mix do deps.get, deps.compile

COPY config ./config/
COPY lib ./lib/
COPY priv ./priv/
COPY native ./native/
COPY rel ./rel/

RUN mix release

FROM alpine:3.18.2 as final-stage

ENV LANG=C.UTF-8
ENV MIX_ENV=prod
ENV USER=jumpwire

# Creates an unprivileged user to be used exclusively to run the app
RUN \
    addgroup \
    -g 1000 \
    -S "${USER}" \
    && adduser \
    -s /bin/sh \
    -u 1000 \
    -G "${USER}" \
    -h "/opt/jumpwire" \
    -D "${USER}"

RUN apk add --update --no-cache libstdc++ bash curl jq sudo

WORKDIR /opt/jumpwire

COPY release/extract-release.sh /tmp/
COPY --from=build-stage /app/_build/prod/jumpwire-*.tar.gz /tmp/
RUN /tmp/extract-release.sh

EXPOSE 4369
EXPOSE 4004
EXPOSE 4443
EXPOSE 3306
EXPOSE 5432
EXPOSE 9569

COPY release/entrypoint.sh /usr/local/bin/entrypoint.sh
CMD ["/usr/local/bin/entrypoint.sh"]
