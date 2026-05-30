#!/usr/bin/env bash
# Wrapper: chạy agy rồi xóa ĐÚNG các entries được tạo bởi call này.
# Dùng lsof để tránh xóa nhầm entries của concurrent calls đang chạy song song.
BRAIN_DIR="$HOME/.gemini/antigravity-cli/brain"
CONVERSATIONS_DIR="$HOME/.gemini/antigravity-cli/conversations"

# Snapshot trước khi chạy (per-invocation temp file để safe với concurrent calls)
SNAP_BRAIN=$(mktemp)
SNAP_CONV=$(mktemp)
ls "$BRAIN_DIR" 2>/dev/null | sort > "$SNAP_BRAIN"
ls "$CONVERSATIONS_DIR" 2>/dev/null | sort > "$SNAP_CONV"

AGY_PID=""
EXIT_CODE=0
CLEANUP_DONE=0

cleanup() {
  [[ $CLEANUP_DONE -eq 1 ]] && return
  CLEANUP_DONE=1

  # Kill agy nếu vẫn còn chạy (timeout/signal case)
  if [[ -n "$AGY_PID" ]] && kill -0 "$AGY_PID" 2>/dev/null; then
    kill "$AGY_PID" 2>/dev/null
    wait "$AGY_PID" 2>/dev/null
  fi

  # Lấy danh sách files đang được mở bởi các agy process KHÁC (concurrent calls)
  # để tránh xóa nhầm entries của chúng.
  local active_files
  active_files=$(lsof -c agy -F n 2>/dev/null | sed -n 's/^n//p')

  comm -13 "$SNAP_BRAIN" <(ls "$BRAIN_DIR" 2>/dev/null | sort) | while read -r entry; do
    # Bỏ qua nếu entry này đang được dùng bởi concurrent agy call khác
    if echo "$active_files" | grep -qF "$entry"; then continue; fi
    rm -rf "${BRAIN_DIR:?}/$entry"
  done

  comm -13 "$SNAP_CONV" <(ls "$CONVERSATIONS_DIR" 2>/dev/null | sort) | while read -r entry; do
    if echo "$active_files" | grep -qF "$entry"; then continue; fi
    rm -rf "${CONVERSATIONS_DIR:?}/$entry"
  done

  rm -f "$SNAP_BRAIN" "$SNAP_CONV"
}

trap 'cleanup; exit $EXIT_CODE' EXIT TERM INT

# Resolve the real agy binary: explicit override → default install path → PATH.
AGY_REAL_BIN="${AGY_REAL_BIN:-$HOME/.local/bin/agy}"
if [[ ! -x "$AGY_REAL_BIN" ]] && command -v agy >/dev/null 2>&1; then
  AGY_REAL_BIN="$(command -v agy)"
fi

# Chạy agy trong background để giữ PID (phục vụ kill khi cần)
"$AGY_REAL_BIN" "$@" &
AGY_PID=$!
wait "$AGY_PID"
EXIT_CODE=$?
