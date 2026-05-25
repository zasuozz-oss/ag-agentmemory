#!/usr/bin/env bash
# setup.sh — wire agentmemory into Claude Code, Codex, Antigravity, then build/start the agy proxy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

AGENTMEMORY_URL_VAL="http://localhost:3111"
PROXY_BASE_URL="http://127.0.0.1:3129"
PROXY_MODEL="agy-cli"
PROXY_API_KEY="sk-agy-proxy"   # dummy — agy proxy ignores the key
CLIENT="all"
FORCE=""
SKIP_PROXY="false"
SKIP_ENV="false"

# Proxy / daemon defaults (previously in setup_proxy.sh)
PROXY_CONFIG_DIR="${HOME}/.ag-agentmemmory-proxy"
PROXY_ENV_FILE="${PROXY_CONFIG_DIR}/proxy.env"
AGY_BIN="${SCRIPT_DIR}/agy-clean-wrapper.sh"
AGY_HOST="127.0.0.1"
AGY_PORT="3129"
AGY_TIMEOUT_MS="120000"
AGY_SANDBOX="false"
SKIP_BUILD="false"
SKIP_AGENTMEMORY_STARTUP="false"
AGENTMEMORY_BIN=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR ]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}▶ $*${NC}"; }

usage() {
  cat <<'USAGE'
Usage: bash setup.sh [options]

Client wiring:
  --client <all|claude-code|codex|antigravity>   Default: all
  --force                                         Re-install even if already wired
  --skip-env                                      Do not modify shell profiles

Proxy / daemon:
  --skip-proxy                                    Do not build / start the agy proxy
  --skip-build                                    Do not run npm install/build
  --agy-bin <path>                                Path to agy wrapper or CLI binary
  --host <host>                                   Proxy host (default 127.0.0.1)
  --port <number>                                 Proxy port (default 3129)
  --timeout-ms <number>                           agy CLI timeout in ms (default 120000)
  --sandbox                                       Pass --sandbox to agy CLI
  --agentmemory-bin <path>                        Path to agentmemory binary (auto-detected)
  --skip-agentmemory-startup                      Do not register agentmemory startup service

  -h, --help                                      Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client=*) CLIENT="${1#*=}"; shift ;;
    --client) [[ $# -ge 2 ]] || err "--client requires a value"; CLIENT="$2"; shift 2 ;;
    --force) FORCE="--force"; shift ;;
    --skip-proxy) SKIP_PROXY="true"; shift ;;
    --skip-env) SKIP_ENV="true"; shift ;;

    --skip-build) SKIP_BUILD="true"; shift ;;
    --agy-bin=*) AGY_BIN="${1#*=}"; shift ;;
    --agy-bin) [[ $# -ge 2 ]] || err "--agy-bin requires a value"; AGY_BIN="$2"; shift 2 ;;
    --host=*) AGY_HOST="${1#*=}"; shift ;;
    --host) [[ $# -ge 2 ]] || err "--host requires a value"; AGY_HOST="$2"; shift 2 ;;
    --port=*) AGY_PORT="${1#*=}"; shift ;;
    --port) [[ $# -ge 2 ]] || err "--port requires a value"; AGY_PORT="$2"; shift 2 ;;
    --timeout-ms=*) AGY_TIMEOUT_MS="${1#*=}"; shift ;;
    --timeout-ms) [[ $# -ge 2 ]] || err "--timeout-ms requires a value"; AGY_TIMEOUT_MS="$2"; shift 2 ;;
    --sandbox) AGY_SANDBOX="true"; shift ;;
    --agentmemory-bin=*) AGENTMEMORY_BIN="${1#*=}"; shift ;;
    --agentmemory-bin) [[ $# -ge 2 ]] || err "--agentmemory-bin requires a value"; AGENTMEMORY_BIN="$2"; shift 2 ;;
    --skip-agentmemory-startup) SKIP_AGENTMEMORY_STARTUP="true"; shift ;;

    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

case "$CLIENT" in
  all|claude-code|codex|antigravity) ;;
  *) err "--client must be one of: all, claude-code, codex, antigravity" ;;
esac
case "$AGY_PORT" in
  ''|*[!0-9]*) err "--port must be a number" ;;
esac
case "$AGY_TIMEOUT_MS" in
  ''|*[!0-9]*) err "--timeout-ms must be a number" ;;
