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

case "$STATUS" in
  synced)             ICON="●" ;;
  icloud_to_gdrive)   ICON="↑" ;;
  gdrive_to_icloud)   ICON="↓" ;;
  syncing)            ICON="↻" ;;
  conflict)           ICON="⚠︎" ;;
  delete_protection)  ICON="⛔︎" ;;
  *)                   ICON="!" ;;
esac

printf '%s %s\n' "$ICON" "$LABEL"
echo '---'
echo "ocr2md SyncBar"
echo "状态：$LABEL"
echo "最后成功：$LAST_SUCCESS"
echo "详情：$DETAIL"
echo '---'
echo "立即同步 | bash=$PROJECT_DIR/scripts/trigger-sync.sh terminal=false refresh=true"
echo '刷新 | refresh=true'
