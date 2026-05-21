# ag-agentmemory

[English](README.md) | [Tiếng Việt](README.vi.md)

Automation setup AgentMemory cho Antigravity, Codex CLI và Claude Code.

Mặc định cấu hình local embeddings bằng `all-MiniLM-L6-v2` qua AgentMemory local provider:

```env
EMBEDDING_PROVIDER=local
BM25_WEIGHT=0.4
VECTOR_WEIGHT=0.6
AGENTMEMORY_URL=http://localhost:3111
```

## Cài Nhanh

```bash
bash setup.sh
```

Chỉ setup một client:

```bash
bash setup.sh --client antigravity
bash setup.sh --client codex
bash setup.sh --client claude-code
```

Bỏ qua sync upstream nếu muốn chạy nhanh:

```bash
bash setup.sh --skip-upstream
```

## Upstream Snapshot

Mỗi lần setup, script sẽ clone hoặc pull upstream AgentMemory vào cache:

```text
.agentmemory-upstream/
```

Sau đó sync sang working copy không có git metadata:

```text
agentmemory/
```

Thư mục `agentmemory/` giữ snapshot local để vẫn đọc được docs, plugin, hooks và scripts nếu upstream GitHub bị xoá hoặc mạng lỗi. Nếu pull/clone lỗi nhưng `agentmemory/` đã tồn tại, setup vẫn tiếp tục dùng snapshot cũ.

## AgentMemory Server

Sau setup, chạy server:

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

## Antigravity

Antigravity chưa có upstream plugin AgentMemory, nên repo này tự setup:

- MCP: `~/.gemini/antigravity/mcp_config.json`
- Instructions: `~/.gemini/GEMINI.md`
- Skills: `~/.gemini/antigravity/skills/`

Setup dùng sentinel block để không xóa nội dung cũ trong `GEMINI.md`.

## Codex CLI

Codex CLI có upstream plugin AgentMemory. Setup ưu tiên:

```bash
codex plugin marketplace add rohitg00/agentmemory
codex plugin install agentmemory
```

Nếu plugin install không khả dụng, setup fallback sang MCP-only trong:

```text
~/.codex/config.toml
```

Fallback không tự tạo custom hooks.

## Claude Code

Claude Code có upstream plugin mạnh nhất của AgentMemory. Setup thử:

```bash
agentmemory connect claude-code
```

Nếu không chạy được non-interactive, dùng thủ công trong Claude Code:

```text
/plugin marketplace add rohitg00/agentmemory
/plugin install agentmemory
```

## CLI

Sau khi build:

```bash
node dist/cli.js setup --client all
node dist/cli.js verify
node dist/cli.js status
```

## Custom Overlay

Ghi đè templates bằng cách đặt file tương ứng trong:

```text
custom/instructions/
custom/skills/
```

Setup copy template mặc định trước, sau đó overlay custom.

Antigravity instructions được ghi vào `~/.gemini/GEMINI.md` bằng block:

```text
<!-- AGENTMEMORY_RULES_START -->
...
<!-- AGENTMEMORY_RULES_END -->
```

Chạy lại `setup.sh` sẽ cập nhật lại block này và copy lại skills vào `~/.gemini/antigravity/skills/`.

## Không Làm

- Không fork AgentMemory upstream.
- Không thay thế Codex/Claude upstream hooks bằng custom hooks.
- Không yêu cầu API key cho embeddings.
- Không bật LLM compression/consolidation mặc định.
