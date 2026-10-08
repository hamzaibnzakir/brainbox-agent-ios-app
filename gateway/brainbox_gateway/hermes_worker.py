"""Hermes worker — runs ONE chat turn through Hermes' documented library API.

Executed by Hermes' own interpreter (e.g. /opt/hermes-src/venv/bin/python)
with cwd = the Hermes checkout. Uses only the standard library plus Hermes.

stdin : one JSON request {message, history, toolsets, use_memory, max_iterations, source_dir}
stdout: JSON lines {"event": "delta"|"tool"|"result"|"error", ...}
stderr: anything Hermes prints (the gateway logs it)

Documented API used (hermes-agent docs, "Using Hermes as a Python Library"):
    from run_agent import AIAgent
    agent = AIAgent(quiet_mode=True, ...)
    agent.run_conversation(user_message, conversation_history=[...])
        -> {"final_response": str, "messages": [...]}

Streaming/tool callbacks are NOT documented. The worker only passes a
callback if the installed AIAgent's signature has a parameter with one of the
names below; otherwise it falls back to the final response. The probe script
prints the real signature so these names can be confirmed.
"""
import inspect
import json
import os
import sys

# Keep stdout exclusively for our JSON events; route Hermes' prints to stderr.
_events = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
sys.stdout = sys.stderr

STREAM_PARAMS = ("stream_delta_callback", "stream_callback", "token_callback", "on_token")
TOOL_PARAMS = ("tool_progress_callback", "tool_callback", "on_tool_progress")


def emit(**event):
    _events.write(json.dumps(event, ensure_ascii=False, default=str) + "\n")


def _first_text(args, kwargs):
    for value in list(args) + list(kwargs.values()):
        if isinstance(value, str):
            return value
    return None


def main():
    request = json.loads(sys.stdin.read() or "{}")
    try:
        sys.stdin.close()  # no interactive input: approval prompts cannot block
    except Exception:
        pass
    source = request.get("source_dir") or os.getcwd()
    if source not in sys.path:
        sys.path.insert(0, source)

    try:
        from run_agent import AIAgent  # documented entry point
    except Exception as exc:  # pragma: no cover - depends on Hermes install
        emit(event="error", message=f"Cannot import Hermes (run_agent.AIAgent): {exc}")
        return 2

    params = inspect.signature(AIAgent.__init__).parameters
    kwargs = {}
    if "quiet_mode" in params:
        kwargs["quiet_mode"] = True
    if "max_iterations" in params and request.get("max_iterations"):
        kwargs["max_iterations"] = int(request["max_iterations"])
    if "skip_memory" in params:
        kwargs["skip_memory"] = not bool(request.get("use_memory", True))
    if "enabled_toolsets" in params and request.get("toolsets"):
        kwargs["enabled_toolsets"] = list(request["toolsets"])

    for name in STREAM_PARAMS:
        if name in params:
            def on_delta(*a, **k):
                text = _first_text(a, k)
                if text:
                    emit(event="delta", text=text)
            kwargs[name] = on_delta
            break

    for name in TOOL_PARAMS:
        if name in params:
            def on_tool(*a, **k):
                parts = [str(x) for x in a] + [f"{key}={val}" for key, val in k.items()]
                tool_name = str(a[0]) if a else str(k.get("name") or k.get("tool") or "tool")
                emit(event="tool", name=tool_name, title=tool_name, input=" ".join(parts[1:])[:2000])
            kwargs[name] = on_tool
            break

    agent = AIAgent(**kwargs)
    history = request.get("history") or []
    run = agent.run_conversation
    run_params = inspect.signature(run).parameters
    call_kwargs = {}
    if "conversation_history" in run_params:
        call_kwargs["conversation_history"] = history
    result = run(request.get("message", ""), **call_kwargs)

    if isinstance(result, dict):
        final = result.get("final_response") or ""
        messages = result.get("messages")
    else:
        final, messages = str(result or ""), None
    emit(event="result", final=final, messages=messages if isinstance(messages, list) else None)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # report, don't leak a traceback to the client
        emit(event="error", message=f"{type(exc).__name__}: {exc}"[:500])
        raise
