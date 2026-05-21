# AgentMemory

Use AgentMemory for durable project memory across sessions.

## Rules

- Use `memory_smart_search` or `memory_recall` when past decisions, bugs, preferences, or architecture may matter.
- Use `memory_save` for durable facts, decisions, preferences, workflow notes, and bug discoveries that will matter in future sessions.
- Use `memory_lesson_save` for reusable lessons.
- Do not save secrets, API keys, tokens, passwords, or private credentials.
- Keep saved memories concise and include relevant file paths when useful.

## Local Embeddings

This setup uses local embeddings:

```env
EMBEDDING_PROVIDER=local
```

AgentMemory's local provider uses `all-MiniLM-L6-v2`, runs offline, and does not require an embedding API key.

## Useful Tools

| Task | Tool |
|------|------|
| Search prior context | `memory_smart_search` |
| Save durable memory | `memory_save` |
| Save reusable lesson | `memory_lesson_save` |
| List recent sessions | `memory_sessions` |
| Diagnose memory state | `memory_diagnose` |
