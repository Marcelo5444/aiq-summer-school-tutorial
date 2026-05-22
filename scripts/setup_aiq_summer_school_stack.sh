#!/usr/bin/env bash
set -Eeuo pipefail

# Run inside the Brev VM:
#   brev shell <instance-name>
#   BREV_INSTANCE_NAME=<instance-name> bash ~/setup_aiq_summer_school_stack.sh
#
# Target profile: CPU-only or GPU VM with about 32 GB RAM. This script still
# adds swap automatically on smaller VMs, but the clean path assumes enough RAM
# for the official NVIDIA RAG ingestor and AI-Q services.

# Required runtime configuration. Leave these empty in git; pass them through
# the environment or through SECRET_FILE on the VM.
BREV_INSTANCE_NAME="${BREV_INSTANCE_NAME:-}"
NGC_API_KEY="${NGC_API_KEY:-${NVIDIA_API_KEY:-}}"
NVIDIA_API_KEY="${NVIDIA_API_KEY:-$NGC_API_KEY}"
TAVILY_API_KEY="${TAVILY_API_KEY:-}"

RAG_REPO="${RAG_REPO:-https://github.com/NVIDIA-AI-Blueprints/rag.git}"
RAG_REF="${RAG_REF:-main}"
RAG_DIR="${RAG_DIR:-$HOME/rag-setup/rag}"
RAG_TAG="${RAG_TAG:-2.5.0}"

AIQ_REPO="${AIQ_REPO:-https://github.com/NVIDIA-AI-Blueprints/aiq.git}"
AIQ_REF="${AIQ_REF:-develop}"
AIQ_DIR="${AIQ_DIR:-$HOME/aiq-setup/aiq}"
AIQ_TAG="${AIQ_TAG:-2.0.0}"
NV_INGEST_IMAGE="${NV_INGEST_IMAGE:-nvcr.io/nvidia/nemo-microservices/nv-ingest@sha256:e447f509ef0abb8a9bf9b692db939f506a3edc055ab508ecade06a0130d2a40b}"

SECRET_FILE="${SECRET_FILE:-$HOME/.config/rag-setup/nvidia.env}"
COLLECTION_NAME="${COLLECTION_NAME:-multimodal_data}"

RUN_SMOKE_TESTS="${RUN_SMOKE_TESTS:-1}"

# For the 32 GB target this should normally be skipped. It is left as auto so
# the script does not fail hard if Brev provisions a smaller machine.
ENABLE_SWAP="${ENABLE_SWAP:-auto}"
SWAP_SIZE="${SWAP_SIZE:-16G}"
MIN_RAM_NO_SWAP_GB="${MIN_RAM_NO_SWAP_GB:-24}"

RAG_WORKERS="${RAG_WORKERS:-2}"
ELASTIC_HEAP="${ELASTIC_HEAP:-2g}"
MAX_INGEST_PROCESS_WORKERS="${MAX_INGEST_PROCESS_WORKERS:-4}"
NV_INGEST_MAX_UTIL="${NV_INGEST_MAX_UTIL:-16}"
INGESTOR_SHM_SIZE="${INGESTOR_SHM_SIZE:-2gb}"
NV_INGEST_SHM_SIZE="${NV_INGEST_SHM_SIZE:-4gb}"
DASK_NWORKERS="${DASK_NWORKERS:-1}"
DASK_NTHREADS="${DASK_NTHREADS:-2}"
DOCKER_CMD=(docker)

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local line="$1"
  printf '\nERROR: setup failed near line %s\n' "$line" >&2
  docker_cmd ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' >&2 || true
}
trap 'on_error "$LINENO"' ERR

docker_cmd() {
  "${DOCKER_CMD[@]}" "$@"
}

compose_cmd() {
  docker_cmd compose "$@"
}

detect_docker_access() {
  command -v docker >/dev/null 2>&1 || die "Docker is required on the Brev VM."

  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
    log "Docker is reachable as the current user."
  elif command -v sudo >/dev/null 2>&1 && sudo -n --preserve-env docker info >/dev/null 2>&1; then
    DOCKER_CMD=(sudo -n --preserve-env docker)
    log "Docker requires sudo on this VM; using passwordless sudo for Docker commands."
  else
    die "Docker is not reachable. Ensure Docker is running and the user can run docker or passwordless sudo docker."
  fi

  compose_cmd version >/dev/null || die "Docker Compose v2 is required."
}

