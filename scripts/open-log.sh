#!/bin/zsh
set -eu

source "${0:A:h}/lib/load-config.sh"
LOG_FILE="$OCR2MD_RCLONE_LOG"

if [[ ! -e "$LOG_FILE" ]]; then
  osascript -e 'display alert "ocr2md SyncBar" message "同步日志不存在。" as warning'
  exit 1
fi

open "$LOG_FILE"
