# ag-agentmemory

[English](README.md) | [Tiếng Việt](README.vi.md)

Repo gốc AgentMemory: https://github.com/rohitg00/agentmemory

Tự động hóa cài đặt AgentMemory cho Antigravity, Codex CLI và Claude Code trên macOS.

`~/.agentmemory/.env` là nguồn cấu hình duy nhất. Embeddings chạy cục bộ. Các LLM call được định tuyến qua proxy Antigravity CLI đã đăng nhập. Không cần API key.

```env
EMBEDDING_PROVIDER=local
BM25_WEIGHT=0.4
VECTOR_WEIGHT=0.6
AGENTMEMORY_URL=http://localhost:3111
AGENTMEMORY_AUTO_COMPRESS=true
CONSOLIDATION_ENABLED=true
GRAPH_EXTRACTION_ENABLED=true
AGENTMEMORY_DROP_STALE_INDEX=false
OPENAI_BASE_URL=http://127.0.0.1:3129
OPENAI_MODEL=agy-cli
```

## Cài Nhanh

Setup mặc định — dùng proxy Antigravity CLI đã đăng nhập, không cần API key:

```bash
bash setup.sh
```

Chỉ setup một client:

```bash
bash setup.sh --client antigravity
bash setup.sh --client codex
bash setup.sh --client claude
```

Bỏ qua sync upstream để chạy nhanh hơn:

```bash
bash setup.sh --skip-upstream
```

## macOS LaunchAgent (Khởi động tự động)

`set-run.sh` đăng ký hai dịch vụ nền liên tục qua macOS LaunchAgents, giúp cả agy-proxy và AgentMemory server tự động khởi động khi đăng nhập và tự restart khi bị crash:

```bash
bash set-run.sh
```

Các dịch vụ được đăng ký:

| Label | Port | Log |
|---|---|---|
| `com.agentmemory.agy-proxy` | 3129 | `~/.agentmemory/agy-proxy.log` |
| `com.agentmemory.server` | 3111 / 3113 | `~/.agentmemory/server.log` |

Kiểm tra trạng thái:

```bash
launchctl list | grep agentmemory
```

## Agy Local Proxy

`setup.sh` không patch AgentMemory upstream. Script khởi động một proxy OpenAI-compatible cục bộ tại `http://127.0.0.1:3129`, sau đó cấu hình AgentMemory dùng provider `openai` sẵn có để trỏ vào proxy này. Proxy chuyển tiếp mỗi request sang `agy --print-timeout 120s -p "<prompt>"`.

Yêu cầu và giới hạn:

- Cần `agy` CLI đã đăng nhập, mặc định tại `~/.local/bin/agy`.
- `agy-clean-wrapper.sh` loại bỏ mã ANSI và ký tự điều khiển khỏi output của `agy` trước khi chuyển tiếp.
- Mỗi LLM call spawn một tiến trình CLI — chậm hơn API trực tiếp.
- Embeddings vẫn chạy cục bộ.
- Hooks và automation dùng LLM được bật mặc định.

## Upstream Snapshot

Mỗi lần setup chạy, script clone hoặc pull AgentMemory upstream vào:

```text
.agentmemory-upstream/
```

Sau đó sync sang working copy không có git metadata:

```text
agentmemory/
```

Thư mục `agentmemory/` giữ snapshot cục bộ để vẫn đọc được docs, plugin, hooks và scripts ngay cả khi repo upstream bị xóa hoặc mạng lỗi. Nếu pull/clone thất bại nhưng `agentmemory/` đã tồn tại, setup tiếp tục dùng snapshot cũ.

## AgentMemory Server

Sau setup, chạy server thủ công:

```bash
npx -y @agentmemory/agentmemory@latest
```

Giao diện Viewer:

```text
http://localhost:3113
```

Kiểm tra sức khỏe:

```bash
curl -fsSL http://localhost:3111/agentmemory/health
```

Trước khi `setup.sh` restart AgentMemory, script backup runtime state vào:

```text
~/.agentmemory/backups/setup-<timestamp>/
```

Backup bao gồm thư mục `data/` cục bộ (nếu có), `~/.agentmemory/standalone.json`, và file env hiện tại.

## Antigravity

Antigravity chưa có upstream plugin AgentMemory. Repo này tự setup thủ công:

- MCP config: `~/.gemini/antigravity/mcp_config.json`
- Instructions: `~/.gemini/GEMINI.md`
- Skills: `~/.gemini/antigravity/skills/`

Sentinel block ngăn ghi đè nội dung cũ trong `GEMINI.md`:

```text
<!-- AGENTMEMORY_RULES_START -->
...
<!-- AGENTMEMORY_RULES_END -->
```

Chạy lại `setup.sh` sẽ cập nhật block này và copy lại các skill đang hoạt động.

## Codex CLI

Setup ghi MCP fallback configuration vào:

```text
~/.codex/config.toml
```

Setup cũng cố gắng cài upstream AgentMemory plugin và chạy `agentmemory connect codex --with-hooks --force`.

## Claude Code

Setup cố gắng cài upstream Claude Code plugin và connect AgentMemory hooks khi có sẵn cả hai CLI `claude` và `agentmemory`.

## CLI

Sau khi build (`npm run build`):

```bash
node dist/cli.js setup --profile local --client all
node dist/cli.js setup --profile agy-local --agy-bin ~/.local/bin/agy
node dist/cli.js agy-proxy --host 127.0.0.1 --port 3129
node dist/cli.js verify
node dist/cli.js status
```

## Custom Overlay

Ghi đè bất kỳ template nào bằng cách đặt file tương ứng vào:

```text
custom/instructions/
custom/skills/
```

Setup copy template mặc định trước, sau đó overlay file custom của bạn lên trên. Chạy lại `setup.sh` sẽ áp dụng lại overlay.

## Không Làm

- Không fork AgentMemory upstream.
- Không yêu cầu API key cho embeddings.
- Không patch source code AgentMemory upstream.