esac

has_client() { [[ "$CLIENT" == "all" || "$CLIENT" == "$1" ]]; }

# ─── OS Detection ─────────────────────────────────────────────────────────────

OS="unknown"
case "$(uname -s)" in
  Darwin) OS="mac" ;;
  Linux)  OS="linux" ;;
  MINGW*|MSYS*|CYGWIN*) OS="win" ;;
esac

GEMINI_BASE="${HOME}/.gemini"
if [[ "$OS" == "win" && -n "${APPDATA:-}" ]]; then
  GEMINI_BASE="${APPDATA}/Google/Gemini"
fi

CODEX_CONFIG="${HOME}/.codex/config.toml"
if [[ "$OS" == "win" && -n "${APPDATA:-}" ]]; then
  CODEX_CONFIG="${APPDATA}/Codex/config.toml"
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

require_command() {
  command -v "$1" >/dev/null 2>&1 || err "Required command not found: $1"
}

# Resolve the agentmemory plugin install directory (ships 6 hook scripts + 8 skills).
agentmemory_plugin_root() {
  local npm_root
  npm_root="$(npm root -g 2>/dev/null || echo '')"
  local candidates=(
    "${npm_root}/@agentmemory/agentmemory/plugin"
    "/opt/homebrew/lib/node_modules/@agentmemory/agentmemory/plugin"
    "/usr/local/lib/node_modules/@agentmemory/agentmemory/plugin"
    "${HOME}/AppData/Roaming/npm/node_modules/@agentmemory/agentmemory/plugin"
  )
  for c in "${candidates[@]}"; do
    if [[ -d "$c/scripts" ]]; then echo "$c"; return 0; fi
  done
  return 1
}

upsert_env_var() {
  local key="$1" value="$2" file="$3"
  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]] && grep -qE "^#?[[:space:]]*${key}[[:space:]]*=" "$file"; then
    if [[ "$OS" == "mac" ]]; then
      sed -i '' "s|^#*[[:space:]]*${key}[[:space:]]*=.*|${key}=${value}|" "$file"
    else
      sed -i "s|^#*[[:space:]]*${key}[[:space:]]*=.*|${key}=${value}|" "$file"
    fi
    info "Updated ${key} in ${file}"
  else
    echo "${key}=${value}" >> "$file"
    info "Added ${key} to ${file}"
  fi
}

# upsert_json_mcp <config-file> <server-name> <command> <args-json> [env-json]
upsert_json_mcp() {
  local target="$1" server_name="$2" cmd="$3" args_json="$4"
  local env_json="${5:-}"
  [[ -n "$env_json" ]] || env_json='{}'
  mkdir -p "$(dirname "$target")"
  node - "$target" "$server_name" "$cmd" "$args_json" "$env_json" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [target, name, cmd, argsJson, envJson] = process.argv.slice(2);
let config = {};
try { config = JSON.parse(fs.readFileSync(target, 'utf8')); } catch {}
if (!config.mcpServers || typeof config.mcpServers !== 'object') config.mcpServers = {};
config.mcpServers[name] = {
  command: cmd,
  args: JSON.parse(argsJson),
  env: JSON.parse(envJson),
};
fs.mkdirSync(path.dirname(target), { recursive: true });
fs.writeFileSync(target, JSON.stringify(config, null, 2) + '\n');
NODE
}

# upsert_block <content> <target> <start-marker> <end-marker>
upsert_block() {
  local content="$1" target="$2" start="$3" end="$4"
  mkdir -p "$(dirname "$target")"
  UPSERT_BLOCK_CONTENT="$content" node - "$target" "$start" "$end" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [target, start, end] = process.argv.slice(2);
const content = process.env.UPSERT_BLOCK_CONTENT || '';
const block = `${start}\n${content.trim()}\n${end}`;
let current = '';
try { current = fs.readFileSync(target, 'utf8'); } catch {}
const escStart = start.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const escEnd   = end.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const re = new RegExp(`${escStart}[\\s\\S]*?${escEnd}`);
const next = current.includes(start) && current.includes(end)
  ? current.replace(re, block)
  : `${current.trimEnd()}${current.trim() ? '\n\n' : ''}${block}\n`;
fs.mkdirSync(path.dirname(target), { recursive: true });
fs.writeFileSync(target, next);
NODE
}

