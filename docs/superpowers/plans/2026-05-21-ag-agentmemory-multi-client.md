# ag-agentmemory Multi-Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an idempotent setup package for AgentMemory across Antigravity, Codex CLI, and Claude Code using local `all-MiniLM-L6-v2` embeddings.

**Architecture:** Implement a small TypeScript CLI with focused setup modules for env files, MCP config, instructions, skills, upstream plugin commands, and verification. Use `setup.sh` as the human entrypoint and keep all generated user config guarded by merge logic or sentinel blocks.

**Tech Stack:** Node.js 20+, TypeScript, Commander, shell script, JSON/TOML text upsert helpers.

---

### Task 1: Scaffold Package

**Files:**
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/package.json`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/tsconfig.json`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/cli.ts`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/setup/clients.ts`

- [ ] **Step 1: Create package metadata**

`package.json` defines `agentmemory-ag`, build/test scripts, Commander, and Node 20.

- [ ] **Step 2: Create TypeScript config**

Use ESM output to `dist/` with `src/` as root.

- [ ] **Step 3: Create CLI entrypoint**

Expose `setup`, `verify`, and `status` commands. `setup` accepts `--client all|antigravity|codex|claude-code`.

- [ ] **Step 4: Create client expansion helper**

`expandClients("all")` returns all three clients and rejects unknown values.

### Task 2: Shared Env Setup

**Files:**
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/setup/env-file.ts`
- Test through: `/Users/zasuo/AI-Tool/ag-agentmemory/src/cli.ts`

- [ ] **Step 1: Implement `.env` upsert**

Create `~/.agentmemory/.env` if missing and upsert active values:

```env
EMBEDDING_PROVIDER=local
BM25_WEIGHT=0.4
VECTOR_WEIGHT=0.6
AGENTMEMORY_URL=http://localhost:3111
```

Preserve unrelated comments and values.

- [ ] **Step 2: Return written path**

The function returns the env path for setup output and verification.

### Task 3: MCP Config Setup

**Files:**
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/setup/mcp-config.ts`

- [ ] **Step 1: Implement Antigravity JSON merge**

Merge `agentmemory` into `~/.gemini/antigravity/mcp_config.json` without touching other servers.

- [ ] **Step 2: Implement Codex TOML fallback**

Replace only the `[mcp_servers.agentmemory]` block in `~/.codex/config.toml`, preserving other config.

- [ ] **Step 3: Use MCP env**

Both configs include `AGENTMEMORY_URL=http://localhost:3111` and `EMBEDDING_PROVIDER=local`.

### Task 4: Instructions And Skills

**Files:**
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/setup/instructions.ts`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/setup/skills.ts`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/templates/instructions/AGENTMEMORY.md`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/templates/skills/agentmemory-recall/SKILL.md`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/templates/skills/agentmemory-observe/SKILL.md`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/templates/skills/agentmemory-session-start/SKILL.md`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/templates/skills/agentmemory-session-end/SKILL.md`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/templates/skills/agentmemory-setup/SKILL.md`

- [ ] **Step 1: Implement instruction sentinel upsert**

Use `<!-- AGENTMEMORY_RULES_START -->` and `<!-- AGENTMEMORY_RULES_END -->`.

- [ ] **Step 2: Install Antigravity instructions**

Write the managed block to `~/.gemini/GEMINI.md`.

- [ ] **Step 3: Implement skill copying with custom overlay**

Copy default skills first and overlay `custom/skills` if present.

- [ ] **Step 4: Install Antigravity skills**

Target `~/.gemini/antigravity/skills`.

### Task 5: Upstream Plugin Setup

**Files:**
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/setup/upstream.ts`

- [ ] **Step 1: Implement command detection**

Detect `codex`, `agentmemory`, and `npx` with `spawnSync`.

- [ ] **Step 2: Implement Codex upstream install**

When `codex` exists, run:

```bash
codex plugin marketplace add rohitg00/agentmemory
codex plugin install agentmemory
```

If either command fails, return a fallback-needed status.

- [ ] **Step 3: Implement Claude Code upstream connect**

When `agentmemory` exists, run:

```bash
agentmemory connect claude-code
```

If unavailable or failed, return manual commands for the user.

### Task 6: Setup Orchestration And Verify

**Files:**
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/setup/setup-command.ts`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/src/setup/verify.ts`
- Modify: `/Users/zasuo/AI-Tool/ag-agentmemory/src/cli.ts`

- [ ] **Step 1: Orchestrate setup**

Always upsert shared env first. Then:

- Antigravity: MCP + instructions + skills
- Codex: upstream plugin, fallback MCP on failure
- Claude Code: upstream connect/manual instructions

- [ ] **Step 2: Implement verification**

Check Node 20, `npx`, env values, Antigravity config, Codex plugin-or-MCP state, and AgentMemory health if server is running.

- [ ] **Step 3: Wire CLI commands**

`setup` calls orchestration, `verify` calls verification, `status` prints verification JSON without failing.

### Task 7: Shell Entrypoint And Docs

**Files:**
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/setup.sh`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/README.vi.md`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/custom/instructions/.gitkeep`
- Create: `/Users/zasuo/AI-Tool/ag-agentmemory/custom/skills/.gitkeep`

- [ ] **Step 1: Implement `setup.sh`**

Check Node 20 and npm, run `npm install`, `npm run build`, then `node dist/cli.js setup --client <client>`.

- [ ] **Step 2: Document usage in Vietnamese**

Include setup commands, client behavior, local embedding config, verification, and non-goals.

### Task 8: Build And Verify

**Files:**
- Uses all created files.

- [ ] **Step 1: Install dependencies**

Run: `npm install`

- [ ] **Step 2: Build**

Run: `npm run build`

Expected: TypeScript compiles with no errors.

- [ ] **Step 3: Run verification**

Run: `node dist/cli.js verify`

Expected: Reports config status and does not mutate files.

- [ ] **Step 4: Run dry status**

Run: `node dist/cli.js status`

Expected: Prints JSON verification status.

---

## Self-Review

- Spec coverage: Antigravity custom setup, Codex upstream-first with MCP fallback, Claude Code upstream-first, shared local embedding env, idempotent safety, verification, and docs are covered.
- Placeholder scan: no TBD/TODO placeholders are present.
- Type consistency: client names are consistently `antigravity`, `codex`, `claude-code`, and `all`.
- Git workflow: no commit steps are included because project instructions explicitly skip commit unless requested.
