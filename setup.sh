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

# Windows-only: the bash cleanup wrapper can't be spawned by node, so a scheduled
# task prunes the throwaway brain/conversation entries the proxy's agy calls
# leave behind. Age-based so it never touches an in-flight or recent entry
# (proxy calls finish within AGY_TIMEOUT_MS, default 120s).
AGY_BRAIN_TTL_MIN="30"            # delete entries idle longer than this
AGY_BRAIN_CLEANUP_EVERY_MIN="15"  # how often the scheduled task runs

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

# Antigravity/Gemini and Codex read their config from the HOME-rooted dotdirs on
# every platform (~/.gemini, ~/.codex) — including the Windows builds, which use
# the MSYS/Git-Bash $HOME (C:\Users\<user>). Do NOT redirect these to %APPDATA%.
GEMINI_BASE="${HOME}/.gemini"
CODEX_CONFIG="${HOME}/.codex/config.toml"

# On Windows, node's child_process.spawn cannot execute the bash cleanup wrapper
# (a .sh file), and lsof-based concurrent cleanup is unavailable anyway. So when
# the user did not override --agy-bin, point the proxy straight at the real agy
# executable. AGY_BIN_WIN holds a native Windows path for env handed to schtasks.
AGY_BIN_WIN=""
if [[ "$OS" == "win" && "$AGY_BIN" == "${SCRIPT_DIR}/agy-clean-wrapper.sh" ]]; then
  for c in \
    "$(command -v agy 2>/dev/null || true)" \
    "${LOCALAPPDATA:-${HOME}/AppData/Local}/agy/bin/agy.exe" \
    "${HOME}/AppData/Local/agy/bin/agy.exe"; do
    if [[ -n "$c" && -x "$c" ]]; then AGY_BIN="$c"; break; fi
  done
  if [[ "$AGY_BIN" == "${SCRIPT_DIR}/agy-clean-wrapper.sh" ]]; then
    warn "Windows: could not locate agy.exe — pass --agy-bin <path-to-agy.exe>"
  else
    warn "Windows: using agy binary directly (bash cleanup wrapper is not spawnable by node): $AGY_BIN"
  fi
fi
if [[ "$OS" == "win" ]]; then
  AGY_BIN_WIN="$(cygpath -w "$AGY_BIN" 2>/dev/null || echo "$AGY_BIN")"
fi

# Under MSYS/Git-Bash, schtasks's "/Create", "/TN", "/SC"… switches get mangled
# into paths (e.g. /Create → C:/Program Files/Git/Create), so every schtasks
# call must run with MSYS path conversion disabled. (taskkill uses //FLAG form.)
schtasks_win() { MSYS_NO_PATHCONV=1 schtasks.exe "$@"; }

