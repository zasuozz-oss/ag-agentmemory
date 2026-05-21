# ag-agentmemory

[English](README.md) | [Tiếng Việt](README.vi.md)

Automation setup for AgentMemory across Antigravity, Codex CLI, and Claude Code.

By default, it configures local embeddings using `all-MiniLM-L6-v2` via AgentMemory's local provider:

```env
EMBEDDING_PROVIDER=local
BM25_WEIGHT=0.4
VECTOR_WEIGHT=0.6
AGENTMEMORY_URL=http://localhost:3111
```

## Quick Install

```bash
bash setup.sh
```

To set up a single client only:

```bash
bash setup.sh --client antigravity
bash setup.sh --client codex
bash setup.sh --client claude-code
```

To skip the upstream sync for faster execution:

```bash
bash setup.sh --skip-upstream
```

## Upstream Snapshot

Each time setup is executed, the script will clone or pull the upstream AgentMemory into the cache:

```text
.agentmemory-upstream/
```

Then, it syncs it to the working copy without git metadata:

```text
agentmemory/
```

The `agentmemory/` directory keeps a local snapshot so that you can still read docs, plugins, hooks, and scripts even if the upstream GitHub repository is deleted or if there is a network issue. If pulling/cloning fails but `agentmemory/` already exists, the setup will proceed using the old snapshot.

## AgentMemory Server

After the setup is complete, run the server:

```bash
npx -y @agentmemory/agentmemory@latest
```

Viewer:

```text
http://localhost:3113
```

Health:

```bash
curl -fsSL http://localhost:3111/agentmemory/health
```

## Antigravity

Since Antigravity does not have an upstream AgentMemory plugin yet, this repository sets it up manually:

- MCP: `~/.gemini/antigravity/mcp_config.json`
- Instructions: `~/.gemini/GEMINI.md`
- Skills: `~/.gemini/antigravity/skills/`

The setup uses a sentinel block to avoid overwriting existing content in `GEMINI.md`.

## Codex CLI

Codex CLI has an upstream AgentMemory plugin. The setup prioritizes:

```bash
codex plugin marketplace add rohitg00/agentmemory
codex plugin install agentmemory
```

If the plugin installation is unavailable, the setup falls back to an MCP-only configuration in:

```text
~/.codex/config.toml
```

Note: The fallback configuration does not automatically create custom hooks.

## Claude Code

Claude Code has the most comprehensive upstream plugin for AgentMemory. The setup will attempt:

```bash
agentmemory connect claude-code
```

If this cannot be run non-interactively, you can set it up manually in Claude Code:

```text
/plugin marketplace add rohitg00/agentmemory
/plugin install agentmemory
```

## CLI

After building:

```bash
node dist/cli.js setup --client all
node dist/cli.js verify
node dist/cli.js status
```

## Custom Overlay

You can override templates by placing the corresponding files in:

```text
custom/instructions/
custom/skills/
```

The setup copies the default templates first, and then overlays your custom templates.

Antigravity instructions are written into `~/.gemini/GEMINI.md` using the following block:

```text
<!-- AGENTMEMORY_RULES_START -->
...
<!-- AGENTMEMORY_RULES_END -->
```

Running `setup.sh` again will update this block and copy active skills to `~/.gemini/antigravity/skills/`.

## What We Do Not Do

- Do not fork the AgentMemory upstream repository.
- Do not replace Codex/Claude upstream hooks with custom hooks.
- Do not require an API key for embeddings.
- Do not enable LLM compression/consolidation by default.