merge_claude_hooks() {
  local patch_json="$1"
  local settings="${HOME}/.claude/settings.json"
  mkdir -p "$(dirname "$settings")"
  node - "$settings" "$patch_json" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [settingsFile, patchJson] = process.argv.slice(2);
let settings = {};
try { settings = JSON.parse(fs.readFileSync(settingsFile, 'utf8')); } catch {}
const patch = JSON.parse(patchJson);

if (!settings.hooks || typeof settings.hooks !== 'object') settings.hooks = {};

for (const [event, entries] of Object.entries(patch)) {
  if (!settings.hooks[event]) { settings.hooks[event] = entries; continue; }
  for (const entry of entries) {
    const cmd = entry.hooks?.[0]?.command;
    if (!cmd) continue;
    const exists = settings.hooks[event].some(
      (e) => e.hooks?.some((h) => h.command === cmd)
    );
    if (!exists) settings.hooks[event].push(entry);
  }
}

fs.mkdirSync(path.dirname(settingsFile), { recursive: true });
fs.writeFileSync(settingsFile, JSON.stringify(settings, null, 2) + '\n');
NODE
}

# ─── Phase 1: Environment ─────────────────────────────────────────────────────

setup_env() {
  step "Environment: agentmemory init + agy proxy provider config"

  require_command agentmemory
  require_command node
  require_command npx

  agentmemory init 2>/dev/null || true

  local env_file="${HOME}/.agentmemory/.env"

  # Core URL
  upsert_env_var "AGENTMEMORY_URL"           "$AGENTMEMORY_URL_VAL" "$env_file"

  # Point AgentMemory's OpenAI client at the agy-cli proxy (no real API key needed)
  upsert_env_var "OPENAI_BASE_URL"           "$PROXY_BASE_URL"      "$env_file"
  upsert_env_var "OPENAI_API_KEY"            "$PROXY_API_KEY"       "$env_file"
  upsert_env_var "OPENAI_MODEL"              "$PROXY_MODEL"         "$env_file"

  # Local embeddings (no remote embedding API needed)
  upsert_env_var "EMBEDDING_PROVIDER"        "local"                "$env_file"

  # Enable LLM-driven features now that a provider is configured
  upsert_env_var "AGENTMEMORY_AUTO_COMPRESS" "true"                 "$env_file"
  upsert_env_var "CONSOLIDATION_ENABLED"     "true"                 "$env_file"
  upsert_env_var "GRAPH_EXTRACTION_ENABLED"  "true"                 "$env_file"
  upsert_env_var "AGENTMEMORY_INJECT_CONTEXT" "true"                "$env_file"

  # Export for the current shell so downstream stages see it
  export AGENTMEMORY_URL="$AGENTMEMORY_URL_VAL"

  if [[ "$SKIP_ENV" == "true" ]]; then
    warn "--skip-env: skipping shell profile update"
    return 0
  fi

  local export_line="export AGENTMEMORY_URL=${AGENTMEMORY_URL_VAL}"
  local comment_line="# agentmemory — required for Claude Code / Codex MCP plugin"

  for profile in "${HOME}/.zshrc" "${HOME}/.bashrc" "${HOME}/.bash_profile"; do
    [[ -f "$profile" ]] || continue
    if grep -qF "AGENTMEMORY_URL" "$profile"; then
      info "AGENTMEMORY_URL already in $profile"
    else
      printf '\n%s\n%s\n' "$comment_line" "$export_line" >> "$profile"
      ok "Added AGENTMEMORY_URL to $profile"
    fi
  done
}

# ─── Phase 2: Claude Code ─────────────────────────────────────────────────────

