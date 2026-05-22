#!/usr/bin/env bash
# Wrapper: chạy agy rồi xóa các entries mới được tạo trong lúc call này
BRAIN_DIR="$HOME/.gemini/antigravity-cli/brain"
CONVERSATIONS_DIR="$HOME/.gemini/antigravity-cli/conversations"
KNOWLEDGE_DIR="$HOME/.gemini/antigravity-cli/knowledge"
IMPLICIT_DIR="$HOME/.gemini/antigravity-cli/implicit"

# Snapshot trước khi chạy (per-invocation temp file để safe với concurrent calls)
SNAP_BRAIN=$(mktemp)
SNAP_CONV=$(mktemp)
ls "$BRAIN_DIR" 2>/dev/null | sort > "$SNAP_BRAIN"
ls "$CONVERSATIONS_DIR" 2>/dev/null | sort > "$SNAP_CONV"

# Chạy agy
/Users/zasuo/.local/bin/agy "$@"
EXIT_CODE=$?

# Xóa entries mới tạo trong call này
comm -13 "$SNAP_BRAIN" <(ls "$BRAIN_DIR" 2>/dev/null | sort) | while read -r entry; do
  rm -rf "${BRAIN_DIR:?}/$entry"
done
comm -13 "$SNAP_CONV" <(ls "$CONVERSATIONS_DIR" 2>/dev/null | sort) | while read -r entry; do
  rm -rf "${CONVERSATIONS_DIR:?}/$entry"
done

rm -f "$SNAP_BRAIN" "$SNAP_CONV"
exit $EXIT_CODE
