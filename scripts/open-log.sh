#!/bin/zsh
set -eu

LOG_FILE="${OCR2MD_RCLONE_LOG:-$HOME/Library/Logs/ocr2md-sync/bridge-test.log}"

if [[ ! -e "$LOG_FILE" ]]; then
  osascript -e 'display alert "ocr2md SyncBar" message "同步日志不存在。" as warning'
  exit 1
fi

open "$LOG_FILE"
