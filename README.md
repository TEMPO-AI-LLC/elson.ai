# Elson.ai

Elson.ai is a local-first macOS voice assistant for fast dictation, transcript cleanup, screenshot-aware replies, and lightweight personal agent workflows.

It is a free, source-available alternative to tools like Wispr Flow (`wispr.ai`) and Willow Voice, with a stronger focus on local state, explicit user control, and paste-first desktop workflows.

## License

This repository is source-available under a combined **Apache 2.0 + Common Clause** license.

See [LICENSE](./LICENSE) for the full text and restrictions.

## What Elson Does

Elson has two primary modes:

- `Transcript`: faithful cleanup and explicit transformation of dictated text.
- `Agent`: answer/action-first mode for local assistant behavior.

Core features currently in the repo:

- Fast speech-to-text with local-first app state
- Transcript cleanup with support for:
  - self-corrections
  - shortening
  - translation
  - explicit rewrites
  - sentence removal and similar edit instructions
- Agent mode for:
  - contextual replies
  - screenshot-aware assistance
  - note/reminder/MyElson updates
  - paste-first local actions
- Per-thread Transcript / Agent selection in chat
- Clipboard-aware output handling and auto-paste controls
- External local skill discovery via `SKILL.md`
- Inline feedback capture and prompt-learning foundations
- macOS packaging, reinstall, update, and permission reset flows

## How Elson Works

At a high level:

1. Elson captures audio from a shortcut or from the chat composer.
2. Audio is transcribed.
3. The selected mode determines what happens next:
   - `Transcript` returns cleaned user-authored text
   - `Agent` produces a reply or local action outcome
4. Elson can use current-turn context such as screenshots, clipboard text, or chat history to understand the request.
5. Elson never auto-sends messages. The strongest local action is paste into the active field.

The app keeps user state locally and persists configuration through local config files and app storage rather than a hosted account model.

## Install

### Option 1: Build and reinstall locally

Use the canonical local rebuild flow:

```bash
bash ./build.sh
```

This:

- builds the host-compatible app variant
- removes the currently installed app
- resets TCC permissions for Elson
- installs a fresh copy into `/Applications`
- opens the app after install

Useful build variants:

```bash
bash ./build.sh --variant modern --no-install
bash ./build.sh --variant compat15 --no-install
bash ./build.sh --variant all --package-zip --no-install
```

Artifacts:

- `elson-modern-latest.dmg`
- `elson-compat15-latest.dmg`
- `elson-universal-installer.zip`

### Option 2: Share with friends

Build the universal friend-shareable package:

```bash
bash ./build.sh --variant all --package-zip --no-install
```

This creates:

- `elson-universal-installer.zip`

The ZIP contains:

- both DMGs
- `Install Elson.command`
- `Update Elson.command`

The installer chooses the compatible artifact for the recipient’s macOS version.

## Update

For in-place local updates that preserve state but still reset TCC permissions:

```bash
bash ./update.sh
```

`update.sh` is the preserve-state path:

- builds the current code first
- chooses the host-compatible local artifact automatically
- keeps local app state
- keeps API keys
- keeps transcript history
- keeps local config
- still resets TCC permissions
- replaces the installed app bundle

Optional overrides:

```bash
bash ./update.sh --variant modern
bash ./update.sh --variant compat15
bash ./update.sh --artifact ./elson-modern-latest.dmg
```

Use `build.sh` for a full clean reinstall and full reset.
Use `update.sh` for a fresh build plus preserve-state update.

## Local Development

Create a local env file from the example:

```bash
cp .env.local.example .env.local
```

Required keys:

- `GROQ_API_KEY`
- `CEREBRAS_API_KEY`
- `GEMINI_API_KEY`

Then build:

```bash
swift build
```

Or run the packaging flow:

```bash
bash ./build.sh --variant modern --no-install
```

## Privacy and Local State

Elson is designed around local-first behavior:

- app state is stored locally
- configuration is stored locally
- transcript history is stored locally
- packaging and update flows work without a hosted Elson account

External model providers are used for transcription and agent output, so dictated content may be sent to the configured model APIs depending on the feature path being used.

## Evals

The public repo keeps the **eval framework** in [`evals_python`](./evals_python), including:

- replay tooling
- fixture tooling
- reporting code

The public repo intentionally excludes:

- private or historical fixture data
- eval result history
- transcript-derived review/history artifacts

See [`evals_python/README.md`](./evals_python/README.md) for the framework itself.
