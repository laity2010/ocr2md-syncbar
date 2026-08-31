#!/bin/zsh
set -u
SYNCROOT="$HOME/Library/Application Support/ocr2md-sync"
LOGDIR="$HOME/Library/Logs/ocr2md-sync"
STATE="$SYNCROOT/unison-state.txt"
LOCK="$SYNCROOT/.unison-sync.lock"
HELPER="$SYNCROOT/group-sync.py"
mkdir -p "$SYNCROOT" "$LOGDIR"

if ! mkdir "$LOCK" 2>/dev/null; then
  # Do not clobber a useful in-progress state record. A running launch already owns it.
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM

if [[ ! -x "$HELPER" ]]; then
  NOW=$(date '+%Y-%m-%d %H:%M:%S')
  {
    printf 'last_start=%s\n' "$NOW"
    printf 'last_end=%s\n' "$NOW"
    printf 'exit_code=2\n'
    printf 'status=error\n'
    printf 'phase=\n'
    printf 'profile=sync-groups\n'
    printf 'error=missing helper: %s\n' "$HELPER"
  } > "$STATE"
  exit 2
fi

"$HELPER"
exit $?
