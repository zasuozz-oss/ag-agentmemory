#!/usr/bin/env bash
# ag-agentmemory setup script
# Configures AgentMemory for Antigravity, Codex CLI, and Claude Code.

set -euo pipefail

CLIENT="all"
SKIP_UPSTREAM=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --client=*) CLIENT="${1#*=}"; shift ;;
    --client) CLIENT="${2:-all}"; shift 2 ;;
    --skip-upstream) SKIP_UPSTREAM=true; shift ;;
    antigravity|codex|claude-code|all) CLIENT="$1"; shift ;;
    *) warn "Bỏ qua argument không hỗ trợ: $1"; shift ;;
  esac
done

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
step() { echo -e "\n${BOLD}▶ $*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_prereqs() {
  step "Kiểm tra prerequisites"
  command -v node >/dev/null 2>&1 || err "Node.js >= 20 required. Tải: https://nodejs.org"
  command -v npm >/dev/null 2>&1 || err "npm required"
  command -v npx >/dev/null 2>&1 || err "npx required"

  node -e "process.exit(parseInt(process.versions.node) < 20 ? 1 : 0)" || \
    err "Node.js >= 20 required (hiện tại: $(node --version))"

  ok "Node.js $(node --version), npm $(npm --version), npx available"
}

build_cli() {
  step "Build ag-agentmemory CLI"
  cd "$SCRIPT_DIR"
  npm install
  npm run build
  ok "CLI built: dist/cli.js"
}

run_setup() {
  step "Cấu hình AgentMemory (${CLIENT})"
  cd "$SCRIPT_DIR"
  local args=(dist/cli.js setup --client "$CLIENT")
  if [[ "$SKIP_UPSTREAM" == "true" ]]; then
    args+=(--skip-upstream)
  fi
  node "${args[@]}"
}

verify_setup() {
  step "Xác minh setup"
  cd "$SCRIPT_DIR"
  if node dist/cli.js verify; then
    ok "Verification passed"
  else
    warn "Verification reported missing optional pieces. Xem output phía trên."
  fi
}

main() {
  echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║      ag-agentmemory Setup Script     ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"

  check_prereqs
  build_cli
  run_setup
  verify_setup

  echo ""
  echo -e "${GREEN}${BOLD}✓ Setup hoàn tất.${NC}"
  echo -e "  Client       : ${CLIENT}"
  echo -e "  Env          : ~/.agentmemory/.env"
  echo -e "  Upstream     : ${SCRIPT_DIR}/agentmemory ${CYAN}(no .git)${NC}"
  echo -e "  Embeddings   : local all-MiniLM-L6-v2"
  echo -e "  Start server : ${CYAN}npx -y @agentmemory/agentmemory@latest${NC}"
  echo -e "  Viewer       : ${CYAN}http://localhost:3113${NC}"
}

main "$@"
