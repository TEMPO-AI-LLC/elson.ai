from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


@dataclass(slots=True)
class ConversationTurn:
    role: str
    content: str


@dataclass(slots=True)
class FixtureAttachment:
    kind: str
    name: str
    mime: str
    source: str
    relative_path: str | None = None
    byte_count: int | None = None
    saved: bool = False

    @property
    def is_image(self) -> bool:
        return self.kind == "image" or self.mime.lower().startswith("image/")


@dataclass(slots=True)
class FixtureAppContext:
    frontmost_app_name: str | None = None
    frontmost_app_bundle_id: str | None = None
    frontmost_window_title: str | None = None


@dataclass(slots=True)
class FixtureContinuationContext:
    candidate_thread_id: str | None = None
    minutes_since_last_turn: float | None = None
    last_turn_created_at: str | None = None
    last_message_role: str | None = None
    last_user_message: str | None = None
    last_assistant_message: str | None = None
    last_reply_mode: str | None = None
    current_frontmost_app_name: str | None = None
    current_frontmost_app_bundle_id: str | None = None
    current_frontmost_window_title: str | None = None
    previous_frontmost_app_name: str | None = None
    previous_frontmost_app_bundle_id: str | None = None
    previous_frontmost_window_title: str | None = None
    same_frontmost_app: bool | None = None
    same_frontmost_window_title: bool | None = None
    last_output_was_auto_pasted: bool | None = None


@dataclass(slots=True)
class IntentEvalFixture:
    id: str
    created_at: str
    surface: str
    input_source: str
    mode_hint: str
    raw_transcript: str | None
    input_text: str
    conversation_history: list[ConversationTurn] = field(default_factory=list)
    clipboard_text: str | None = None
    screen_text: str | None = None
    screen_description: str | None = None
    app_context: FixtureAppContext = field(default_factory=FixtureAppContext)
    continuation_context: FixtureContinuationContext | None = None
    my_elson_markdown: str = ""
    intent_agent_prompt: str | None = None
    working_agent_prompt: str | None = None
    system_prompt: str | None = None
    user_prompt: str | None = None
    audio_decider_provider: str | None = None
    model: str | None = None
    temperature: float | None = None
    top_p: float | None = None
    top_k: int | None = None
    thinking_level: str | None = None
    full_agent_allowed: bool = True
    expected_route: str | None = None
    expected_thread_decision: str | None = None
    expected_reply_relation: str | None = None
    provider_api_url: str | None = None
    request_payload_relative_path: str | None = None
    attachments: list[FixtureAttachment] = field(default_factory=list)
    has_real_attachments: bool = False
    fixture_completeness: str = "partial"
    notes: str | None = None
    fixture_dir: Path | None = None

    @property
    def created_at_dt(self) -> datetime:
        return parse_datetime(self.created_at)

    @property
    def is_labeled(self) -> bool:
        return bool(
            self.expected_route
            or self.expected_thread_decision
            or self.expected_reply_relation
        )

    @property
    def is_partial(self) -> bool:
        return self.fixture_completeness != "complete"

    def attachment_path(self, attachment: FixtureAttachment) -> Path | None:
        if not self.fixture_dir or not attachment.relative_path:
            return None
        return self.fixture_dir / attachment.relative_path

    def to_manifest_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["schema_version"] = 3
        payload.pop("fixture_dir", None)
        return payload

    @classmethod
    def from_dict(cls, data: dict[str, Any], fixture_dir: Path | None = None) -> "IntentEvalFixture":
        turns = [
            ConversationTurn(
                role=(item.get("role") or "user"),
                content=item.get("content") or "",
            )
            for item in data.get("conversation_history", [])
        ]
        attachments = [
            FixtureAttachment(
                kind=item.get("kind") or "file",
                name=item.get("name") or "attachment",
                mime=item.get("mime") or "application/octet-stream",
                source=item.get("source") or "unknown",
                relative_path=item.get("relative_path"),
                byte_count=item.get("byte_count"),
                saved=bool(item.get("saved", False)),
            )
            for item in data.get("attachments", [])
        ]
        app_context_raw = data.get("app_context") or {}
        continuation_context_raw = data.get("continuation_context") or None
        return cls(
            id=data["id"],
            created_at=data["created_at"],
            surface=data.get("surface") or "shortcut",
            input_source=data.get("input_source") or "audio",
            mode_hint=data.get("mode_hint") or "agent",
            raw_transcript=data.get("raw_transcript"),
            input_text=data.get("input_text") or data.get("text") or data.get("enhanced_transcript") or data.get("raw_transcript") or "",
            conversation_history=turns,
            clipboard_text=data.get("clipboard_text"),
            screen_text=data.get("screen_text"),
            screen_description=data.get("screen_description"),
            app_context=FixtureAppContext(
                frontmost_app_name=app_context_raw.get("frontmost_app_name"),
                frontmost_app_bundle_id=app_context_raw.get("frontmost_app_bundle_id"),
                frontmost_window_title=app_context_raw.get("frontmost_window_title"),
            ),
            continuation_context=None if continuation_context_raw is None else FixtureContinuationContext(
                candidate_thread_id=continuation_context_raw.get("candidate_thread_id"),
                minutes_since_last_turn=continuation_context_raw.get("minutes_since_last_turn"),
                last_turn_created_at=continuation_context_raw.get("last_turn_created_at"),
                last_message_role=continuation_context_raw.get("last_message_role"),
                last_user_message=continuation_context_raw.get("last_user_message"),
                last_assistant_message=continuation_context_raw.get("last_assistant_message"),
                last_reply_mode=continuation_context_raw.get("last_reply_mode"),
                current_frontmost_app_name=continuation_context_raw.get("current_frontmost_app_name"),
                current_frontmost_app_bundle_id=continuation_context_raw.get("current_frontmost_app_bundle_id"),
                current_frontmost_window_title=continuation_context_raw.get("current_frontmost_window_title"),
                previous_frontmost_app_name=continuation_context_raw.get("previous_frontmost_app_name"),
                previous_frontmost_app_bundle_id=continuation_context_raw.get("previous_frontmost_app_bundle_id"),
                previous_frontmost_window_title=continuation_context_raw.get("previous_frontmost_window_title"),
                same_frontmost_app=continuation_context_raw.get("same_frontmost_app"),
                same_frontmost_window_title=continuation_context_raw.get("same_frontmost_window_title"),
                last_output_was_auto_pasted=continuation_context_raw.get("last_output_was_auto_pasted"),
            ),
            my_elson_markdown=data.get("my_elson_markdown") or "",
            intent_agent_prompt=data.get("intent_agent_prompt"),
            working_agent_prompt=data.get("working_agent_prompt"),
            system_prompt=data.get("system_prompt"),
            user_prompt=data.get("user_prompt"),
            audio_decider_provider=data.get("audio_decider_provider"),
            model=data.get("model"),
            temperature=data.get("temperature"),
            top_p=data.get("top_p"),
            top_k=data.get("top_k"),
            thinking_level=data.get("thinking_level"),
            full_agent_allowed=bool(data.get("full_agent_allowed", True)),
            expected_route=data.get("expected_route"),
            expected_thread_decision=data.get("expected_thread_decision"),
            expected_reply_relation=data.get("expected_reply_relation"),
            provider_api_url=data.get("provider_api_url"),
            request_payload_relative_path=data.get("request_payload_relative_path"),
            attachments=attachments,
            has_real_attachments=bool(data.get("has_real_attachments", False)),
            fixture_completeness=data.get("fixture_completeness") or "partial",
            notes=data.get("notes"),
            fixture_dir=fixture_dir,
        )


