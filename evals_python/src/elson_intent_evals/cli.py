from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path

from .config import load_local_config
from .constants import DEFAULT_FIXTURE_ROOT
from .fixtures import harvest, load_fixtures, purge_old_paths
from .models import IntentEvalCaseResult
from .providers import replay_fixture
from .reporting import write_reports


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="elson-intent-evals")
    subparsers = parser.add_subparsers(dest="command", required=True)

    harvest_parser = subparsers.add_parser("harvest")
    harvest_parser.add_argument("--fixtures", type=Path, default=DEFAULT_FIXTURE_ROOT)
    harvest_parser.add_argument("--last-days", type=int)
    harvest_parser.add_argument("--review-csv", type=Path)

    replay_parser = subparsers.add_parser("replay")
    replay_parser.add_argument("--fixtures", type=Path, default=DEFAULT_FIXTURE_ROOT)
    replay_parser.add_argument("--last-days", type=int)
    replay_parser.add_argument("--runs", type=int, default=2)
    replay_parser.add_argument("--provider", choices=["google", "cerebras", "config"], default="config")
    replay_parser.add_argument("--only-labeled", action="store_true")
    replay_parser.add_argument("--expected-route", choices=["direct_transcript", "full_agent"])
    replay_parser.add_argument("--output-dir", type=Path)
    replay_parser.add_argument("--allow-partial-fixtures", action="store_true")

    purge_parser = subparsers.add_parser("purge")
    purge_parser.add_argument("--fixtures", type=Path, default=DEFAULT_FIXTURE_ROOT)
    purge_parser.add_argument("--days", type=int, required=True)

    return parser


def main() -> None:
    args = build_parser().parse_args()
    local_config = load_local_config()

    if args.command == "harvest":
        counts = harvest(
            fixture_root=args.fixtures,
            local_config=local_config,
            last_days=args.last_days,
            review_csv=args.review_csv,
        )
        print(f"harvested review_csv={counts['review_csv']} history={counts['history']} into {args.fixtures}")
        return

    if args.command == "purge":
        removed = purge_old_paths(args.fixtures, days=args.days)
        print(f"purged_fixtures={removed} root={args.fixtures}")
        return

    if args.command == "replay":
        fixtures = load_fixtures(
            args.fixtures,
            last_days=args.last_days,
            only_labeled=args.only_labeled,
            expected_route=args.expected_route,
            allow_partial=args.allow_partial_fixtures,
        )
        if not fixtures:
            print("no fixtures matched the filters")
            return

        results: list[IntentEvalCaseResult] = []
        for fixture in fixtures:
            runs, provider, model = replay_fixture(
                fixture,
                requested_provider=args.provider,
                local_config=local_config,
                runs=args.runs,
            )
            non_empty_routes = [run.route for run in runs if run.route]
            non_empty_thread_decisions = [run.thread_decision for run in runs if run.thread_decision]
            non_empty_reply_relations = [run.reply_relation for run in runs if run.reply_relation]
            majority_route = None
            if non_empty_routes:
                majority_route = Counter(non_empty_routes).most_common(1)[0][0]
            majority_thread_decision = None
            if non_empty_thread_decisions:
                majority_thread_decision = Counter(non_empty_thread_decisions).most_common(1)[0][0]
            majority_reply_relation = None
            if non_empty_reply_relations:
                majority_reply_relation = Counter(non_empty_reply_relations).most_common(1)[0][0]

            route_stable = len(set(non_empty_routes)) <= 1 if non_empty_routes else False
            thread_decision_stable = len(set(non_empty_thread_decisions)) <= 1 if non_empty_thread_decisions else False
            reply_relation_stable = len(set(non_empty_reply_relations)) <= 1 if non_empty_reply_relations else False
            stable = route_stable and thread_decision_stable and reply_relation_stable

            route_matches_expected = None
            thread_decision_matches_expected = None
            reply_relation_matches_expected = None
            combined_matches_expected = None
            matches_expected = None
            false_escalation = False
            false_suppression = False
            if fixture.expected_route:
                route_matches_expected = majority_route == fixture.expected_route
                false_escalation = (
                    fixture.expected_route == "direct_transcript"
                    and majority_route == "full_agent"
                )
                false_suppression = (
                    fixture.expected_route == "full_agent"
                    and majority_route == "direct_transcript"
                )
            if fixture.expected_thread_decision:
                thread_decision_matches_expected = (
                    majority_thread_decision == fixture.expected_thread_decision
                )
            if fixture.expected_reply_relation:
                reply_relation_matches_expected = (
                    majority_reply_relation == fixture.expected_reply_relation
                )

            labeled_dimensions: list[bool] = []
            if route_matches_expected is not None:
                labeled_dimensions.append(route_matches_expected)
            if thread_decision_matches_expected is not None:
                labeled_dimensions.append(thread_decision_matches_expected)
            if reply_relation_matches_expected is not None:
                labeled_dimensions.append(reply_relation_matches_expected)
            if labeled_dimensions:
                combined_matches_expected = all(labeled_dimensions)
                matches_expected = combined_matches_expected
            results.append(
                IntentEvalCaseResult(
                    fixture_id=fixture.id,
                    created_at=fixture.created_at,
                    expected_route=fixture.expected_route,
                    expected_thread_decision=fixture.expected_thread_decision,
                    expected_reply_relation=fixture.expected_reply_relation,
                    runs=runs,
                    majority_route=majority_route,
                    majority_thread_decision=majority_thread_decision,
                    majority_reply_relation=majority_reply_relation,
                    route_stable=route_stable,
                    thread_decision_stable=thread_decision_stable,
                    reply_relation_stable=reply_relation_stable,
                    stable=stable,
                    route_matches_expected=route_matches_expected,
                    thread_decision_matches_expected=thread_decision_matches_expected,
                    reply_relation_matches_expected=reply_relation_matches_expected,
                    combined_matches_expected=combined_matches_expected,
                    matches_expected=matches_expected,
                    false_escalation=false_escalation,
                    false_suppression=false_suppression,
                    provider=provider,
                    model=model,
                    has_real_attachments=fixture.has_real_attachments,
                    fixture_completeness=fixture.fixture_completeness,
                    notes=fixture.notes,
                )
            )

        report_dir = write_reports(
            results,
            output_dir=args.output_dir,
            metadata={
                "fixture_root": str(args.fixtures),
                "requested_provider": args.provider,
                "runs": args.runs,
                "allow_partial_fixtures": args.allow_partial_fixtures,
            },
        )
        print(f"replayed_cases={len(results)} report_dir={report_dir}")
