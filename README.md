# ag-agentmemmory-proxy

[English](README.md) | [Tiếng Việt](README.vi.md)

A local OpenAI-compatible proxy for `agy-cli`. The proxy runs on your machine, accepts OpenAI chat completion requests, and forwards each prompt to the authenticated `agy` CLI.

Upstream AgentMemory: https://github.com/rohitg00/agentmemory

## Setup Overview

1. Install AgentMemory globally.
2. Install the Claude Code plugin (hooks wired automatically).
3. Install the Codex CLI plugin and trust hooks interactively.
4. Run `bash setup.sh` — builds the proxy, registers agentmemory to start at login, and starts everything.
5. Point AgentMemory upstream at the proxy endpoint if you want to use `agy-cli` as the LLM provider.

## 1. Install AgentMemory

> **macOS + Homebrew node**: npm global requires sudo because Homebrew owns the `node_modules` directory.

```bash
sudo npm install -g @agentmemory/agentmemory
```

Verify:

```bash
agentmemory status
curl -fsSL http://localhost:3111/agentmemory/health
```

Viewer: `http://localhost:3113`

Useful commands:

```bash
agentmemory doctor   # diagnose and auto-fix issues
agentmemory stop
agentmemory status
```

## 2. Claude Code Setup (Plugin + 12 Hooks)

The Claude Code plugin automatically wires **12 hooks**: SessionStart, UserPromptSubmit, PreToolUse,
PostToolUse, PostToolUseFailure, PreCompact, SubagentStart, SubagentStop, Notification,
TaskCompleted, Stop, SessionEnd.

Run these two commands inside Claude Code:

```text
/plugin marketplace add rohitg00/agentmemory
/plugin install agentmemory
```

Restart Claude Code after installing. Hooks activate immediately — no further action needed.

## 3. Codex CLI Setup (Plugin + 6 Hooks)

The Codex plugin wires **6 hooks**: session_start, user_prompt_submit, pre_tool_use, post_tool_use,
pre_compact, stop.

**Step 1** — Install the plugin from a terminal:

```bash
codex plugin marketplace add rohitg00/agentmemory
codex plugin add agentmemory@agentmemory
```

**Step 2** — Trust hooks inside the Codex TUI (required):

```bash
codex
```

When Codex displays `"Trust this hook?"` for each hook, choose **Yes / Always trust**.
All 6 hooks must be accepted. Afterwards `~/.codex/config.toml` will contain 6 entries:

```toml
[hooks.state."agentmemory@agentmemory:hooks/hooks.codex.json:session_start:0:0"]
trusted_hash = "sha256:..."
# ... (6 entries total)
```

Verify:

```bash
grep "hooks.state.*agentmemory" ~/.codex/config.toml | wc -l
# must return 6
```

> **Note**: If the plugin is removed and reinstalled, all `trusted_hash` entries are wiped.
> Open the Codex TUI again and re-trust all 6 hooks.

## 4. Proxy Setup + Auto-Start

`setup.sh` does everything in one run:

- Builds the proxy (`npm install` + `npm run build`)
- Writes config to `~/.ag-agentmemmory-proxy/proxy.env`
- Starts the agy proxy on `127.0.0.1:3129`
- **Registers agentmemory server to start automatically at login**:
  - **macOS**: creates LaunchAgent `com.agentmemory` (KeepAlive — restarts on crash)
  - **Windows** (Git Bash / MSYS2): creates Task Scheduler task `AgentMemory` (ONLOGON)

```bash
bash setup.sh
```

Options:

```bash
bash setup.sh --skip-build                         # skip npm install/build
bash setup.sh --skip-agentmemory-startup           # skip auto-start registration
bash setup.sh --agentmemory-bin /path/to/binary    # specify binary manually
bash setup.sh --agy-bin /path/to/agy-clean-wrapper.sh
bash setup.sh --host 127.0.0.1 --port 3129
bash setup.sh --timeout-ms 120000
bash setup.sh --sandbox
```

Files created:

```text
~/.ag-agentmemmory-proxy/proxy.env            # proxy config
~/.ag-agentmemmory-proxy/agy-proxy.log        # agy proxy log
~/.ag-agentmemmory-proxy/agentmemory.log      # agentmemory server log
~/Library/LaunchAgents/com.agentmemory.plist  # macOS startup plist (auto-created)
```

### macOS — Manage LaunchAgent manually

```bash
# Stop
launchctl unload ~/Library/LaunchAgents/com.agentmemory.plist

# Restart
launchctl load ~/Library/LaunchAgents/com.agentmemory.plist

# View logs
tail -f ~/.ag-agentmemmory-proxy/agentmemory.log
```

### Windows — Manage Task Scheduler manually

```bash
schtasks.exe /End    /TN AgentMemory          # stop
schtasks.exe /Run    /TN AgentMemory          # start
schtasks.exe /Delete /TN AgentMemory /F       # remove
```

### agy proxy LaunchAgent (macOS)

To also auto-start the agy proxy at login:

```bash
bash set-run.sh
```

## 5. Point AgentMemory at the Proxy

After the proxy is running, configure AgentMemory upstream to use the local endpoint as its LLM provider:

```env
OPENAI_BASE_URL=http://127.0.0.1:3129
OPENAI_MODEL=agy-cli
```

Restart AgentMemory:

```bash
agentmemory stop
agentmemory
```

## Proxy CLI

```bash
npm run build
node dist/cli.js agy-proxy --host 127.0.0.1 --port 3129
node dist/cli.js status
node dist/cli.js verify
```

## Proxy Config

```env
AGY_PROXY_HOST=127.0.0.1
AGY_PROXY_PORT=3129
AGY_CLI_BIN=/path/to/ag-agentmemmory-proxy/agy-clean-wrapper.sh
AGY_CLI_TIMEOUT_MS=120000
AGY_CLI_SANDBOX=false
```

## Health Check

```bash
# AgentMemory server
curl -fsSL http://localhost:3111/agentmemory/health

# agy proxy
curl -fsSL http://127.0.0.1:3129/health
# {"ok":true,"service":"agy-proxy"}
```

## Uninstall

```bash
# Remove AgentMemory
agentmemory remove
rm -rf ~/.agentmemory
sudo rm -rf /opt/homebrew/lib/node_modules/@agentmemory  # macOS Homebrew

# Remove LaunchAgent (macOS)
launchctl unload ~/Library/LaunchAgents/com.agentmemory.plist
rm ~/Library/LaunchAgents/com.agentmemory.plist

# Remove Task Scheduler task (Windows)
schtasks.exe /Delete /TN AgentMemory /F

# Remove Codex plugin
codex plugin remove agentmemory@agentmemory
codex plugin marketplace remove agentmemory

# Remove Claude Code plugin (inside Claude Code)
/plugin uninstall agentmemory
```
