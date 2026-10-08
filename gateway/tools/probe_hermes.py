#!/usr/bin/env python3
"""Read-only Hermes probe for the Brainbox gateway.

Run it with HERMES' OWN interpreter, from anywhere:

    /opt/hermes-src/venv/bin/python probe_hermes.py            # inspection only
    /opt/hermes-src/venv/bin/python probe_hermes.py --live     # + one tiny test prompt

What it does NOT do: change config, restart services, touch Telegram, print
secrets or environment variables. `--live` sends ONE short prompt through the
documented library API with memory disabled (it uses a few tokens of your
model quota). Paste the whole output back to Claude.
"""
from __future__ import annotations

import argparse
import inspect
import json
import os
import re
import subprocess
import sys
import time

SOURCE = os.environ.get("HERMES_SRC", "/opt/hermes-src")
HERMES_BIN = os.path.join(SOURCE, "venv", "bin", "hermes")
STREAM_CANDIDATES = ("stream_delta_callback", "stream_callback", "token_callback", "on_token")
TOOL_CANDIDATES = ("tool_progress_callback", "tool_callback", "on_tool_progress")
SECRET_RE = re.compile(r"(sk-[A-Za-z0-9_-]{10,}|\d{8,10}:[A-Za-z0-9_-]{30,}|[A-Za-z0-9_-]{32,})")

report: dict = {"probe_version": 1, "python": sys.version.split()[0], "source_dir": SOURCE}


def redact(text: str) -> str:
    return SECRET_RE.sub("<redacted>", text)


def section(title: str) -> None:
    print(f"\n=== {title} " + "=" * max(0, 60 - len(title)))


def run(cmd: list[str], timeout: int = 30) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return redact((out.stdout + out.stderr).strip())
    except Exception as exc:  # noqa: BLE001
        return f"<failed: {exc}>"


def cli_checks() -> None:
    section("CLI")
    version = run([HERMES_BIN, "--version"])
    print("hermes --version:", version)
    report["cli_version"] = version
    chat_help = run([HERMES_BIN, "chat", "--help"])
    top_help = run([HERMES_BIN, "--help"])
    sessions_help = run([HERMES_BIN, "sessions", "--help"])
    flags = {}
    for flag in ("-q", "--query", "-Q", "--quiet", "-t", "--toolsets", "--yolo", "-r", "--resume", "-c", "--continue", "-z"):
        flags[flag] = {"chat": bool(re.search(rf"(^|\s){re.escape(flag)}([\s,=]|$)", chat_help, re.M)),
                       "global": bool(re.search(rf"(^|\s){re.escape(flag)}([\s,=]|$)", top_help, re.M))}
    report["cli_flags"] = flags
    print("flags found:", json.dumps(flags, indent=1))
    print("\n--- hermes chat --help (first 60 lines) ---")
    print("\n".join(chat_help.splitlines()[:60]))
    print("\n--- hermes sessions --help (first 25 lines) ---")
    print("\n".join(sessions_help.splitlines()[:25]))


