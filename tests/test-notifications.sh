#!/bin/zsh
set -eu

ROOT="${0:A:h:h}"
NOTIFIER="$ROOT/scripts/notify-status.sh"
TMP=$(mktemp -d /tmp/ocr2md-syncbar-notify-tests.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"

run() {
  OCR2MD_NOTIFICATION_STATE_FILE="$STATE" OCR2MD_NOTIFICATION_DRY_RUN=1 \
    "$NOTIFIER" "$1" "$2" "$3"
}

OUT1=$(run synced 已同步 正常)
OUT2=$(run conflict 检测到冲突 冲突)
OUT3=$(run conflict 检测到冲突 冲突)
OUT4=$(run synced 已同步 恢复)
OUT5=$(run conflict 检测到冲突 冲突再次出现)
OUT6=$(run error 同步异常 错误)

[[ -z "$OUT1" ]] || { echo 'FAIL healthy state should stay silent'; exit 1; }
[[ "$OUT2" == NOTIFY* ]] || { echo 'FAIL first conflict should notify'; exit 1; }
[[ -z "$OUT3" ]] || { echo 'FAIL repeated conflict should stay silent'; exit 1; }
[[ -z "$OUT4" ]] || { echo 'FAIL recovery should stay silent'; exit 1; }
[[ "$OUT5" == NOTIFY* ]] || { echo 'FAIL conflict after recovery should notify again'; exit 1; }
[[ "$OUT6" == NOTIFY* ]] || { echo 'FAIL changed abnormal state should notify'; exit 1; }

echo '6 notification transition checks passed'
