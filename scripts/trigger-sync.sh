#!/bin/zsh
set -u

source "${0:A:h}/lib/load-config.sh"

LABEL="$OCR2MD_LAUNCH_AGENT_LABEL"
DOMAIN="gui/$(id -u)"
JOB="$DOMAIN/$LABEL"

if ! /bin/launchctl print "$JOB" >/dev/null 2>&1; then
  print -u2 "ocr2md sync LaunchAgent is not loaded: $JOB"
  exit 1
fi

# No -k: if the service is already running, do not kill/restart the active sync.
/bin/launchctl kickstart "$JOB"
