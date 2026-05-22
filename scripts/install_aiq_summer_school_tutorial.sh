#!/usr/bin/env bash
set -Eeuo pipefail

# Host-side installer. Run this on the laptop, not inside the Brev VM.
#
# Fill these values before running:
#   BREV_INSTANCE_NAME: the Brev machine name, for example native-rose-wombat
#   NVIDIA_API_KEY:    NVIDIA/NGC API key used for hosted NIMs and nvcr.io
#   TAVILY_API_KEY:    Tavily API key used by AI-Q web search
#
# Then run:
#   scripts/install_aiq_summer_school_tutorial.sh
#
# The script intentionally refuses to start if required values are empty or
# still set to the placeholder strings. Do not commit secrets after editing.

BREV_INSTANCE_NAME="${BREV_INSTANCE_NAME:-__PASTE_BREV_INSTANCE_NAME_HERE__}"
NVIDIA_API_KEY="${NVIDIA_API_KEY:-__PASTE_NVIDIA_API_KEY_HERE__}"
NGC_API_KEY="${NGC_API_KEY:-$NVIDIA_API_KEY}"
TAVILY_API_KEY="${TAVILY_API_KEY:-__PASTE_TAVILY_API_KEY_HERE__}"

REMOTE_HOME="${REMOTE_HOME:-/home/ubuntu}"
REMOTE_SETUP_SCRIPT="${REMOTE_SETUP_SCRIPT:-$REMOTE_HOME/setup_aiq_summer_school_stack.sh}"
REMOTE_SECRET_FILE="${REMOTE_SECRET_FILE:-$REMOTE_HOME/.config/rag-setup/nvidia.env}"

RUN_SMOKE_TESTS="${RUN_SMOKE_TESTS:-1}"

LOCAL_RAG_UI_PORT="${LOCAL_RAG_UI_PORT:-8091}"
LOCAL_RAG_API_PORT="${LOCAL_RAG_API_PORT:-18081}"
LOCAL_INGESTOR_API_PORT="${LOCAL_INGESTOR_API_PORT:-18082}"
LOCAL_AIQ_UI_PORT="${LOCAL_AIQ_UI_PORT:-3000}"
LOCAL_AIQ_API_PORT="${LOCAL_AIQ_API_PORT:-8000}"
LOCAL_PHOENIX_PORT="${LOCAL_PHOENIX_PORT:-6006}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_SETUP_SOURCE="${REMOTE_SETUP_SOURCE:-$SCRIPT_DIR/setup_aiq_summer_school_stack.sh}"

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_value() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || die "Set $name at the top of this script before running."
  [[ "$value" != __PASTE_*_HERE__ ]] || die "Replace the $name placeholder at the top of this script before running."
}

require_file() {
  local name="$1"
  local path="$2"
  [[ -f "$path" ]] || die "$name does not exist: $path"
}

