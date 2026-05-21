---
name: agentmemory-recall
description: Use when a task may depend on prior sessions, project decisions, bugs, user preferences, or architecture context stored in AgentMemory
---

# AgentMemory Recall

Before relying on memory or assumptions, search AgentMemory.

## Procedure

1. Use `memory_smart_search` for broad semantic + keyword search.
2. Use `memory_recall` for simpler direct recall.
3. Prefer results with specific files, concepts, or decisions.
4. State when a conclusion comes from recalled memory.

## Query Style

Use concrete terms:

- feature or subsystem name
- file path
- bug symptom
- decision keyword
- user preference

Avoid generic queries like `setup` or `bug` unless paired with project context.
