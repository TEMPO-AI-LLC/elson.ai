from __future__ import annotations

import csv
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Iterable

from .config import LocalConfig
from .constants import (
    DEFAULT_DOCUMENTS_ELSON_DIR,
    DEFAULT_FIXTURE_ROOT,
    DEFAULT_REVIEW_CSV_CANDIDATES,
    DEFAULT_TRANSCRIPT_HISTORY_PATH,
)
from .models import ConversationTurn, IntentEvalFixture, parse_datetime


def load_fixture(path: Path) -> IntentEvalFixture:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    return IntentEvalFixture.from_dict(manifest, fixture_dir=path.parent)


def iter_fixture_manifests(root: Path) -> Iterable[Path]:
    if not root.exists():
        return []
    return sorted(root.rglob("manifest.json"))


def load_fixtures(
    root: Path = DEFAULT_FIXTURE_ROOT,
    *,
    last_days: int | None = None,
    only_labeled: bool = False,
    expected_route: str | None = None,
    allow_partial: bool = False,
) -> list[IntentEvalFixture]:
    fixtures: list[IntentEvalFixture] = []
    cutoff = None
    if last_days is not None:
        cutoff = datetime.now(tz=UTC) - timedelta(days=last_days)
    for manifest_path in iter_fixture_manifests(root):
        fixture = load_fixture(manifest_path)
        if cutoff and fixture.created_at_dt < cutoff:
            continue
        if only_labeled and not fixture.is_labeled:
            continue
        if expected_route and fixture.expected_route != expected_route:
            continue
        if fixture.is_partial and not allow_partial:
            continue
        fixtures.append(fixture)
    return sorted(fixtures, key=lambda item: item.created_at_dt)


def save_fixture(fixture: IntentEvalFixture, fixture_root: Path = DEFAULT_FIXTURE_ROOT) -> Path:
    fixture_dir = fixture_root / fixture.created_at[:10] / fixture.id
    fixture_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = fixture_dir / "manifest.json"
    manifest_path.write_text(
        json.dumps(fixture.to_manifest_dict(), indent=2, ensure_ascii=False, sort_keys=True),
        encoding="utf-8",
    )
    return fixture_dir


def harvest(
    fixture_root: Path,
    local_config: LocalConfig,
    *,
    last_days: int | None = None,
    review_csv: Path | None = None,
    history_file: Path = DEFAULT_TRANSCRIPT_HISTORY_PATH,
) -> dict[str, int]:
    counts = {"review_csv": 0, "history": 0}
    cutoff = None
    if last_days is not None:
        cutoff = datetime.now(tz=UTC) - timedelta(days=last_days)
    review_path = review_csv or first_existing(DEFAULT_REVIEW_CSV_CANDIDATES)
    seen_signatures = existing_signatures(fixture_root)
    if review_path and review_path.exists():
        for index, row in enumerate(csv.DictReader(review_path.open(encoding="utf-8", newline="")), start=1):
            created_at = row.get("created_at") or ""
            if not created_at:
                continue
            created_at_dt = parse_datetime(created_at)
            if cutoff and created_at_dt < cutoff:
                continue
            signature = signature_for(
                created_at=created_at,
                source=row.get("source") or "shortcut",
                text=row.get("text") or "",
                raw_transcript=row.get("raw_transcript") or "",
            )
            if signature in seen_signatures:
                continue
            fixture = IntentEvalFixture(
                id=f"harvest-review-{created_at.replace(':', '-').replace('.', '-')}-{index:04d}",
                created_at=created_at,
                surface="shortcut",
                input_source="audio",
                mode_hint="agent",
                raw_transcript=(row.get("raw_transcript") or None),
                input_text=row.get("text") or row.get("raw_transcript") or "",
                conversation_history=[],
                clipboard_text=None,
                screen_text=None,
                screen_description=None,
                my_elson_markdown="",
                intent_agent_prompt=None,
                working_agent_prompt=None,
                expected_route=(row.get("expected_route") or None),
                audio_decider_provider=local_config.audio_decider_provider,
                fixture_completeness="partial",
                has_real_attachments=False,
                notes=row.get("rationale") or None,
            )
            save_fixture(fixture, fixture_root)
            seen_signatures.add(signature)
            counts["review_csv"] += 1

    if history_file.exists():
        entries = json.loads(history_file.read_text(encoding="utf-8"))
        for index, item in enumerate(entries, start=1):
            created_at = item.get("createdAt") or item.get("created_at")
            if not created_at:
                continue
            created_at_dt = parse_datetime(created_at)
            if cutoff and created_at_dt < cutoff:
                continue
            signature = signature_for(
                created_at=created_at,
                source=item.get("source") or "history",
                text=item.get("text") or "",
                raw_transcript=item.get("rawTranscript") or item.get("raw_transcript") or "",
            )
            if signature in seen_signatures:
                continue
            fixture = IntentEvalFixture(
                id=f"harvest-history-{created_at.replace(':', '-').replace('.', '-')}-{index:04d}",
                created_at=created_at,
                surface="shortcut",
                input_source="audio",
                mode_hint="agent",
                raw_transcript=item.get("rawTranscript") or item.get("raw_transcript"),
                input_text=item.get("text") or item.get("rawTranscript") or "",
                conversation_history=[],
                clipboard_text=None,
                screen_text=None,
                screen_description=None,
                my_elson_markdown="",
                intent_agent_prompt=None,
                working_agent_prompt=None,
                expected_route=None,
                audio_decider_provider=local_config.audio_decider_provider,
                fixture_completeness="partial",
                has_real_attachments=False,
                notes="Harvested from transcript-history.json",
            )
            save_fixture(fixture, fixture_root)
            seen_signatures.add(signature)
            counts["history"] += 1
    return counts


def purge_old_paths(root: Path, *, days: int) -> int:
    if not root.exists():
        return 0
    cutoff = datetime.now(tz=UTC) - timedelta(days=days)
    removed = 0
    for manifest_path in root.rglob("manifest.json"):
        fixture = load_fixture(manifest_path)
        if fixture.created_at_dt >= cutoff:
            continue
        fixture_dir = manifest_path.parent
        for child in sorted(fixture_dir.rglob("*"), reverse=True):
            if child.is_file():
                child.unlink(missing_ok=True)
            elif child.is_dir():
                child.rmdir()
        fixture_dir.rmdir()
        removed += 1
    return removed


def first_existing(paths: list[Path]) -> Path | None:
    for path in paths:
        if path.exists():
            return path
    return None


def existing_signatures(root: Path) -> set[tuple[str, str, str, str]]:
    signatures: set[tuple[str, str, str, str]] = set()
    if not root.exists():
        return signatures
    for manifest_path in root.rglob("manifest.json"):
        fixture = load_fixture(manifest_path)
        signatures.add(
            signature_for(
                created_at=fixture.created_at,
                source=fixture.input_source,
                text=fixture.input_text,
                raw_transcript=fixture.raw_transcript or "",
            )
        )
    return signatures


def signature_for(*, created_at: str, source: str, text: str, raw_transcript: str) -> tuple[str, str, str, str]:
    return (
        created_at.strip(),
        source.strip(),
        text.strip(),
        raw_transcript.strip(),
    )
