#!/bin/zsh
set -u

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/lib/load-config.sh" || exit 1

ICLOUD_NAME="${OCR2MD_ICLOUD_PATH:t}"
GDRIVE_NAME="${OCR2MD_GDRIVE_PATH:t}"
PAIR_LABEL="${OCR2MD_SYNC_PAIR_LABEL:-$ICLOUD_NAME ↔ $GDRIVE_NAME}"
OPEN_SCRIPT="$SCRIPT_DIR/open-sync-folder.sh"

# SwiftBar submenu. Keep full absolute paths visible so the operator can always
# tell exactly which pair this SyncBar instance is maintaining.
echo '维护目录（1 组）'
echo "--$PAIR_LABEL"
echo "--iCloud：$OCR2MD_ICLOUD_PATH | bash=$OPEN_SCRIPT param1=icloud terminal=false"
echo "--Google Drive：$OCR2MD_GDRIVE_PATH | bash=$OPEN_SCRIPT param1=gdrive terminal=false"
