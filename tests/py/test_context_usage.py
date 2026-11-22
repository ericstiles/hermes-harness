"""Unit tests for lib/context_usage.py (session token usage -> CONTEXT: lines, bead 39w.1)."""

import http.client
import io
import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

import context_usage as cu

SCRIPT = Path(__file__).resolve().parents[2] / "lib" / "context_usage.py"
SECRET = "SECRET-CONTENT-7f3a"
CACHE = """context_lengths:
  qwen3.8:27b-mlx@http://127.0.0.1:11434/v1: 262144
  other:7b@http://127.0.0.1:11434/v1: 8192
"""


def _export(**overrides: object) -> str:
    """One `hermes sessions export` JSON line (real field names, values from a real run)."""
    record = {
        "id": "20261121_191639_ed76de",
        "model": "qwen3.8:27b-mlx",
        "input_tokens": 49060,
        "output_tokens": 6277,
        "cache_read_tokens": 818682,
        "api_call_count": 21,
        "message_count": 43,
        "system_prompt": f"system prompt {SECRET}",
        "title": f"title {SECRET}",
        "messages": [{"role": "user", "content": f"please {SECRET}", "token_count": None}],
    }
    record.update(overrides)
    return json.dumps(record) + "\n"


def _no_lookups() -> dict[str, object]:
    return {"config_lookup": lambda: None, "cache_text": None, "ollama_lookup": lambda m: None}


def test_usage_json_is_turned_into_a_context_used_line() -> None:
    usage = cu.parse_export(_export())
    line = cu.context_line(usage, cu.Window(262144, "hermes context_length_cache"))
    assert line == (
        "CONTEXT: used cumulative in=49060 out=6277 cache_read=818682 api_calls=21 "
        "model=qwen3.8:27b-mlx (summed over all API calls; no peak available, so no %) "
        "[window: 262144 (hermes context_length_cache)]"
    )


def test_no_percentage_for_cumulative_totals_even_with_a_known_window() -> None:
    usage = cu.parse_export(_export())
    line = cu.context_line(usage, cu.Window(262144, "explicit --window"))
    assert not re.search(r"\d%", line)
    assert "cumulative" in line


def test_no_window_known_gives_token_counts_without_percentage_and_a_reason() -> None:
    window = cu.resolve_window(None, "qwen3.8:27b-mlx", **_no_lookups())
    assert window.tokens is None
    line = cu.context_line(cu.parse_export(_export()), window)
    assert "in=49060" in line
    assert line.endswith(
        "[window: unknown (no --window; model.context_length not set; "
        "no context_length_cache entry; ollama has no context_length for the model)]"
    )
    assert not re.search(r"\d%", line)


def test_window_resolution_order_and_source_labels() -> None:
    lookups = {
        "config_lookup": lambda: "131072",
        "cache_text": CACHE,
        "ollama_lookup": lambda m: 65536,
    }
    model = "qwen3.8:27b-mlx"
    assert cu.resolve_window("4096", model, **lookups) == cu.Window(4096, "explicit --window")
    assert cu.resolve_window(None, model, **lookups) == cu.Window(
        131072, "hermes config model.context_length"
    )
    no_config = {**lookups, "config_lookup": lambda: None}
    assert cu.resolve_window(None, model, **no_config) == cu.Window(
        262144, "hermes context_length_cache"
    )
    only_ollama = {**no_config, "cache_text": None}
    assert cu.resolve_window(None, model, **only_ollama) == cu.Window(65536, "ollama /api/ps")


def test_lookup_errors_fall_through_to_the_next_source() -> None:
    def broken() -> str:
        raise OSError("hermes not on PATH")

    lookups = {"config_lookup": broken, "cache_text": CACHE, "ollama_lookup": lambda m: None}
    window = cu.resolve_window(None, "qwen3.8:27b-mlx", **lookups)
    assert window == cu.Window(262144, "hermes context_length_cache")


@pytest.mark.parametrize("bad", ["0", "-5", "lots", ""])
def test_bad_explicit_window_is_ignored_with_a_reason(bad: str) -> None:
    window = cu.resolve_window(bad, "qwen3.8:27b-mlx", **_no_lookups())
    assert window.tokens is None
    assert "--window" in window.source


def test_window_from_cache_matches_the_model_only() -> None:
    assert cu.window_from_cache(CACHE, "qwen3.8:27b-mlx") == 262144
    assert cu.window_from_cache(CACHE, "qwen3.8") is None
    two_hosts = CACHE + "  qwen3.8:27b-mlx@http://other:11434/v1: 32768\n"
    assert cu.window_from_cache(two_hosts, "qwen3.8:27b-mlx") is None  # ambiguous: no guess