wait_url() {
  local name="$1"
  local url="$2"
  local seconds="${3:-180}"
  local deadline=$((SECONDS + seconds))

  while (( SECONDS < deadline )); do
    if curl -fsS "$url" >/tmp/"${name}".health 2>/tmp/"${name}".health.err; then
      log "$name is ready"
      return 0
    fi
    sleep 5
  done

  printf 'Timed out waiting for %s at %s\n' "$name" "$url" >&2
  cat /tmp/"${name}".health.err >&2 || true
  return 1
}

json_get() {
  local file="$1"
  local key="$2"
  python3 - "$file" "$key" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
value = data
for part in sys.argv[2].split("."):
    if not part:
        continue
    if isinstance(value, dict):
        value = value.get(part, "")
    else:
        value = ""
        break
if isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PY
}

source_secrets() {
  if [[ -f "$SECRET_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$SECRET_FILE"
    set +a
  fi

  NGC_API_KEY="${NGC_API_KEY:-${NVIDIA_API_KEY:-}}"
  NVIDIA_API_KEY="${NVIDIA_API_KEY:-$NGC_API_KEY}"
  TAVILY_API_KEY="${TAVILY_API_KEY:-}"

  [[ -n "$BREV_INSTANCE_NAME" ]] || die "Set BREV_INSTANCE_NAME before running this script."
  [[ -n "$NGC_API_KEY" ]] || die "Set NGC_API_KEY or NVIDIA_API_KEY in $SECRET_FILE or the environment."
  [[ -n "$TAVILY_API_KEY" ]] || die "Set TAVILY_API_KEY in $SECRET_FILE or the environment."

  export NGC_API_KEY NVIDIA_API_KEY TAVILY_API_KEY
  log "Loaded API keys from environment/secrets file. Key values are not printed."
}

install_prereqs() {
  local missing=()
  for cmd in git curl python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    log "Installing missing OS packages: ${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y ca-certificates coreutils "${missing[@]}"
  fi

  detect_docker_access
}

memory_gb() {
  awk '/MemTotal/ {printf "%.0f\n", $2 / 1024 / 1024}' /proc/meminfo
}

ensure_swap_if_needed() {
  local mem_gb
  mem_gb="$(memory_gb)"

  if [[ "$ENABLE_SWAP" == "0" || "$ENABLE_SWAP" == "false" ]]; then
    log "Swap management disabled. Detected RAM: ${mem_gb} GiB."
    return 0
  fi

  if [[ "$ENABLE_SWAP" == "auto" && "$mem_gb" -ge "$MIN_RAM_NO_SWAP_GB" ]]; then
    log "Detected ${mem_gb} GiB RAM; skipping swap setup for the 32 GB profile."
    return 0
  fi

  local desired_bytes current_bytes
  desired_bytes="$(numfmt --from=iec "$SWAP_SIZE")"
  current_bytes="$(swapon --show=NAME,SIZE --bytes --noheadings 2>/dev/null | awk '$1 == "/swapfile" {print $2}')"

  if [[ -n "$current_bytes" && "$current_bytes" -ge "$desired_bytes" ]]; then
    log "Swap is already enabled with at least $SWAP_SIZE."
    return 0
  fi

  if [[ -n "$current_bytes" ]]; then
    log "Growing /swapfile to $SWAP_SIZE."
    sudo swapoff /swapfile || die "Could not disable existing /swapfile. Stop services or set ENABLE_SWAP=0."
  else
    log "Enabling $SWAP_SIZE swap because detected RAM is ${mem_gb} GiB."
  fi

  sudo fallocate -l "$SWAP_SIZE" /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  if ! grep -q '^/swapfile ' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  fi
}

docker_login_ngc() {
  log "Logging in to nvcr.io"
  printf '%s\n' "$NGC_API_KEY" | docker_cmd login nvcr.io -u '$oauthtoken' --password-stdin >/dev/null
}

clone_or_update() {
  local repo="$1"
  local dir="$2"
  local ref="$3"

  if [[ -d "$dir/.git" ]]; then
    log "Updating $dir"
    git -C "$dir" fetch --all --prune
  else
    log "Cloning $repo into $dir"
    mkdir -p "$(dirname "$dir")"
    git clone "$repo" "$dir"
  fi

  if [[ "$ref" != "default" ]]; then
    git -C "$dir" checkout "$ref"
    if git -C "$dir" symbolic-ref -q HEAD >/dev/null; then
      git -C "$dir" pull --ff-only || log "Continuing with local $dir checkout because fast-forward pull was not possible."
    fi
  fi
}

write_rag_overrides() {
  cat > "$RAG_DIR/deploy/compose/docker-compose-rag-server.brev-override.yaml" <<YAML
services:
  rag-server:
    command: --port 8081 --host 0.0.0.0 --workers ${RAG_WORKERS}
    restart: unless-stopped
  rag-frontend:
    restart: unless-stopped
YAML

  cat > "$RAG_DIR/deploy/compose/vectordb.brev-override.yaml" <<YAML
services:
  elasticsearch:
    restart: unless-stopped
    environment:
      - ES_JAVA_OPTS=-Xms${ELASTIC_HEAP} -Xmx${ELASTIC_HEAP}
  minio:
    restart: unless-stopped
YAML

  cat > "$RAG_DIR/deploy/compose/docker-compose-ingestor-server.brev-override.yaml" <<YAML
services:
  ingestor-server:
    restart: unless-stopped
    shm_size: ${INGESTOR_SHM_SIZE}
  nv-ingest-ms-runtime:
    image: ${NV_INGEST_IMAGE}
    restart: unless-stopped
    shm_size: ${NV_INGEST_SHM_SIZE}
  redis:
    restart: unless-stopped
YAML
}

set_rag_env() {
  cd "$RAG_DIR"
  # shellcheck disable=SC1091
  source deploy/compose/nvdev.env

  export NGC_API_KEY NVIDIA_API_KEY
  export TAG="$RAG_TAG"
  export PROMPT_CONFIG_FILE="$RAG_DIR/src/nvidia_rag/rag_server/prompt.yaml"

  export APP_VECTORSTORE_NAME=elasticsearch
  export APP_VECTORSTORE_URL=http://elasticsearch:9200
  export APP_VECTORSTORE_ENABLEGPUSEARCH=False
  export APP_VECTORSTORE_ENABLEGPUINDEX=False
  export APP_VECTORSTORE_SEARCHTYPE=dense
  export COLLECTION_NAME="$COLLECTION_NAME"

  export ENABLE_RERANKER=True
  export ENABLE_QUERYREWRITER=False
  export ENABLE_FILTER_GENERATOR=False

  export APP_NVINGEST_EXTRACTTEXT=True
  export APP_NVINGEST_EXTRACTTABLES=False
  export APP_NVINGEST_EXTRACTCHARTS=False
  export APP_NVINGEST_EXTRACTINFOGRAPHICS=False
  export APP_NVINGEST_EXTRACTIMAGES=False
  export APP_NVINGEST_EXTRACTPAGEASIMAGE=False
  export APP_NVINGEST_PDFEXTRACTMETHOD=pdfium
  export APP_NVINGEST_TEXTDEPTH=page
  export MAX_INGEST_PROCESS_WORKERS="$MAX_INGEST_PROCESS_WORKERS"
  export NV_INGEST_MAX_UTIL="$NV_INGEST_MAX_UTIL"
  export ENABLE_REDIS_BACKEND=True
}

start_rag() {
  log "Starting Elasticsearch and RAG Blueprint"
  cd "$RAG_DIR"
  set_rag_env
  write_rag_overrides

  mkdir -p deploy/compose/volumes/elasticsearch
  sudo chown -R 1000:1000 deploy/compose/volumes/elasticsearch

  compose_cmd -f deploy/compose/vectordb.yaml stop milvus etcd >/dev/null 2>&1 || true
  compose_cmd -f deploy/compose/vectordb.yaml rm -f milvus etcd >/dev/null 2>&1 || true

  compose_cmd \
    -f deploy/compose/vectordb.yaml \
    -f deploy/compose/vectordb.brev-override.yaml \
    --profile elasticsearch \
    up -d elasticsearch
  wait_url elasticsearch http://localhost:9200/_cluster/health 300

  compose_cmd \
    -f deploy/compose/docker-compose-rag-server.yaml \
    -f deploy/compose/docker-compose-rag-server.brev-override.yaml \
    --env-file deploy/compose/nvdev.env \
    up -d --force-recreate rag-server rag-frontend
  wait_url rag-server http://localhost:8081/v1/health 420
}

start_rag_ingestor() {
  log "Starting official RAG ingestor services"
  cd "$RAG_DIR"
  set_rag_env

  compose_cmd \
    -f deploy/compose/vectordb.yaml \
    -f deploy/compose/vectordb.brev-override.yaml \
    --profile minio \
    up -d minio

  compose_cmd \
    -f deploy/compose/docker-compose-ingestor-server.yaml \
    -f deploy/compose/docker-compose-ingestor-server.brev-override.yaml \
    --env-file deploy/compose/nvdev.env \
    up -d redis nv-ingest-ms-runtime ingestor-server

  wait_url rag-ingestor http://localhost:8082/v1/health 420
  wait_url nv-ingest http://localhost:7670/v1/health/ready 600
}

create_rag_collection() {
  log "Ensuring Elasticsearch collection '$COLLECTION_NAME' exists"
  local body code
  body="$(mktemp)"
  code="$(
    curl -sS -o "$body" -w '%{http_code}' \
      -X POST http://localhost:8082/v1/collection \
      -H 'Content-Type: application/json' \
      -d "{
        \"collection_name\":\"$COLLECTION_NAME\",
        \"vdb_endpoint\":\"http://elasticsearch:9200\",
        \"description\":\"AIQ Summer School RAG knowledge base\",
        \"tags\":[\"tutorial\",\"rag\"],
        \"owner\":\"agent_summer_school\",
        \"created_by\":\"tutorial\",
        \"business_domain\":\"AI\",
        \"status\":\"Active\",
        \"metadata_schema\":[]
      }"
  )"

  if [[ "$code" =~ ^2 ]]; then
    cat "$body"
    rm -f "$body"
    return 0
  fi

  if grep -qiE 'already|exist' "$body"; then
    log "Collection already exists."
    rm -f "$body"
    return 0
  fi

  printf 'Collection creation failed with HTTP %s:\n' "$code" >&2
  cat "$body" >&2
  rm -f "$body"
  return 1
}

