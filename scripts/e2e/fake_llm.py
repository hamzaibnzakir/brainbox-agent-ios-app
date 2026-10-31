"""A tiny OpenAI-compatible chat-completions server for end-to-end tests.

Hermes is pointed at it as a `custom` provider so real turns run through the
real agent loop (tools, approvals, streaming) without any model key.

Behaviour, keyed on the latest user message:
  * contains "run tool"  -> first reply calls the `terminal` tool (`echo e2e-tool-ok`, or the
                            command after "run tool:"),
                            the follow-up turn answers with the tool output.
  * contains "slow"      -> streams 40 chunks with a small delay (reconnect tests).
  * anything else        -> streams "Echo: <message>" in a few chunks.
"""
import argparse
import asyncio
import json
import time

from aiohttp import web


def _last_user(messages):
    for m in reversed(messages):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, list):
                return " ".join(p.get("text", "") for p in c if isinstance(p, dict))
            return c or ""
    return ""


def _chunk(model, delta, finish=None):
    return {
        "id": "chatcmpl-e2e", "object": "chat.completion.chunk", "created": int(time.time()), "model": model,
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }


async def completions(request):
    body = await request.json()
    model = body.get("model", "fake-model")
    messages = body.get("messages", [])
    text = _last_user(messages)
    last = messages[-1] if messages else {}
    tool_turn = "run tool" in text.lower() and last.get("role") != "tool" and any(
        t.get("function", {}).get("name") == "terminal" for t in body.get("tools") or [])

    if tool_turn:
        command = text.split("run tool:", 1)[1].strip() if "run tool:" in text else "echo e2e-tool-ok"
        call = {"index": 0, "id": "call_e2e", "type": "function",
                "function": {"name": "terminal", "arguments": json.dumps({"command": command})}}
        pieces = [({"role": "assistant", "tool_calls": [call]}, None), ({}, "tool_calls")]
    else:
        if last.get("role") == "tool":
            reply = "Tool said: " + str(last.get("content", ""))[:200]
        elif "slow" in text.lower():
            reply = " ".join(f"w{i}" for i in range(40))
        else:
            reply = "Echo: " + text
        words = reply.split(" ")
        pieces = [({"role": "assistant", "content": ""}, None)]
        pieces += [({"content": (w if i == 0 else " " + w)}, None) for i, w in enumerate(words)]
        pieces.append(({}, "stop"))

    if not body.get("stream"):
        content = "".join(p[0].get("content", "") for p in pieces)
        msg = {"role": "assistant", "content": content or None}
        if tool_turn:
            msg["tool_calls"] = [pieces[0][0]["tool_calls"][0] | {"index": None}]
        return web.json_response({"id": "chatcmpl-e2e", "object": "chat.completion", "model": model,
                                  "choices": [{"index": 0, "message": msg,
                                               "finish_reason": "tool_calls" if tool_turn else "stop"}],
                                  "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}})

    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
    await resp.prepare(request)
    delay = 0.15 if "slow" in text.lower() else 0.01
    for delta, finish in pieces:
        await resp.write(f"data: {json.dumps(_chunk(model, delta, finish))}\n\n".encode())
        await asyncio.sleep(delay)
    usage = {"id": "chatcmpl-e2e", "object": "chat.completion.chunk", "model": model, "choices": [],
             "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}
    await resp.write(f"data: {json.dumps(usage)}\n\ndata: [DONE]\n\n".encode())
    return resp


async def models(_request):
    return web.json_response({"object": "list", "data": [{"id": "fake-model", "object": "model",
                                                          "context_length": 128000}]})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18080)
    args = ap.parse_args()
    app = web.Application()
    app.router.add_post("/v1/chat/completions", completions)
    app.router.add_get("/v1/models", models)
    web.run_app(app, host="127.0.0.1", port=args.port, print=None)


if __name__ == "__main__":
    main()
