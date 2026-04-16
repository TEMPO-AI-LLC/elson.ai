from __future__ import annotations

import json
import shutil
from dataclasses import asdict, dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
TARGET_ROOT = REPO_ROOT / "evals_python" / "fixtures" / "shortcut-reply"
WORDS_MARKDOWN = "## Words\n- Elson\n- Alex\n- Figma\n- Notion\n- Mail\n"


@dataclass(slots=True)
class AppContext:
    frontmost_app_name: str | None
    frontmost_app_bundle_id: str | None
    frontmost_window_title: str | None


@dataclass(slots=True)
class ContinuationContext:
    candidate_thread_id: str | None
    minutes_since_last_turn: float | None
    last_turn_created_at: str | None
    last_message_role: str | None
    last_user_message: str | None
    last_assistant_message: str | None
    last_reply_mode: str | None
    current_frontmost_app_name: str | None
    current_frontmost_app_bundle_id: str | None
    current_frontmost_window_title: str | None
    previous_frontmost_app_name: str | None
    previous_frontmost_app_bundle_id: str | None
    previous_frontmost_window_title: str | None
    same_frontmost_app: bool | None
    same_frontmost_window_title: bool | None
    last_output_was_auto_pasted: bool | None


def app(name: str, bundle: str, window: str) -> AppContext:
    return AppContext(name, bundle, window)


def continuation(
    *,
    candidate_thread_id: str,
    minutes_since_last_turn: float,
    last_turn_created_at: str,
    last_message_role: str,
    last_user_message: str,
    last_assistant_message: str,
    last_reply_mode: str,
    current: AppContext,
    previous: AppContext,
    last_output_was_auto_pasted: bool,
) -> ContinuationContext:
    return ContinuationContext(
        candidate_thread_id=candidate_thread_id,
        minutes_since_last_turn=minutes_since_last_turn,
        last_turn_created_at=last_turn_created_at,
        last_message_role=last_message_role,
        last_user_message=last_user_message,
        last_assistant_message=last_assistant_message,
        last_reply_mode=last_reply_mode,
        current_frontmost_app_name=current.frontmost_app_name,
        current_frontmost_app_bundle_id=current.frontmost_app_bundle_id,
        current_frontmost_window_title=current.frontmost_window_title,
        previous_frontmost_app_name=previous.frontmost_app_name,
        previous_frontmost_app_bundle_id=previous.frontmost_app_bundle_id,
        previous_frontmost_window_title=previous.frontmost_window_title,
        same_frontmost_app=current.frontmost_app_bundle_id == previous.frontmost_app_bundle_id,
        same_frontmost_window_title=current.frontmost_window_title == previous.frontmost_window_title,
        last_output_was_auto_pasted=last_output_was_auto_pasted,
    )


def manifest(
    *,
    fixture_id: str,
    created_at: str,
    raw_transcript: str,
    enhanced_transcript: str,
    expected_route: str,
    expected_thread_decision: str,
    expected_reply_relation: str,
    notes: str,
    app_context: AppContext,
    continuation_context: ContinuationContext | None = None,
    screen_text: str | None = None,
    screen_description: str | None = None,
    clipboard_text: str | None = None,
) -> dict:
    return {
        "schema_version": 2,
        "id": fixture_id,
        "created_at": created_at,
        "surface": "shortcut",
        "input_source": "audio",
        "mode_hint": "agent",
        "raw_transcript": raw_transcript,
        "enhanced_transcript": enhanced_transcript,
        "conversation_history": [],
        "clipboard_text": clipboard_text,
        "screen_text": screen_text,
        "screen_description": screen_description,
        "app_context": asdict(app_context),
        "continuation_context": None if continuation_context is None else asdict(continuation_context),
        "my_elson_markdown": WORDS_MARKDOWN,
        "intent_agent_prompt": None,
        "working_agent_prompt": None,
        "system_prompt": None,
        "user_prompt": None,
        "audio_decider_provider": None,
        "model": None,
        "temperature": None,
        "top_p": None,
        "top_k": None,
        "thinking_level": None,
        "full_agent_allowed": True,
        "expected_route": expected_route,
        "expected_thread_decision": expected_thread_decision,
        "expected_reply_relation": expected_reply_relation,
        "provider_api_url": None,
        "request_payload_relative_path": None,
        "attachments": [],
        "has_real_attachments": False,
        "fixture_completeness": "complete",
        "notes": notes,
    }