extract_aiq_release_config() {
  log "Extracting AI-Q $AIQ_TAG config from the release image"
  cd "$AIQ_DIR"
  docker_cmd run --rm --entrypoint python "nvcr.io/nvidia/blueprint/aiq-agent:$AIQ_TAG" \
    -c 'from pathlib import Path; print(Path("/app/configs/config_web_frag.yml").read_text())' \
    > configs/config_web_frag_2_0_0.yml

  awk '
    { print }
    /^        level: INFO$/ && !done {
      print "    tracing:"
      print "      phoenix:"
      print "        _type: phoenix"
      print "        endpoint: http://phoenix:6006/v1/traces"
      print "        project: aiq-summer-school-tutorial"
      done=1
    }
  ' configs/config_web_frag_2_0_0.yml > configs/config_web_frag_phoenix.yml

  grep -q 'phoenix' configs/config_web_frag_phoenix.yml || die "Could not insert Phoenix tracing into AI-Q config."

  python3 - <<'PY'
from pathlib import Path

p = Path("configs/config_web_frag_phoenix.yml")
text = p.read_text()
text = text.replace("    enable_plan_approval: true", "    enable_plan_approval: false")
text = text.replace("  enable_escalation: true", "  enable_escalation: false")
text = text.replace("  use_async_deep_research: true", "  use_async_deep_research: false")
p.write_text(text)
PY
}

