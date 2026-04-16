from __future__ import annotations

import json
import re
import time
import base64
from importlib.metadata import PackageNotFoundError, version
from typing import Any

import httpx

from .config import (
    LocalConfig,
    api_key_for_provider,
    load_model_config,
    provider_choice,
    stage_config_for_provider,
)
from .constants import INTENT_RESPONSE_SCHEMA
from .models import IntentEvalFixture, IntentEvalRunResult
from .prompt_config import prompt_string


def installed_lighteval_version() -> str | None:
    try:
        return version("lighteval")
    except PackageNotFoundError:
        return None


def replay_fixture(
    fixture: IntentEvalFixture,
    *,
    requested_provider: str | None,
    local_config: LocalConfig,
    runs: int,
) -> tuple[list[IntentEvalRunResult], str | None, str | None]:
    provider = provider_choice(requested_provider, local_config, fixture.audio_decider_provider)
    key = api_key_for_provider(provider, local_config)
    if not key:
        raise RuntimeError(f"Missing API key for provider {provider}.")

    model_config = load_model_config()
    stage = stage_config_for_provider(provider, model_config)
    model = stage["model"]
    results: list[IntentEvalRunResult] = []
    for run_index in range(1, runs + 1):
        started = time.perf_counter()
        try:
            payload, api_url, model = build_request_payload(
                fixture=fixture,
                provider=provider,
                current_stage=stage,
            )
            response = send_request(provider=provider, api_url=api_url, api_key=key, payload=payload)
            parsed = parse_provider_response(provider, response)
            duration_ms = int((time.perf_counter() - started) * 1000)
            results.append(
                IntentEvalRunResult(
                    run_index=run_index,
                    route=parsed.get("route"),
                    thread_decision=parsed.get("thread_decision"),
                    reply_relation=parsed.get("reply_relation"),
                    reply_confidence=parsed.get("reply_confidence"),
                    reason=parsed.get("reason"),
                    duration_ms=duration_ms,
                    provider=provider,
                    model=model,
                )
            )
        except Exception as exc:  # noqa: BLE001
            duration_ms = int((time.perf_counter() - started) * 1000)
            results.append(
                IntentEvalRunResult(
                    run_index=run_index,
                    route=None,
                    thread_decision=None,
                    reply_relation=None,
                    reply_confidence=None,
                    reason=None,
                    duration_ms=duration_ms,
                    error=str(exc),
                    provider=provider,
                    model=model,
                )
            )
    return results, provider, model


def build_request_payload(
    *,
    fixture: IntentEvalFixture,
    provider: str,
    current_stage: dict[str, Any],
) -> tuple[dict[str, Any], str, str]:
    system_prompt = synthesize_system_prompt(fixture)
    user_prompt = synthesize_user_prompt(fixture)
    model = current_stage["model"]
    if provider == "google":
        return (
            build_google_payload(
                fixture=fixture,
                system_prompt=system_prompt,
                user_prompt=user_prompt,
                stage=current_stage,
            ),
            default_api_url(provider, model),
            model,
        )
    if provider == "cerebras":
        return (
            build_cerebras_payload(
                fixture=fixture,
                system_prompt=system_prompt,
                user_prompt=user_prompt,
                stage=current_stage,
            ),
            default_api_url(provider, model),
            model,
        )
    raise ValueError(f"Unsupported provider: {provider}")


def build_google_payload(
    *,
    fixture: IntentEvalFixture,
    system_prompt: str,
    user_prompt: str,
    stage: dict[str, Any],
) -> dict[str, Any]:
    contents: list[dict[str, Any]] = [
        {
            "role": "model" if turn.role == "assistant" else "user",
            "parts": [{"text": turn.content}],
        }
        for turn in fixture.conversation_history
    ]
    current_parts: list[dict[str, Any]] = []
    for attachment in fixture.attachments:
        if not attachment.is_image:
            continue
        image_path = fixture.attachment_path(attachment)
        if image_path and image_path.exists():
            current_parts.append(
                {
                    "inlineData": {
                        "mimeType": attachment.mime,
                        "data": base64.b64encode(image_path.read_bytes()).decode("ascii"),
                    }
                }
            )
    current_parts.append({"text": user_prompt})
    contents.append({"role": "user", "parts": current_parts})
    generation_config: dict[str, Any] = {}
    if stage.get("temperature") is not None:
        generation_config["temperature"] = stage["temperature"]
    if stage.get("top_p") is not None:
        generation_config["topP"] = stage["top_p"]
    if stage.get("top_k") is not None:
        generation_config["topK"] = stage["top_k"]
    if stage.get("thinking_level") and str(stage["thinking_level"]).lower() != "none":
        if str(stage["model"]).lower().startswith("gemini-3"):
            generation_config["thinkingConfig"] = {
                "thinkingLevel": stage["thinking_level"]
            }
    generation_config["responseMimeType"] = "application/json"
    generation_config["responseJsonSchema"] = INTENT_RESPONSE_SCHEMA
    return {
        "systemInstruction": {"parts": [{"text": system_prompt}]},
        "contents": contents,
        "generationConfig": generation_config,
    }