# Non-admin logon persistence. Task Scheduler /SC ONLOGON needs elevation on
# locked-down Windows ("Access is denied"), so when that fails we drop a hidden
# VBS launcher into the user's Startup folder instead — it runs at every logon
# with no admin rights and no visible console window.
# Args: <name> <win_bat>  (win_bat = native Windows path to the .bat)
install_startup_folder_launcher() {
  local name="$1" win_bat="$2"
  local sdir
  sdir="$(cygpath -u "${APPDATA}" 2>/dev/null || echo "${APPDATA}")/Microsoft/Windows/Start Menu/Programs/Startup"
  mkdir -p "$sdir"
  local vbs="${sdir}/${name}.vbs"
  cat > "$vbs" <<VBS
Set s = CreateObject("WScript.Shell")
s.Run "cmd /c ""${win_bat}""", 0, False
VBS
  command -v unix2dos >/dev/null 2>&1 && unix2dos "$vbs" >/dev/null 2>&1 || true
  ok "Startup launcher: ${vbs}"
}

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
  upsert_env_var "AGENTMEMORY_REFLECT"       "true"                 "$env_file"
  upsert_env_var "TOKEN_BUDGET"              "2000"                 "$env_file"
  # Raise LLM call timeout above default 60s so compress requests survive
  # the agy-cli proxy peak latency without tripping the provider circuit breaker.
  upsert_env_var "AGENTMEMORY_LLM_TIMEOUT_MS" "120000"              "$env_file"

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

  # macOS GUI apps (Claude Code Desktop, Spotlight-launched Codex) don't read
  # ~/.zshrc — they inherit env from the launchd user domain. Push the vars into
  # launchctl for the current session, and register a LaunchAgent so they
  # persist across reboots.
  if [[ "${OSTYPE:-}" == darwin* ]] && command -v launchctl >/dev/null 2>&1; then
    launchctl setenv AGENTMEMORY_URL            "$AGENTMEMORY_URL_VAL" || true
    launchctl setenv OPENAI_BASE_URL            "$PROXY_BASE_URL"      || true
    launchctl setenv OPENAI_API_KEY             "$PROXY_API_KEY"       || true
    launchctl setenv OPENAI_MODEL               "$PROXY_MODEL"         || true
    launchctl setenv AGENTMEMORY_AUTO_COMPRESS  "true"                 || true
    launchctl setenv GRAPH_EXTRACTION_ENABLED   "true"                 || true
    launchctl setenv AGENTMEMORY_INJECT_CONTEXT "true"                 || true
    launchctl setenv AGENTMEMORY_REFLECT        "true"                 || true
    launchctl setenv CONSOLIDATION_ENABLED      "true"                 || true
    launchctl setenv TOKEN_BUDGET               "2000"                 || true
    launchctl setenv AGENTMEMORY_LLM_TIMEOUT_MS "120000"               || true
    ok "launchctl setenv populated for current GUI session"

    local setenv_label="com.agentmemory.setenv"
    local setenv_plist="${HOME}/Library/LaunchAgents/${setenv_label}.plist"
    mkdir -p "${HOME}/Library/LaunchAgents"
    cat > "$setenv_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${setenv_label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>/bin/launchctl setenv AGENTMEMORY_URL ${AGENTMEMORY_URL_VAL}; /bin/launchctl setenv OPENAI_BASE_URL ${PROXY_BASE_URL}; /bin/launchctl setenv OPENAI_API_KEY ${PROXY_API_KEY}; /bin/launchctl setenv OPENAI_MODEL ${PROXY_MODEL}; /bin/launchctl setenv AGENTMEMORY_AUTO_COMPRESS true; /bin/launchctl setenv GRAPH_EXTRACTION_ENABLED true; /bin/launchctl setenv AGENTMEMORY_INJECT_CONTEXT true; /bin/launchctl setenv AGENTMEMORY_REFLECT true; /bin/launchctl setenv CONSOLIDATION_ENABLED true; /bin/launchctl setenv TOKEN_BUDGET 2000; /bin/launchctl setenv AGENTMEMORY_LLM_TIMEOUT_MS 120000; /bin/launchctl setenv TRANSFORMERS_CACHE \${HOME}/.cache/huggingface</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST
    launchctl unload "$setenv_plist" 2>/dev/null || true
    launchctl load   "$setenv_plist"
    ok "Persisted env via LaunchAgent: ${setenv_label}"
  fi
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

  # `agentmemory connect` writes `npx -y @agentmemory/mcp` + AGENTMEMORY_SECRET
  # into the MCP block. On npm 11 / node 25 the npx install hits an "Invalid
  # Version" bug in onnx-proto → protobufjs@6.11.6, so we rewrite the command
  # to call the globally installed `agentmemory mcp` binary directly. The
  # AGENTMEMORY_SECRET env is also unused for the local loopback daemon.
  info "Sanitizing agentmemory MCP entry in ~/.claude.json"
  local agentmemory_bin_path
  agentmemory_bin_path="$(command -v agentmemory || true)"
  node - "$agentmemory_bin_path" <<'NODE' || true
(() => {
  const fs = require('node:fs');
  const bin = process.argv[2] || 'agentmemory';
  const f = `${process.env.HOME}/.claude.json`;
  let c;
  try { c = JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return; }
  const m = c.mcpServers?.agentmemory;
  if (!m) return;
  let changed = false;
  if (m.env && 'AGENTMEMORY_SECRET' in m.env) { delete m.env.AGENTMEMORY_SECRET; changed = true; }
  if (m.env && 'AGENTMEMORY_URL' in m.env && /\$\{?AGENTMEMORY_URL\}?/.test(m.env.AGENTMEMORY_URL)) {
    m.env.AGENTMEMORY_URL = process.env.AGENTMEMORY_URL || 'http://localhost:3111';
    changed = true;
  }
  if (m.command === 'npx') { m.command = bin; m.args = ['mcp']; changed = true; }
  if (changed) fs.writeFileSync(f, JSON.stringify(c, null, 2) + '\n');
})();
NODE

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
  SessionEnd:  [{ hooks: [{ type: "command", command: cmd("session-end") }] }],
};
process.stdout.write(JSON.stringify(config));
NODE
)"
  merge_claude_hooks "$hooks_json"

  install_claude_code_skills
  install_claude_code_instructions

  ok "Claude Code wired with 6 hooks (restart Claude Code to pick up changes)"
}

install_claude_code_instructions() {
  local target="${HOME}/.claude/CLAUDE.md"
  local source="${SCRIPT_DIR}/custom/claude-code/CLAUDE.md"
  info "Instructions → $target (source: $source)"
  [[ -f "$source" ]] || err "Missing instruction source: $source"
  mkdir -p "$(dirname "$target")"
  local content
  content="$(cat "$source")"
  upsert_block "$content" "$target" \
    "<!-- AGENTMEMORY_RULES_START -->" \
    "<!-- AGENTMEMORY_RULES_END -->"
  ok "Claude Code instructions updated in $target"
}

# ─── Phase 3: Codex ───────────────────────────────────────────────────────────

