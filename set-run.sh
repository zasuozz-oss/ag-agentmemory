#!/usr/bin/env bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────
AGY_PROXY_LABEL="com.agentmemory.agy-proxy"
AGENTMEMORY_LABEL="com.agentmemory.server"

AGY_PROXY_PLIST="$HOME/Library/LaunchAgents/${AGY_PROXY_LABEL}.plist"
AGENTMEMORY_PLIST="$HOME/Library/LaunchAgents/${AGENTMEMORY_LABEL}.plist"

NODE_BIN="/opt/homebrew/bin/node"
AGY_PROXY_SCRIPT="/Users/zasuo/AI-Tool/ag-agentmemory/dist/cli.js"
AGENTMEMORY_BIN="/opt/homebrew/lib/node_modules/@agentmemory/agentmemory/dist/index.mjs"

LOG_DIR="$HOME/.agentmemory"
AGY_PROXY_LOG="$LOG_DIR/agy-proxy.log"
AGENTMEMORY_LOG="$LOG_DIR/server.log"

WORK_DIR="/Users/zasuo/AI-Tool/ag-agentmemory"
# ──────────────────────────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR"

write_agy_proxy_plist() {
  cat > "$AGY_PROXY_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${AGY_PROXY_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_BIN}</string>
    <string>${AGY_PROXY_SCRIPT}</string>
    <string>agy-proxy</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/Users/zasuo/.local/bin</string>
    <key>AGY_PROXY_PORT</key><string>3129</string>
    <key>AGY_CLI_BIN</key><string>/Users/zasuo/AI-Tool/ag-agentmemory/agy-clean-wrapper.sh</string>
  </dict>
  <key>WorkingDirectory</key><string>${WORK_DIR}</string>
  <key>StandardOutPath</key><string>${AGY_PROXY_LOG}</string>
  <key>StandardErrorPath</key><string>${AGY_PROXY_LOG}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
</dict>
</plist>
PLIST
  echo "  [ok] wrote $AGY_PROXY_PLIST"
}

write_agentmemory_plist() {
  cat > "$AGENTMEMORY_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${AGENTMEMORY_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_BIN}</string>
    <string>${AGENTMEMORY_BIN}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TRANSFORMERS_CACHE</key><string>/Users/zasuo/.cache/xenova-transformers</string>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/Users/zasuo/.local/bin</string>
  </dict>
  <key>WorkingDirectory</key><string>${WORK_DIR}</string>
  <key>StandardOutPath</key><string>${AGENTMEMORY_LOG}</string>
  <key>StandardErrorPath</key><string>${AGENTMEMORY_LOG}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
</dict>
</plist>
PLIST
  echo "  [ok] wrote $AGENTMEMORY_PLIST"
}

stop_service() {
  local label="$1"
  if launchctl list | grep -q "$label" 2>/dev/null; then
    launchctl stop "$label" 2>/dev/null || true
    launchctl unload "$HOME/Library/LaunchAgents/${label}.plist" 2>/dev/null || true
    echo "  [ok] stopped $label"
  fi
}

start_service() {
  local plist="$1"
  local label="$2"
  launchctl load "$plist"
  launchctl start "$label"
  echo "  [ok] started $label"
}

wait_for_port() {
  local port="$1"
  local name="$2"
  local path="${3:-/health}"
  local retries=45
  echo -n "  Waiting for $name (port $port)"
  for i in $(seq 1 $retries); do
    if curl -sf "http://127.0.0.1:${port}${path}" > /dev/null 2>&1; then
      echo " ready"
      return 0
    fi
    echo -n "."
    sleep 1
  done
  echo " timeout (check log)"
  return 1
}

# ─── Main ─────────────────────────────────────────────────────────────────────
echo ""
echo "=== agentmemory + agy-proxy setup ==="
echo ""

echo "[1/4] Writing LaunchAgent plists..."
write_agy_proxy_plist
write_agentmemory_plist

echo ""
echo "[2/4] Stopping existing services..."
stop_service "$AGENTMEMORY_LABEL"
stop_service "$AGY_PROXY_LABEL"
sleep 1

echo ""
echo "[3/4] Starting services..."
start_service "$AGY_PROXY_PLIST" "$AGY_PROXY_LABEL"
sleep 2
start_service "$AGENTMEMORY_PLIST" "$AGENTMEMORY_LABEL"

echo ""
echo "[4/4] Verifying..."
wait_for_port 3129 "agy-proxy" "/health"
wait_for_port 3111 "agentmemory" "/agentmemory/health"

echo ""
echo "=== Done ==="
echo "  agy-proxy  → http://127.0.0.1:3129"
echo "  agentmemory → http://localhost:3111"
echo "  viewer      → http://localhost:3113"
echo "  logs        → $LOG_DIR/"
echo ""
