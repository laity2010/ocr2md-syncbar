#!/bin/zsh
set -u

PLUGIN_DIR="${0:A:h}"
PROJECT_DIR="${PLUGIN_DIR:h}"
PARSER="$PROJECT_DIR/scripts/parse-rclone-status.sh"

RESULT="$($PARSER)"
STATUS=$(printf '%s\n' "$RESULT" | sed -n 's/^STATUS=//p' | head -1)
LABEL=$(printf '%s\n' "$RESULT" | sed -n 's/^LABEL=//p' | head -1)
LAST_SUCCESS=$(printf '%s\n' "$RESULT" | sed -n 's/^LAST_SUCCESS=//p' | head -1)
DETAIL=$(printf '%s\n' "$RESULT" | sed -n 's/^DETAIL=//p' | head -1)

"$PROJECT_DIR/scripts/notify-status.sh" "$STATUS" "$LABEL" "$DETAIL" >/dev/null 2>&1 || true

case "$STATUS" in
  synced)
    ICON="🟢"
    ;;
  icloud_to_gdrive)
    ICON="🔵"
    ;;
  gdrive_to_icloud)
    ICON="🔵"
    ;;
  syncing)
    ICON="🔵"
    ;;
  delete_protection)
    ICON="🟠"
    ;;
  stale|service_unavailable|conflict)
    ICON="🔴"
    ;;
  *)
    ICON="🔴"
    ;;
esac

printf '%s %s\n' "$ICON" "$LABEL"
echo '---'
echo "ocr2md SyncBar"
echo "状态：$ICON $LABEL"
echo "最后成功：$LAST_SUCCESS"
echo "详情：$DETAIL"
echo '---'
echo "立即同步 | bash=$PROJECT_DIR/scripts/trigger-sync.sh terminal=false refresh=true"
echo "打开日志 | bash=$PROJECT_DIR/scripts/open-log.sh terminal=false"
"$PROJECT_DIR/scripts/list-managed-folders.sh"
echo '刷新 | refresh=true'