def library_checks() -> None:
    section("LIBRARY API")
    sys.path.insert(0, SOURCE)
    old = sys.stdout
    sys.stdout = sys.stderr  # Hermes import-time prints go to stderr
    try:
        from run_agent import AIAgent  # type: ignore
    except Exception as exc:  # noqa: BLE001
        sys.stdout = old
        print("import run_agent.AIAgent FAILED:", exc)
        report["library_import"] = f"failed: {exc}"
        return
    sys.stdout = old
    report["library_import"] = "ok"
    init_sig = inspect.signature(AIAgent.__init__)
    run_sig = inspect.signature(AIAgent.run_conversation)
    params = list(init_sig.parameters)
    report["aiagent_init_params"] = params
    report["run_conversation_params"] = list(run_sig.parameters)
    report["stream_callback_param"] = next((p for p in STREAM_CANDIDATES if p in params), None)
    report["tool_callback_param"] = next((p for p in TOOL_CANDIDATES if p in params), None)
    report["other_callback_params"] = [p for p in params if "callback" in p.lower() or p.lower().startswith("on_")]
    print("AIAgent.__init__ params:", ", ".join(params))
    print("run_conversation params:", ", ".join(run_sig.parameters))
    print("callback-like params:", report["other_callback_params"])
    for name in report["other_callback_params"]:
        print(f"  {name}: default={init_sig.parameters[name].default!r} annotation={init_sig.parameters[name].annotation!r}")
    has_interrupt = [m for m in ("interrupt", "cancel", "stop") if hasattr(AIAgent, m)]
    report["interrupt_methods"] = has_interrupt
    print("interrupt-like methods:", has_interrupt)

    # How does the agent ask for dangerous-command approval? (read-only grep)
    hits = []
    for root, _, files in os.walk(SOURCE):
        if "/venv" in root or "/.git" in root or "node_modules" in root:
            continue
        for f in files:
            if not f.endswith(".py"):
                continue
            path = os.path.join(root, f)
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for i, line in enumerate(fh, 1):
                        if re.search(r"(approval_callback|dangerous|yolo|input\()", line):
                            hits.append(f"{os.path.relpath(path, SOURCE)}:{i}: {line.strip()[:140]}")
            except OSError:
                pass
            if len(hits) > 60:
                break
    report["approval_mentions"] = hits[:60]
    print("\n--- approval / dangerous-command handling (first 60 matches) ---")
    print("\n".join(hits[:60]) or "(none)")


def live_check() -> None:
    section("LIVE TEST (one tiny prompt, memory off)")
    sys.path.insert(0, SOURCE)
    old = sys.stdout
    sys.stdout = sys.stderr
    try:
        from run_agent import AIAgent  # type: ignore
        params = inspect.signature(AIAgent.__init__).parameters
        deltas: list[str] = []
        tools: list[str] = []
        kwargs = {"quiet_mode": True}
        if "skip_memory" in params:
            kwargs["skip_memory"] = True
        if "max_iterations" in params:
            kwargs["max_iterations"] = 2
        stream = report.get("stream_callback_param")
        if stream:
            kwargs[stream] = lambda *a, **k: deltas.append(next((x for x in a if isinstance(x, str)), ""))
        tool = report.get("tool_callback_param")
        if tool:
            kwargs[tool] = lambda *a, **k: tools.append(repr(a)[:120])
        started = time.time()
        agent = AIAgent(**kwargs)
        result = agent.run_conversation("Reply with exactly: BRAINBOX_PROBE_OK", conversation_history=[])
        elapsed = time.time() - started
    except Exception as exc:  # noqa: BLE001
        sys.stdout = old
        print("live test FAILED:", redact(f"{type(exc).__name__}: {exc}"))
        report["live"] = {"ok": False, "error": redact(str(exc))[:300]}
        return
    sys.stdout = old
    final = result.get("final_response") if isinstance(result, dict) else str(result)
    messages = result.get("messages") if isinstance(result, dict) else None
    report["live"] = {
        "ok": "BRAINBOX_PROBE_OK" in (final or ""),
        "seconds": round(elapsed, 1),
        "result_type": type(result).__name__,
        "result_keys": sorted(result.keys()) if isinstance(result, dict) else None,
        "messages_len": len(messages) if isinstance(messages, list) else None,
        "message_roles": [m.get("role") for m in messages][:10] if isinstance(messages, list) else None,
        "stream_chunks": len(deltas),
        "stream_text": "".join(deltas)[:80],
        "tool_events": tools[:5],
        "final": (final or "")[:120],
    }
    print(json.dumps(report["live"], indent=1))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true", help="also send one tiny prompt (uses a few tokens)")
    args = parser.parse_args()
    if not os.path.isdir(SOURCE):
        print(f"Hermes source dir not found: {SOURCE} (set HERMES_SRC)")
        sys.exit(2)
    cli_checks()
    library_checks()
    if args.live:
        live_check()
    section("SUMMARY (paste everything back)")
    print(json.dumps(report, indent=1, default=str))


if __name__ == "__main__":
    main()
