---
name: webdev
description: Docker and compose, a persistent PostgreSQL per project (pg-dev), and the Rust/wasm web toolchain -- all already in this container. Use before installing, pulling or starting any of them.
---

# Web development in this container

Nothing here needs installing. Do not apt-get Docker or PostgreSQL, and do not
curl an installer for trunk, wasm-pack or wasm-bindgen.

## Containers

`docker`, `docker compose` (also `docker-compose`) and `podman` all work, and
are rootless podman running inside this container. Docker SDKs and
testcontainers reach it through `$DOCKER_HOST` (also `/var/run/docker.sock`),
which starts podman's API service on the first connection.

- `-p 8080:80` publishes on this container's localhost: `curl localhost:8080`.
- Images, containers and volumes last as long as this session, and are gone in
  the next one. Data that has to outlive the session goes in a bind mount from
  the project or home, or, for PostgreSQL, in pg-dev.
- `netavark: create veth pair: ... Operation not supported (os error 95)` on a
  compose or custom network means the host kernel cannot load its `veth`
  module, usually because it was upgraded without a reboot. Tell the user.
  Meanwhile a single container on the default network works, and a Docker API
  client can ask for `network_mode: pasta`.

## PostgreSQL: `pg-dev`

A server for this project whose data persists across sessions, in the home
volume. Use it instead of a postgres container whenever the data matters.

```sh
pg-dev                                # start; prints postgres://claude@localhost:5432/claude
export DATABASE_URL=$(pg-dev url app) # creates database `app` if needed
pg-dev status                         # where the data is, running or not
pg-dev stop
```

Bare `psql`, `createdb` and `pg_dump` connect with no options. Auth is trust:
roles `claude` and `postgres` are superusers and any password works, so a
project's `postgres://postgres:postgres@localhost:5432/...` works as written
once its database exists. pgvector and the contrib extensions are installed.
`initdb`, `pg_ctl` and `postgres` are on PATH for test harnesses that start
throwaway servers. `pg-dev --help` has the rest.

## Rust web

The `wasm32-unknown-unknown` target, and `trunk`, `cargo leptos`, `wasm-pack`,
`wasm-bindgen` (with `wasm-bindgen-test-runner`), `wasm-opt`, `sqlx`
(sqlx-cli) and `cargo generate`.

- `wasm-bindgen` must match the project's `wasm-bindgen` crate exactly. trunk,
  cargo-leptos and wasm-pack fetch the right one themselves; for a bare
  `wasm-bindgen` call, `cargo binstall -y wasm-bindgen-cli@<that version>`.
- Every build goes through sccache (`sccache --show-stats`), so dependencies
  compiled in any earlier session or checkout come from its cache.
  `RUSTC_WRAPPER= cargo build` bypasses it.
