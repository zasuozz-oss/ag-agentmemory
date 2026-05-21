---
name: agentmemory-setup
description: Use when installing, verifying, or troubleshooting AgentMemory setup for Antigravity, Codex CLI, or Claude Code
---

# AgentMemory Setup

Use this for AgentMemory setup and verification.

## Expected Local Embedding Config

`~/.agentmemory/.env` should contain:

```env
EMBEDDING_PROVIDER=local
BM25_WEIGHT=0.4
VECTOR_WEIGHT=0.6
AGENTMEMORY_URL=http://localhost:3111
```

## Start Server

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

## Client Setup

- Antigravity: use custom MCP config and these skills.
- Codex CLI: prefer upstream plugin, fallback to MCP-only.
- Claude Code: prefer upstream plugin or `agentmemory connect claude-code`.
