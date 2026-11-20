# syntax=docker/dockerfile:1
# gamehost: Caddy + the deploy API in one image. Versions were current when written; bump deliberately.
ARG SWIFT_IMAGE=swift:6.4.2-noble
ARG CADDY_IMAGE=caddy:2.11.9
ARG RUNTIME_IMAGE=ubuntu:24.04

FROM ${SWIFT_IMAGE} AS build
WORKDIR /src
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources ./Sources
RUN swift build -c release --product gamehost --static-swift-stdlib \
 && install -D .build/release/gamehost /out/gamehost

# The official Caddy binary is statically linked, so it runs on the Ubuntu runtime.
# For TLS_MODE=wildcard (milestone 5) replace this stage with an xcaddy build that includes a DNS module.
FROM ${CADDY_IMAGE} AS caddy

FROM ${RUNTIME_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends brotli gzip tini ca-certificates libcap2-bin curl libstdc++6 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /data --shell /usr/sbin/nologin gamehost \
 && mkdir -p /data && chown gamehost:gamehost /data
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY --from=build /out/gamehost /usr/local/bin/gamehost
COPY docker/entrypoint.sh /usr/local/bin/gamehost-entrypoint
# Lets the non-root user bind 80/443. (Incompatible with --security-opt no-new-privileges.)
RUN setcap cap_net_bind_service=+ep /usr/local/bin/caddy \
 && chmod 0755 /usr/local/bin/gamehost-entrypoint

ENV GAMEHOST_DATA_DIR=/data \
    XDG_DATA_HOME=/data/caddy/state \
    XDG_CONFIG_HOME=/data/caddy/config
USER gamehost
VOLUME ["/data"]
EXPOSE 80 443 443/udp 8081
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD curl -fsS http://127.0.0.1:8080/healthz >/dev/null || exit 1
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/gamehost-entrypoint"]
