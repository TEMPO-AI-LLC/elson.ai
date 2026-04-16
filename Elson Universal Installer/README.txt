Elson Universal Installer

Contents:
- Install Elson.command
- install.sh
- elson-modern-latest.dmg
- elson-compat15-latest.dmg

Behavior:
- macOS 26 or newer installs the modern build first.
- macOS 15 through 25 installs the compat15 build first.
- If the preferred DMG is missing, the installer falls back only to a build that is still compatible with the current macOS version.

Usage:
1. Double-click "Install Elson.command".
2. If Gatekeeper asks, allow the script to run.
3. Elson will be reinstalled and macOS permissions will be reset in the same order as the normal install flow.
