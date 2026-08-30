#!/bin/zsh
set -eu

ROOT="${0:A:h}"
CONFIG_LOCAL="$ROOT/config/local.env"
CONFIG_EXAMPLE="$ROOT/config/config.example"
PLUGIN_DIR="$ROOT/swiftbar"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ocr2md-syncbar currently supports macOS only." >&2
  exit 1
fi

if [[ ! -x /opt/homebrew/bin/brew && ! -x /usr/local/bin/brew ]]; then
  echo "Homebrew is required to install SwiftBar." >&2
  echo "Install Homebrew first, then run ./install.sh again." >&2
  exit 1
fi

BREW=/opt/homebrew/bin/brew
[[ -x "$BREW" ]] || BREW=/usr/local/bin/brew

if [[ ! -d /Applications/SwiftBar.app ]]; then
  echo "Installing SwiftBar..."
  "$BREW" install --cask swiftbar
else
  echo "SwiftBar already installed."
fi

EXECUTABLES=(
  "$ROOT"/swiftbar/*.sh(N)
  "$ROOT"/scripts/*.sh(N)
  "$ROOT"/scripts/lib/*.sh(N)
)
(( ${#EXECUTABLES[@]} > 0 )) && chmod +x "${EXECUTABLES[@]}"

if [[ ! -f "$CONFIG_LOCAL" ]]; then
  cp "$CONFIG_EXAMPLE" "$CONFIG_LOCAL"
  echo
  echo "Created config/local.env from the template."
  echo "Edit it with this Mac's rclone bridge paths, then run ./install.sh again."
  exit 2
fi

echo "Using existing config/local.env."

defaults write com.ameba.SwiftBar PluginDirectory "$PLUGIN_DIR"
defaults write com.ameba.SwiftBar PR_LAUNCH_AT_LOGIN -bool true
killall SwiftBar 2>/dev/null || true
sleep 1
open -a SwiftBar

echo "SwiftBar plugin directory: $PLUGIN_DIR"
echo
"$ROOT/scripts/doctor.sh"
