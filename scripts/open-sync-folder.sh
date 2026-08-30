#!/bin/zsh
set -u

source "${0:A:h}/lib/load-config.sh"

TARGET="${1:-}"
ICLOUD_PATH="$OCR2MD_ICLOUD_PATH"
GDRIVE_PATH="$OCR2MD_GDRIVE_PATH"

case "$TARGET" in
  icloud) PATH_TO_OPEN="$ICLOUD_PATH" ;;
  gdrive) PATH_TO_OPEN="$GDRIVE_PATH" ;;
  *)
    echo "Usage: $0 {icloud|gdrive}" >&2
    exit 64
    ;;
esac

if [[ ! -d "$PATH_TO_OPEN" ]]; then
  echo "Sync folder not found: $PATH_TO_OPEN" >&2
  exit 1
fi

open "$PATH_TO_OPEN"
