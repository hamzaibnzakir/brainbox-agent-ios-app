# Hermes parity: live streaming, commands, and Telegram behaviour

Verified against hermes-agent **284d220** (the version on the VPS), by reading its source and
by running its real `/v1/runs` handlers in `gateway/tests/test_hermes_contract.py`.
Nothing here has been verified on the live VPS yet.

## Confirmed root causes

| # | Symptom | Root cause (Hermes 284d220) | Fix |
|---|---|---|---|
| 1 | Replies stop streaming and only appear at the end | `GET /v1/runs/{id}/events` has one consumer. When that connection closes for any reason (phone locked, Wi-Fi→cellular, tunnel hiccup) `_handle_run_events` calls `_drop_run_transport`: the queue is deleted, `_text_cb` stops emitting `message.delta`, and re-subscribing returns 404. Only the final `output` survives, by polling. (`api_server_runs.py` 718–758, 604–608.) | The proxy's **run relay** subscribes to Hermes on acceptance and keeps the only consumer; events get a sequence number and a buffer. The app resumes with `Last-Event-ID` — no loss, no duplicates, no re-ordering. |
| 2 | No way to tell "still working" from "stuck" | Hermes sends `: keepalive` comments every 30 s and no progress events while a tool runs; model-retry and compression notices go to `status_callback`, which the API server doesn't wire. | Real phases (responding / running `tool` / waiting for approval / stopping), link state (live / reconnecting / following by status / disconnected), "last event N s ago", and after 3 minutes without a Hermes event: "No response received for 3 minutes" — worded by what is known, never a failure. Heartbeats prove the link only. |
| 3 | A dead socket after backgrounding hangs forever | URLSession doesn't error a stream iOS silently killed; request timeout was 1 h. | Relay heartbeats every 15 s; no frame for 45 s → the app re-opens the stream from its cursor. Foregrounding and network-return reconnect immediately. |
| 4 | Slash commands "fail" | The API server never parses commands; Telegram's handlers (`gateway/slash_commands*.py`) run against the gateway's live session state, which isn't exposed over HTTP. The app's command list came only from the new proxy, so without it every Hermes command and skill was "unknown". | Bundled 284d220 registry as a fallback; `/brainbox/commands/run` runs Hermes' registry-owned handlers (`hermes_cli.slash_exec`: /help, /commands, /version, /profile, …) and `/btw` (`agent.side_question`). `/stop /steer /queue /new /model /status /usage /bg /approve /deny` are done through the matching API calls. Commands that truly need Telegram's live session (e.g. /compress, /personality) are refused with that reason. Unknown commands are an error; nothing is ever sent to the model as a command. |
| 5 | Shorter, plain, "dumber" answers than Telegram | The `api_server` platform hint (`agent/prompt_builder.py` 744) tells the model: *assume plain text, no markdown, keep responses brief*. Telegram's says Markdown renders. | Every app run carries a short `instructions` note: this client renders Markdown, answer as you would on Telegram (ephemeral prompt slot — not persisted, byte-stable, cache-safe). |
| 6 | Different persona / tone from Telegram | Telegram adds `GatewayRunner._load_ephemeral_system_prompt()` (`display.personality` or `agent.system_prompt`) every turn (`run_turn_runner.py` 1655). The API server only uses the request's `instructions`. | The proxy adds that same text, computed by Hermes' own function, before the app's note (`[parity] gateway_prompt = true`, cached 60 s). |

## Telegram vs app, side by side

| Area | Telegram path (`gateway/run_turn_runner.py`) | App path (`/v1/runs`, `api_server.py` `_create_agent`) | Status |
|---|---|---|---|
| Model / provider | `_resolve_session_agent_runtime` + session `/model` override + fallback chain | Same resolver (`resolve_effective_model`), same fallback chain; per-chat model via the run's `model` | Same |
| Custom OpenAI-compatible endpoint | From config | From the same config | Same |
| Provider routing (OpenRouter prefs) | `provider_routing` applied | Not passed by the API server | **Difference in Hermes** — the parity report says whether you use it |
| Platform hint | Telegram: Markdown | api_server: plain text, brief | Fixed by the client note (#5) |
| Gateway prompt (personality / system_prompt) | Applied every turn | Not applied | Fixed by the proxy (#6) |
| Prefill messages | Applied | Not applied | **Difference in Hermes** — reported by the parity report |
| Toolsets | `platform_toolsets.telegram` or `hermes-telegram` | `platform_toolsets.api_server` or `hermes-api-server` (= core minus clarify, computer_use, kanban, tts — by design, there's no UI for them) | Default difference is intentional. If you added toolsets/MCP servers for Telegram, the parity report lists them; aligning needs a config change (below) |
| History / session identity | Session store keyed by chat | `session_id` = the app's `ios_…` session; Hermes loads its history from SessionDB | Same mechanism |
| Context compression | Automatic | Automatic (the run adopts the live compression tip, #98619) | Same |
| Working directory / files | Hermes' terminal backend | Same backend; uploads land in the device's inbox, the agent gets the path | Same |
| Agent loop, retries, timeouts | `AIAgent.run_conversation` | Same function, same `max_iterations` | Same |
| Approvals | Inline buttons | `approval.request` events + `/approval` | Same core (`tools.approval`) |
| Background jobs | `/bg` spawns a fresh session | App `/bg` starts a separate run in its own session; result posted back | Equivalent |
| Interruption | `/stop` → interrupt | `POST /v1/runs/{id}/stop` → hard interrupt + reap that run's processes | Same; one run's stop never touches another (tested) |
| Images | Vision enrichment for non-vision models | Sent as `image_url` parts to the model directly | **Difference in Hermes** — a non-vision main model will say it can't see images |

## Changes that need your approval on the VPS

1. **Deploy the updated proxy** (relay, command runner, parity, gateway prompt). Commands are in `docs/RELEASE_CANDIDATE.md` §1.
2. **Optional — toolset parity.** If `/brainbox/parity` shows toolsets in `only_telegram` you want in the app too, set the API server's list explicitly, e.g.
   `hermes config set platform_toolsets.api_server '["hermes-api-server", "<your extra toolset or MCP server>"]'`
   then restart the Hermes gateway. This changes live config, so it isn't done for you.

Nothing else on the server changes: no Hermes code, no Telegram settings, no history or jobs.
