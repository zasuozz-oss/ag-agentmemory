# ag-agentmemory Multi-Client Setup Design

## Goal

Build `ag-agentmemory` as an idempotent automation package for configuring AgentMemory across Antigravity, Codex CLI, and Claude Code.

The setup must use local embeddings via `all-MiniLM-L6-v2` by default and must preserve existing user configuration.

## Clients

### Antigravity

Antigravity does not have a first-class upstream AgentMemory integration today, so `ag-agentmemory` owns the full setup for this client.

The setup writes or repairs:

- MCP config: `~/.gemini/antigravity/mcp_config.json`
- Global instructions: `~/.gemini/GEMINI.md`
- Skills: `~/.gemini/antigravity/skills/`

The MCP entry is named `agentmemory` and runs:

```json
{
  "command": "npx",
  "args": ["-y", "@agentmemory/mcp"],
  "env": {
    "AGENTMEMORY_URL": "http://localhost:3111",
    "EMBEDDING_PROVIDER": "local"
  }
}
```

The Antigravity skills emulate the useful parts of hook-driven memory capture:

- `agentmemory-recall`
- `agentmemory-observe`
- `agentmemory-session-start`
- `agentmemory-session-end`
- `agentmemory-setup`

### Codex CLI

Codex CLI has upstream AgentMemory support through the Codex plugin platform. The preferred setup path is:

```bash
codex plugin marketplace add rohitg00/agentmemory
codex plugin install agentmemory
```

The upstream plugin registers:

- `@agentmemory/mcp`
- 6 lifecycle hooks: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PreCompact`, `Stop`
- 4 skills: `/recall`, `/remember`, `/session-history`, `/forget`

`ag-agentmemory` should use this upstream path when `codex` is available.

If plugin installation is unavailable or fails, `ag-agentmemory` falls back to MCP-only setup in `~/.codex/config.toml`:

```toml
[mcp_servers.agentmemory]
command = "npx"
args = ["-y", "@agentmemory/mcp"]

[mcp_servers.agentmemory.env]
AGENTMEMORY_URL = "http://localhost:3111"
EMBEDDING_PROVIDER = "local"
```

The fallback must not attempt to create custom Codex hooks unless explicitly requested later.

### Claude Code

Claude Code has the strongest upstream AgentMemory integration. The preferred setup path is the upstream plugin:

```text
/plugin marketplace add rohitg00/agentmemory
/plugin install agentmemory
```

For CLI automation, `ag-agentmemory` may call:

```bash
agentmemory connect claude-code
```

The upstream Claude Code plugin registers MCP, 12 hooks, and the AgentMemory skills. `ag-agentmemory` should not replace this with custom hooks.

If automation cannot install the Claude Code plugin non-interactively, it should print exact manual commands and still configure the shared AgentMemory environment.

## Shared AgentMemory Environment

All clients share `~/.agentmemory/.env`. Setup must upsert these values:

```env
EMBEDDING_PROVIDER=local
BM25_WEIGHT=0.4
VECTOR_WEIGHT=0.6
AGENTMEMORY_URL=http://localhost:3111
```

Existing unrelated keys and comments must be preserved. Existing active values for these four keys may be replaced by setup because they define the selected local embedding mode.

The local provider uses Xenova `all-MiniLM-L6-v2` with 384-dimensional embeddings.

## Package Structure

```text
ag-agentmemory/
├── package.json
├── tsconfig.json
├── setup.sh
├── README.vi.md
├── src/
│   ├── cli.ts
│   └── setup/
│       ├── clients.ts
│       ├── env-file.ts
│       ├── instructions.ts
│       ├── mcp-config.ts
│       ├── skills.ts
│       ├── upstream.ts
│       └── verify.ts
├── src/templates/
│   ├── instructions/AGENTMEMORY.md
│   └── skills/
└── custom/
    ├── instructions/
    └── skills/
```

`custom/` overlays templates the same way `ag-rtk` does.

## CLI

The package exposes:

```bash
agentmemory-ag setup --client all
agentmemory-ag setup --client antigravity
agentmemory-ag setup --client codex
agentmemory-ag setup --client claude-code
agentmemory-ag verify
agentmemory-ag status
```

`setup.sh` is the user-facing entrypoint and defaults to:

```bash
bash setup.sh --client all
```

## Safety

Setup must be idempotent:

- JSON MCP config is merged, not overwritten.
- TOML config only replaces the `agentmemory` MCP block.
- Markdown instructions use sentinel markers.
- Skill directories are copied from templates and custom overlays.
- Existing user files are preserved outside managed blocks.

The setup script must not create git commits or branches.

## Verification

Verification checks:

- Node.js is at least version 20.
- `npx` is available.
- `~/.agentmemory/.env` contains local embedding values.
- Antigravity MCP config has an `agentmemory` server.
- Codex has either the upstream plugin path installed or MCP fallback configured.
- Claude Code setup is either detected or exact manual commands are reported.
- If AgentMemory server is running, `http://localhost:3111/agentmemory/health` responds.

If the server is not running, verification should print:

```bash
npx -y @agentmemory/agentmemory@latest
```

## Non-Goals

- Do not fork AgentMemory upstream.
- Do not replace upstream Codex or Claude Code plugins with custom hooks.
- Do not require API keys for embeddings.
- Do not enable LLM-backed compression or consolidation by default.
