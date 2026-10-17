# `docker/docker-compose.openviking.yaml`

> 逐字复制的真实源码（43 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
# Optional OpenViking memory service overlay.
#
# First-time initialization:
#   docker compose -f docker/docker-compose.yaml \
#     -f docker/docker-compose.openviking.yaml up -d openviking
#   docker exec -it helix-openviking openviking-server init
#
# Full stack:
#   docker compose -f docker/docker-compose.yaml \
#     -f docker/docker-compose.openviking.yaml up -d --build

services:
  openviking:
    image: ${OPENVIKING_IMAGE:-ghcr.io/volcengine/openviking:latest}
    container_name: helix-openviking
    command: ["--without-bot"]
    ports:
      - "${OPENVIKING_PORT:-1933}:1933"
    volumes:
      - openviking-data:/app/.openviking
    networks:
      - helix
    restart: unless-stopped
    healthcheck:
      test:
        [
          "CMD",
          "python",
          "-c",
          "import urllib.request; urllib.request.urlopen('http://127.0.0.1:1933/health', timeout=3)",
        ]
      interval: 10s
      timeout: 5s
      retries: 12

  gateway:
    depends_on:
      openviking:
        condition: service_healthy

volumes:
  openviking-data:
```
