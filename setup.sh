#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${HOME}/.ag-agentmemmory-proxy"
PROXY_ENV="${CONFIG_DIR}/proxy.env"
AGY_BIN="${SCRIPT_DIR}/agy-clean-wrapper.sh"
AGY_HOST="127.0.0.1"
AGY_PORT="3129"
AGY_TIMEOUT_MS="120000"
AGY_SANDBOX="false"
SKIP_BUILD="false"
SKIP_AGENTMEMORY_STARTUP="false"
AGENTMEMORY_BIN=""

OS="$(uname -s)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}==> $*${NC}"; }

usage() {
  cat <<'USAGE'
Usage: bash setup.sh [options]

Options:
  --agy-bin <path>                 Path to agy wrapper or agy CLI binary
  --host <host>                    Proxy host, default 127.0.0.1
  --port <number>                  Proxy port, default 3129
  --timeout-ms <number>            agy CLI timeout, default 120000
  --sandbox                        Pass --sandbox to agy CLI
  --skip-build                     Do not run npm install/build
  --agentmemory-bin <path>         Path to agentmemory binary (auto-detected if omitted)
  --skip-agentmemory-startup       Do not register agentmemory as a startup service
  -h, --help                       Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agy-bin=*)         AGY_BIN="${1#*=}";            shift ;;
    --agy-bin)           [[ $# -ge 2 ]] || err "--agy-bin requires a value";  AGY_BIN="$2";            shift 2 ;;
    --host=*)            AGY_HOST="${1#*=}";            shift ;;
    --host)              [[ $# -ge 2 ]] || err "--host requires a value";     AGY_HOST="$2";            shift 2 ;;
    --port=*)            AGY_PORT="${1#*=}";            shift ;;
    --port)              [[ $# -ge 2 ]] || err "--port requires a value";     AGY_PORT="$2";            shift 2 ;;
    --timeout-ms=*)      AGY_TIMEOUT_MS="${1#*=}";     shift ;;
    --timeout-ms)        [[ $# -ge 2 ]] || err "--timeout-ms requires a value"; AGY_TIMEOUT_MS="$2";   shift 2 ;;
    --agentmemory-bin=*) AGENTMEMORY_BIN="${1#*=}";   shift ;;
    --agentmemory-bin)   [[ $# -ge 2 ]] || err "--agentmemory-bin requires a value"; AGENTMEMORY_BIN="$2"; shift 2 ;;
    --sandbox)           AGY_SANDBOX="true";           shift ;;
    --skip-build)        SKIP_BUILD="true";            shift ;;
    --skip-agentmemory-startup) SKIP_AGENTMEMORY_STARTUP="true"; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   err "Unsupported argument: $1" ;;
  esac
done

case "$AGY_PORT" in
  ''|*[!0-9]*) err "--port must be a number" ;;
esac
case "$AGY_TIMEOUT_MS" in
  ''|*[!0-9]*) err "--timeout-ms must be a number" ;;
esac

require_command() {
  command -v "$1" >/dev/null 2>&1 || err "$1 not found"
}

# ─── agentmemory server ───────────────────────────────────────────────────────

find_agentmemory_bin() {
  if [[ -n "$AGENTMEMORY_BIN" ]]; then
    [[ -x "$AGENTMEMORY_BIN" ]] || err "--agentmemory-bin not executable: $AGENTMEMORY_BIN"
    return 0
  fi

  # Probe PATH first, then common npm global locations
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
  local log="${CONFIG_DIR}/agentmemory.log"

  mkdir -p "${HOME}/Library/LaunchAgents" "$CONFIG_DIR"

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

  # Reload (unload first if already registered)
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"

  ok "LaunchAgent registered: ${label}"
  ok "Plist : ${plist}"
  ok "Log   : ${log}"
}