install_claude_code() {
  step "Claude Code: MCP + 6 agentmemory hooks"
  require_command claude

  local plugin_root
  plugin_root="$(agentmemory_plugin_root)" || err "agentmemory plugin not found — install @agentmemory/agentmemory globally"
  info "Plugin root: $plugin_root"

  info "Wiring agentmemory MCP into Claude Code"
  agentmemory connect claude-code ${FORCE} 2>&1 | grep -v "^$" || true

  info "Merging 6 agentmemory hooks into ~/.claude/settings.json"
  # Real hook scripts shipped by the agentmemory plugin:
  #   session-start, prompt-submit, pre-tool-use, post-tool-use, pre-compact, stop
  local hooks_json
  hooks_json="$(node - "$plugin_root" <<'NODE'
const root = process.argv[2];
const cmd = (name) => `node "${root}/scripts/${name}.mjs"`;
const config = {
  SessionStart: [{ hooks: [{ type: "command", command: cmd("session-start"), statusMessage: "agentmemory: loading session context" }] }],
  UserPromptSubmit: [{ hooks: [{ type: "command", command: cmd("prompt-submit"), statusMessage: "agentmemory: recalling relevant memories" }] }],
  PreToolUse:  [{ matcher: "Edit|Write|Read|Glob|Grep", hooks: [{ type: "command", command: cmd("pre-tool-use") }] }],
  PostToolUse: [{ hooks: [{ type: "command", command: cmd("post-tool-use") }] }],
  PreCompact:  [{ hooks: [{ type: "command", command: cmd("pre-compact") }] }],
  Stop:        [{ hooks: [{ type: "command", command: cmd("stop") }] }],
};
process.stdout.write(JSON.stringify(config));
NODE
)"
  merge_claude_hooks "$hooks_json"

  ok "Claude Code wired with 6 hooks (restart Claude Code to pick up changes)"
}

# ─── Phase 3: Codex ───────────────────────────────────────────────────────────

install_codex() {
  step "Codex: MCP + plugin (6 hooks via Codex plugin system)"
  require_command codex

  local plugin_root
  plugin_root="$(agentmemory_plugin_root)" || err "agentmemory plugin not found — install @agentmemory/agentmemory globally"

  info "Wiring agentmemory MCP into Codex"
  agentmemory connect codex ${FORCE} 2>&1 | grep -v "^$" || true

  # Codex loads hooks via its plugin system. Register the agentmemory plugin
  # directory as a local marketplace, then install the agentmemory plugin.
  info "Registering agentmemory plugin marketplace: $plugin_root"
  if codex plugin marketplace add "$plugin_root" 2>&1 | grep -v "^$"; then
    info "Installing agentmemory plugin"
    codex plugin add "agentmemory@agentmemory" 2>&1 | grep -v "^$" || \
      warn "codex plugin add failed — open Codex TUI to install + trust the agentmemory plugin manually"
  else
    warn "codex plugin marketplace add failed — open Codex TUI to add the plugin manually:"
    warn "  codex plugin marketplace add $plugin_root"
    warn "  codex plugin add agentmemory@agentmemory"
  fi

  ok "Codex MCP wired"
  warn "First TUI launch: Codex will prompt to trust the agentmemory plugin + its 6 hooks — accept all."
}

# ─── Phase 4: Antigravity ─────────────────────────────────────────────────────

install_antigravity_mcp() {
  local target="${GEMINI_BASE}/antigravity/mcp_config.json"
  info "MCP config → $target"
  upsert_json_mcp "$target" "agentmemory" "npx" \
    '["-y","@agentmemory/mcp"]' \
    "{\"AGENTMEMORY_URL\":\"${AGENTMEMORY_URL_VAL}\",\"EMBEDDING_PROVIDER\":\"local\"}"
  ok "Antigravity MCP config updated"
}

install_antigravity_instructions() {
  local target="${GEMINI_BASE}/GEMINI.md"
  info "Instructions → $target"
  local content='# AgentMemory

Use AgentMemory for durable project memory across sessions.

## Rules

- Use `memory_smart_search` or `memory_recall` when past decisions, bugs, preferences, or architecture may matter.
- Use `memory_save` for durable facts, decisions, preferences, workflow notes, and bug discoveries.
- Use `memory_lesson_save` for reusable lessons.
- Do not save secrets, API keys, tokens, passwords, or private credentials.
- Keep saved memories concise and include relevant file paths when useful.

## Proxy Configuration

This setup uses local embeddings via the Antigravity CLI proxy:

```env
EMBEDDING_PROVIDER=local
AGENTMEMORY_AUTO_COMPRESS=true
CONSOLIDATION_ENABLED=true
GRAPH_EXTRACTION_ENABLED=true
OPENAI_BASE_URL=http://127.0.0.1:3129
OPENAI_MODEL=agy-cli
```

API keys are optional — AgentMemory calls the local proxy, which forwards to the logged-in `agy` CLI.'

  upsert_block "$content" "$target" \
    "<!-- AGENTMEMORY_RULES_START -->" \
    "<!-- AGENTMEMORY_RULES_END -->"
  ok "Antigravity instructions updated in $target"
}