def build_cases() -> list[dict]:
    gmail_inbox = app("Mail", "com.google.Chrome", "Inbox - user@example.com - Mail")
    gmail_thread = app("Mail", "com.google.Chrome", "Alex Martin - Sprint Review - Mail")
    notion_doc = app("Notion", "notion.id", "Prompt routing notes")
    notion_other = app("Notion", "notion.id", "Quarterly planning")
    figma_file = app("Figma", "com.figma.Desktop", "Training UX Copy")
    figma_other = app("Figma", "com.figma.Desktop", "Billing flow")
    slack_channel = app("Slack", "com.tinyspeck.slackmacgap", "team-product | Slack")

    return [
        manifest(
            fixture_id="synthetic-transcript-new-01",
            created_at="2026-04-06T10:00:00Z",
            raw_transcript="schreib an tim danke fuer das update ich melde mich morgen mit feedback",
            enhanced_transcript="Danke fuer das Update. Ich melde mich morgen mit Feedback.",
            expected_route="direct_transcript",
            expected_thread_decision="start_new_thread",
            expected_reply_relation="none",
            notes="transcript_new standalone email dictation",
            app_context=gmail_inbox,
        ),
        manifest(
            fixture_id="synthetic-transcript-new-02",
            created_at="2026-04-06T10:01:00Z",
            raw_transcript="das ist produktfeedback bitte die copy nicht weicher machen sondern direkter und klarer",
            enhanced_transcript="Bitte die Copy nicht weicher machen, sondern direkter und klarer.",
            expected_route="direct_transcript",
            expected_thread_decision="start_new_thread",
            expected_reply_relation="none",
            notes="transcript_new product feedback despite recent candidate thread",
            app_context=figma_file,
            continuation_context=continuation(
                candidate_thread_id="thread-transcript-reply-keep-tone",
                minutes_since_last_turn=1.4,
                last_turn_created_at="2026-04-06T09:59:00Z",
                last_message_role="assistant",
                last_user_message="Schreib: Das klingt gut, aber ich brauche noch einen Tag.",
                last_assistant_message="Das klingt gut, aber ich brauche noch einen Tag.",
                last_reply_mode="transcript",
                current=figma_file,
                previous=figma_file,
                last_output_was_auto_pasted=True,
            ),
        ),
        manifest(
            fixture_id="synthetic-transcript-new-03",
            created_at="2026-04-06T10:02:00Z",
            raw_transcript="wie wuerde ich das bauen component fuer component mit edge cases und migration",
            enhanced_transcript="Wie wuerde ich das bauen, Component fuer Component, mit Edge Cases und Migration?",
            expected_route="direct_transcript",
            expected_thread_decision="start_new_thread",
            expected_reply_relation="none",
            notes="transcript_new architecture brainstorming remains authored text",
            app_context=notion_doc,
            continuation_context=continuation(
                candidate_thread_id="thread-agent-summary-email",
                minutes_since_last_turn=2.7,
                last_turn_created_at="2026-04-06T09:59:20Z",
                last_message_role="assistant",
                last_user_message="Fass mir diese Mail in zwei Saetzen zusammen.",
                last_assistant_message="Es geht um den verschobenen Termin und den neuen Budgetrahmen.",
                last_reply_mode="reply",
                current=notion_doc,
                previous=gmail_thread,
                last_output_was_auto_pasted=False,
            ),
        ),
        manifest(
            fixture_id="synthetic-transcript-new-04",
            created_at="2026-04-06T10:03:00Z",
            raw_transcript="enhance den prompt und lade dann bitte die skills runter und fuehr das setup aus",
            enhanced_transcript="Enhance den Prompt und lade dann bitte die Skills runter und fuehr das Setup aus.",
            expected_route="direct_transcript",
            expected_thread_decision="start_new_thread",
            expected_reply_relation="none",
            notes="transcript_new unsupported external execution stays transcript",
            app_context=notion_other,
            continuation_context=continuation(
                candidate_thread_id="thread-agent-state-check",
                minutes_since_last_turn=0.9,
                last_turn_created_at="2026-04-06T10:02:06Z",
                last_message_role="assistant",
                last_user_message="Bist du gerade im Agent Mode?",
                last_assistant_message="Ja, Agent Mode ist aktiv.",
                last_reply_mode="reply",
                current=notion_other,
                previous=notion_other,
                last_output_was_auto_pasted=False,
            ),
        ),
        manifest(
            fixture_id="synthetic-transcript-new-05",
            created_at="2026-04-06T10:04:00Z",
            raw_transcript="ok super danke fuer gestern wir schicken das deck morgen",
            enhanced_transcript="OK, super, danke fuer gestern. Wir schicken das Deck morgen.",
            expected_route="direct_transcript",
            expected_thread_decision="start_new_thread",
            expected_reply_relation="none",
            notes="transcript_new casual outward message, not command",
            app_context=slack_channel,
        ),
        manifest(
            fixture_id="synthetic-agent-new-01",
            created_at="2026-04-06T10:05:00Z",
            raw_transcript="fass mir diese mail in zwei saetzen zusammen",
            enhanced_transcript="Fass mir diese Mail in zwei Saetzen zusammen.",
            expected_route="full_agent",
            expected_thread_decision="start_new_thread",
            expected_reply_relation="none",
            notes="agent_new summarize visible email",
            app_context=gmail_thread,
            screen_text="From: Alex Martin\nSubject: Sprint Review verschoben\nHallo Team, wir verschieben den Termin auf Donnerstag 14 Uhr.",
            screen_description="Visible email thread about a moved sprint review meeting.",
        ),
        manifest(
            fixture_id="synthetic-agent-new-02",
            created_at="2026-04-06T10:06:00Z",
            raw_transcript="wer hat diese nachricht geschrieben",
            enhanced_transcript="Wer hat diese Nachricht geschrieben?",
            expected_route="full_agent",
            expected_thread_decision="start_new_thread",
            expected_reply_relation="none",
            notes="agent_new visible sender question even with prior candidate",
            app_context=gmail_thread,
            screen_text="From: Casey Parker\nSubject: Budget review\nHallo Team, anbei das aktualisierte Budget.",
            screen_description="Visible email with sender Casey Parker.",
            continuation_context=continuation(
                candidate_thread_id="thread-transcript-new-feedback",
                minutes_since_last_turn=1.1,
                last_turn_created_at="2026-04-06T10:04:50Z",
                last_message_role="assistant",
                last_user_message="Bitte die Copy nicht weicher machen, sondern direkter und klarer.",
                last_assistant_message="Bitte die Copy nicht weicher machen, sondern direkter und klarer.",
                last_reply_mode="transcript",
                current=gmail_thread,
                previous=figma_file,
                last_output_was_auto_pasted=True,
            ),
        ),
        manifest(
            fixture_id="synthetic-agent-new-03",
            created_at="2026-04-06T10:07:00Z",
            raw_transcript="bist du gerade im agent mode",
            enhanced_transcript="Bist du gerade im Agent Mode?",
            expected_route="full_agent",
            expected_thread_decision="start_new_thread",
            expected_reply_relation="none",
            notes="agent_new explicit Elson app-state question",
            app_context=slack_channel,
        ),
        manifest(
            fixture_id="synthetic-agent-new-04",
            created_at="2026-04-06T10:08:00Z",
            raw_transcript="erinnere mich morgen um neun an den kunde call",
            enhanced_transcript="Erinnere mich morgen um neun an den Kunden-Call.",
            expected_route="full_agent",
            expected_thread_decision="start_new_thread",
            expected_reply_relation="none",
            notes="agent_new reminder capture",
            app_context=notion_doc,
        ),
        manifest(
            fixture_id="synthetic-agent-new-05",
            created_at="2026-04-06T10:09:00Z",
            raw_transcript="mach einen screenshot",
            enhanced_transcript="Mach einen Screenshot.",
            expected_route="full_agent",
            expected_thread_decision="start_new_thread",
            expected_reply_relation="none",
            notes="agent_new local screenshot action",
            app_context=figma_other,
        ),
        manifest(
            fixture_id="synthetic-transcript-reply-01",
            created_at="2026-04-06T10:10:00Z",
            raw_transcript="nee so nicht schreib lieber danke ich melde mich morgen",
            enhanced_transcript="Nee, so nicht. Schreib lieber: Danke, ich melde mich morgen.",
            expected_route="direct_transcript",
            expected_thread_decision="continue_current_thread",
            expected_reply_relation="reply_to_last_assistant",
            notes="transcript_reply correction of previous transcript output",
            app_context=gmail_inbox,
            continuation_context=continuation(
                candidate_thread_id="thread-email-draft-01",
                minutes_since_last_turn=0.6,
                last_turn_created_at="2026-04-06T10:09:24Z",
                last_message_role="assistant",
                last_user_message="Danke fuer das Update. Ich melde mich morgen mit Feedback.",
                last_assistant_message="Danke fuer das Update. Ich melde mich morgen mit Feedback.",
                last_reply_mode="transcript",
                current=gmail_inbox,
                previous=gmail_inbox,
                last_output_was_auto_pasted=True,
            ),
        ),
        manifest(
            fixture_id="synthetic-transcript-reply-02",
            created_at="2026-04-06T10:11:00Z",
            raw_transcript="aendere koennen zu verstehen",
            enhanced_transcript="Aendere 'koennen' zu 'verstehen'.",
            expected_route="direct_transcript",
            expected_thread_decision="continue_current_thread",
            expected_reply_relation="reply_to_last_assistant",
            notes="transcript_reply wording correction",
            app_context=figma_file,
            continuation_context=continuation(
                candidate_thread_id="thread-training-copy-01",
                minutes_since_last_turn=1.2,
                last_turn_created_at="2026-04-06T10:09:48Z",
                last_message_role="assistant",
                last_user_message="Tim hat schreiben koennen, aber du hast bei dem Lernziel immer noch verstehen genommen.",
                last_assistant_message="Tim hat schreiben koennen, aber du hast bei dem Lernziel immer noch verstehen genommen.",
                last_reply_mode="transcript",
                current=figma_file,
                previous=figma_file,
                last_output_was_auto_pasted=True,
            ),
        ),
        manifest(
            fixture_id="synthetic-transcript-reply-03",
            created_at="2026-04-06T10:12:00Z",
            raw_transcript="das ist als frage an tim gemeint warum hast du understand geschrieben statt can",
            enhanced_transcript="Das ist als Frage an Tim gemeint: Warum hast du 'understand' geschrieben statt 'can'?",
            expected_route="direct_transcript",
            expected_thread_decision="continue_current_thread",
            expected_reply_relation="reply_to_last_assistant",
            notes="transcript_reply wording dispute meant to be sent onward",
            app_context=figma_file,
            continuation_context=continuation(
                candidate_thread_id="thread-training-copy-02",
                minutes_since_last_turn=3.4,
                last_turn_created_at="2026-04-06T10:08:36Z",
                last_message_role="assistant",
                last_user_message="Tim hat geschrieben koennen, aber du hast bei dem Lernziel immer noch verstehen genommen.",
                last_assistant_message="Die Anpassung beruht auf meiner methodischen Empfehlung fuer Selbstlerneinheiten.",
                last_reply_mode="reply",
                current=figma_file,
                previous=figma_file,
                last_output_was_auto_pasted=False,
            ),
        ),
        manifest(
            fixture_id="synthetic-transcript-reply-04",
            created_at="2026-04-06T10:13:00Z",
            raw_transcript="streich den letzten satz und ersetz ihn durch wir priorisieren das im naechsten sprint",
            enhanced_transcript="Streich den letzten Satz und ersetz ihn durch: Wir priorisieren das im naechsten Sprint.",
            expected_route="direct_transcript",
            expected_thread_decision="continue_current_thread",
            expected_reply_relation="reply_to_last_user",
            notes="transcript_reply correction to user's last drafted wording",
            app_context=notion_doc,
            continuation_context=continuation(
                candidate_thread_id="thread-spec-draft-01",
                minutes_since_last_turn=4.1,
                last_turn_created_at="2026-04-06T10:08:54Z",
                last_message_role="assistant",
                last_user_message="Wir shippen das in zwei Phasen. Der letzte Satz ist noch offen.",
                last_assistant_message="Wir shippen das in zwei Phasen. Der letzte Satz ist noch offen.",
                last_reply_mode="transcript",
                current=notion_doc,
                previous=notion_doc,
                last_output_was_auto_pasted=True,
            ),
        ),
        manifest(
            fixture_id="synthetic-transcript-reply-05",
            created_at="2026-04-06T10:14:00Z",
            raw_transcript="nein das du soll drinbleiben schreib du hattest das doch schon erklaert",
            enhanced_transcript="Nein, das 'du' soll drinbleiben. Schreib: Du hattest das doch schon erklaert.",
            expected_route="direct_transcript",
            expected_thread_decision="continue_current_thread",
            expected_reply_relation="reply_to_last_assistant",
            notes="transcript_reply pronoun correction with same app but different window",
            app_context=slack_channel,
            continuation_context=continuation(
                candidate_thread_id="thread-slack-reply-01",
                minutes_since_last_turn=6.8,
                last_turn_created_at="2026-04-06T10:07:12Z",
                last_message_role="assistant",
                last_user_message="Schreib: Ihr hattet das doch schon erklaert.",
                last_assistant_message="Ihr hattet das doch schon erklaert.",
                last_reply_mode="transcript",
                current=slack_channel,
                previous=app("Slack", "com.tinyspeck.slackmacgap", "design-ops | Slack"),
                last_output_was_auto_pasted=True,
            ),
        ),
        manifest(
            fixture_id="synthetic-agent-reply-01",
            created_at="2026-04-06T10:15:00Z",
            raw_transcript="und was bedeutet der zweite punkt genau",
            enhanced_transcript="Und was bedeutet der zweite Punkt genau?",
            expected_route="full_agent",
            expected_thread_decision="continue_current_thread",
            expected_reply_relation="reply_to_last_assistant",
            notes="agent_reply follow-up on assistant summary",
            app_context=gmail_thread,
            screen_text="1. Termin verschoben auf Donnerstag.\n2. Budgetrahmen muss vorab bestaetigt werden.",
            screen_description="Visible bullet summary in the email thread.",
            continuation_context=continuation(
                candidate_thread_id="thread-email-summary-01",
                minutes_since_last_turn=0.7,
                last_turn_created_at="2026-04-06T10:14:18Z",
                last_message_role="assistant",
                last_user_message="Fass mir diese Mail in zwei Saetzen zusammen.",
                last_assistant_message="Der Termin wurde auf Donnerstag verschoben. Vorher muss noch der Budgetrahmen bestaetigt werden.",
                last_reply_mode="reply",
                current=gmail_thread,
                previous=gmail_thread,
                last_output_was_auto_pasted=False,
            ),
        ),
        manifest(
            fixture_id="synthetic-agent-reply-02",
            created_at="2026-04-06T10:16:00Z",
            raw_transcript="wer hat die mail denn geschickt",
            enhanced_transcript="Wer hat die Mail denn geschickt?",
            expected_route="full_agent",
            expected_thread_decision="continue_current_thread",
            expected_reply_relation="reply_to_last_assistant",
            notes="agent_reply asks for sender after prior summary",
            app_context=gmail_thread,
            screen_text="From: Casey Parker\nSubject: Budget review",
            screen_description="Visible email thread with sender Casey Parker.",
            continuation_context=continuation(
                candidate_thread_id="thread-email-summary-02",
                minutes_since_last_turn=1.5,
                last_turn_created_at="2026-04-06T10:14:30Z",
                last_message_role="assistant",
                last_user_message="Fass mir diese Mail in zwei Saetzen zusammen.",
                last_assistant_message="Es geht um das aktualisierte Budget und die naechsten Freigaben.",
                last_reply_mode="reply",
                current=gmail_thread,
                previous=gmail_thread,
                last_output_was_auto_pasted=False,
            ),
        ),
        manifest(
            fixture_id="synthetic-agent-reply-03",
            created_at="2026-04-06T10:17:00Z",
            raw_transcript="kannst du das jetzt als reminder fuer morgen speichern",
            enhanced_transcript="Kannst du das jetzt als Reminder fuer morgen speichern?",
            expected_route="full_agent",
            expected_thread_decision="continue_current_thread",
            expected_reply_relation="reply_to_last_user",
            notes="agent_reply turns prior user note into reminder",
            app_context=notion_doc,
            continuation_context=continuation(
                candidate_thread_id="thread-note-to-reminder-01",
                minutes_since_last_turn=2.2,
                last_turn_created_at="2026-04-06T10:14:48Z",
                last_message_role="assistant",
                last_user_message="Morgen um neun Kunde wegen Vertrag anrufen.",
                last_assistant_message="Morgen um neun Kunde wegen Vertrag anrufen.",
                last_reply_mode="transcript",
                current=notion_doc,
                previous=notion_doc,
                last_output_was_auto_pasted=True,
            ),
        ),
        manifest(
            fixture_id="synthetic-agent-reply-04",
            created_at="2026-04-06T10:18:00Z",
            raw_transcript="und bist du sicher dass das die aktuelle version ist",
            enhanced_transcript="Und bist du sicher, dass das die aktuelle Version ist?",
            expected_route="full_agent",
            expected_thread_decision="continue_current_thread",
            expected_reply_relation="reply_to_last_assistant",
            notes="agent_reply challenge on assistant context answer",
            app_context=figma_other,
            screen_text="File name: Billing flow v17\nUpdated: Today 08:12",
            screen_description="Visible Figma file header for Billing flow v17.",
            continuation_context=continuation(
                candidate_thread_id="thread-figma-version-01",
                minutes_since_last_turn=5.9,
                last_turn_created_at="2026-04-06T10:12:06Z",
                last_message_role="assistant",
                last_user_message="Welche Version ist das gerade?",
                last_assistant_message="Das ist aktuell Billing flow v17.",
                last_reply_mode="reply",
                current=figma_other,
                previous=figma_other,
                last_output_was_auto_pasted=False,
            ),
        ),
        manifest(
            fixture_id="synthetic-agent-reply-05",
            created_at="2026-04-06T10:19:00Z",
            raw_transcript="was stand direkt unter der ueberschrift",
            enhanced_transcript="Was stand direkt unter der Ueberschrift?",
            expected_route="full_agent",
            expected_thread_decision="continue_current_thread",
            expected_reply_relation="reply_to_last_assistant",
            notes="agent_reply asks for another fact from visible context",
            app_context=notion_other,
            screen_text="Q2 Planning\nHiring freeze remains in effect until July.\nTravel budgets unchanged.",
            screen_description="Visible Notion document with heading Q2 Planning and two lines below it.",
            continuation_context=continuation(
                candidate_thread_id="thread-notion-heading-01",
                minutes_since_last_turn=3.3,
                last_turn_created_at="2026-04-06T10:15:42Z",
                last_message_role="assistant",
                last_user_message="Wie lautet die Ueberschrift?",
                last_assistant_message="Die Ueberschrift lautet Q2 Planning.",
                last_reply_mode="reply",
                current=notion_other,
                previous=notion_other,
                last_output_was_auto_pasted=False,
            ),
        ),
    ]


def write_cases(cases: list[dict]) -> None:
    if TARGET_ROOT.exists():
        shutil.rmtree(TARGET_ROOT)
    for case in cases:
        fixture_dir = TARGET_ROOT / case["created_at"][:10] / case["id"]
        fixture_dir.mkdir(parents=True, exist_ok=True)
        (fixture_dir / "manifest.json").write_text(
            json.dumps(case, indent=2, ensure_ascii=False, sort_keys=True),
            encoding="utf-8",
        )


if __name__ == "__main__":
    write_cases(build_cases())
    print(f"wrote {len(build_cases())} fixtures to {TARGET_ROOT}")