@pytest.mark.parametrize(
    ("text", "reason"),
    [
        ("", "empty input"),
        ("not json\n", "not JSON"),
        ("[1, 2]\n", "not a JSON object"),
        (_export(input_tokens="many"), "input_tokens is not a non-negative integer"),
        (_export(api_call_count=-1), "api_call_count is not a non-negative integer"),
        (json.dumps({"model": "m"}) + "\n", "input_tokens is missing"),
    ],
)
def test_malformed_export_is_rejected_with_a_reason(text: str, reason: str) -> None:
    with pytest.raises(ValueError, match=re.escape(reason)):
        cu.parse_export(text)


@pytest.mark.parametrize("stdin", ["", "garbage\n", f'{{"content": "{SECRET}"\n'])
def test_malformed_usage_json_logs_unavailable_and_exits_0(stdin: str) -> None:
    done = subprocess.run(
        [sys.executable, str(SCRIPT), "--window", "1000"],
        input=stdin, capture_output=True, text=True, timeout=30, check=False,
    )  # fmt: skip
    assert done.returncode == 0
    assert done.stdout.startswith("CONTEXT: unavailable (")
    assert done.stdout.count("\n") == 1
    assert SECRET not in done.stdout + done.stderr


def test_message_content_is_never_printed() -> None:
    done = subprocess.run(
        [sys.executable, str(SCRIPT), "--window", "262144"],
        input=_export(), capture_output=True, text=True, timeout=30, check=False,
    )  # fmt: skip
    assert done.returncode == 0
    assert done.stdout.startswith("CONTEXT: used cumulative in=49060 ")
    assert SECRET not in done.stdout + done.stderr


def test_unsafe_model_name_is_not_echoed() -> None:
    usage = cu.parse_export(_export(model=f"x\n{SECRET} $(rm -rf ~)"))
    line = cu.context_line(usage, cu.Window(None, "unknown (test)"))
    assert "model=unknown" in line
    assert SECRET not in line and "\n" not in line


# --- bead hermes-harness-aju: odd inputs must not lose the usage counts ---


@pytest.fixture
def no_real_lookups(monkeypatch: pytest.MonkeyPatch) -> None:
    """main() without calling hermes or Ollama."""
    monkeypatch.setattr(cu, "hermes_config_context_length", lambda: None)
    monkeypatch.setattr(cu, "read_cache", lambda environ: None)
    monkeypatch.setattr(cu, "ollama_ps_context_length", lambda model, host: None)


def _main(argv: list[str], stdin: str) -> str:
    out = io.StringIO()
    assert cu.main(argv, io.StringIO(stdin), out, {}) == 0
    return out.getvalue()


def test_unicode_digit_window_is_ignored_with_reason(no_real_lookups: None) -> None:
    window = cu.resolve_window("²", "qwen3.8:27b-mlx", **_no_lookups())
    assert window.tokens is None
    assert "--window is not a positive integer" in window.source
    line = _main(["--window", "²"], _export())
    assert line.startswith("CONTEXT: used cumulative in=49060 ")
    assert "--window is not a positive integer" in line


@pytest.mark.parametrize(
    "error", [http.client.HTTPException("bad status"), TypeError("NoneType"), KeyError("x")]
)
def test_ollama_http_or_shape_error_falls_through(error: Exception) -> None:
    def broken(model: str) -> int:
        raise error

    lookups = {"config_lookup": lambda: None, "cache_text": None, "ollama_lookup": broken}
    window = cu.resolve_window(None, "qwen3.8:27b-mlx", **lookups)
    assert window.tokens is None
    assert "ollama has no context_length for the model" in window.source


@pytest.mark.parametrize("payload", [b'{"models": null}', b"[1, 2]", b'{"models": [7, null]}'])
def test_ollama_unexpected_shape_is_no_window(
    monkeypatch: pytest.MonkeyPatch, payload: bytes
) -> None:
    monkeypatch.setattr(cu.urllib.request, "urlopen", lambda url, timeout: io.BytesIO(payload))
    assert cu.ollama_ps_context_length("qwen3.8:27b-mlx", "http://127.0.0.1:11434") is None


def test_non_utf8_input_reason_is_fixed_text() -> None:
    done = subprocess.run(
        [sys.executable, str(SCRIPT), "--window", "1000"],
        input=b'{"content": "\xff\xfe ' + SECRET.encode() + b'"}\n',
        capture_output=True, timeout=30, check=False,
    )  # fmt: skip
    assert done.returncode == 0
    assert done.stdout == b"CONTEXT: unavailable (not UTF-8)\n"


def test_window_flag_without_value_reports_not_positive(no_real_lookups: None) -> None:
    line = _main(["--window"], _export())
    assert line.startswith("CONTEXT: used cumulative in=49060 ")
    assert "--window is not a positive integer" in line
    assert "no --window" not in line
