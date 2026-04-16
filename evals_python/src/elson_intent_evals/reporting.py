from __future__ import annotations

import csv
import json
from dataclasses import asdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .constants import DEFAULT_RESULTS_ROOT
from .models import IntentEvalCaseResult
from .providers import installed_lighteval_version


def write_reports(
    results: list[IntentEvalCaseResult],
    *,
    output_dir: Path | None = None,
    metadata: dict[str, Any] | None = None,
) -> Path:
    target = output_dir or default_output_dir()
    target.mkdir(parents=True, exist_ok=True)
    meta = {
        "generated_at": datetime.now(tz=UTC).isoformat(),
        "lighteval_version": installed_lighteval_version(),
    }
    if metadata:
        meta.update(metadata)
    (target / "report.json").write_text(
        json.dumps(
            {
                "metadata": meta,
                "results": [asdict(result) for result in results],
            },
            indent=2,
            ensure_ascii=False,
            sort_keys=True,
        ),
        encoding="utf-8",
    )

    csv_rows = [result.to_csv_row() for result in results]
    csv_path = target / "report.csv"
    fieldnames = list(csv_rows[0].keys()) if csv_rows else []
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        if fieldnames:
            writer.writeheader()
            writer.writerows(csv_rows)

    (target / "summary.md").write_text(render_summary(results, meta), encoding="utf-8")
    return target


def render_summary(results: list[IntentEvalCaseResult], metadata: dict[str, Any]) -> str:
    labeled = [item for item in results if item.expected_route]
    route_labeled = [item for item in results if item.expected_route]
    thread_labeled = [item for item in results if item.expected_thread_decision]
    reply_labeled = [item for item in results if item.expected_reply_relation]
    combined_labeled = [
        item for item in results
        if item.expected_route or item.expected_thread_decision or item.expected_reply_relation
    ]
    route_matches = [item for item in route_labeled if item.route_matches_expected]
    thread_matches = [item for item in thread_labeled if item.thread_decision_matches_expected]
    reply_matches = [item for item in reply_labeled if item.reply_relation_matches_expected]
    combined_matches = [item for item in combined_labeled if item.combined_matches_expected]
    false_escalations = sum(1 for item in results if item.false_escalation)
    false_suppressions = sum(1 for item in results if item.false_suppression)
    unstable = sum(1 for item in results if not item.stable)
    lines = [
        "# Intent Eval Summary",
        "",
        f"- generated_at: `{metadata['generated_at']}`",
        f"- lighteval_version: `{metadata.get('lighteval_version') or 'not installed'}`",
        f"- total_cases: `{len(results)}`",
        f"- labeled_route_cases: `{len(route_labeled)}`",
        f"- labeled_thread_cases: `{len(thread_labeled)}`",
        f"- labeled_reply_cases: `{len(reply_labeled)}`",
        f"- route_matches_expected: `{len(route_matches)}`",
        f"- thread_matches_expected: `{len(thread_matches)}`",
        f"- reply_matches_expected: `{len(reply_matches)}`",
        f"- combined_exact_matches: `{len(combined_matches)}`",
        f"- false_escalations: `{false_escalations}`",
        f"- false_suppressions: `{false_suppressions}`",
        f"- unstable_cases: `{unstable}`",
        "",
        "## Failing Cases",
        "",
    ]
    failing = [
        item for item in combined_labeled
        if item.combined_matches_expected is False or not item.stable
    ]
    if not failing:
        lines.append("- None")
    else:
        for item in failing:
            lines.append(
                f"- `{item.fixture_id}` route `{item.expected_route or '-'}->{item.majority_route or '-'}` "
                f"thread `{item.expected_thread_decision or '-'}->{item.majority_thread_decision or '-'}` "
                f"reply `{item.expected_reply_relation or '-'}->{item.majority_reply_relation or '-'}` "
                f"stable=`{item.stable}`"
            )
    lines.append("")
    return "\n".join(lines)


def default_output_dir() -> Path:
    stamp = datetime.now(tz=UTC).strftime("%Y%m%d-%H%M%S")
    return DEFAULT_RESULTS_ROOT / stamp
