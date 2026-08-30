#!/bin/zsh

THIS_FILE="${(%):-%N}"
LIB_DIR="${THIS_FILE:A:h}"
PROJECT_DIR="${LIB_DIR}/../.."
PROJECT_DIR="${PROJECT_DIR:A}"
LOCAL_CONFIG="$PROJECT_DIR/config/local.env"
EXAMPLE_CONFIG="$PROJECT_DIR/config/config.example"

if [[ -r "$LOCAL_CONFIG" ]]; then
  source "$LOCAL_CONFIG"
elif [[ -r "$EXAMPLE_CONFIG" ]]; then
  source "$EXAMPLE_CONFIG"
else
  echo "ocr2md SyncBar config not found" >&2
  return 1
fi
