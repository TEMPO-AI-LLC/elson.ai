# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Elson.ai is a local-first macOS voice assistant for fast dictation, transcript cleanup, screenshot-aware replies, and lightweight personal agent workflows. It is a native Swift/SwiftUI app (Bundle ID: `ai.elson.desktop`).

Two primary modes:
- **Transcript**: cleans/transforms dictated text (corrections, shortening, translation, rewrites)
- **Agent**: answer/action-first mode (contextual replies, screenshot-aware assistance, notes, reminders)

## Build Commands

```bash
# Quick build
swift build

# Full clean rebuild + install (resets all local state and TCC permissions)
bash ./build.sh

# Build without installing
bash ./build.sh --variant modern --no-install

# Preserve-state update (keeps config, API keys, history; still resets TCC)
bash ./update.sh

# Build both variants + universal installer zip
bash ./build.sh --variant all --package-zip --no-install
```

Build variants are controlled by `ELSON_BUILD_VARIANT` env var or `--variant` flag:
- `modern` — macOS 26.0+ (default)
- `compat15` — macOS 15.0+ (defines `ELSON_COMPAT15_VARIANT` Swift flag)
- `auto` — auto-detects host macOS version
- `all` — builds both

## Evals (Python)

```bash
cd evals_python
python3 -m venv .venv && source .venv/bin/activate && pip install -e .

python -m elson_intent_evals harvest --last-days 5
python -m elson_intent_evals replay --last-days 5 [--runs N] [--provider google|cerebras]
python -m elson_intent_evals purge --days 30
```

## Local Development Setup

```bash
cp .env.local.example .env.local
# Fill in: GROQ_API_KEY, CEREBRAS_API_KEY, GEMINI_API_KEY
```

Runtime config lives at `~/Documents/Elson/Config/local-config.json` (see `Config/local-config.example.json` for schema).

## Architecture

**Swift 6.2 / SwiftUI app** using Swift Package Manager. Single dependency: `swift-markdown-ui`.

### Key Layers

- **`Elson/App/`** — `ElsonWindowCoordinator`: multi-window coordinator managing floating indicator, thread history, and feedback windows via NSHostingView-in-NSWindow
- **`Elson/Runtime/`** — Core orchestration layer:
  - `ElsonRuntime` — main request orchestrator
  - `RuntimeTransport` protocol with two implementations: `EmbeddedAgentTransport` (full agent path) and `LocalDirectTransport` (transcript-only path)
  - `LocalAIService` — AI provider integration
  - `ElsonPromptCatalog` / `PromptConfig` — prompt template management with `{placeholder}` substitution, loaded from `prompt-config.json`
  - `MyElsonMemory` — persistent user memory/context
  - `ElsonLocalConfig` — runtime config from local-config.json
- **`Elson/Services/`** — System integrations: `AudioRecordingService`, `KeyboardService` (global shortcuts), `ScreenSnapshotService`, `PermissionCoordinator`, `SkillCatalogStore`
- **`Elson/Models/`** — State management: `AppSettings` (@Observable, persisted to UserDefaults), `ChatStore` (thread persistence via JSON files in `~/Library/Application Support/Elson/chat-threads/`), `APIProvider` (strategy pattern for Groq/Google/Cerebras/OpenAI)
- **`Elson/Views/`** — SwiftUI views: `ContentView` (root, onboarding gate), `BubbleIndicatorView`, `ThreadHistoryWindowView`, `ElsonSettingsView`, `InstallOnboardingView`
- **`Elson/Resources/`** — `model-config.json` (per-provider model names), `prompt-config.json` (all prompt templates), `AppIcon.icns`

### Patterns

- **State**: `@Observable` + SwiftUI Environment injection; `@MainActor` throughout
- **Concurrency**: Swift structured concurrency (async/await); `Sendable` constraints on transport and config types
- **Provider abstraction**: `APIProvider` enum + `ProviderConfig` protocol; each provider handles its own request/response serialization
- **Request/Response envelopes**: `ElsonRequestEnvelope` / `ElsonResponseEnvelope` with thread context, attachments, and action payloads
- **File storage**: JSON files in Application Support directory; base64-encoded safe filenames for thread IDs

## Critical Development Rules (from AGENTS.md)

- **TCC reset is mandatory on every reinstall** — stop Elson, unregister from LaunchServices, remove from `/Applications`, install fresh app, then run `tccutil` reset for all services (All, ScreenCapture, Microphone, Accessibility, SystemPolicyDocumentsFolder, SystemPolicyDesktopFolder, SystemPolicyDownloadsFolder, SystemPolicyAllFiles)
- **Versions must monotonically increase** — bump both `CFBundleShortVersionString` and `CFBundleVersion` in `Elson/Resources/Info.plist` before any rebuild/install
- **`build.sh` = full reset; `update.sh` = preserve state** — never mix semantics
- **Never use raw workspace paths** — all workspace file access must go through `withSelectedWorkspaceFolderAccess()` (sandbox/security-scoped bookmarks)
- **Prompt discipline** — always commit before prompt edits; every prompt edit must be followed by an eval run against intent cases
- **Keep copy minimal** — omit descriptions unless they prevent confusion
