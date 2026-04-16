from __future__ import annotations

import json
from functools import lru_cache

from .constants import REPO_ROOT


@lru_cache(maxsize=1)
def load_prompt_config() -> dict[str, list[str]]:
    path = REPO_ROOT / "Elson" / "Resources" / "prompt-config.json"
    return json.loads(path.read_text(encoding="utf-8"))


def prompt_string(key: str, **replacements: str) -> str:
    lines = load_prompt_config().get(key, [])
    value = "\n".join(lines)
    for token, replacement in replacements.items():
        value = value.replace(f"{{{token}}}", replacement)
    return value.strip()
