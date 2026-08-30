#!/bin/zsh
set -u

LOG_FILE="${OCR2MD_RCLONE_LOG:-$HOME/Library/Logs/ocr2md-sync/bridge-test.log}"
STALE_AFTER_SECONDS="${OCR2MD_STALE_AFTER_SECONDS:-180}"
NOW_EPOCH="${OCR2MD_NOW_EPOCH:-$(date +%s)}"
LAUNCH_AGENT_LABEL="${OCR2MD_LAUNCH_AGENT_LABEL:-com.ocr2md.rclone-bridge-test}"
SERVICE_LOADED_OVERRIDE="${OCR2MD_SERVICE_LOADED:-}"

emit() {
  printf 'STATUS=%s\n' "$1"
  printf 'LABEL=%s\n' "$2"
  printf 'LAST_SUCCESS=%s\n' "$3"
  printf 'DETAIL=%s\n' "$4"
}

SERVICE_LOADED=0
if [[ -n "$SERVICE_LOADED_OVERRIDE" ]]; then
  [[ "$SERVICE_LOADED_OVERRIDE" == "1" ]] && SERVICE_LOADED=1
elif launchctl print "gui/$(id -u)/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1; then
  SERVICE_LOADED=1
fi

if [[ -r "$LOG_FILE" ]]; then
  LAST_SUCCESS=$(grep 'Bisync successful' "$LOG_FILE" | tail -1 | sed -E 's/^([0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}).*/\1/' || true)
  [[ -n "$LAST_SUCCESS" ]] || LAST_SUCCESS="—"
else
  LAST_SUCCESS="—"
fi

if (( ! SERVICE_LOADED )); then
  emit "service_unavailable" "同步服务未运行" "$LAST_SUCCESS" "LaunchAgent 未加载：$LAUNCH_AGENT_LABEL"
  exit 0
fi

if [[ ! -r "$LOG_FILE" ]]; then
  emit "error" "日志不可读" "$LAST_SUCCESS" "$LOG_FILE"
  exit 0
fi

LAST_SUCCESS_AGE=-1
if [[ "$LAST_SUCCESS" != "—" ]]; then
  LAST_SUCCESS_EPOCH=$(date -j -f "%Y/%m/%d %H:%M:%S" "$LAST_SUCCESS" "+%s" 2>/dev/null || true)
  if [[ -n "$LAST_SUCCESS_EPOCH" ]]; then
    LAST_SUCCESS_AGE=$(( NOW_EPOCH - LAST_SUCCESS_EPOCH ))
    (( LAST_SUCCESS_AGE < 0 )) && LAST_SUCCESS_AGE=0
  fi
fi

# Every LaunchAgent invocation starts with this rclone notice on this bridge.
# Parse only the newest invocation so old errors do not poison the current state.
START_LINE=$(grep -n 'NOTICE: Config file ' "$LOG_FILE" | tail -1 | cut -d: -f1 || true)
if [[ -n "$START_LINE" ]]; then
  RUN=$(tail -n "+$START_LINE" "$LOG_FILE")
else
  RUN=$(tail -250 "$LOG_FILE")
fi

HAS_SUCCESS=0
HAS_FAILED=0
HAS_DELETE_GUARD=0
HAS_P1_TO_P2=0
HAS_P2_TO_P1=0
HAS_NO_CHANGES=0
HAS_CONFLICT=0

printf '%s\n' "$RUN" | grep -q 'Bisync successful' && HAS_SUCCESS=1
printf '%s\n' "$RUN" | grep -Eqi 'Failed to bisync|Bisync aborted|Bisync critical error' && HAS_FAILED=1
printf '%s\n' "$RUN" | grep -Eqi 'Safety abort: too many deletes|Failed to bisync: too many deletes' && HAS_DELETE_GUARD=1
printf '%s\n' "$RUN" | grep -q 'Queue copy to Path2' && HAS_P1_TO_P2=1
printf '%s\n' "$RUN" | grep -q 'Queue copy to Path1' && HAS_P2_TO_P1=1
printf '%s\n' "$RUN" | grep -q 'No changes found' && HAS_NO_CHANGES=1

