# Chat archive and permanent deletion

Applies to the app's own Hermes conversations (`ios_` + 32 hex). Telegram, cron/scheduled-task,
CLI and every other non-`ios_` session can't be archived, deleted or changed from the app: the
app refuses those ids, and the Brainbox proxy refuses them again on the server.

## How it works

| Action | App | Server (Brainbox proxy → Hermes) |
| --- | --- | --- |
| **Archive** / **Restore** | Needs a live connection. Hides or restores the chat in History. The flag is saved on the device and on the server, so it survives restarts and reinstalls. | `PATCH /api/sessions/{ios_id}` `{"archived": true/false}`. The proxy checks the id and that this device owns the chat. |
| **Delete permanently** | Confirmation dialog, then needs a live connection. The chat is removed from the device **only after** the server confirms it's gone. On any error the chat stays and the error is shown. | `DELETE /brainbox/sessions/{ios_id}` (proxy-only route; Hermes' raw `DELETE /api/sessions/…` is refused through the proxy). |
| Offline | Archive and delete are refused with "Nothing was changed". Nothing is queued. | — |
| Chats only on the device (Mock provider, never sent) | Deleted locally, with a message that says so. | No request. If the server answers `session_not_found`, the app says the server had no copy. |

### What the proxy's delete does

1. It validates the id against `^ios_[0-9a-f]{32}$`, so `/`, `..`, other prefixes and uppercase are rejected with 400.
2. It checks ownership. Each device token has a key: the first 24 hex characters of its SHA-256. A chat created by another device returns 403. Chats from before the registry have no owner, and the first device that manages one claims it.
3. It opens Hermes' `state.db` **read-only** (`mode=ro`) and finds the conversation's compression continuations. It uses the same rule as Hermes: forks (`/branch`), sub-agent (delegate) sessions and tool sessions are never included.
4. It deletes each continuation, deepest first, then the root, through **Hermes' own** `DELETE /api/sessions/{id}`. If any step fails, it returns `502 delete_failed` and lists what was and wasn't deleted.
5. It removes the files Hermes' HTTP delete leaves behind: `<id>.json`, `<id>.jsonl` and `request_dump_<id>_*.json`. Only plain files directly inside `~/.hermes/sessions` are touched; symlinks are skipped.
6. It verifies that no session row and no message rows remain. If anything does, it returns `500 delete_unverified` and the app keeps the chat.
7. It forgets the ownership entry and writes an audit line. The audit line holds the id and counts only, never message content.

## Exactly what permanent deletion removes

- The conversation's session row and all its messages, including the continuation sessions created by context compression. Hermes' FTS trigger removes the search-index rows.
- Sub-agent (delegate) sessions started by those sessions. Hermes `delete_session` removes them.
- The session transcript files `<id>.json` / `<id>.jsonl` and request dumps `request_dump_<id>_*.json` in `~/.hermes/sessions`.
- The proxy's ownership record.
- The copy on this device.

## What remains (not removed by the app)

- **Backups and snapshots** of the VPS or `~/.hermes` that were taken before the deletion.
- **SQLite free pages and the WAL file.** Deleted rows can linger on disk until SQLite reuses the pages or someone runs `VACUUM`. The app never runs `VACUUM`.
- **Logs.** This covers Hermes' own logs and journald, plus anything a model provider keeps on its side. The proxy's audit log keeps request paths and ids, never content.
- **Long-term memory.** Facts the agent saved to its memory store during the chat are separate from the conversation.
- **Branches made with `/branch` (forks).** These are separate conversations, and each is deleted on its own.
- **Scheduled-task (cron) runs, Telegram sessions and other non-`ios_` sessions.** These are never touched.
- **Idempotency fingerprints** Hermes keeps for recent requests. These hold no message content.

## Limits

- Archive and delete work on the **default** Hermes profile only. For chats on other profiles, the app says so and changes nothing.
- A chat deleted from another device disappears from the server. A stale copy on this device stays until you delete it there too. The app never removes local chats just because the server didn't list them.
- Opening an archived chat that exists only on the server imports its root transcript. For a compressed chat, that's the part before the first compression.
- Not yet verified against the live VPS. The proxy isn't deployed there, and nothing here has been run against production data.
