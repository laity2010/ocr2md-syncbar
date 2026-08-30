#!/bin/zsh
set -u

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/lib/load-config.sh" || exit 1

fail=0
ok()   { printf '✓ %s\n' "$1"; }
bad()  { printf '✗ %s\n' "$1"; fail=1; }
info() { printf '  %s\n' "$1"; }

printf '%s\n' 'ocr2md SyncBar doctor'
printf '%s\n' '--------------------'

if [[ -d /Applications/SwiftBar.app ]]; then
  ok 'SwiftBar installed'
else
  bad 'SwiftBar not installed'
fi

EXPECTED_PLUGIN_DIR="${SCRIPT_DIR:h}/swiftbar"
ACTUAL_PLUGIN_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
if [[ "$ACTUAL_PLUGIN_DIR" == "$EXPECTED_PLUGIN_DIR" ]]; then
  ok 'SwiftBar plugin directory configured'
else
  bad 'SwiftBar plugin directory does not match this checkout'
  info "expected: $EXPECTED_PLUGIN_DIR"
  info "actual:   ${ACTUAL_PLUGIN_DIR:-<unset>}"
fi

if launchctl print "gui/$(id -u)/$OCR2MD_LAUNCH_AGENT_LABEL" >/dev/null 2>&1; then
  ok "LaunchAgent loaded ($OCR2MD_LAUNCH_AGENT_LABEL)"
else
  bad "LaunchAgent not loaded ($OCR2MD_LAUNCH_AGENT_LABEL)"
fi

if [[ -r "$OCR2MD_RCLONE_LOG" ]]; then
  ok 'rclone log readable'
  info "$OCR2MD_RCLONE_LOG"
else
  bad 'rclone log not readable'
  info "$OCR2MD_RCLONE_LOG"
fi

if [[ -d "$OCR2MD_ICLOUD_PATH" ]]; then
  ok 'iCloud sync folder exists'
else
  bad 'iCloud sync folder missing'
  info "$OCR2MD_ICLOUD_PATH"
fi

if [[ -d "$OCR2MD_GDRIVE_PATH" ]]; then
  ok 'Google Drive sync folder exists'
else
  bad 'Google Drive sync folder missing'
  info "$OCR2MD_GDRIVE_PATH"
fi

RESULT="$($SCRIPT_DIR/parse-rclone-status.sh 2>/dev/null || true)"
STATUS=$(printf '%s\n' "$RESULT" | sed -n 's/^STATUS=//p' | head -1)
LABEL=$(printf '%s\n' "$RESULT" | sed -n 's/^LABEL=//p' | head -1)
if [[ -n "$STATUS" ]]; then
  ok "status parser works ($LABEL)"
else
  bad 'status parser failed'
fi

exit "$fail"