# Do not mistake rclone's routine "checking potential conflicts" messages for an actual conflict.
# A non-access-file WARNING about changes on both paths is a conflict candidate.
if printf '%s\n' "$RUN" | grep -Eqi 'conflict winner|conflict loser|conflict.*renam|renam.*conflict'; then
  HAS_CONFLICT=1
elif printf '%s\n' "$RUN" | grep -E 'WARNING[[:space:]]+New or changed in both paths' | grep -vq '\.rclone-bisync-access'; then
  HAS_CONFLICT=1
fi

if (( HAS_DELETE_GUARD )); then
  DETAIL=$(printf '%s\n' "$RUN" | grep -E 'Safety abort: too many deletes|Failed to bisync: too many deletes' | tail -1 | sed -E 's/^[0-9\/]+ [0-9:]+ (ERROR|NOTICE):[[:space:]]*//')
  emit "delete_protection" "批量删除保护" "$LAST_SUCCESS" "$DETAIL"
elif (( HAS_CONFLICT )); then
  # Prefer rclone's explicit both-paths warning for the detail text. This avoids
  # accidentally matching a file or directory whose ordinary name contains
  # the word "conflict".
  DETAIL=$(printf '%s\n' "$RUN" | grep -E 'WARNING[[:space:]]+New or changed in both paths' | grep -v '\.rclone-bisync-access' | tail -1 | sed -E 's/^[0-9\/]+ [0-9:]+ (INFO|NOTICE|ERROR|WARNING):[[:space:]]*//')
  if [[ -z "$DETAIL" ]]; then
    DETAIL=$(printf '%s\n' "$RUN" | grep -Ei 'Renaming Path[12] copy|conflict winner|conflict loser|conflict.*renam|renam.*conflict' | tail -1 | sed -E 's/^[0-9\/]+ [0-9:]+ (INFO|NOTICE|ERROR|WARNING):[[:space:]]*//')
  fi
  [[ -n "$DETAIL" ]] || DETAIL="同一文件在两端同时发生变化"
  emit "conflict" "检测到冲突" "$LAST_SUCCESS" "$DETAIL"
elif (( HAS_SUCCESS )); then
  if (( LAST_SUCCESS_AGE >= STALE_AFTER_SECONDS && LAST_SUCCESS_AGE >= 0 )); then
    AGE_MINUTES=$(( LAST_SUCCESS_AGE / 60 ))
    emit "stale" "同步停滞" "$LAST_SUCCESS" "最后成功已过去 ${AGE_MINUTES} 分钟"
  elif (( HAS_P1_TO_P2 && ! HAS_P2_TO_P1 )); then
    emit "icloud_to_gdrive" "iCloud → Google Drive" "$LAST_SUCCESS" "本轮同步成功"
  elif (( HAS_P2_TO_P1 && ! HAS_P1_TO_P2 )); then
    emit "gdrive_to_icloud" "Google Drive → iCloud" "$LAST_SUCCESS" "本轮同步成功"
  elif (( HAS_NO_CHANGES )); then
    emit "synced" "已同步" "$LAST_SUCCESS" "两端没有变化"
  else
    emit "synced" "已同步" "$LAST_SUCCESS" "本轮同步成功"
  fi
elif (( HAS_FAILED )); then
  DETAIL=$(printf '%s\n' "$RUN" | grep -Ei 'Failed to bisync|Bisync aborted|Bisync critical error' | tail -1 | sed -E 's/^[0-9\/]+ [0-9:]+ (INFO|NOTICE|ERROR|WARNING):[[:space:]]*//')
  emit "error" "同步异常" "$LAST_SUCCESS" "$DETAIL"
else
  emit "syncing" "同步中" "$LAST_SUCCESS" "正在检查两端变化"
fi