def build_cerebras_payload(
    *,
    fixture: IntentEvalFixture,
    system_prompt: str,
    user_prompt: str,
    stage: dict[str, Any],
) -> dict[str, Any]:
    messages: list[dict[str, str]] = [{"role": "system", "content": system_prompt}]
    messages.extend(
        {"role": turn.role, "content": turn.content}
        for turn in fixture.conversation_history
    )
    messages.append({"role": "user", "content": user_prompt})
    payload: dict[str, Any] = {
        "model": stage["model"],
        "messages": messages,
        "temperature": stage.get("temperature", 0),
        "response_format": {"type": "json_object"},
    }
    if stage.get("top_p") is not None:
        payload["top_p"] = stage["top_p"]
    if stage.get("thinking_level") and str(stage["thinking_level"]).lower() != "none":
        payload["reasoning_effort"] = stage["thinking_level"]
    return payload


def send_request(*, provider: str, api_url: str, api_key: str, payload: dict[str, Any]) -> dict[str, Any]:
    headers = {"Content-Type": "application/json"}
    if provider == "google":
        headers["x-goog-api-key"] = api_key
    elif provider == "cerebras":
        headers["Authorization"] = f"Bearer {api_key}"
    else:
        raise ValueError(f"Unsupported provider: {provider}")
    with httpx.Client(timeout=120) as client:
        response = client.post(api_url, headers=headers, json=payload)
        response.raise_for_status()
        return response.json()


def parse_provider_response(provider: str, payload: dict[str, Any]) -> dict[str, Any]:
    text = extract_response_text(provider, payload)
    parsed = extract_json_block(text)
    route = parsed.get("route")
    thread_decision = parsed.get("thread_decision") or parsed.get("threadDecision")
    reply_relation = parsed.get("reply_relation") or parsed.get("replyRelation")
    reply_confidence = (
        parsed["reply_confidence"]
        if "reply_confidence" in parsed
        else parsed.get("replyConfidence")
    )
    reason = parsed.get("reason")
    return {
        "route": route,
        "thread_decision": thread_decision,
        "reply_relation": reply_relation,
        "reply_confidence": reply_confidence,
        "reason": reason,
    }


def extract_response_text(provider: str, payload: dict[str, Any]) -> str:
    if provider == "google":
        candidates = payload.get("candidates") or []
        if not candidates:
            raise RuntimeError("Google response has no candidates.")
        parts = ((candidates[0].get("content") or {}).get("parts") or [])
        text = "\n".join(part.get("text", "") for part in parts if part.get("text"))
        if not text.strip():
            raise RuntimeError("Google response text is empty.")
        return text
    if provider == "cerebras":
        choices = payload.get("choices") or []
        if not choices:
            raise RuntimeError("Cerebras response has no choices.")
        message = choices[0].get("message") or {}
        text = message.get("content") or ""
        if not text.strip():
            raise RuntimeError("Cerebras response text is empty.")
        return text
    raise ValueError(f"Unsupported provider: {provider}")


def extract_json_block(text: str) -> dict[str, Any]:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if not match:
        raise RuntimeError("Unable to extract JSON block from provider response.")
    return json.loads(match.group(0))


def synthesize_system_prompt(fixture: IntentEvalFixture) -> str:
    base = prompt_string(
        "default_intent_agent_prompt",
        working_agent_capability_contract=prompt_string("working_agent_capability_contract"),
        shared_agent_ground_rules=prompt_string("shared_agent_ground_rules"),
    )
    task = prompt_string(
        "intent_agent_task",
        working_agent_capability_contract=prompt_string("working_agent_capability_contract"),
    )
    return f"{base}\n\n{task}"


