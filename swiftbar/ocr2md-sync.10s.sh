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
  synced)
    ICON="●"
    COLOR="#1B7F3A,#72D58C"
    ;;
  icloud_to_gdrive|gdrive_to_icloud|syncing)
    case "$STATUS" in
      icloud_to_gdrive) ICON="↑" ;;
      gdrive_to_icloud) ICON="↓" ;;
      syncing)          ICON="↻" ;;
    esac
    COLOR="#1261A0,#70B7FF"
    ;;
  delete_protection)
    ICON="⛔︎"
    COLOR="#A65300,#FFB35C"
    ;;
  stale|service_unavailable|conflict)
    case "$STATUS" in
      conflict) ICON="⚠︎" ;;
      *)        ICON="!" ;;
    esac
    COLOR="#B42318,#FF7B72"
    ;;
  *)
    ICON="!"
    COLOR="#B42318,#FF7B72"
    ;;
esac

printf '%s %s | color=%s\n' "$ICON" "$LABEL" "$COLOR"
echo '---'
echo "ocr2md SyncBar"
echo "状态：$LABEL | color=$COLOR"
echo "最后成功：$LAST_SUCCESS"
echo "详情：$DETAIL"
echo '---'
echo "立即同步 | bash=$PROJECT_DIR/scripts/trigger-sync.sh terminal=false refresh=true"
echo "打开日志 | bash=$PROJECT_DIR/scripts/open-log.sh terminal=false"
echo "打开 iCloud 端 | bash=$PROJECT_DIR/scripts/open-sync-folder.sh param1=icloud terminal=false"
echo "打开 Google Drive 端 | bash=$PROJECT_DIR/scripts/open-sync-folder.sh param1=gdrive terminal=false"
echo '刷新 | refresh=true'
