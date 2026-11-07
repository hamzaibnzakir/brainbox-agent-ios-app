# Model providers and tools (incl. optional Grok / xAI)

## How the layers are split today

| Layer | Owns | Never owns |
| --- | --- | --- |
| **App** (`AgentProvider`, `RunControllingProvider`, `ChatStore`, `ParallelRunEngine`) | Chat UI, slash-command routing, stop/steer state, parallel orchestration, files/terminal UI, local notifications | Model API keys, tool execution, permissions |
| **Brainbox proxy** | Device tokens, route allow-list, `ios_` session isolation, chat delete/archive, workspace files, PTY terminal, command catalog | Model calls |
| **Hermes** (VPS) | The agent loop, model providers and keys, tools (terminal, files, browser, MCP, skills), approvals, cron, sessions | — |

The model provider is a Hermes setting, so it is independent of where tools run. Chat, files, the terminal, task orchestration and permissions all talk to Hermes runs. Changing the model changes none of them.

## Grok / xAI: what fits and how to add it

Hermes 284d220 already supports xAI:

- `XAI_API_KEY` is listed among the provider keys in `hermes_cli/config_defaults.py`.
- There's an **X Search** toolset that uses xAI's `x_search` Responses tool. It registers when xAI credentials exist and the toolset is enabled.

So **no app code and no key in the app** is needed:

1. On the VPS, add `XAI_API_KEY` to Hermes' `.env`. Use `hermes setup` / `hermes model` or edit the file; this needs your approval.
2. Choose a Grok model per preset (Workspace → preset → model / provider), or per chat with `/model <name>`. `/model` validates the name against Hermes' `/v1/models`.
3. Optionally enable the X Search toolset in `hermes tools`. It then appears in the app under Workspace → Tools & skills.

### Which xAI capabilities are worth using here

Source: xAI's tools overview, docs.x.ai/docs/guides/tools/overview.

| xAI capability | Fit for Brainbox | Recommendation |
| --- | --- | --- |
| Grok models (chat / reasoning) | Good: another model choice for runs | Use through Hermes (above) |
| **X Search** | Unique (live X posts); useful for research tasks | Use through Hermes' x_search toolset |
| Web Search | Hermes already has web tools | Optional; avoid two overlapping search tools |
| Code Execution (xAI sandbox) | Runs on xAI's servers, not your VPS; Hermes already runs code on the VPS with approvals | Not needed. It would also bypass your VPS permission model |
| Remote MCP tools | Hermes already connects to MCP servers itself | Keep MCP in Hermes, so there's one allow-list and one approval path |
| Function calling | Hermes' agent loop already does this for every provider | Nothing to add |
| Image generation / vision | Images already reach the model inline as `image_url` parts | Only if a Grok vision model is chosen |

### If a direct provider is ever needed

If you ever want to call xAI without Hermes, add it **behind the proxy, never in the app**:

1. Implement a server-side adapter that exposes the same run contract the app already uses: `POST /v1/runs`, `GET /v1/runs/{id}/events` (SSE with `message.delta`, `tool.*` and `run.*` events), `/stop`, `/steer` and `/approval`.
2. Keep tool execution in an allow-listed server component that emits the same `tool.started` / `tool.completed` / `approval.request` events.
3. The app keeps working unchanged. `HermesRunMapper`, Stop, steering, parallel agents and notifications only depend on those events.

Keys stay on the server (`.env`, mode 600). The app only ever holds its Brainbox device token.