write_aiq_env_and_override() {
  log "Writing AI-Q env and Brev override"
  cd "$AIQ_DIR"
  umask 077
  cat > deploy/.env <<EOF
APP_ENV=production
LOG_LEVEL=INFO
NVIDIA_API_KEY=$NVIDIA_API_KEY
NGC_API_KEY=$NGC_API_KEY
TAVILY_API_KEY=$TAVILY_API_KEY
BACKEND_IMAGE=nvcr.io/nvidia/blueprint/aiq-agent:$AIQ_TAG
FRONTEND_IMAGE=nvcr.io/nvidia/blueprint/aiq-frontend:$AIQ_TAG
BACKEND_CONFIG=/app/configs/config_web_frag_phoenix.yml
RAG_SERVER_URL=http://rag-server:8081/v1
RAG_INGEST_URL=http://ingestor-server:8082/v1
COLLECTION_NAME=$COLLECTION_NAME
PORT=8000
FRONTEND_PORT=3000
DASK_NWORKERS=$DASK_NWORKERS
DASK_NTHREADS=$DASK_NTHREADS
REQUIRE_AUTH=false
BACKEND_URL=http://aiq-agent:8000
NAT_JOB_STORE_DB_URL=postgresql+asyncpg://aiq:aiq_dev@postgres:5432/aiq_jobs
AIQ_CHECKPOINT_DB=postgresql://aiq:aiq_dev@postgres:5432/aiq_checkpoints
AIQ_SUMMARY_DB=postgresql+psycopg://aiq:aiq_dev@postgres:5432/aiq_jobs
EOF

  cat > deploy/compose/docker-compose.aiq-summer-school.yaml <<'YAML'
services:
  aiq-agent:
    restart: unless-stopped
    networks:
      - aiq-network
      - nvidia-rag
    environment:
      - RAG_SERVER_URL=${RAG_SERVER_URL}
      - RAG_INGEST_URL=${RAG_INGEST_URL}
      - COLLECTION_NAME=${COLLECTION_NAME}
      - TAVILY_API_KEY=${TAVILY_API_KEY}
      - NVIDIA_API_KEY=${NVIDIA_API_KEY}
      - NGC_API_KEY=${NGC_API_KEY}
      - DASK_NWORKERS=${DASK_NWORKERS:-1}
      - DASK_NTHREADS=${DASK_NTHREADS:-2}
  postgres:
    restart: unless-stopped
  frontend:
    restart: unless-stopped
networks:
  nvidia-rag:
    external: true
YAML
}

