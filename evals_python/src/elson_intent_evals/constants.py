from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_FIXTURE_ROOT = (
    Path.home()
    / "Library"
    / "Application Support"
    / "Elson"
    / "Evals"
    / "intent-fixtures"
)
DEFAULT_RESULTS_ROOT = REPO_ROOT / "evals_python" / "results"
DEFAULT_LOCAL_CONFIG_PATH = (
    Path.home()
    / "Library"
    / "Application Support"
    / "Elson"
    / "local-config.json"
)
DEFAULT_TRANSCRIPT_HISTORY_PATH = (
    Path.home()
    / "Library"
    / "Application Support"
    / "Elson"
    / "transcript-history.json"
)
DEFAULT_DOCUMENTS_ELSON_DIR = Path.home() / "Documents" / "Elson"
DEFAULT_REVIEW_CSV_CANDIDATES = [
    REPO_ROOT / "all_logged_transcripts_agent_review.csv",
    DEFAULT_DOCUMENTS_ELSON_DIR / "all_logged_transcripts_agent_review.csv",
]
DEFAULT_MODEL_CONFIG_PATH = REPO_ROOT / "Elson" / "Resources" / "model-config.json"

INTENT_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "route": {
            "type": "string",
            "enum": ["direct_transcript", "full_agent"],
        },
        "thread_decision": {
            "type": "string",
            "enum": ["continue_current_thread", "start_new_thread"],
        },
        "reply_relation": {
            "type": "string",
            "enum": ["reply_to_last_assistant", "reply_to_last_user", "none"],
        },
        "reply_confidence": {
            "type": ["number", "null"],
            "description": "Optional confidence from 0.0 to 1.0 for the reply-vs-new-thread decision.",
        },
        "reason": {
            "type": "string",
            "description": "Short reason for the routing choice.",
        },
    },
    "required": ["route", "thread_decision", "reply_relation", "reason"],
}
