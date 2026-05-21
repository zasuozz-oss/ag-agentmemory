---
name: agentmemory-session-start
description: Use at the start of meaningful work to load relevant AgentMemory context for the current project or task
---

# AgentMemory Session Start

Load relevant context before making assumptions.

## Procedure

1. Identify the project, feature, files, and user request.
2. Search with `memory_smart_search`.
3. Summarize only the memories that affect the current task.
4. Ignore stale or unrelated results.

## Search Examples

```text
current project setup preferences
agentmemory antigravity codex claude setup
<feature name> architecture decision
<file path> prior bug
```
