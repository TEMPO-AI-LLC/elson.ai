# Elson Intent Evals

Python package for replaying **Intent Agent** decisions only.

It does three things:

1. harvest cases from existing local artifacts
2. replay them against the current provider with **2 direct API calls per case by default**
3. write JSON, CSV, and Markdown reports

Important:

- This package does **not** run the Working Agent.
- Gemini replay uses the **real screenshot/image files** when fixture bundles contain them.
- Fixture retention is infinite by default.
- Manual cleanup is available through `purge --days N`.
- Shared prompt source of truth lives in `Elson/Resources/prompt-config.json`, which is read by both Swift and Python.

## Install

```bash
cd evals_python
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

## Default paths

- Fixtures: `~/Library/Application Support/Elson/Evals/intent-fixtures`
- Reports: `evals_python/results`
- Local config: `~/Library/Application Support/Elson/local-config.json`

The public repository keeps the eval framework code, but does not ship private fixture bundles, replay history, or transcript-derived review data.

## Commands

Harvest labeled and unlabeled cases from the last five days:

```bash
python -m elson_intent_evals harvest --last-days 5
```

Replay the last five days with the default 2 runs per case:

```bash
python -m elson_intent_evals replay --last-days 5
```

Replay only labeled fixtures:

```bash
python -m elson_intent_evals replay --last-days 5 --only-labeled
```

Override the default and run more replays when needed:

```bash
python -m elson_intent_evals replay --last-days 5 --runs 3
```

Force Google or Cerebras regardless of stored provider:

```bash
python -m elson_intent_evals replay --last-days 5 --provider google
python -m elson_intent_evals replay --last-days 5 --provider cerebras
```

Allow partial fixtures explicitly:

```bash
python -m elson_intent_evals replay --last-days 5 --allow-partial-fixtures
```

Purge fixtures older than 30 days:

```bash
python -m elson_intent_evals purge --days 30
```

## What a fixture contains

Each fixture lives in its own folder:

```text
<fixture-root>/<YYYY-MM-DD>/<fixture-id>/
  manifest.json
  request-payload.json
  attachments/
    screenshot-1.jpg
```

`manifest.json` contains the replay metadata and attachment references. For Gemini, `attachments/` is critical because production Intent calls send the **real screenshot bytes**, not just OCR text.

## Harvest sources

`harvest` reads from:

- an external review CSV exported by the maintainer
- `~/Documents/Elson/*_elson.csv`
- `~/Library/Application Support/Elson/transcript-history.json`
- already saved fixture bundles

Historical log-derived cases are often **partial** because they do not contain the original screenshot file. Newer fixtures captured by the app are replay-faithful and include the real attachment files.

## Reports

Every replay run writes:

- `report.json`
- `report.csv`
- `summary.md`

Per case, the report includes:

- expected route
- run 1 / run 2 route, plus any extra runs when `--runs` is increased
- majority route
- stable or unstable
- match or mismatch
- provider and model
- `has_real_attachments`
- `fixture_completeness`

## Lighteval note

This package depends on `lighteval` and records the installed framework version in reports. The replay adapter is intentionally custom because Elson's Intent Agent decision is a provider-specific multimodal API call rather than a generic benchmark task.
