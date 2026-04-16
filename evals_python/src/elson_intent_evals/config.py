from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .constants import DEFAULT_LOCAL_CONFIG_PATH, DEFAULT_MODEL_CONFIG_PATH


@dataclass(slots=True)
class LocalConfig:
    audio_decider_provider: str = "google"
    intent_agent_prompt: str | None = None
    working_agent_prompt: str | None = None
    groq_api_key: str | None = None
    cerebras_api_key: str | None = None
    gemini_api_key: str | None = None


def load_local_config(path: Path = DEFAULT_LOCAL_CONFIG_PATH) -> LocalConfig:
    data: dict[str, Any] = {}
    if path.exists():
        data = json.loads(path.read_text(encoding="utf-8"))
    env_local = load_env_local()
    return LocalConfig(
        audio_decider_provider=(data.get("audio_decider_provider") or "google"),
        intent_agent_prompt=data.get("intent_agent_prompt"),
        working_agent_prompt=data.get("working_agent_prompt"),
        groq_api_key=env_local.get("GROQ_API_KEY") or data.get("groq_api_key"),
        cerebras_api_key=env_local.get("CEREBRAS_API_KEY") or data.get("cerebras_api_key"),
        gemini_api_key=env_local.get("GEMINI_API_KEY") or data.get("gemini_api_key"),
    )


def load_env_local() -> dict[str, str]:
    candidates = [
        Path.cwd() / ".env.local",
        Path(__file__).resolve().parents[3] / ".env.local",
    ]
    values: dict[str, str] = {}
    for candidate in candidates:
        if not candidate.exists():
            continue
        for line in candidate.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            key, raw_value = stripped.split("=", 1)
            value = raw_value.strip().strip("\"").strip("'")
            values[key.strip()] = value
        break
    return values


def provider_choice(requested: str | None, local_config: LocalConfig, fixture_provider: str | None) -> str:
    if requested and requested != "config":
        return requested
    return (local_config.audio_decider_provider or fixture_provider or "google").lower()


def api_key_for_provider(provider: str, local_config: LocalConfig) -> str:
    if provider == "google":
        return os.environ.get("GEMINI_API_KEY") or local_config.gemini_api_key or ""
    if provider == "cerebras":
        return os.environ.get("CEREBRAS_API_KEY") or local_config.cerebras_api_key or ""
    raise ValueError(f"Unsupported provider: {provider}")


def load_model_config(path: Path = DEFAULT_MODEL_CONFIG_PATH) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def stage_config_for_provider(provider: str, model_config: dict[str, Any]) -> dict[str, Any]:
    runtime = model_config["local_runtime"]
    if provider == "google":
        return runtime["google"]["intent_agent"]
    if provider == "cerebras":
        return runtime["cerebras"]["intent_agent"]
    raise ValueError(f"Unsupported provider: {provider}")
