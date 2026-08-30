# ocr2md-syncbar

macOS menu bar status component for the ocr2md iCloud ↔ Google Drive rclone bridge.

SwiftBar reads the existing rclone bisync log and reports sync status without owning the sync process. It can also ask the existing LaunchAgent to run one sync immediately.

## Local configuration

Machine-specific paths live in `config/local.env`, which is ignored by Git.

Start from the tracked template:

```sh
cp config/config.example config/local.env
```

Then set these values for the Mac:

- `OCR2MD_RCLONE_LOG`
- `OCR2MD_LAUNCH_AGENT_LABEL`
- `OCR2MD_ICLOUD_PATH`
- `OCR2MD_GDRIVE_PATH`
- `OCR2MD_STALE_AFTER_SECONDS`

The current Mac already has its local configuration. Future changes from test folders to production folders should be made in `config/local.env` only.

## Install / reinstall

On a Mac that already has the ocr2md rclone bridge configured:

```sh
git clone https://github.com/laity2010/ocr2md-syncbar.git
cd ocr2md-syncbar
./install.sh
```

The installer:

- installs SwiftBar with Homebrew if needed;
- preserves an existing `config/local.env`;
- creates `config/local.env` from the template if it is missing;
- points SwiftBar at this checkout's `swiftbar/` directory;
- starts SwiftBar and runs a health check.

`config/local.env` is deliberately not committed. On a new Mac, edit that file once with the local LaunchAgent label, rclone log path, iCloud path, and Google Drive path, then run `./install.sh` again.

## Health check

Run:

```sh
./scripts/doctor.sh
```

It checks SwiftBar, the plugin directory, the LaunchAgent, the rclone log, both sync folders, and the status parser without changing sync data.

