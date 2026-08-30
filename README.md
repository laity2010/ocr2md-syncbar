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
