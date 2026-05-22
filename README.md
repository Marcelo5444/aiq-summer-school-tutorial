# AIQ Summer School Tutorial

This repo contains the minimal setup for the AIQ Summer School tutorial:

- NVIDIA RAG Blueprint with Elasticsearch
- Official RAG UI/API ingestion
- NVIDIA AI-Q with web search through Tavily
- Phoenix traces
- Local port forwarding back to your laptop

The tested machine shape is a Brev CPU instance like `n2d-standard-8` with about 8 vCPU, 32 GB RAM, and 100 GB+ disk. A GPU is not needed because the tutorial uses NVIDIA-hosted NIM APIs.

## 1. Create Accounts And API Keys

Before running the tutorial, each assistant needs these accounts and keys:

1. NVIDIA Build / NIM API

   Create or sign in at [NVIDIA Build API Keys](https://build.nvidia.com/settings/api-keys).

   Generate an API key from the API Keys page. This key is used as both `NVIDIA_API_KEY` and `NGC_API_KEY` for the RAG + AIQ stack.

2. Tavily Search API

   Create or sign in at [Tavily](https://app.tavily.com).

   Copy an API key from the dashboard. This key is used as `TAVILY_API_KEY` for internet search inside the AIQ workflow.

3. Brev

   Create or sign in at [Brev](https://brev.nvidia.com).

   You do not need to paste a Brev API key into the tutorial script. You only need to be logged in with the Brev CLI on your laptop and know the target Brev instance name.

Keep all keys private. Do not send them by email, Slack, screenshots, or commit them to GitHub. Paste them only into the local setup file before running the installer.

## 2. Paste Values In The Script

Open:

```bash
scripts/install_aiq_summer_school_tutorial.sh
```

Paste the Brev machine name and API keys at the top:

```bash
BREV_INSTANCE_NAME="${BREV_INSTANCE_NAME:-native-rose-wombat}"
NVIDIA_API_KEY="${NVIDIA_API_KEY:-__PASTE_NVIDIA_API_KEY_HERE__}"
NGC_API_KEY="${NGC_API_KEY:-$NVIDIA_API_KEY}"
TAVILY_API_KEY="${TAVILY_API_KEY:-__PASTE_TAVILY_API_KEY_HERE__}"
```

The script stops immediately if any placeholder value is still present.

## 3. Run The Installer

From this repo on your laptop:

```bash
scripts/install_aiq_summer_school_tutorial.sh
```

The script does everything in order:

1. Checks the required values.
2. Copies the setup script and keys to the Brev VM.
3. Installs and starts RAG, Elasticsearch, official ingestor, AI-Q, and Phoenix.
4. Creates the default RAG collection.
5. Runs smoke tests.
6. Starts local port forwarding.
7. Verifies the local URLs.

## 4. Open The Tutorial

After the tutorial setup finishes, open:

- AI-Q UI: `http://localhost:3000`
- Phoenix traces: `http://localhost:6006`
- RAG UI: `http://localhost:8091`

Health checks:

- AI-Q API: `http://localhost:8000/health`
- RAG API: `http://localhost:18081/v1/health`
- Ingestor API: `http://localhost:18082/v1/health`
