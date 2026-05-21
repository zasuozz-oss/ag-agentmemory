---
name: agentmemory-observe
description: Use during active work to save important observations, decisions, bug discoveries, architecture insights, or lessons learned to AgentMemory long-term storage
---

# AgentMemory Observe

Save information that will help future sessions.

## Save With `memory_save`

Use for:

- architecture decisions
- user preferences
- bug root causes
- workflow discoveries
- durable project facts

Fields:

```text
content: concise memory
type: bug | architecture | pattern | preference | workflow | fact
concepts: comma-separated specific keywords
files: comma-separated file paths when relevant
```

## Save With `memory_lesson_save`

Use for reusable lessons:

```text
content: what worked or what to avoid
context: when this applies
confidence: 0.5-1.0
project: project name
tags: comma-separated tags
```

## Avoid

- secrets, tokens, passwords, API keys
- routine file reads
- temporary debugging noise
- duplicate memories