write_skill() {
  local skill_dir="$1" name="$2"
  shift 2
  mkdir -p "$skill_dir/$name"
  printf '%s\n' "$@" > "$skill_dir/$name/SKILL.md"
}

install_antigravity_skills() {
  local target="${GEMINI_BASE}/antigravity/skills"
  info "Skills → $target"
  mkdir -p "$target"

  write_skill "$target" "recall" \
    '---' \
    'name: recall' \
    'description: Search agentmemory for past observations, sessions, and learnings about a topic. Use when the user says "recall", "remember", "what did we do", or needs context from past sessions.' \
    'argument-hint: "[search query]"' \
    'user-invocable: true' \
    '---' \
    '' \
    'The user wants to recall past context about: $ARGUMENTS' \
    '' \
    'Use `memory_smart_search` with the query as the `query` argument and `limit: 10`.' \
    'Present results grouped by session — type, title, narrative. Highlight importance >= 7.' \
    'If no results, suggest 2-3 alternative search terms. Do NOT fabricate observations.'

  write_skill "$target" "remember" \
    '---' \
    'name: remember' \
    'description: Explicitly save an insight, decision, or learning to agentmemory long-term storage. Use when the user says "remember this", "save this", or wants to preserve knowledge for future sessions.' \
    'argument-hint: "[what to remember]"' \
    'user-invocable: true' \
    '---' \
    '' \
    'The user wants to save this to long-term memory: $ARGUMENTS' \
    '' \
    '1. Extract the core insight, decision, or fact.' \
    '2. Extract 2-5 searchable `concepts` (lowercased keyword phrases).' \
    '3. Extract any relevant `files` (absolute or repo-relative paths).' \
    '4. Call `memory_save` with `content`, `concepts`, and `files`.' \
    '5. Confirm to the user and show the concepts tagged.'

  write_skill "$target" "forget" \
    '---' \
    'name: forget' \
    'description: Delete specific observations or sessions from agentmemory. Use when user says "forget this", "delete memory", or wants to remove specific data.' \
    'argument-hint: "[session ID, file path, or search term]"' \
    'user-invocable: true' \
    '---' \
    '' \
    'The user wants to remove data from agentmemory: $ARGUMENTS' \
    '' \
    'IMPORTANT: Always confirm with the user before deleting.' \
    '1. Search with `memory_smart_search`, query from user input, limit 20.' \
    '2. Show found items and ask for explicit confirmation.' \
    '3. Once confirmed, call `memory_governance_delete` with `memoryIds: [...]`.' \
    '4. Confirm deletion count back to the user.'

  write_skill "$target" "handoff" \
    '---' \
    'name: handoff' \
    'description: Resume the most recent agent session for the current project. Use when user says "where were we", "resume", "handoff", or starts with no fresh context.' \
    'argument-hint: "[optional cwd override]"' \
    'user-invocable: true' \
    '---' \
    '' \
    'The user wants to resume work. Optional cwd override: $ARGUMENTS' \
    '' \
    '1. Call `memory_sessions` and find the most recent session matching the current working directory.' \
    '2. If the session ended on an unanswered question, surface that first.' \
    '3. Summarize the session: title, key files, key decisions, errors.' \
    '4. Use `memory_recall` (limit 10) for supporting observations.' \
    '5. End with a "next step?" pointer. Do not invent observations.'

  write_skill "$target" "recap" \
    '---' \
    'name: recap' \
    'description: Summarize recent agent sessions for the current project. Use when user asks "recap", "what have we been doing", "this week", "today".' \
    'argument-hint: "[last N | today | this week]"' \
    'user-invocable: true' \
    '---' \
    '' \
    'The user wants a recap. Time window args: $ARGUMENTS' \
    '' \
    'Parse $ARGUMENTS: "today" = current date, "this week" = last 7 days, "last N" / bare number = N sessions, empty = last 10.' \
    'Call `memory_sessions`, filter by cwd and time window, sort by startedAt descending.' \
    'Group by date. For each session: id (8 chars), title, observation count, status.' \
    'Use `memory_recall` (limit 3) for highlights (importance >= 7).' \
    'End with totals: "N sessions across M days, K observations."'

  write_skill "$target" "session-history" \
    '---' \
    'name: session-history' \
    'description: Show recent sessions for this project. Use when user asks "what did we do last time", "session history", or "past sessions".' \
    'user-invocable: true' \
    '---' \
    '' \
    'Call `memory_sessions` with `limit: 20`. Present in reverse chronological order:' \
    '- Session ID (8 chars), project, start time, status' \
    '- Key highlights per session (type + title) for sessions with observations' \
    '- Observation count and summary/title if available' \
    'Do NOT fabricate sessions.'

  write_skill "$target" "commit-context" \
    '---' \
    'name: commit-context' \
    'description: Trace a file, function, or line back to the agent session that produced its current commit.' \
    'argument-hint: "[file, function, or line]"' \
    'user-invocable: true' \
    '---' \
    '' \
    'The user wants commit context for: $ARGUMENTS' \
    '' \
    'Run `git blame` or `git log -L` on the target to get the commit SHA.' \
    'Look up the linked session via `memory_commit_lookup` with `sha: "<full-sha>"` if available,' \
    'or fall back to HTTP: GET $AGENTMEMORY_URL/agentmemory/session/by-commit?sha=<sha>.' \
    'Present: commit SHA, branch, author, message, linked session(s), key observations (importance >= 7).' \
    'Do not fabricate intent. Say plainly if no session is linked.'

  write_skill "$target" "commit-history" \
    '---' \
    'name: commit-history' \
    'description: List recent git commits linked to agent sessions. Use when user asks "show agent commits" or wants commits with session context.' \
    'argument-hint: "[branch=... repo=... limit=...]"' \
    'user-invocable: true' \
    '---' \
    '' \
    'Parse $ARGUMENTS for optional branch=, repo=, limit= tokens. Defaults: no filter, limit 100.' \
    'Call `memory_commits` with parsed filters, or fall back to HTTP:' \
    'GET $AGENTMEMORY_URL/agentmemory/commits with URL-encoded query params.' \
    'Render reverse-chronological: short SHA, branch, timestamp, commit message, linked session id(s).' \
    'If empty, tell the user and suggest dropping filters. Do not invent commits.'

  ok "Antigravity skills written to $target"
}