validate_config() {
  if [[ -z "$NVIDIA_API_KEY" && -n "$NGC_API_KEY" ]]; then
    NVIDIA_API_KEY="$NGC_API_KEY"
  fi
  if [[ -z "$NGC_API_KEY" && -n "$NVIDIA_API_KEY" ]]; then
    NGC_API_KEY="$NVIDIA_API_KEY"
  fi

  require_value BREV_INSTANCE_NAME "$BREV_INSTANCE_NAME"
  require_value NVIDIA_API_KEY "$NVIDIA_API_KEY"
  require_value NGC_API_KEY "$NGC_API_KEY"
  require_value TAVILY_API_KEY "$TAVILY_API_KEY"
  require_file REMOTE_SETUP_SOURCE "$REMOTE_SETUP_SOURCE"

  [[ "$BREV_INSTANCE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "BREV_INSTANCE_NAME has unsupported characters: $BREV_INSTANCE_NAME"
  [[ "$RUN_SMOKE_TESTS" == "0" || "$RUN_SMOKE_TESTS" == "1" ]] || die "RUN_SMOKE_TESTS must be 0 or 1."

  command -v brev >/dev/null 2>&1 || die "brev CLI is not installed or not on PATH."
  command -v curl >/dev/null 2>&1 || die "curl is not installed or not on PATH."
  command -v lsof >/dev/null 2>&1 || die "lsof is not installed or not on PATH."
}

write_local_secret_file() {
  local tmp
  tmp="$(mktemp /private/tmp/rag-setup-secrets.XXXXXX)"
  chmod 600 "$tmp"
  {
    printf 'export NGC_API_KEY=%q\n' "$NGC_API_KEY"
    printf 'export NVIDIA_API_KEY=%q\n' "$NVIDIA_API_KEY"
    printf 'export TAVILY_API_KEY=%q\n' "$TAVILY_API_KEY"
  } > "$tmp"
  printf '%s\n' "$tmp"
}

stage_remote_files() {
  local secret_tmp="$1"

  log "Staging installer and secrets on $BREV_INSTANCE_NAME"
  brev exec "$BREV_INSTANCE_NAME" "mkdir -p '$REMOTE_HOME/.config/rag-setup' '$REMOTE_HOME/rag-setup' && chmod 700 '$REMOTE_HOME/.config/rag-setup'"
  brev copy "$secret_tmp" "$BREV_INSTANCE_NAME:$REMOTE_SECRET_FILE"
  brev copy "$REMOTE_SETUP_SOURCE" "$BREV_INSTANCE_NAME:$REMOTE_SETUP_SCRIPT"

  brev exec "$BREV_INSTANCE_NAME" "bash -lc 'chmod 600 \"$REMOTE_SECRET_FILE\"; chmod +x \"$REMOTE_SETUP_SCRIPT\"; source \"$REMOTE_SECRET_FILE\"; echo nvidia_key_len:\${#NGC_API_KEY}; echo tavily_key_len:\${#TAVILY_API_KEY}'"
}

run_remote_install() {
  log "Running full RAG + AI-Q install on $BREV_INSTANCE_NAME"
  brev exec "$BREV_INSTANCE_NAME" \
    "bash -lc 'BREV_INSTANCE_NAME=\"$BREV_INSTANCE_NAME\" RUN_SMOKE_TESTS=\"$RUN_SMOKE_TESTS\" bash \"$REMOTE_SETUP_SCRIPT\"'"
}

start_port_forwards() {
  log "Starting laptop port forwards after successful install"

  local ports=(
    "$LOCAL_RAG_UI_PORT:8090"
    "$LOCAL_RAG_API_PORT:8081"
    "$LOCAL_INGESTOR_API_PORT:8082"
    "$LOCAL_AIQ_UI_PORT:3000"
    "$LOCAL_AIQ_API_PORT:8000"
    "$LOCAL_PHOENIX_PORT:6006"
  )

  local spec local_port remote_port log_file
  for spec in "${ports[@]}"; do
    local_port="${spec%%:*}"
    remote_port="${spec##*:}"

    if lsof -nP -iTCP:"$local_port" -sTCP:LISTEN >/dev/null 2>&1; then
      log "localhost:$local_port is already listening; leaving the existing listener in place."
      continue
    fi

    log_file="/private/tmp/brev-${BREV_INSTANCE_NAME}-${local_port}-to-${remote_port}-$$.log"
    echo "Forwarding localhost:$local_port -> $BREV_INSTANCE_NAME:$remote_port"
    nohup brev port-forward "$BREV_INSTANCE_NAME" -p "$spec" >"$log_file" 2>&1 &
    sleep 2
  done
}

wait_local_url() {
  local name="$1"
  local url="$2"
  local seconds="${3:-120}"
  local deadline=$((SECONDS + seconds))

  while (( SECONDS < deadline )); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      log "$name is reachable at $url"
      return 0
    fi
    sleep 5
  done

  die "Timed out waiting for $name at $url. Check /private/tmp/brev-${BREV_INSTANCE_NAME}-*.log."
}

verify_local_access() {
  wait_local_url "AI-Q API" "http://localhost:$LOCAL_AIQ_API_PORT/health" 180
  wait_local_url "RAG API" "http://localhost:$LOCAL_RAG_API_PORT/v1/health" 180
  wait_local_url "RAG ingestor API" "http://localhost:$LOCAL_INGESTOR_API_PORT/v1/health" 180
  wait_local_url "AI-Q UI" "http://localhost:$LOCAL_AIQ_UI_PORT" 180
  wait_local_url "Phoenix" "http://localhost:$LOCAL_PHOENIX_PORT" 180
  wait_local_url "RAG UI" "http://localhost:$LOCAL_RAG_UI_PORT" 180

  cat <<EOF

Tutorial setup is installed and forwarded from $BREV_INSTANCE_NAME.

Open these on the laptop:
  AI-Q UI:         http://localhost:$LOCAL_AIQ_UI_PORT
  Phoenix traces: http://localhost:$LOCAL_PHOENIX_PORT
  RAG UI:         http://localhost:$LOCAL_RAG_UI_PORT

Health endpoints:
  AI-Q API:        http://localhost:$LOCAL_AIQ_API_PORT/health
  RAG API:         http://localhost:$LOCAL_RAG_API_PORT/v1/health
  Ingestor API:    http://localhost:$LOCAL_INGESTOR_API_PORT/v1/health
EOF
}

main() {
  validate_config

  local secret_tmp
  secret_tmp="$(write_local_secret_file)"
  trap 'rm -f "$secret_tmp"' EXIT

  stage_remote_files "$secret_tmp"
  run_remote_install
  start_port_forwards
  verify_local_access
}

main "$@"
