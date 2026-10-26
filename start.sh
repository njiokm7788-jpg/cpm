#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

require_nonempty() {
    local key="$1"
    if [[ -z "${!key:-}" ]]; then
        echo "ERROR: Missing/empty HF Secret $key" >&2
        exit 1
    fi
}
require_nonempty CPA_MANAGEMENT_KEY
require_nonempty OMCPA_MASTER_KEY
require_nonempty GITSTORE_GIT_URL
require_nonempty GITSTORE_GIT_TOKEN

# CPA_MANAGEMENT_KEY can be ANY nonempty string; no 64-hex requirement.
# CPA_API_KEY can also be a custom key; reject newline/quotes to avoid YAML injection.
if [[ "$CPA_API_KEY" == *$'\n'* || "$CPA_API_KEY" == *$'\r'* || "$CPA_API_KEY" == *'"'* || "$CPA_API_KEY" == *\\* ]]; then
    echo 'ERROR: CPA_API_KEY cannot contain quotes, backslashes or newlines.' >&2
    exit 1
fi
# OMC supports 64 hex characters (recommended and validated here).
if [[ ! "$OMCPA_MASTER_KEY" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo 'ERROR: OMCPA_MASTER_KEY must be 64 hex characters (openssl rand -hex 32).' >&2
    exit 1
fi
# GitHub HTTPS repo, no credentials in the URL.
if [[ ! "$GITSTORE_GIT_URL" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$ ]]; then
    echo 'ERROR: GITSTORE_GIT_URL must look like https://github.com/user/private-data.git' >&2
    exit 1
fi
# Username is optional in CPA GitStore; x-access-token works as GitHub HTTPS username.
export GITSTORE_GIT_USERNAME="${GITSTORE_GIT_USERNAME:-x-access-token}"

mkdir -p /data/cpa /data/omc

# GitStore only consults this template on FIRST initialization of an empty repo.
# Existing config/config.yaml takes priority, so changing CPA_API_KEY in HF Secrets
# does NOT automatically rotate an already persisted API key.
cat > /app/config.example.yaml <<YAML
config-version: 8
server:
  host: "127.0.0.1"
  port: 8317
  tls:
    enable: false
management:
  allow-remote: false
  secret-key: ""
  disable-control-panel: true
access:
  api-keys:
    - "${CPA_API_KEY}"
observability:
  logs:
    debug: false
    logging-to-file: false
  usage:
    usage-statistics-enabled: true
    redis-usage-queue-retention-seconds: 600
YAML
chmod 600 /app/config.example.yaml

# Keep management password OUT of the Git repo.
export MANAGEMENT_PASSWORD="$CPA_MANAGEMENT_KEY"
export OMCPA_CPA_MANAGEMENT_KEY="$CPA_MANAGEMENT_KEY"
if [[ -n "${SPACE_HOST:-}" && -z "${OMCPA_PUBLIC_URL:-}" ]]; then
    export OMCPA_PUBLIC_URL="https://${SPACE_HOST}"
fi

GO_GC_PERCENT="${GO_GC_PERCENT:-80}"
CPA_GOMEMLIMIT="${CPA_GOMEMLIMIT:-3GiB}"
OMC_GOMEMLIMIT="${OMC_GOMEMLIMIT:-2GiB}"
CADDY_GOMEMLIMIT="${CADDY_GOMEMLIMIT:-512MiB}"

pids=()
monitor_pid=""
cleanup() {
    trap - TERM INT
    if [[ -n "$monitor_pid" ]]; then kill "$monitor_pid" 2>/dev/null || true; fi
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap 'cleanup; exit 143' TERM INT

# GitStore bootstrapping expects config.example.yaml relative to this directory.
cd /app
env GOMEMLIMIT="$CPA_GOMEMLIMIT" GOGC="$GO_GC_PERCENT" /usr/local/bin/cli-proxy-api &
pids+=("$!")
env GOMEMLIMIT="$OMC_GOMEMLIMIT" GOGC="$GO_GC_PERCENT" /usr/local/bin/oh-my-cpa &
pids+=("$!")
env GOMEMLIMIT="$CADDY_GOMEMLIMIT" GOGC="$GO_GC_PERCENT" /usr/local/bin/caddy run --config /app/Caddyfile --adapter caddyfile &
pids+=("$!")

monitor_memory() {
    local timer_pid=""
    trap '[[ -z "$timer_pid" ]] || kill "$timer_pid" 2>/dev/null || true; exit 0' TERM INT
    while true; do
        sleep 300 &
        timer_pid="$!"
        wait "$timer_pid" || break
        [[ -r /sys/fs/cgroup/memory.current ]] || continue
        read -r current < /sys/fs/cgroup/memory.current || continue
        read -r maximum < /sys/fs/cgroup/memory.max || maximum="max"
        [[ "$current" =~ ^[0-9]+$ ]] || continue
        if [[ "$maximum" =~ ^[0-9]+$ && "$maximum" -gt 0 ]]; then
            local pct=$((current * 100 / maximum))
            echo "[memory] $((current / 1048576))MiB / $((maximum / 1048576))MiB (${pct}%)"
            if (( pct >= 80 )); then
                echo '[memory] WARNING: cgroup memory usage >= 80%; inspect load.' >&2
            fi
        else
            echo "[memory] $((current / 1048576))MiB (unknown cgroup limit)"
        fi
    done
}
monitor_memory &
monitor_pid="$!"
echo 'CPA GitStore + OMC + Caddy launched on port 7860 (/omc/ and /v1).'

status=0
wait -n "${pids[@]}" || status=$?
cleanup
if [[ "$status" -eq 0 ]]; then exit 1; else exit "$status"; fi