install_antigravity() {
  step "Antigravity: MCP + skills + instructions"
  install_antigravity_mcp
  install_antigravity_skills
  install_antigravity_instructions
  ok "Antigravity setup complete — restart Antigravity to pick up changes"
}

# ─── Phase 5: agy proxy + agentmemory daemon startup ──────────────────────────

find_agentmemory_bin() {
  if [[ -n "$AGENTMEMORY_BIN" ]]; then
    [[ -x "$AGENTMEMORY_BIN" ]] || err "--agentmemory-bin not executable: $AGENTMEMORY_BIN"
    return 0
  fi

  local candidates=(
    "$(command -v agentmemory 2>/dev/null || true)"
    "/opt/homebrew/bin/agentmemory"
    "/usr/local/bin/agentmemory"
    "${HOME}/.local/bin/agentmemory"
    "${HOME}/AppData/Roaming/npm/agentmemory"
  )

  for c in "${candidates[@]}"; do
    if [[ -n "$c" && -x "$c" ]]; then
      AGENTMEMORY_BIN="$c"
      info "Found agentmemory: $AGENTMEMORY_BIN"
      return 0
    fi
  done

  warn "agentmemory binary not found — skipping startup registration"
  warn "Install with: sudo npm install -g @agentmemory/agentmemory"
  return 1
}

agentmemory_healthy() {
  node -e "fetch('http://localhost:3111/agentmemory/health').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
}

# macOS: register as LaunchAgent (runs at login, auto-restarts on crash)
register_launchagent() {
  local label="com.agentmemory"
  local plist="${HOME}/Library/LaunchAgents/${label}.plist"
  local log="${PROXY_CONFIG_DIR}/agentmemory.log"

  mkdir -p "${HOME}/Library/LaunchAgents" "$PROXY_CONFIG_DIR"

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${AGENTMEMORY_BIN}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin</string>
    <key>AGENTMEMORY_URL</key><string>${AGENTMEMORY_URL_VAL}</string>
    <key>OPENAI_BASE_URL</key><string>${PROXY_BASE_URL}</string>
    <key>OPENAI_API_KEY</key><string>${PROXY_API_KEY}</string>
    <key>OPENAI_MODEL</key><string>${PROXY_MODEL}</string>
    <key>EMBEDDING_PROVIDER</key><string>local</string>
    <key>AGENTMEMORY_AUTO_COMPRESS</key><string>true</string>
    <key>CONSOLIDATION_ENABLED</key><string>true</string>
    <key>GRAPH_EXTRACTION_ENABLED</key><string>true</string>
    <key>AGENTMEMORY_INJECT_CONTEXT</key><string>true</string>
  </dict>
  <key>WorkingDirectory</key><string>${HOME}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>${log}</string>
  <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
PLIST

  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"

  ok "LaunchAgent registered: ${label}"
  ok "Plist : ${plist}"
  ok "Log   : ${log}"
}

