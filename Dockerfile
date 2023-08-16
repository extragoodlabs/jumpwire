# syntax=docker/dockerfile:1
FROM hexpm/elixir:1.14.5-erlang-25.3.2.4-alpine-3.18.2 as build-stage

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

FROM build-stage as release-stage

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

FROM scratch AS export-stage
COPY --from=release-stage /app/_build/prod/jumpwire-*.tar.gz /