@dataclass(slots=True)
class IntentEvalRunResult:
    run_index: int
    route: str | None
    thread_decision: str | None
    reply_relation: str | None
    reply_confidence: float | None
    reason: str | None
    duration_ms: int
    error: str | None = None
    provider: str | None = None
    model: str | None = None


@dataclass(slots=True)
class IntentEvalCaseResult:
    fixture_id: str
    created_at: str
    expected_route: str | None
    expected_thread_decision: str | None
    expected_reply_relation: str | None
    runs: list[IntentEvalRunResult]
    majority_route: str | None
    majority_thread_decision: str | None
    majority_reply_relation: str | None
    route_stable: bool
    thread_decision_stable: bool
    reply_relation_stable: bool
    stable: bool
    route_matches_expected: bool | None
    thread_decision_matches_expected: bool | None
    reply_relation_matches_expected: bool | None
    combined_matches_expected: bool | None
    matches_expected: bool | None
    false_escalation: bool
    false_suppression: bool
    provider: str | None
    model: str | None
    has_real_attachments: bool
    fixture_completeness: str
    notes: str | None = None

    def to_csv_row(self) -> dict[str, Any]:
        row: dict[str, Any] = {
            "fixture_id": self.fixture_id,
            "created_at": self.created_at,
            "expected_route": self.expected_route or "",
            "expected_thread_decision": self.expected_thread_decision or "",
            "expected_reply_relation": self.expected_reply_relation or "",
            "majority_route": self.majority_route or "",
            "majority_thread_decision": self.majority_thread_decision or "",
            "majority_reply_relation": self.majority_reply_relation or "",
            "route_stable": self.route_stable,
            "thread_decision_stable": self.thread_decision_stable,
            "reply_relation_stable": self.reply_relation_stable,
            "stable": self.stable,
            "route_matches_expected": "" if self.route_matches_expected is None else self.route_matches_expected,
            "thread_decision_matches_expected": "" if self.thread_decision_matches_expected is None else self.thread_decision_matches_expected,
            "reply_relation_matches_expected": "" if self.reply_relation_matches_expected is None else self.reply_relation_matches_expected,
            "combined_matches_expected": "" if self.combined_matches_expected is None else self.combined_matches_expected,
            "matches_expected": "" if self.matches_expected is None else self.matches_expected,
            "false_escalation": self.false_escalation,
            "false_suppression": self.false_suppression,
            "provider": self.provider or "",
            "model": self.model or "",
            "has_real_attachments": self.has_real_attachments,
            "fixture_completeness": self.fixture_completeness,
            "notes": self.notes or "",
        }
        for idx, run in enumerate(self.runs, start=1):
            row[f"run_{idx}_route"] = run.route or ""
            row[f"run_{idx}_thread_decision"] = run.thread_decision or ""
            row[f"run_{idx}_reply_relation"] = run.reply_relation or ""
            row[f"run_{idx}_reply_confidence"] = "" if run.reply_confidence is None else run.reply_confidence
            row[f"run_{idx}_reason"] = run.reason or ""
            row[f"run_{idx}_error"] = run.error or ""
            row[f"run_{idx}_duration_ms"] = run.duration_ms
        return row


def parse_datetime(raw: str) -> datetime:
    if raw.endswith("Z"):
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(UTC)
    return datetime.fromisoformat(raw).astimezone(UTC)
