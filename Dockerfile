# syntax=docker/dockerfile:1
# Build this once in GitHub Actions; HF only pulls the published image.
# For reproducible upgrades, replace upstream :latest with reviewed immutable digests.
FROM eceasy/cli-proxy-api:latest AS cpa
FROM wiziscool/oh-my-cpa:latest AS omc
FROM caddy:2.10.2 AS caddy

FROM debian:bookworm-slim
LABEL org.opencontainers.image.title="CPA + OMC on HF" \
      org.opencontainers.image.description="CLIProxyAPI GitStore + Oh My CPA + Caddy on one HF port"
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1000 user \
    && useradd -m -u 1000 -g 1000 -s /bin/bash user \
    && mkdir -p /app /data/cpa /data/omc \
    && chown -R user:user /app /data

COPY --from=cpa /CLIProxyAPI/CLIProxyAPI /usr/local/bin/cli-proxy-api
COPY --from=omc /usr/local/bin/oh-my-cpa /usr/local/bin/oh-my-cpa
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY --chown=user:user Caddyfile start.sh /app/
RUN chmod 755 /app/start.sh /usr/local/bin/cli-proxy-api /usr/local/bin/oh-my-cpa /usr/local/bin/caddy \
    && caddy validate --config /app/Caddyfile --adapter caddyfile

USER user
WORKDIR /app
ENV HOME=/home/user \
    TZ=UTC \
    GITSTORE_LOCAL_PATH=/data/cpa \
    OMCPA_UPDATER_ENABLED=false \
    OMCPA_BASE_PATH=/omc \
    OMCPA_LISTEN_ADDR=127.0.0.1:8080 \
    OMCPA_CPA_BASE_URL=http://127.0.0.1:8317 \
    OMCPA_DATA_DIR=/data/omc \
    OMCPA_USAGE_BATCH_SIZE=200 \
    OMCPA_USAGE_RETENTION_DAYS=30 \
    OMCPA_USAGE_INBOX_RETENTION_DAYS=1 \
    OMCPA_UPDATE_CHECK_ENABLED=false \
    OMCPA_UPDATE_CHECK_ON_PAGE_LOAD=false \
    OMCPA_TRUSTED_PROXY_CIDRS=127.0.0.1/32
EXPOSE 7860
STOPSIGNAL SIGTERM
CMD ["/app/start.sh"]