start_aiq() {
  log "Starting Phoenix and AI-Q"
  cd "$AIQ_DIR"
  extract_aiq_release_config
  write_aiq_env_and_override

  docker_cmd rm -f phoenix >/dev/null 2>&1 || true
  docker_cmd run -d --name phoenix --network nvidia-rag --restart unless-stopped \
    -p 6006:6006 \
    arizephoenix/phoenix:latest >/dev/null

  cd "$AIQ_DIR/deploy/compose"
  compose_cmd --env-file ../.env \
    -f docker-compose.yaml \
    -f docker-compose.aiq-summer-school.yaml \
    up -d

  wait_url aiq-api http://localhost:8000/health 600
  wait_url aiq-ui http://localhost:3000 300
  wait_url phoenix http://localhost:6006 300
}

document_available() {
  curl -sS "http://localhost:8082/v1/documents?collection_name=$COLLECTION_NAME" \
    | grep -qiE 'total_documents":[1-9]|document_name'
}

run_smoke_tests() {
  if [[ "$RUN_SMOKE_TESTS" != "1" && "$RUN_SMOKE_TESTS" != "true" ]]; then
    log "Skipping smoke tests because RUN_SMOKE_TESTS=$RUN_SMOKE_TESTS."
    return 0
  fi

  log "Running health and integration smoke tests"
  curl -sS http://localhost:8081/v1/health
  curl -sS http://localhost:8082/v1/health
  curl -sS http://localhost:8000/health
  curl -sS http://localhost:8000/v1/data_sources | tee /tmp/aiq-data-sources.json
  grep -q 'web_search' /tmp/aiq-data-sources.json
  grep -q 'knowledge_layer' /tmp/aiq-data-sources.json
  curl -sS http://localhost:8000/v1/knowledge/health
  curl -sS http://localhost:8000/v1/collections

  log "Running AI-Q web search smoke test"
  local code
  for attempt in 1 2 3; do
    code="$(
      curl -sS --max-time 360 \
        -o /tmp/rag-aiq-web-smoke.txt \
        -w '%{http_code}' \
        -X POST http://localhost:8000/generate \
        -H 'Content-Type: application/json' \
        -d '{"query":"Use web_search_tool to find the NVIDIA Build API keys page and include one source URL."}'
    )" || code="000"
    if [[ "$code" =~ ^2 ]] && [[ -s /tmp/rag-aiq-web-smoke.txt ]] && grep -qiE 'http|build.nvidia.com|nvidia' /tmp/rag-aiq-web-smoke.txt; then
      break
    fi
    log "AI-Q web smoke test attempt $attempt did not return a usable web result yet; retrying."
    sleep 45
  done
  [[ "$code" =~ ^2 ]]
  [[ -s /tmp/rag-aiq-web-smoke.txt ]]
  grep -qiE 'http|build.nvidia.com|nvidia' /tmp/rag-aiq-web-smoke.txt

  if document_available; then
    log "Running RAG query smoke test"
    for attempt in 1 2 3; do
      code="$(
        curl -sS --max-time 360 \
        -o /tmp/rag-rag-smoke.txt \
        -w '%{http_code}' \
        -X POST http://localhost:8081/v1/generate \
        -H 'Content-Type: application/json' \
        -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Summarize the available documents in this collection.\"}],\"collection_name\":\"$COLLECTION_NAME\",\"max_tokens\":1024,\"vdb_top_k\":10,\"reranker_top_k\":5}"
      )" || code="000"
      if [[ "$code" =~ ^2 ]] && [[ -s /tmp/rag-rag-smoke.txt ]] && ! grep -qiE 'traceback|exception|internal server error' /tmp/rag-rag-smoke.txt; then
        break
      fi
      log "RAG smoke test attempt $attempt did not return a usable answer yet; retrying."
      sleep 30
    done
    [[ "$code" =~ ^2 ]]
    [[ -s /tmp/rag-rag-smoke.txt ]]
    ! grep -qiE 'traceback|exception|internal server error' /tmp/rag-rag-smoke.txt

    log "Running AI-Q combined RAG + web query smoke test"
    for attempt in 1 2 3; do
      code="$(
        curl -sS --max-time 600 \
        -o /tmp/rag-aiq-combined-smoke.txt \
        -w '%{http_code}' \
        -X POST http://localhost:8000/generate \
        -H 'Content-Type: application/json' \
        -d '{"query":"Use both tools briefly. First use knowledge_search to summarize the available RAG documents. Then use web_search_tool to find the NVIDIA Build API keys page and include one source URL."}'
      )" || code="000"
      if [[ "$code" =~ ^2 ]] && [[ -s /tmp/rag-aiq-combined-smoke.txt ]] && ! grep -qiE 'traceback|exception|internal server error' /tmp/rag-aiq-combined-smoke.txt; then
        break
      fi
      log "AI-Q combined smoke test attempt $attempt did not return a usable answer yet; retrying."
      sleep 45
    done
    [[ "$code" =~ ^2 ]]
    [[ -s /tmp/rag-aiq-combined-smoke.txt ]]
    ! grep -qiE 'traceback|exception|internal server error' /tmp/rag-aiq-combined-smoke.txt
  else
    log "No documents found in $COLLECTION_NAME; skipping RAG answer smoke tests. Use the RAG UI to upload documents."
  fi

  log "Smoke tests completed"
}