install_codex() {
  step "Codex: MCP + plugin (6 hooks via Codex plugin system)"
  require_command codex

  local plugin_root
  plugin_root="$(agentmemory_plugin_root)" || err "agentmemory plugin not found — install @agentmemory/agentmemory globally"

  info "Wiring agentmemory MCP into Codex"
  agentmemory connect codex ${FORCE} 2>&1 | grep -v "^$" || true

  # Same npx workaround as Claude — rewrite Codex MCP to call the agentmemory
  # binary directly (see Phase 2 for context on the npm 11 / onnx-proto bug).
  local codex_toml="${HOME}/.codex/config.toml"
  local agentmemory_bin_path
  agentmemory_bin_path="$(command -v agentmemory || echo agentmemory)"
  if [[ -f "$codex_toml" ]] && grep -q '^\[mcp_servers.agentmemory\]' "$codex_toml"; then
    info "Sanitizing agentmemory MCP entry in $codex_toml"
    # Done in node (not python3): node is already a hard dependency, whereas on
    # Windows `python3` is usually the Microsoft Store stub that prints "Python
    # was not found" and exits non-zero, silently skipping this rewrite.
    node - "$codex_toml" "$agentmemory_bin_path" <<'NODE' || true
const fs = require('node:fs');
const [target, binp] = process.argv.slice(2);
let text;
try { text = fs.readFileSync(target, 'utf8'); } catch { process.exit(0); }
// Match the [mcp_servers.agentmemory] section up to (but not including) the next
// [section] header or end-of-file. JS has no \Z, so the end anchor is a negative
// lookahead "(?![\s\S])" meaning "no character follows".
const re = /^\[mcp_servers\.agentmemory\][\s\S]*?(?=^\[|(?![\s\S]))/m;
const m = text.match(re);
if (!m) process.exit(0);
let block = m[0]
  .replace(/^command\s*=.*$/m, `command = "${binp}"`)
  .replace(/^args\s*=.*$/m, 'args = ["mcp"]');
// Replace via a function so backslashes / $ in the path are not interpreted.
const next = text.replace(re, () => block);
if (next !== text) fs.writeFileSync(target, next);
NODE
  fi

  # Codex marketplaces require a `.agents/plugins/marketplace.json` listing
  # plugin sub-paths. The agentmemory npm plugin is a single plugin folder,
  # so we wrap it in a synthetic marketplace at ~/.agentmemory-marketplace
  # that symlinks to the real plugin (so npm upgrades flow through).
  local marketplace_name="agentmemory-marketplace"
  local marketplace_root="${HOME}/.${marketplace_name}"
  local marketplace_manifest="${marketplace_root}/.agents/plugins/marketplace.json"
  local marketplace_plugin_link="${marketplace_root}/plugins/agentmemory"

  info "Building Codex marketplace stub at: $marketplace_root"
  mkdir -p "${marketplace_root}/.agents/plugins" "${marketplace_root}/plugins"

  # Symlink (or replace) the plugin folder so upgrades to the npm package
  # are picked up without rerunning setup.sh.
  if [[ -L "$marketplace_plugin_link" || -e "$marketplace_plugin_link" ]]; then
    rm -rf "$marketplace_plugin_link"
  fi
  ln -s "$plugin_root" "$marketplace_plugin_link"

  cat > "$marketplace_manifest" <<JSON
{
  "name": "${marketplace_name}",
  "interface": {
    "displayName": "AgentMemory"
  },
  "plugins": [
    {
      "name": "agentmemory",
      "source": {
        "source": "local",
        "path": "./plugins/agentmemory"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Memory"
    }
  ]
}
JSON

  info "Registering marketplace with Codex"
  # Remove any stale registration so re-runs don't conflict.
  codex plugin marketplace remove "$marketplace_name" >/dev/null 2>&1 || true
  if codex plugin marketplace add "$marketplace_root" 2>&1 | grep -v "^$"; then
    info "Installing agentmemory@${marketplace_name}"
    if codex plugin add "agentmemory@${marketplace_name}" 2>&1 | grep -v "^$"; then
      ok "Codex plugin installed: agentmemory@${marketplace_name}"
    else
      warn "codex plugin add failed — open Codex TUI and run:"
      warn "  codex plugin add agentmemory@${marketplace_name}"
    fi
  else
    warn "codex plugin marketplace add failed. Manual recovery:"
    warn "  codex plugin marketplace add ${marketplace_root}"
    warn "  codex plugin add agentmemory@${marketplace_name}"
  fi

  # Ensure hooks are enabled globally — Codex may default to hooks=false.
  if [[ -f "$CODEX_CONFIG" ]]; then
    if grep -qE '^hooks\s*=\s*false' "$CODEX_CONFIG"; then
      if [[ "$OS" == "mac" ]]; then
        sed -i '' 's/^hooks[[:space:]]*=[[:space:]]*false/hooks = true/' "$CODEX_CONFIG"
      else
        sed -i 's/^hooks[[:space:]]*=[[:space:]]*false/hooks = true/' "$CODEX_CONFIG"
      fi
      ok "Codex config: hooks = false → hooks = true"
    elif ! grep -qE '^hooks\s*=' "$CODEX_CONFIG"; then
      # No hooks key at all — inject under [features] block
      node - "$CODEX_CONFIG" <<'NODE' || true
const fs = require('node:fs');
const target = process.argv[2];
let text = '';
try { text = fs.readFileSync(target, 'utf8'); } catch {}
if (text.includes('[features]')) {
  text = text.replace(/(\[features\][^\[]*?)(\n\[|\s*$)/s, (_, block, after) =>
    block.trimEnd() + '\nhooks = true\n' + after
  );
} else {
  text = text.trimEnd() + '\n\n[features]\nhooks = true\n';
}
fs.writeFileSync(target, text);
NODE
      ok "Codex config: injected hooks = true under [features]"
    fi
  fi

  # Ensure plugin entry exists in config.toml so hooks are loaded without TUI install step.
  if [[ -f "$CODEX_CONFIG" ]] && ! grep -q '"agentmemory@agentmemory-marketplace"' "$CODEX_CONFIG"; then
    node - "$CODEX_CONFIG" <<'NODE' || true
const fs = require('node:fs');
const target = process.argv[2];
let text = '';
try { text = fs.readFileSync(target, 'utf8'); } catch {}
const entry = '\n[plugins."agentmemory@agentmemory-marketplace"]\nenabled = true\n';
// Insert before first [plugins.] block if present, else append.
if (/^\[plugins\./m.test(text)) {
  text = text.replace(/^(\[plugins\.)/m, entry.trimStart() + '\n$1');
} else {
  text = text.trimEnd() + entry;
}
fs.writeFileSync(target, text);
NODE
    ok "Codex config: added [plugins.\"agentmemory@agentmemory-marketplace\"] enabled = true"
  fi

  install_codex_skills
  install_codex_instructions

  ok "Codex MCP wired"
  warn "First TUI launch: Codex will prompt to trust the agentmemory plugin + its 6 hooks — accept all."
}

install_codex_instructions() {
  local target="${HOME}/.codex/AGENTS.md"
  local source="${SCRIPT_DIR}/custom/codex/AGENTS.md"
  info "Instructions → $target (source: $source)"
  [[ -f "$source" ]] || err "Missing instruction source: $source"
  mkdir -p "$(dirname "$target")"
  local content
  content="$(cat "$source")"
  upsert_block "$content" "$target" \
    "<!-- AGENTMEMORY_RULES_START -->" \
    "<!-- AGENTMEMORY_RULES_END -->"
  ok "Codex instructions updated in $target"
}

# ─── Phase 4: Antigravity ─────────────────────────────────────────────────────

install_antigravity_mcp() {
  local agentmemory_bin_path
  agentmemory_bin_path="$(command -v agentmemory || echo agentmemory)"

  # Antigravity has moved its MCP config location across versions. Newer builds
  # read ~/.gemini/config/mcp_config.json (see the ~/.gemini/config/.migrated
  # marker); older ones used ~/.gemini/antigravity/mcp_config.json and the Gemini
  # global settings.json mcpServers block. Always write the new canonical path;
  # sync the legacy ones only if they already exist (so post-migration installs
  # don't sprout stray config files), keeping entries from shadowing each other.
  local canonical="${GEMINI_BASE}/config/mcp_config.json"
  local legacy=(
    "${GEMINI_BASE}/antigravity/mcp_config.json"
    "${GEMINI_BASE}/settings.json"
  )
  local targets=("$canonical")
  local t
  for t in "${legacy[@]}"; do
    [[ -f "$t" ]] && targets+=("$t")
  done
  local target
  for target in "${targets[@]}"; do
    info "MCP config → $target"
    upsert_json_mcp "$target" "agentmemory" "$agentmemory_bin_path" \
      '["mcp"]' \
      "{\"AGENTMEMORY_URL\":\"${AGENTMEMORY_URL_VAL}\",\"EMBEDDING_PROVIDER\":\"local\"}"
  done
  ok "Antigravity MCP configs updated"
}

install_antigravity_instructions() {
  local target="${GEMINI_BASE}/GEMINI.md"
  local source="${SCRIPT_DIR}/custom/antigravity/GEMINI.md"
  info "Instructions → $target (source: $source)"
  [[ -f "$source" ]] || err "Missing instruction source: $source"
  local content
  content="$(cat "$source")"
  upsert_block "$content" "$target" \
    "<!-- AGENTMEMORY_RULES_START -->" \
    "<!-- AGENTMEMORY_RULES_END -->"
  ok "Antigravity instructions updated in $target"
}

copy_skills() {
  local source="$1" target="$2" label="$3"
  info "Skills → $target (source: $source)"
  [[ -d "$source" ]] || err "Missing skills source dir: $source"
  mkdir -p "$target"
  local skill_path skill_name
  for skill_path in "$source"/*/; do
    [[ -d "$skill_path" ]] || continue
    skill_name="$(basename "$skill_path")"
    mkdir -p "$target/$skill_name"
    cp -f "$skill_path"/* "$target/$skill_name/"
  done
  ok "${label} skills copied to $target"
}

install_antigravity_skills() {
  # Newer Antigravity reads skills from ~/.gemini/config/skills (post-migration,
  # marked by ~/.gemini/config/.migrated); older builds used
  # ~/.gemini/antigravity/skills. Write the new canonical path, and keep the
  # legacy one in sync only if it still exists (don't create stray dirs).
  copy_skills "${SCRIPT_DIR}/custom/skills" "${GEMINI_BASE}/config/skills" "Antigravity"
  if [[ -d "${GEMINI_BASE}/antigravity/skills" ]]; then
    copy_skills "${SCRIPT_DIR}/custom/skills" "${GEMINI_BASE}/antigravity/skills" "Antigravity (legacy)"
  fi
}

install_claude_code_skills() {
  copy_skills "${SCRIPT_DIR}/custom/skills" "${HOME}/.claude/skills" "Claude Code"
}

install_codex_skills() {
  copy_skills "${SCRIPT_DIR}/custom/skills" "${HOME}/.codex/skills" "Codex"
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
    <key>AGENTMEMORY_DROP_STALE_INDEX</key><string>true</string>
    <key>AGENTMEMORY_REFLECT</key><string>true</string>
    <key>TOKEN_BUDGET</key><string>2000</string>
    <key>AGENTMEMORY_LLM_TIMEOUT_MS</key><string>120000</string>
    <key>TRANSFORMERS_CACHE</key><string>\${HOME}/.cache/huggingface</string>
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
  # cmd.exe runs the .bat and can't redirect to an MSYS path (/c/Users/...), so
  # the in-.bat log target must be a native Windows path.
  local win_log
  win_log="$(cygpath -w "$log" 2>/dev/null || echo "$log")"

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
set PATH=%USERPROFILE%\.local\bin;%PATH%
set AGENTMEMORY_URL=${AGENTMEMORY_URL_VAL}
set OPENAI_BASE_URL=${PROXY_BASE_URL}
set OPENAI_API_KEY=${PROXY_API_KEY}
set OPENAI_MODEL=${PROXY_MODEL}
set EMBEDDING_PROVIDER=local
set AGENTMEMORY_AUTO_COMPRESS=true
set CONSOLIDATION_ENABLED=true
set GRAPH_EXTRACTION_ENABLED=true
set AGENTMEMORY_INJECT_CONTEXT=true
set AGENTMEMORY_REFLECT=true
set TOKEN_BUDGET=2000
set AGENTMEMORY_LLM_TIMEOUT_MS=120000
set AGENTMEMORY_DROP_STALE_INDEX=true
"${win_bin}" >> "${win_log}" 2>&1
BAT
  # Ensure CRLF line endings for Windows batch
  if command -v unix2dos >/dev/null 2>&1; then unix2dos "$bat" >/dev/null 2>&1 || true; fi

  schtasks_win /Delete /TN "$task_name" /F 2>/dev/null || true
  # /RL HIGHEST needs an elevated shell; try it first, then fall back to a
  # normal-privilege task. Never let a failure abort the script (set -e): a
  # missing startup task is a warning, not fatal — the daemon can be started by
  # hand. (Original code left /Create unguarded, so a non-admin run died here.)
  if ! schtasks_win /Create /F /TN "$task_name" /SC ONLOGON /TR "cmd.exe /c \"${win_bat}\"" /RL HIGHEST 2>/dev/null \
     && ! schtasks_win /Create /F /TN "$task_name" /SC ONLOGON /TR "cmd.exe /c \"${win_bat}\"" 2>/dev/null; then
    warn "Task Scheduler ONLOGON needs elevation; using Startup folder for logon persistence."
    install_startup_folder_launcher "AgentMemory" "$win_bat"
    return 0
  fi

  schtasks_win /Run /TN "$task_name" 2>/dev/null || true

  ok "Task Scheduler registered: ${task_name}"
  ok "Launcher : ${bat}"
  ok "Log      : ${log}"
}

# Windows: agentmemory needs the native iii-engine binary, which it cannot
# auto-install (the GitHub release ships as a .zip, not a tarball). Fetch it once
# into ~/.local/bin so the daemon (:3111) can start. Pinned to the version the
# current agentmemory build expects.
III_VERSION="v0.11.2"
ensure_iii_engine() {
  local iii_dir="${HOME}/.local/bin"
  if [[ -x "${iii_dir}/iii.exe" ]] || command -v iii >/dev/null 2>&1; then
    info "iii-engine present: $(command -v iii 2>/dev/null || echo "${iii_dir}/iii.exe")"
    return 0
  fi
  info "Installing iii-engine ${III_VERSION} (required by agentmemory) into ${iii_dir}"
  mkdir -p "$iii_dir"
  local win_dir
  win_dir="$(cygpath -w "$iii_dir" 2>/dev/null || echo "$iii_dir")"
  if powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
    \$ErrorActionPreference='Stop';
    \$asset = if (\$env:PROCESSOR_ARCHITECTURE -match 'ARM64') {'iii-aarch64-pc-windows-msvc.zip'} else {'iii-x86_64-pc-windows-msvc.zip'};
    \$url = 'https://github.com/iii-hq/iii/releases/download/iii/${III_VERSION}/' + \$asset;
    \$tmp = Join-Path \$env:TEMP 'iii-dl'; New-Item -ItemType Directory -Force -Path \$tmp | Out-Null;
    \$zip = Join-Path \$tmp \$asset; Invoke-WebRequest -Uri \$url -OutFile \$zip -UseBasicParsing;
    Expand-Archive -Path \$zip -DestinationPath \$tmp -Force;
    \$exe = Get-ChildItem -Path \$tmp -Recurse -Filter 'iii.exe' | Select-Object -First 1;
    Copy-Item \$exe.FullName (Join-Path '${win_dir}' 'iii.exe') -Force;
  " 2>/dev/null; then
    ok "iii-engine installed: ${iii_dir}/iii.exe"
    return 0
  fi
  warn "Could not auto-install iii-engine; agentmemory (:3111) will not start until it is present."
  warn "Manual: download iii ${III_VERSION} (iii-x86_64-pc-windows-msvc.zip) → extract iii.exe to ${iii_dir}"
  return 1
}

# Spawn the agentmemory daemon detached for the current session (Git Bash can run
# the npm shim directly), used when we cannot register/run a scheduled task.
# ~/.local/bin is prepended so the daemon finds the iii-engine binary.
start_agentmemory_now() {
  local log="${PROXY_CONFIG_DIR}/agentmemory.log"
  PATH="${HOME}/.local/bin:$PATH" \
  AGENTMEMORY_URL="$AGENTMEMORY_URL_VAL" \
  OPENAI_BASE_URL="$PROXY_BASE_URL" OPENAI_API_KEY="$PROXY_API_KEY" OPENAI_MODEL="$PROXY_MODEL" \
  EMBEDDING_PROVIDER="local" AGENTMEMORY_AUTO_COMPRESS="true" CONSOLIDATION_ENABLED="true" \
  GRAPH_EXTRACTION_ENABLED="true" AGENTMEMORY_INJECT_CONTEXT="true" AGENTMEMORY_REFLECT="true" \
  TOKEN_BUDGET="2000" AGENTMEMORY_LLM_TIMEOUT_MS="120000" AGENTMEMORY_DROP_STALE_INDEX="true" \
    nohup "$AGENTMEMORY_BIN" >> "$log" 2>&1 &
  disown || true
  info "Started agentmemory (detached) — log: ${log}"
}

setup_agentmemory_startup() {
  if [[ "$SKIP_AGENTMEMORY_STARTUP" == "true" ]]; then
    warn "Skipping agentmemory startup registration (--skip-agentmemory-startup)"
    return 0
  fi

  step "Register agentmemory server as startup service"

  find_agentmemory_bin || return 0

  [[ "$OS" == "win" ]] && ensure_iii_engine || true

  case "$OS" in
    mac) register_launchagent ;;
    win) register_task_scheduler ;;
    *)
      warn "OS '${OS}' not supported for auto-start registration"
      warn "Start agentmemory manually: agentmemory"
      return 0
      ;;
  esac

  case "$OS" in
    mac)
      # launchd (KeepAlive) owns the process. If one was already running, bounce
      # it so launchd respawns it with the new env vars.
      if agentmemory_healthy; then
        info "Restarting agentmemory daemon to pick up new env vars..."
        pkill -f "node.*agentmemory" 2>/dev/null || true
        pkill -f "/.local/bin/iii" 2>/dev/null || true
        sleep 2
      fi
      ;;
    win)
      # No KeepAlive service on non-admin Windows (the Startup launcher only fires
      # at logon), so stop any daemon already on :3111 and start a fresh detached
      # one for this session — picking up the current env and iii-engine.
      local am_pid
      am_pid="$(netstat -ano 2>/dev/null | grep -i 'LISTENING' | grep ':3111 ' | awk '{print $NF}' | head -1 || true)"
      [[ -n "$am_pid" ]] && taskkill.exe //F //PID "$am_pid" 2>/dev/null || true
      start_agentmemory_now
      sleep 2
      ;;
  esac

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
  # On Windows the proxy is launched by cmd.exe/node, which need a native path
  # (C:\...), not the MSYS form (/c/...) that node's spawn cannot resolve.
  local agy_cli_bin="$AGY_BIN"
  [[ "$OS" == "win" && -n "$AGY_BIN_WIN" ]] && agy_cli_bin="$AGY_BIN_WIN"
  cat > "$PROXY_ENV_FILE" <<EOF
# Managed by ag-agentmemory setup.sh
AGY_PROXY_HOST=${AGY_HOST}
AGY_PROXY_PORT=${AGY_PORT}
AGY_CLI_BIN=${agy_cli_bin}
AGY_CLI_TIMEOUT_MS=${AGY_TIMEOUT_MS}
AGY_CLI_SANDBOX=${AGY_SANDBOX}
AGY_PROXY_CONCURRENCY=4
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

register_proxy_launchagent() {
  local label="com.agy.proxy"
  local plist="${HOME}/Library/LaunchAgents/${label}.plist"
  local log_file="${PROXY_CONFIG_DIR}/agy-proxy.log"
  local node_bin
  node_bin="$(command -v node)" || err "node not found in PATH"

  mkdir -p "${HOME}/Library/LaunchAgents" "$PROXY_CONFIG_DIR"

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${node_bin}</string>
    <string>${SCRIPT_DIR}/dist/cli.js</string>
    <string>agy-proxy</string>
    <string>--host</string><string>${AGY_HOST}</string>
    <string>--port</string><string>${AGY_PORT}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin</string>
    <key>AGY_CLI_BIN</key><string>${AGY_BIN}</string>
    <key>AGY_CLI_TIMEOUT_MS</key><string>${AGY_TIMEOUT_MS}</string>
    <key>AGY_CLI_SANDBOX</key><string>${AGY_SANDBOX}</string>
    <key>AGY_PROXY_CONCURRENCY</key><string>4</string>
  </dict>
  <key>WorkingDirectory</key><string>${SCRIPT_DIR}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>${log_file}</string>
  <key>StandardErrorPath</key><string>${log_file}</string>
</dict>
</plist>
PLIST

  launchctl unload "$plist" 2>/dev/null || true
  launchctl load   "$plist"

  ok "LaunchAgent registered: ${label}"
  ok "Plist : ${plist}"
  ok "Log   : ${log_file}"
}

# Windows (Git Bash / MSYS2 / Cygwin): register the proxy as a Task Scheduler
# ONLOGON task so it survives reboots (parity with the mac LaunchAgent).
register_proxy_task_scheduler() {
  local task_name="AgyProxy"
  local log_file="${PROXY_CONFIG_DIR}/agy-proxy.log"
  local node_bin
  node_bin="$(command -v node)" || err "node not found in PATH"
  mkdir -p "$PROXY_CONFIG_DIR"

  local win_node win_cli win_agy win_log bat win_bat
  win_node="$(cygpath -w "$node_bin" 2>/dev/null || echo "$node_bin")"
  win_cli="$(cygpath -w "${SCRIPT_DIR}/dist/cli.js" 2>/dev/null || echo "${SCRIPT_DIR}/dist/cli.js")"
  win_agy="${AGY_BIN_WIN:-$AGY_BIN}"
  win_log="$(cygpath -w "$log_file" 2>/dev/null || echo "$log_file")"
  bat="${PROXY_CONFIG_DIR}/agy-proxy-startup.bat"
  win_bat="$(cygpath -w "$bat" 2>/dev/null || echo "$bat")"

  cat > "$bat" <<BAT
@echo off
set AGY_CLI_BIN=${win_agy}
set AGY_CLI_TIMEOUT_MS=${AGY_TIMEOUT_MS}
set AGY_CLI_SANDBOX=${AGY_SANDBOX}
set AGY_PROXY_CONCURRENCY=4
"${win_node}" "${win_cli}" agy-proxy --host ${AGY_HOST} --port ${AGY_PORT} >> "${win_log}" 2>&1
BAT
  if command -v unix2dos >/dev/null 2>&1; then unix2dos "$bat" >/dev/null 2>&1 || true; fi

  schtasks_win /End    /TN "$task_name" 2>/dev/null || true
  schtasks_win /Delete /TN "$task_name" /F 2>/dev/null || true
  if ! schtasks_win /Create /F /TN "$task_name" /SC ONLOGON /TR "cmd.exe /c \"${win_bat}\"" 2>/dev/null; then
    warn "Task Scheduler ONLOGON needs elevation; using Startup folder + detached spawn."
    install_startup_folder_launcher "AgyProxy" "$win_bat"
    export AGY_CLI_BIN="$AGY_BIN_WIN" AGY_CLI_TIMEOUT_MS="$AGY_TIMEOUT_MS" \
           AGY_CLI_SANDBOX="$AGY_SANDBOX" AGY_PROXY_CONCURRENCY=4
    nohup node "${SCRIPT_DIR}/dist/cli.js" agy-proxy --host "$AGY_HOST" --port "$AGY_PORT" \
      >> "$log_file" 2>&1 &
    disown || true
    return 0
  fi

  schtasks_win /Run /TN "$task_name" 2>/dev/null || true
  ok "Task Scheduler registered: ${task_name}"
  ok "Launcher : ${bat}"
  ok "Log      : ${log_file}"
}

# Windows-only: schedule periodic pruning of stale agy brain/conversation
# entries. The mac/linux path handles this per-call via agy-clean-wrapper.sh;
# on Windows node can't spawn that .sh, so we age-prune on a timer instead.
register_brain_cleanup_task() {
  local task_name="AgyBrainCleanup"
  local log_file="${PROXY_CONFIG_DIR}/agy-brain-cleanup.log"
  local node_bin
  node_bin="$(command -v node)" || err "node not found in PATH"
  mkdir -p "$PROXY_CONFIG_DIR"

  local cjs="${PROXY_CONFIG_DIR}/agy-brain-cleanup.cjs"
  # Surgical-by-age: only remove top-level entries whose mtime is older than the
  # TTL, so a running call (or one a user just resumed) is never touched.
  cat > "$cjs" <<'CJS'
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const ttlMin = Number.parseInt(process.env.AGY_BRAIN_TTL_MIN || '30', 10) || 30;
const cutoff = Date.now() - ttlMin * 60_000;
const base = path.join(os.homedir(), '.gemini', 'antigravity-cli');
let removed = 0;
for (const sub of ['brain', 'conversations']) {
  const dir = path.join(base, sub);
  let entries;
  try { entries = fs.readdirSync(dir); } catch { continue; }
  for (const name of entries) {
    const p = path.join(dir, name);
    let st;
    try { st = fs.statSync(p); } catch { continue; }
    if (st.mtimeMs >= cutoff) continue; // in-flight or recently used — keep
    try { fs.rmSync(p, { recursive: true, force: true }); removed++; } catch {}
  }
}
console.log(`[${new Date().toISOString()}] agy-brain-cleanup: removed ${removed} stale entr${removed === 1 ? 'y' : 'ies'} (ttl ${ttlMin}m)`);
CJS

  local win_node win_cjs win_log bat win_bat
  win_node="$(cygpath -w "$node_bin" 2>/dev/null || echo "$node_bin")"
  win_cjs="$(cygpath -w "$cjs" 2>/dev/null || echo "$cjs")"
  win_log="$(cygpath -w "$log_file" 2>/dev/null || echo "$log_file")"
  bat="${PROXY_CONFIG_DIR}/agy-brain-cleanup.bat"
  win_bat="$(cygpath -w "$bat" 2>/dev/null || echo "$bat")"

  cat > "$bat" <<BAT
@echo off
set AGY_BRAIN_TTL_MIN=${AGY_BRAIN_TTL_MIN}
"${win_node}" "${win_cjs}" >> "${win_log}" 2>&1
BAT
  if command -v unix2dos >/dev/null 2>&1; then unix2dos "$bat" >/dev/null 2>&1 || true; fi

  schtasks_win /Delete /TN "$task_name" /F 2>/dev/null || true
  # /SC MINUTE tasks for the current user do not need elevation.
  if ! schtasks_win /Create /F /TN "$task_name" /SC MINUTE /MO "$AGY_BRAIN_CLEANUP_EVERY_MIN" \
       /TR "cmd.exe /c \"${win_bat}\"" 2>/dev/null; then
    warn "Could not register brain-cleanup task '${task_name}' (admin rights?). Skipping."
    return 0
  fi
  ok "Task Scheduler registered: ${task_name} (every ${AGY_BRAIN_CLEANUP_EVERY_MIN}m, ttl ${AGY_BRAIN_TTL_MIN}m)"
  ok "Cleanup  : ${cjs}"
  ok "Log      : ${log_file}"
}

# Stop any proxy already bound to the proxy port, regardless of how it was
# started, so the freshly registered service can own the port.
stop_running_proxy() {
  case "$OS" in
    win)
      local p
      p="$(netstat -ano 2>/dev/null | grep -i 'LISTENING' | grep ":${AGY_PORT} " | awk '{print $NF}' | head -1 || true)"
      [[ -n "$p" ]] && taskkill.exe //F //PID "$p" 2>/dev/null || true
      ;;
    *)
      if command -v pkill >/dev/null 2>&1; then
        pkill -f "dist/cli.js agy-proxy" 2>/dev/null || true
      fi
      ;;
  esac
}

start_proxy() {
  step "Start agy OpenAI-compatible proxy"
  [[ -f "${SCRIPT_DIR}/dist/cli.js" ]] || err "dist/cli.js not found; run without --skip-build"

  # Free the proxy port from any detached proxy left by older runs.
  stop_running_proxy

  case "$OS" in
    mac)
      register_proxy_launchagent
      ;;
    win)
      register_proxy_task_scheduler
      register_brain_cleanup_task
      ;;
    *)
      warn "OS '${OS}' has no proxy auto-start support; falling back to detached spawn"
      export AGY_CLI_BIN="$AGY_BIN"
      export AGY_CLI_TIMEOUT_MS="$AGY_TIMEOUT_MS"
      export AGY_CLI_SANDBOX="$AGY_SANDBOX"
      export AGY_PROXY_CONCURRENCY=4
      nohup node "${SCRIPT_DIR}/dist/cli.js" agy-proxy --host "$AGY_HOST" --port "$AGY_PORT" \
        >> "${PROXY_CONFIG_DIR}/agy-proxy.log" 2>&1 &
      disown || true
      ;;
  esac

  for _ in {1..15}; do
    if proxy_healthy; then
      ok "Proxy healthy: http://${AGY_HOST}:${AGY_PORT}"
      return 0
    fi
    sleep 1
  done

  err "Proxy did not become healthy. Check ${PROXY_CONFIG_DIR}/agy-proxy.log"
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
  echo "  Dashboard   : http://localhost:3113  (agentmemory viewer)"
  echo "  Proxy log   : ${PROXY_CONFIG_DIR}/agy-proxy.log"
  echo "  Memory log  : ${PROXY_CONFIG_DIR}/agentmemory.log"
  if [[ "$OS" == "win" && "$SKIP_PROXY" != "true" ]]; then
    echo "  Cleanup log : ${PROXY_CONFIG_DIR}/agy-brain-cleanup.log (task: AgyBrainCleanup)"
  fi
  echo ""
  echo "  Restart Claude Code / Codex / Antigravity to pick up MCP and hooks."
  if has_client codex; then
    echo ""
    echo -e "  ${YELLOW}Codex hooks:${NC} open Codex TUI once and accept the 6 agentmemory hook prompts."
  fi
}

main "$@"
