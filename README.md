# ag-agentmemory

[English](README.md) | [Tiếng Việt](README.vi.md)

Upstream AgentMemory repo: https://github.com/rohitg00/agentmemory

Automation setup for AgentMemory across Antigravity, Codex CLI, and Claude Code on macOS.

`~/.agentmemory/.env` is the single source of truth for configuration. Embeddings run locally. LLM calls route through the logged-in Antigravity CLI proxy. No API key required.

```env
EMBEDDING_PROVIDER=local
BM25_WEIGHT=0.4
VECTOR_WEIGHT=0.6
AGENTMEMORY_URL=http://localhost:3111
AGENTMEMORY_AUTO_COMPRESS=true
CONSOLIDATION_ENABLED=true
GRAPH_EXTRACTION_ENABLED=true
AGENTMEMORY_DROP_STALE_INDEX=false
OPENAI_BASE_URL=http://127.0.0.1:3129
OPENAI_MODEL=agy-cli
```

## Quick Install

Default setup — uses the logged-in Antigravity CLI proxy, no API key:

```bash
bash setup.sh
```

Single client only:

```bash
bash setup.sh --client antigravity
bash setup.sh --client codex
bash setup.sh --client claude
```

Skip upstream sync for faster execution:

```bash
bash setup.sh --skip-upstream
```

## macOS LaunchAgent (Autostart)

`set-run.sh` registers two persistent background services via macOS LaunchAgents so both the agy-proxy and the AgentMemory server start automatically at login and restart on crash:

```bash
bash set-run.sh
```

Services registered:

| Label | Port | Log |
|---|---|---|
| `com.agentmemory.agy-proxy` | 3129 | `~/.agentmemory/agy-proxy.log` |
| `com.agentmemory.server` | 3111 / 3113 | `~/.agentmemory/server.log` |

Check status:

```bash
launchctl list | grep agentmemory
```

## Agy Local Proxy

`setup.sh` does not patch upstream AgentMemory. It starts a local OpenAI-compatible proxy at `http://127.0.0.1:3129`, then configures AgentMemory's existing `openai` provider to point to that proxy. The proxy forwards each request to `agy --print-timeout 120s -p "<prompt>"`.

Requirements and limits:

- Requires a logged-in `agy` CLI, defaulting to `~/.local/bin/agy`.
- `agy-clean-wrapper.sh` strips ANSI codes and control characters from `agy` output before forwarding.
- Each LLM call spawns a CLI process — slower than direct API calls.
- Embeddings remain local.
- Hooks and LLM-backed automation are enabled by default.

## Upstream Snapshot

Each time setup runs, the script clones or pulls upstream AgentMemory into:

```text
.agentmemory-upstream/
```

Then syncs it to a working copy without git metadata:

```text
agentmemory/
```

`agentmemory/` keeps a local snapshot so docs, plugins, hooks, and scripts remain readable even if the upstream repository is deleted or unavailable. If pull or clone fails but `agentmemory/` already exists, setup continues with the existing snapshot.

## AgentMemory Server

After setup, run the server manually:

```bash
npx -y @agentmemory/agentmemory@latest
```

Viewer UI:

```text
http://localhost:3113
```

Health check:

```bash
curl -fsSL http://localhost:3111/agentmemory/health
```

Before `setup.sh` restarts AgentMemory, it backs up runtime state to:

```text
~/.agentmemory/backups/setup-<timestamp>/
```

The backup includes the local `data/` directory (if present), `~/.agentmemory/standalone.json`, and the current env file.

## Antigravity

Antigravity has no upstream AgentMemory plugin yet. This repo sets it up manually:

- MCP config: `~/.gemini/antigravity/mcp_config.json`
- Instructions: `~/.gemini/GEMINI.md`
- Skills: `~/.gemini/antigravity/skills/`

A sentinel block prevents overwriting existing content in `GEMINI.md`:

```text
<!-- AGENTMEMORY_RULES_START -->
...
<!-- AGENTMEMORY_RULES_END -->
```

Running `setup.sh` again updates this block and recopies active skills.

## Codex CLI

Setup writes the MCP fallback configuration to:

```text
~/.codex/config.toml
```

Setup also attempts to install the upstream AgentMemory plugin and run `agentmemory connect codex --with-hooks --force`.

## Claude Code

Setup attempts to install the upstream Claude Code plugin and connect AgentMemory hooks when both `claude` and `agentmemory` CLIs are available.

## CLI

After building (`npm run build`):

```bash
node dist/cli.js setup --profile local --client all
node dist/cli.js setup --profile agy-local --agy-bin ~/.local/bin/agy
node dist/cli.js agy-proxy --host 127.0.0.1 --port 3129
node dist/cli.js verify
node dist/cli.js status
```

## Custom Overlay

Override any template by placing a file at the corresponding path under:

```text
custom/instructions/
custom/skills/
```

Setup copies the default templates first, then overlays your custom files on top. Running `setup.sh` again re-applies the overlay.

## What We Do Not Do

- Do not fork the AgentMemory upstream repository.
- Do not require an API key for embeddings.
- Do not patch upstream AgentMemory source files.
