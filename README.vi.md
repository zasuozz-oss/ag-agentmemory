# ag-agentmemmory-proxy

[README](README.md) | [Tiếng Việt](README.vi.md)

`ag-agentmemmory-proxy` cung cấp một proxy cục bộ tương thích OpenAI cho `agy-cli`. Proxy chạy trên máy local, nhận request dạng OpenAI chat completions, rồi chuyển prompt sang `agy` CLI đã đăng nhập.

Nguồn AgentMemory upstream: https://github.com/rohitg00/agentmemory

## Tổng Quan Setup

1. Cài AgentMemory global.
2. Cài plugin cho Claude Code (hooks tự động).
3. Cài plugin cho Codex CLI và trust hooks.
4. Chạy `bash setup.sh` — tự động build proxy, đăng ký agentmemory chạy lúc login, và start mọi thứ.
5. Trỏ AgentMemory upstream về endpoint proxy nếu muốn dùng `agy-cli` làm LLM provider.

## 1. Cài AgentMemory

> **macOS + Homebrew node**: npm global yêu cầu sudo vì Homebrew quản lý thư mục `node_modules`.

```bash
sudo npm install -g @agentmemory/agentmemory
```

Kiểm tra:

```bash
agentmemory status
curl -fsSL http://localhost:3111/agentmemory/health
```

Viewer: `http://localhost:3113`

Lệnh hữu ích:

```bash
agentmemory doctor   # chẩn đoán + tự sửa
agentmemory stop
agentmemory status
```

## 2. Setup Claude Code (Plugin + 12 Hooks)

Claude Code plugin tự động wire **12 hooks**: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
PostToolUseFailure, PreCompact, SubagentStart, SubagentStop, Notification, TaskCompleted, Stop, SessionEnd.

Trong Claude Code, chạy hai lệnh:

```text
/plugin marketplace add rohitg00/agentmemory
/plugin install agentmemory
```

Restart Claude Code sau khi cài. Hooks kích hoạt ngay, không cần thao tác thêm.

## 3. Setup Codex CLI (Plugin + 6 Hooks)

Codex plugin wire **6 hooks**: session_start, user_prompt_submit, pre_tool_use, post_tool_use,
pre_compact, stop.

**Bước 1** — Cài plugin từ terminal:

```bash
codex plugin marketplace add rohitg00/agentmemory
codex plugin add agentmemory@agentmemory
```

**Bước 2** — Trust hooks trong Codex TUI (bắt buộc):

```bash
codex
```

Khi Codex hiển thị `"Trust this hook?"` cho từng hook, chọn **Yes / Always trust**.
Phải accept đủ cả 6 hook. Sau khi trust xong, `~/.codex/config.toml` sẽ có 6 entry:

```toml
[hooks.state."agentmemory@agentmemory:hooks/hooks.codex.json:session_start:0:0"]
trusted_hash = "sha256:..."
# ... (6 entries tổng cộng)
```

Kiểm tra:

```bash
grep "hooks.state.*agentmemory" ~/.codex/config.toml | wc -l
# phải trả về 6
```

> **Lưu ý**: Nếu plugin bị gỡ và cài lại, `trusted_hash` bị xóa — phải mở Codex TUI và trust lại.

## 4. Setup Proxy + Khởi Động Tự Động

`setup.sh` thực hiện toàn bộ một lần:

- Build proxy (`npm install` + `npm run build`)
- Ghi config vào `~/.ag-agentmemmory-proxy/proxy.env`
- Start agy proxy trên `127.0.0.1:3129`
- **Đăng ký agentmemory server chạy tự động lúc login**:
  - **macOS**: tạo LaunchAgent `com.agentmemory` (KeepAlive, tự restart nếu crash)
  - **Windows** (Git Bash / MSYS2): tạo Task Scheduler task `AgentMemory` (ONLOGON)

```bash
bash setup.sh
```

Tùy chọn:

```bash
bash setup.sh --skip-build                         # bỏ qua npm install/build
bash setup.sh --skip-agentmemory-startup           # không đăng ký auto-start
bash setup.sh --agentmemory-bin /path/to/binary    # chỉ định binary thủ công
bash setup.sh --agy-bin /path/to/agy-clean-wrapper.sh
bash setup.sh --host 127.0.0.1 --port 3129
bash setup.sh --timeout-ms 120000
bash setup.sh --sandbox
```

Files được tạo:

```text
~/.ag-agentmemmory-proxy/proxy.env          # config proxy
~/.ag-agentmemmory-proxy/agy-proxy.log      # log agy proxy
~/.ag-agentmemmory-proxy/agentmemory.log    # log agentmemory server
~/Library/LaunchAgents/com.agentmemory.plist  # macOS startup (tự tạo)
```

### macOS — Quản lý LaunchAgent thủ công

```bash
# Dừng
launchctl unload ~/Library/LaunchAgents/com.agentmemory.plist

# Khởi động lại
launchctl load ~/Library/LaunchAgents/com.agentmemory.plist

# Xem log
tail -f ~/.ag-agentmemmory-proxy/agentmemory.log
```

### Windows — Quản lý Task Scheduler thủ công

```bash
# Dừng
schtasks.exe /End /TN AgentMemory

# Khởi động lại
schtasks.exe /Run /TN AgentMemory

# Xóa
schtasks.exe /Delete /TN AgentMemory /F
```

### LaunchAgent cho agy proxy (macOS)

Để agy proxy cũng chạy tự động khi login:

```bash
bash set-run.sh
```

## 5. Trỏ AgentMemory Về Proxy

Sau khi proxy chạy, cấu hình AgentMemory upstream dùng endpoint local làm LLM provider:

```env
OPENAI_BASE_URL=http://127.0.0.1:3129
OPENAI_MODEL=agy-cli
```

Restart AgentMemory:

```bash
agentmemory stop
agentmemory
```

## CLI Proxy

```bash
npm run build
node dist/cli.js agy-proxy --host 127.0.0.1 --port 3129
node dist/cli.js status
node dist/cli.js verify
```

## Config Proxy

```env
AGY_PROXY_HOST=127.0.0.1
AGY_PROXY_PORT=3129
AGY_CLI_BIN=/path/to/ag-agentmemmory-proxy/agy-clean-wrapper.sh
AGY_CLI_TIMEOUT_MS=120000
AGY_CLI_SANDBOX=false
```

## Health Check

```bash
# agentmemory server
curl -fsSL http://localhost:3111/agentmemory/health

# agy proxy
curl -fsSL http://127.0.0.1:3129/health
# {"ok":true,"service":"agy-proxy"}
```

## Gỡ Cài Đặt Hoàn Toàn

```bash
# Xóa agentmemory
agentmemory remove
rm -rf ~/.agentmemory
sudo rm -rf /opt/homebrew/lib/node_modules/@agentmemory  # macOS

# Xóa LaunchAgent (macOS)
launchctl unload ~/Library/LaunchAgents/com.agentmemory.plist
rm ~/Library/LaunchAgents/com.agentmemory.plist

# Xóa Task Scheduler (Windows)
schtasks.exe /Delete /TN AgentMemory /F

# Codex plugin
codex plugin remove agentmemory@agentmemory
codex plugin marketplace remove agentmemory

# Claude Code (trong Claude Code)
/plugin uninstall agentmemory
```
