# `docker/docker-compose.dood.yaml`

> 逐字复制的真实源码（27 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
# Helix — Docker-out-of-Docker (DooD) overlay (OPT-IN, NOT loaded by default)
#
# Mounts the host Docker socket into the gateway container so that
# AioSandboxProvider running in pure-Docker mode — config.yaml:
#   sandbox.use: helix.community.aio_sandbox:AioSandboxProvider
# with NO provisioner_url — can start per-thread sandbox containers via the
# host Docker daemon.
#
# SECURITY: the host Docker socket grants the gateway container
# root-equivalent control of the host. Only load this overlay when you have
# explicitly chosen aio (DooD) sandbox mode and accept that trade-off. The
# default LocalSandboxProvider and the provisioner/Kubernetes mode do NOT need
# it and never load this file. See backend/docs/CONFIGURATION.md Security Note 
# section for the full threat model.
#
# scripts/deploy.sh and scripts/docker.sh append this overlay automatically
# only when detect_sandbox_mode() returns "aio". Manual use:
#   docker compose -f docker-compose.yaml -f docker-compose.dood.yaml up -d
#
# Compatible with both docker-compose.yaml (prod) and docker-compose-dev.yaml
# (dev): both define a `gateway` service, and Compose merges this volume entry
# onto it. HELIX_DOCKER_SOCKET defaults to /var/run/docker.sock.
services:
  gateway:
    volumes:
      - ${HELIX_DOCKER_SOCKET:-/var/run/docker.sock}:/var/run/docker.sock
```