# Windows (Git Bash / MSYS2 / Cygwin): register as Task Scheduler ONLOGON task
register_task_scheduler() {
  local task_name="AgentMemory"
  local log="${PROXY_CONFIG_DIR}/agentmemory.log"

  local win_bin
  if command -v cygpath >/dev/null 2>&1; then
    win_bin="$(cygpath -w "$AGENTMEMORY_BIN")"
    if [[ "$win_bin" != *.cmd && "$win_bin" != *.exe ]]; then
      win_bin="${win_bin}.cmd"
    fi
  else
    win_bin="$AGENTMEMORY_BIN"
  fi

  local bat="${PROXY_CONFIG_DIR}/agentmemory-startup.bat"
  local win_bat
  win_bat="$(cygpath -w "$bat" 2>/dev/null || echo "$bat")"
  mkdir -p "$PROXY_CONFIG_DIR"

  cat > "$bat" <<BAT
@echo off
set AGENTMEMORY_URL=${AGENTMEMORY_URL_VAL}
set OPENAI_BASE_URL=${PROXY_BASE_URL}
set OPENAI_API_KEY=${PROXY_API_KEY}
set OPENAI_MODEL=${PROXY_MODEL}
set EMBEDDING_PROVIDER=local
set AGENTMEMORY_AUTO_COMPRESS=true
set CONSOLIDATION_ENABLED=true
set GRAPH_EXTRACTION_ENABLED=true
set AGENTMEMORY_INJECT_CONTEXT=true
"${win_bin}" >> "${log}" 2>&1
BAT
  # Ensure CRLF line endings for Windows batch
  if command -v unix2dos >/dev/null 2>&1; then unix2dos "$bat" >/dev/null 2>&1 || true; fi

  schtasks.exe /Delete /TN "$task_name" /F 2>/dev/null || true
  schtasks.exe /Create /F \
    /TN  "$task_name" \
    /SC  ONLOGON \
    /TR  "cmd.exe /c \"${win_bat}\"" \
    /RL  HIGHEST

  schtasks.exe /Run /TN "$task_name" 2>/dev/null || true

  ok "Task Scheduler registered: ${task_name}"
  ok "Launcher : ${bat}"
  ok "Log      : ${log}"
}

setup_agentmemory_startup() {
  if [[ "$SKIP_AGENTMEMORY_STARTUP" == "true" ]]; then
    warn "Skipping agentmemory startup registration (--skip-agentmemory-startup)"
    return 0
  fi

  step "Register agentmemory server as startup service"

  find_agentmemory_bin || return 0

  case "$OS" in
    mac) register_launchagent ;;
    win) register_task_scheduler ;;
    *)
      warn "OS '${OS}' not supported for auto-start registration"
      warn "Start agentmemory manually: agentmemory"
      return 0
      ;;
  esac

  # If the daemon was already running before we updated the env, kill it so
  # the startup service restarts it with the new variables.
  if agentmemory_healthy; then
    info "Restarting agentmemory daemon to pick up new env vars..."
    case "$OS" in
      mac)
        pkill -f "node.*agentmemory" 2>/dev/null || true
        ;;
      win)
        taskkill.exe //F //IM node.exe //FI "WINDOWTITLE eq agentmemory*" 2>/dev/null || true
        schtasks.exe /Run /TN "AgentMemory" 2>/dev/null || true
        ;;
    esac
    sleep 2
  fi

  info "Waiting for agentmemory server on :3111..."
  for _ in {1..15}; do
    if agentmemory_healthy; then
      ok "agentmemory healthy: http://localhost:3111/agentmemory/health"
      return 0
    fi
    sleep 1
  done
  warn "agentmemory did not respond within 15s — check ${PROXY_CONFIG_DIR}/agentmemory.log"
}

