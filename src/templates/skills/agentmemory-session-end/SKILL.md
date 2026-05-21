---
name: agentmemory-session-end
description: Use when completing a task or before ending a session to save key outcomes and unresolved follow-ups to AgentMemory
---

# AgentMemory Session End

Capture useful outcomes before the session ends.

## Procedure

1. Save a concise session summary with `memory_save`.
2. Save any reusable lessons with `memory_lesson_save`.
3. Save unresolved blockers as `UNRESOLVED:` facts.
4. Do not duplicate memories already saved during the session.

## Session Summary Shape

```text
content: Session summary: <what changed and why>
type: workflow
concepts: specific concepts
files: main files changed
```