def synthesize_user_prompt(fixture: IntentEvalFixture) -> str:
    attachment_summary = "None"
    if fixture.attachments:
        attachment_summary = "\n".join(
            f"{attachment.kind} | {attachment.name} | {attachment.mime} | source={attachment.source}"
            for attachment in fixture.attachments
        )
    continuation_context = fixture.continuation_context
    continuation_text = "None"
    if continuation_context is not None:
        continuation_text = (
            f"candidate_thread_id: {continuation_context.candidate_thread_id or 'None'}\n"
            f"minutes_since_last_turn: {format_float(continuation_context.minutes_since_last_turn)}\n"
            f"last_turn_created_at: {continuation_context.last_turn_created_at or 'None'}\n"
            f"last_message_role: {continuation_context.last_message_role or 'None'}\n"
            f"last_user_message: {continuation_context.last_user_message or 'None'}\n"
            f"last_assistant_message: {continuation_context.last_assistant_message or 'None'}\n"
            f"last_reply_mode: {continuation_context.last_reply_mode or 'None'}\n"
            f"current_frontmost_app_name: {continuation_context.current_frontmost_app_name or 'None'}\n"
            f"current_frontmost_app_bundle_id: {continuation_context.current_frontmost_app_bundle_id or 'None'}\n"
            f"current_frontmost_window_title: {continuation_context.current_frontmost_window_title or 'None'}\n"
            f"previous_frontmost_app_name: {continuation_context.previous_frontmost_app_name or 'None'}\n"
            f"previous_frontmost_app_bundle_id: {continuation_context.previous_frontmost_app_bundle_id or 'None'}\n"
            f"previous_frontmost_window_title: {continuation_context.previous_frontmost_window_title or 'None'}\n"
            f"same_frontmost_app: {format_bool(continuation_context.same_frontmost_app)}\n"
            f"same_frontmost_window_title: {format_bool(continuation_context.same_frontmost_window_title)}\n"
            f"last_output_was_auto_pasted: {format_bool(continuation_context.last_output_was_auto_pasted)}"
        )
    return (
        f"mode_hint: {fixture.mode_hint}\n"
        f"full_agent_allowed: {'true' if fixture.full_agent_allowed else 'false'}\n"
        f"surface: {fixture.surface}\n"
        f"input_source: {fixture.input_source}\n\n"
        f"frontmost_app_name: {fixture.app_context.frontmost_app_name or 'None'}\n"
        f"frontmost_app_bundle_id: {fixture.app_context.frontmost_app_bundle_id or 'None'}\n"
        f"frontmost_window_title: {fixture.app_context.frontmost_window_title or 'None'}\n\n"
        f"continuation_context:\n{continuation_text}\n\n"
        f"words_glossary:\n{words_glossary_markdown(fixture.my_elson_markdown) or 'None'}\n\n"
        f"clipboard_text:\n{fixture.clipboard_text or 'None'}\n\n"
        f"screen_text:\n{fixture.screen_text or 'None'}\n\n"
        f"screen_description:\n{fixture.screen_description or 'None'}\n\n"
        f"attachments:\n{attachment_summary}\n\n"
        f"raw_transcript:\n{fixture.raw_transcript or fixture.input_text}"
    )


def words_glossary_markdown(markdown: str) -> str:
    if not markdown.strip():
        return ""

    lines = markdown.splitlines()
    collecting = False
    items: list[str] = []
    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            continue
        normalized = line.lower().replace("##", "", 1).strip() if line.startswith("##") else None
        if line.startswith("##"):
            collecting = normalized == "words"
            continue
        if collecting:
            cleaned = re.sub(r"^[-*•]\s*", "", line).strip()
            if cleaned:
                items.append(cleaned)
    if not items:
        return ""
    return "## Words\n" + "\n".join(f"- {item}" for item in items)


def format_bool(value: bool | None) -> str:
    if value is None:
        return "None"
    return "true" if value else "false"


def format_float(value: float | None) -> str:
    if value is None:
        return "None"
    return f"{value:.2f}"


def default_api_url(provider: str, model: str) -> str:
    if provider == "google":
        return f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    if provider == "cerebras":
        return "https://api.cerebras.ai/v1/chat/completions"
    raise ValueError(f"Unsupported provider: {provider}")