# Windows (Git Bash / MSYS2 / Cygwin): register as Task Scheduler ONLOGON task
register_task_scheduler() {
  local task_name="AgentMemory"
  local log="${CONFIG_DIR}/agentmemory.log"

  # Convert agentmemory binary path to Windows format
  local win_bin
  if command -v cygpath >/dev/null 2>&1; then
    win_bin="$(cygpath -w "$AGENTMEMORY_BIN")"
    # npm on Windows installs a .cmd shim; use that if the plain path has no extension
    if [[ "$win_bin" != *.cmd && "$win_bin" != *.exe ]]; then
      win_bin="${win_bin}.cmd"
    fi
  else
    win_bin="$AGENTMEMORY_BIN"
  fi

  local win_log
  win_log="$(cygpath -w "$log" 2>/dev/null || echo "$log")"

  # Write a minimal launcher .bat so the task stays hidden and output is captured
  local bat="${CONFIG_DIR}/agentmemory-startup.bat"
  local win_bat
  win_bat="$(cygpath -w "$bat" 2>/dev/null || echo "$bat")"
  mkdir -p "$CONFIG_DIR"

  printf '@echo off\r\n"%s" >> "%s" 2>&1\r\n' "$win_bin" "$win_log" > "$bat"

  # Remove existing task silently, then create
  schtasks.exe /Delete /TN "$task_name" /F 2>/dev/null || true
  schtasks.exe /Create /F \
    /TN  "$task_name" \
    /SC  ONLOGON \
    /TR  "cmd.exe /c \"${win_bat}\"" \
    /RL  HIGHEST

  # Start immediately (best-effort)
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
    Darwin)
      register_launchagent
      ;;
    MINGW*|MSYS*|CYGWIN*)
      register_task_scheduler
      ;;
    *)
      warn "OS '${OS}' not supported for auto-start registration"
      warn "Start agentmemory manually: agentmemory"
      return 0
      ;;
  esac

  # Wait for agentmemory to become healthy (service started via RunAtLoad / schtasks /Run)
  info "Waiting for agentmemory server on :3111..."
  for _ in {1..15}; do
    if agentmemory_healthy; then
      ok "agentmemory healthy: http://localhost:3111/agentmemory/health"
      return 0
    fi
    sleep 1
  done
  warn "agentmemory did not respond within 15s — check ${CONFIG_DIR}/agentmemory.log"
}

# ─── agy proxy ───────────────────────────────────────────────────────────────

write_proxy_env() {
  step "Write ag-agentmemmory-proxy proxy config"
  mkdir -p "$CONFIG_DIR"
  cat > "$PROXY_ENV" <<EOF
# Managed by ag-agentmemmory-proxy
AGY_PROXY_HOST=${AGY_HOST}
AGY_PROXY_PORT=${AGY_PORT}
AGY_CLI_BIN=${AGY_BIN}
AGY_CLI_TIMEOUT_MS=${AGY_TIMEOUT_MS}
AGY_CLI_SANDBOX=${AGY_SANDBOX}
EOF
  ok "Updated $PROXY_ENV"
}

build_proxy() {
  if [[ "$SKIP_BUILD" == "true" ]]; then
    warn "Skipping build"
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
  mkdir -p "$CONFIG_DIR"

  [[ -f "${SCRIPT_DIR}/dist/cli.js" ]] || err "dist/cli.js not found; run 'npm run build' first (or drop --skip-build)"

  if proxy_healthy; then
    ok "Proxy already healthy: http://${AGY_HOST}:${AGY_PORT}"
    return 0
  fi

  export AGY_CLI_BIN="$AGY_BIN"
  export AGY_CLI_TIMEOUT_MS="$AGY_TIMEOUT_MS"
  export AGY_CLI_SANDBOX="$AGY_SANDBOX"

  local log_file="${CONFIG_DIR}/agy-proxy.log"
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

# ─── main ─────────────────────────────────────────────────────────────────────

main() {
  echo -e "${BOLD}ag-agentmemmory-proxy setup${NC}"

  require_command node
  require_command npm
  [[ -x "$AGY_BIN" ]] || err "agy binary not executable: $AGY_BIN"

  build_proxy
  write_proxy_env
  start_proxy
  setup_agentmemory_startup

  echo ""
  ok "Setup complete"
  echo "  Config      : ${PROXY_ENV}"
  echo "  Proxy       : http://${AGY_HOST}:${AGY_PORT}"
  echo "  Proxy log   : ${CONFIG_DIR}/agy-proxy.log"
  echo "  Memory log  : ${CONFIG_DIR}/agentmemory.log"
}

main "$@"
