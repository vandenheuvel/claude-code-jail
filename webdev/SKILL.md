---
name: webdev
description: Docker and compose -- already in this container, as rootless podman. Use before installing Docker, or pulling or starting any container.
---

# Web development in this container

Nothing here needs installing. Do not apt-get Docker.

## Containers

`docker`, `docker compose` (also `docker-compose`) and `podman` all work, and
are rootless podman running inside this container. Docker SDKs and
testcontainers reach it through `$DOCKER_HOST` (also `/var/run/docker.sock`),
which starts podman's API service on the first connection.

- `-p 8080:80` publishes on this container's localhost: `curl localhost:8080`.
- Images, containers and volumes last as long as this session, and are gone in
  the next one. Data that has to outlive the session goes in a bind mount from
  the project or home.
- `netavark: create veth pair: ... Operation not supported (os error 95)` on a
  compose or custom network means the host kernel cannot load its `veth`
  module, usually because it was upgraded without a reboot. Tell the user.
  Meanwhile a single container on the default network works, and a Docker API
  client can ask for `network_mode: pasta`.