print_access_info() {
  cat <<EOF

Deployment is up on the Brev VM.

Remote service URLs on the VM:
  RAG UI:          http://localhost:8090
  RAG API:         http://localhost:8081/v1/health
  RAG ingestor:    http://localhost:8082/v1/health
  AI-Q UI:         http://localhost:3000
  AI-Q API:        http://localhost:8000/health
  Phoenix traces:  http://localhost:6006

Run these on your laptop to access the tutorial locally:
  brev port-forward $BREV_INSTANCE_NAME -p 8091:8090
  brev port-forward $BREV_INSTANCE_NAME -p 18081:8081
  brev port-forward $BREV_INSTANCE_NAME -p 18082:8082
  brev port-forward $BREV_INSTANCE_NAME -p 3000:3000
  brev port-forward $BREV_INSTANCE_NAME -p 8000:8000
  brev port-forward $BREV_INSTANCE_NAME -p 6006:6006

Local browser URLs after forwarding:
  AI-Q UI:         http://localhost:3000
  Phoenix traces: http://localhost:6006
  RAG UI:         http://localhost:8091
EOF
}

main() {
  source_secrets
  install_prereqs
  ensure_swap_if_needed
  docker_login_ngc
  clone_or_update "$RAG_REPO" "$RAG_DIR" "$RAG_REF"
  clone_or_update "$AIQ_REPO" "$AIQ_DIR" "$AIQ_REF"
  start_rag
  start_rag_ingestor
  create_rag_collection
  start_aiq
  run_smoke_tests
  print_access_info
}

main "$@"
