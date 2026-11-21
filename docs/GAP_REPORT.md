# Gap report: "Full-Stack Agentic Workspace" brief vs. repository

**Audit date:** 2026-10-24

**What was audited:**
- Branch `feature/full-stack-upgrade`, at the commit that adds this file. It is based on `b94076d`, the scheduled-tasks lifecycle work.
- The Hermes source at **284d220**, the exact commit installed on the VPS (per the audit).
- The Brainbox Hermes proxy in `gateway/`.

## Facts that shape the design

These were verified in the Hermes source, not assumed.

| Fact | Where in Hermes source | Consequence |
| --- | --- | --- |
| The API server has **no slash-command handling**: `/v1/runs` passes `input` to the model unchanged. Commands are parsed only by the messaging gateway, CLI and TUI. | `gateway/platforms/api_server_runs.py` `_handle_runs`; `gateway/run_inbound.py` | Sending `/compress` through the API would reach the model as a sentence. The app must route commands itself and refuse the ones the API can't perform. |
| Skill slash commands (`/<skill> …`) are Hermes building a message from the skill's files. | `agent/skill_commands.py` `build_skill_invocation_message` | The proxy can call that same function in Hermes's venv, giving identical behaviour without re-implementing it. |
| `POST /v1/runs/{id}/stop` sets `stopping`, then hard-interrupts the agent and reaps that run's background processes. The run ends `cancelled`. | `_handle_stop_run` | Stop is real server-side cancellation. The UI must wait for `stopping` and then `cancelled` before saying "stopped". |
| `POST /v1/runs/{id}/steer` injects text into a running agent. It returns 409 unless the status is `running`. | `_handle_steer_run` | "Inject" is real. "Queue" and "interrupt-then-send" are app-side sequences on top of real stop and run calls. |
| Concurrent runs are capped by `gateway.api_server.max_concurrent_runs` (default 10). Above the cap it returns 429 with `Retry-After`. | `_concurrency_limited_response` | Parallel agents are real independent runs, each with its own run id and session. The app must respect 429. |
| `delegate_task` sub-agents inside one run emit `subagent.start` / `subagent.complete` events (with id, goal, status and summary). They can't be stopped individually. | `_make_run_event_callback` | Show them as children of the run. Say honestly that cancelling one means stopping its parent run. |
| Image parts (`image_url`, data URLs) are accepted as user content, and the agent loop handles list content. Non-image file parts are rejected on these endpoints. | `_normalize_multimodal_content`, `agent/conversation_loop.py` | Images go to the model inline. Other files go to the workspace inbox, and the model is given their server path. |
| Per-request `model` / `provider` overrides are supported. `/v1/models` and `/api/model/options` list the choices. | `_request_agent_overrides` | A chat model picker can be real. |

## Requirement → status

Status key: ✅ done on this branch · 🟡 partly done · ❌ missing.

### 1. Execution engine

| Requirement | Current code | Missing work | Tests |
| --- | --- | --- | --- |
| **A. Slash commands** | ❌ The composer sends text as a prompt. | Command catalog from the proxy (Hermes's own registry plus skills). App router with three kinds of command: app commands mapped to real API calls, Hermes skills built server-side, and known-but-unsupported commands refused. Autocomplete with descriptions and argument hints. | Router unit tests; proxy catalog and skill tests; UI test of the suggestion list. |
| **B. Stop** | 🟡 The provider calls the real stop, including an early-stop race fix (P0). But `ChatStore.stop()` marks the reply "cancelled" after 1.5 s whether or not the server confirmed. | A stop state machine: *requested → stopping (server ack) → stopped / finished first / failed*. Keep following the run until it reaches a terminal state, fall back to polling, and make stop idempotent. Distinguish shell-command reaping from model stop in the UI copy. | Mock-server tests: stop before the run id exists, stop after completion, double stop, stop-request failure, stream drop during stop. |
| **B. Steering** | 🟡 `steer()` exists, but there's no UI mode choice. | Three modes: Inject (steer), Queue (send after the current run ends), and Interrupt (stop, wait for terminal, then send). A guard so late events can't overwrite newer messages. | Ordering and race tests. |
| **C. Concurrent agents** | ❌ Teammates are UI presets, so there is only one execution at a time. | A parallel-task orchestrator: N independent runs, each with its own `ios_` session, run id, stream, cancel and result. Configurable limit, 429 back-off, a parent record, and a final synthesis run. Show Hermes `delegate_task` sub-agents as children. | Tests for isolation (cancel one, the others continue), failure, 429, and duplicate submit. |

### 2. App experience

| Requirement | Current code | Missing work |
| --- | --- | --- |
| Home dashboard | 🟡 `HomeView` exists and uses real data only. | Redesign, mascot, task composer. |
| Chat | 🟡 Streaming, history, stop and retry exist. | Attachments, command autocomplete, model picker, steering modes, redesign. |
| Agent Workspace | 🟡 Team and Tasks screens exist. | Parallel task view with per-agent state and results. |
| Scheduled Tasks | ✅ `b94076d`, preserved. | Verify on the real VPS (manual steps in the final report). |
| Files | 🟡 Proxy API and app screen with progress and cancel exist. | Stable file ids, per-device ownership, retry. |
| Terminal | 🟡 Proxy PTY (tested with a real PTY in CI) and app SwiftTerm screen exist. | Wire into the Server tab and redesign. |
| Settings | 🟡 Existing. | Notifications (push), diagnostics, models. |

### 3–7. Files, terminal, deletion, scheduled tasks, push

| Area | Status | Gap |
| --- | --- | --- |
| File handling | 🟡 | IDs and ownership: today the inbox is shared by every device. The image → model path is missing. "Delivered" must only appear after the server confirms. |
| Terminal | 🟡 | App integration. The confirmation for dangerous commands is a warning, which the brief allows. No VPS verification yet. |
| Deletion / archive | ✅ | Done: proxy cascade delete with verification, ownership, archive/restore, Archived Chats screen, and tests. Remaining: the "absent after reinstall or another client" check. The server list is the source of truth, and the sync re-reads it on connect. |
| Scheduled tasks | ✅ code | Needs verification on the real VPS. |
| Push | 🟡 | Proxy service and app manager are written. Needs Settings UI, and real delivery needs a paid Apple account (external prerequisite). |

### 8. Provider abstraction

- **Status:** 🟡. `AgentProvider` already separates the chat UI from the backend.
- **Gap:** a written design for adding an optional xAI provider server-side, behind the proxy. The key would live on the server only, with the same tool and permission boundaries.
- **Not in this release:** an xAI client. It is out of scope, and keys must never be in the app.

### 9–10. Security preservation and tests

- Existing guarantees stay and keep their tests: the proxy allow-list, `ios_` isolation, the Telegram read-only rule and device tokens.
- New tests are listed per row above.
- Every fake-server result is reported separately from real-VPS verification, which needs your approval to run.

## External prerequisites (can't be done from here)

1. **Deploying the updated proxy to the VPS.** Needs your approval. The commands are in `docs/HERMES_API_DEPLOYMENT.md`.
2. **Terminal account `brainbox-term`.** You create it (`docs/TERMINAL.md`).
3. **Notifications:** now local (no paid account needed). Background alerts depend on iOS Background App Refresh timing.
4. **Real-VPS verification** of stop, steer, parallel runs, images, files, terminal and deletion, after deployment.

## Order of work

1. Stop / steering
2. Slash commands
3. Concurrent agents
4. Files and attachments
5. Design system and mascot across all screens
6. Server tab, Settings and push UI
7. Provider doc
8. CI, screenshots, IPA and PR
