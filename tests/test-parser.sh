#!/bin/zsh
set -eu

ROOT="${0:A:h:h}"
PARSER="$ROOT/scripts/parse-rclone-status.sh"
TMP=$(mktemp -d /tmp/ocr2md-syncbar-parser-tests.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

run_case() {
  local name="$1"
  local expected="$2"
  local body="$3"
  local log="$TMP/$name.log"
  printf '%s\n' "$body" > "$log"
  local result actual_status
  result=$(OCR2MD_RCLONE_LOG="$log" "$PARSER")
  actual_status=$(printf '%s\n' "$result" | sed -n 's/^STATUS=//p' | head -1)
  if [[ "$actual_status" == "$expected" ]]; then
    printf 'PASS %-22s -> %s\n' "$name" "$actual_status"
    pass=$((pass + 1))
  else
    printf 'FAIL %-22s expected=%s actual=%s\n%s\n' "$name" "$expected" "$actual_status" "$result"
    fail=$((fail + 1))
  fi
}

PREFIX='2026/08/30 13:00:00 NOTICE: Config file "/tmp/rclone.conf" not found - using defaults'

run_case synced synced "$PREFIX
2026/08/30 13:00:00 INFO  : No changes found
2026/08/30 13:00:00 INFO  : Bisync successful"

run_case icloud_to_gdrive icloud_to_gdrive "$PREFIX
2026/08/30 13:00:00 INFO  : - Path1             Queue copy to Path2                         - /tmp/a.md
2026/08/30 13:00:00 INFO  : Bisync successful"

run_case gdrive_to_icloud gdrive_to_icloud "$PREFIX
2026/08/30 13:00:00 INFO  : - Path2             Queue copy to Path1                         - /tmp/a.md
2026/08/30 13:00:00 INFO  : Bisync successful"

run_case syncing syncing "$PREFIX
2026/08/30 13:00:00 INFO  : Synching Path1 /tmp/path1 with Path2 /tmp/path2
2026/08/30 13:00:00 INFO  : Building Path1 and Path2 listings"

run_case conflict conflict "$PREFIX
2026/08/30 13:00:00 NOTICE: - WARNING           New or changed in both paths                - file.md
2026/08/30 13:00:00 NOTICE: - Path1             Renaming Path1 copy                         - /tmp/file.md.conflict1
2026/08/30 13:00:00 NOTICE: - Path2             Renaming Path2 copy                         - /tmp/file.md.conflict2
2026/08/30 13:00:00 INFO  : Bisync successful"

run_case delete_protection delete_protection "$PREFIX
2026/08/30 13:00:00 ERROR : Safety abort: too many deletes (>25%, 1 of 3) on Path1 /tmp/path1. Run with --force if desired.
2026/08/30 13:00:00 NOTICE: Failed to bisync: too many deletes"

run_case error error "$PREFIX
2026/08/30 13:00:00 ERROR : Bisync critical error: path1 and path2 are out of sync, run --resync to recover
2026/08/30 13:00:00 NOTICE: Failed to bisync: bisync aborted"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
