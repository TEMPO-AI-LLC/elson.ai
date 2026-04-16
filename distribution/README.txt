Elson Universal Installer

Contents:
- Install Elson.command
- Update Elson.command
- install.sh
- update.sh
- elson-modern-latest.dmg
- elson-compat15-latest.dmg

Behavior:
- macOS 26 or newer installs the modern build first.
- macOS 15 through 25 installs the compat15 build first.
- If the preferred DMG is missing, the installer falls back only to a build that is still compatible with the current macOS version.
- Install resets permissions and local Elson state for a clean reinstall.
- Update replaces the app bundle, resets TCC permissions, and keeps API keys, history, and local config.

Usage:
1. Double-click "Install Elson.command".
2. Double-click "Update Elson.command" when you want an in-place app update instead.
3. If Gatekeeper asks, allow the script to run.
