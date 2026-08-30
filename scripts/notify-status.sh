#!/bin/zsh
set -u

STATUS="${1:-}"
LABEL="${2:-同步异常}"
DETAIL="${3:-请检查同步状态。}"
STATE_FILE="${OCR2MD_NOTIFICATION_STATE_FILE:-$HOME/Library/Caches/ocr2md-syncbar/last-status}"
DRY_RUN="${OCR2MD_NOTIFICATION_DRY_RUN:-0}"

case "$STATUS" in
  conflict|delete_protection|stale|service_unavailable|error)
    ABNORMAL=1
    ;;
  *)
    ABNORMAL=0
    ;;
esac

mkdir -p "${STATE_FILE:h}" 2>/dev/null || true
PREVIOUS=""
[[ -r "$STATE_FILE" ]] && PREVIOUS=$(<"$STATE_FILE")
printf '%s\n' "$STATUS" > "$STATE_FILE" 2>/dev/null || true

# Notify only when entering a new abnormal state. Repeated 10-second refreshes
# of the same problem stay silent; returning to healthy resets the transition.
if (( ! ABNORMAL )) || [[ "$PREVIOUS" == "$STATUS" ]]; then
  exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'NOTIFY status=%s label=%s detail=%s\n' "$STATUS" "$LABEL" "$DETAIL"
  exit 0
fi

osascript - "$LABEL" "$DETAIL" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set statusLabel to item 1 of argv
  set statusDetail to item 2 of argv
  display notification statusDetail with title "ocr2md SyncBar" subtitle statusLabel
end run
APPLESCRIPT