write_proxy_env() {
  step "Write agy proxy config"
  mkdir -p "$PROXY_CONFIG_DIR"
  cat > "$PROXY_ENV_FILE" <<EOF
# Managed by ag-agentmemory setup.sh
AGY_PROXY_HOST=${AGY_HOST}
AGY_PROXY_PORT=${AGY_PORT}
AGY_CLI_BIN=${AGY_BIN}
AGY_CLI_TIMEOUT_MS=${AGY_TIMEOUT_MS}
AGY_CLI_SANDBOX=${AGY_SANDBOX}
EOF
  ok "Updated $PROXY_ENV_FILE"
}

build_proxy() {
  if [[ "$SKIP_BUILD" == "true" ]]; then
    warn "Skipping build (--skip-build)"
    return 0
  fi

  step "Build agy proxy"
  cd "$SCRIPT_DIR"
  npm install
  npm run build
  ok "Built dist/cli.js"
}

proxy_healthy() {
  node -e "fetch('http://${AGY_HOST}:${AGY_PORT}/health').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
}

start_proxy() {
  step "Start agy OpenAI-compatible proxy"
  mkdir -p "$PROXY_CONFIG_DIR"

  [[ -f "${SCRIPT_DIR}/dist/cli.js" ]] || err "dist/cli.js not found; run without --skip-build"

  if proxy_healthy; then
    ok "Proxy already healthy: http://${AGY_HOST}:${AGY_PORT}"
    return 0
  fi

  export AGY_CLI_BIN="$AGY_BIN"
  export AGY_CLI_TIMEOUT_MS="$AGY_TIMEOUT_MS"
  export AGY_CLI_SANDBOX="$AGY_SANDBOX"

  local log_file="${PROXY_CONFIG_DIR}/agy-proxy.log"
  local pid
  pid="$(node - "$log_file" "$SCRIPT_DIR/dist/cli.js" "$AGY_HOST" "$AGY_PORT" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const [logFile, cliPath, host, port] = process.argv.slice(2);
fs.mkdirSync(path.dirname(logFile), { recursive: true });
const out = fs.openSync(logFile, 'a');
const child = spawn(process.execPath, [cliPath, 'agy-proxy', '--host', host, '--port', port], {
  detached: true,
  stdio: ['ignore', out, out],
  env: process.env,
});
child.unref();
console.log(child.pid);
NODE
)"
  [[ -n "$pid" ]] || err "Failed to spawn proxy process; check ${log_file}"
  info "Started proxy process ${pid}"

  for _ in {1..15}; do
    if proxy_healthy; then
      ok "Proxy healthy: http://${AGY_HOST}:${AGY_PORT}"
      return 0
    fi
    sleep 1
  done

  err "Proxy did not become healthy. Check ${log_file}"
}

run_proxy() {
  require_command node
  require_command npm
  [[ -x "$AGY_BIN" ]] || err "agy binary not executable: $AGY_BIN"

  build_proxy
  write_proxy_env
  start_proxy
  setup_agentmemory_startup
}

# ─── main ─────────────────────────────────────────────────────────────────────

main() {
  echo -e "${BOLD}ag-agentmemory setup${NC}  (client=${CLIENT}${FORCE:+ force})"

  setup_env

  if has_client claude-code; then install_claude_code; fi
  if has_client codex;       then install_codex;       fi
  if has_client antigravity; then install_antigravity; fi

  if [[ "$SKIP_PROXY" == "true" ]]; then
    warn "--skip-proxy: skipping agy proxy + agentmemory startup registration"
  else
    run_proxy
  fi

  echo ""
  ok "All done."
  echo ""
  echo "  Proxy       : http://${AGY_HOST}:${AGY_PORT}"
  echo "  Proxy log   : ${PROXY_CONFIG_DIR}/agy-proxy.log"
  echo "  Memory log  : ${PROXY_CONFIG_DIR}/agentmemory.log"
  echo ""
  echo "  Restart Claude Code / Codex / Antigravity to pick up MCP and hooks."
  if has_client codex; then
    echo ""
    echo -e "  ${YELLOW}Codex hooks:${NC} open Codex TUI once and accept the 6 agentmemory hook prompts."
  fi
}

main "$@"
