"""Durable, resumable run-event relay between Hermes and the app.

Why it exists (verified in hermes-agent 284d220, ``gateway/platforms/api_server_runs.py``):

* ``GET /v1/runs/{id}/events`` has ONE consumer. When that connection closes for any
  reason, ``_handle_run_events`` calls ``_drop_run_transport`` — the run's event queue is
  deleted, ``_text_cb`` stops producing ``message.delta`` events, and re-subscribing returns
  404. A phone that loses its socket for a second (backgrounding, a tunnel hiccup, switching
  Wi-Fi → cellular) therefore loses every later token and tool event; only the final output
  is recoverable, by polling ``GET /v1/runs/{id}``.
* Events carry no sequence number, so a client cannot resume or de-duplicate.

The relay subscribes to Hermes itself the moment a run is accepted, so Hermes always has
a live consumer regardless of the phone. Every event gets a per-run sequence number and is
kept in a bounded buffer. The app reads ``GET /brainbox/runs/{id}/events?after=<seq>`` and
can reconnect at any time without losing, duplicating or re-ordering events.

Truthfulness rules:

* Only Hermes events are relayed as run events. The relay's own frames use the
  ``brainbox.*`` namespace: ``brainbox.heartbeat`` (transport liveness — never progress),
  ``brainbox.upstream`` (the relay lost / regained Hermes' stream) and ``brainbox.snapshot``
  (text whose individual events were evicted from the buffer).
* If Hermes' stream ends without a terminal event, the relay follows the run by status and
  emits the terminal event Hermes reports, marked ``"source": "status"``.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Callable

log = logging.getLogger("brainbox.run_relay")

TERMINAL_EVENTS = {"run.completed", "run.failed", "run.cancelled", "run.interrupted"}
TERMINAL_STATUSES = {"completed", "failed", "cancelled", "interrupted"}

@dataclass
class RelayLimits:
    max_events: int = 20_000           # per run; older events are folded into a snapshot
    retention_seconds: float = 900     # keep a finished run this long for late readers
    max_runs: int = 200                # tracked runs (oldest finished evicted first)
    heartbeat_seconds: float = 15      # transport heartbeat to subscribers
    status_poll_seconds: float = 3     # after Hermes' stream is lost
    status_refresh_seconds: float = 30  # Hermes' own status, reported in heartbeats
    subscribe_attempts: int = 5        # Hermes registers the stream just after 202


@dataclass
class RelayedRun:
    run_id: str
    owner: str
    profile: str | None
    path_prefix: str
    key: str
    created_at: float = field(default_factory=time.time)
    events: deque = field(default_factory=deque)   # (seq, frame_bytes, name)
    next_seq: int = 1
    # Concatenated message.delta text of events evicted from `events`.
    evicted_text: str = ""
    evicted_through: int = 0
    upstream: str = "connecting"      # connecting | live | lost | polling | closed | gone
    last_event_at: float | None = None  # last real Hermes event
    upstream_alive_at: float | None = None  # last byte from Hermes (incl. keepalive)
    hermes_status: str | None = None
    hermes_last_event: str | None = None
    finished_at: float | None = None
    task: asyncio.Task | None = None
    delta_text: dict = field(default_factory=dict)  # seq -> delta, folded into evicted_text on eviction
    last_status_approval: str | None = None
    # Newer Hermes numbers its own events (`seq`) and resumes from Last-Event-ID; 284d220 doesn't.
    upstream_seq: int | None = None
    changed: asyncio.Event = field(default_factory=asyncio.Event)

    @property
    def finished(self) -> bool:
        return self.finished_at is not None

    @property
    def last_seq(self) -> int:
        return self.next_seq - 1

    def frames_after(self, seq: int) -> list[tuple[int, bytes]]:
        return [(s, frame) for s, frame, _ in self.events if s > seq]

    def snapshot_frame(self) -> bytes:
        payload = {"event": "brainbox.snapshot", "run_id": self.run_id, "seq": self.evicted_through,
                   "text": self.evicted_text, "reason": "evicted"}
        return sse_frame(payload, event_id=self.evicted_through)

    def heartbeat_frame(self, now: float) -> bytes:
        payload = {"event": "brainbox.heartbeat", "run_id": self.run_id, "server_time": now,
                   "last_seq": self.last_seq, "last_event_at": self.last_event_at,
                   "upstream": self.upstream, "upstream_alive_at": self.upstream_alive_at,
                   "hermes_status": self.hermes_status, "hermes_last_event": self.hermes_last_event}
        # No `id:` — a heartbeat must never move the client's resume cursor.
        return sse_frame(payload, event_id=None, event="brainbox.heartbeat")


def sse_frame(payload: dict[str, Any], *, event_id: int | None, event: str | None = None) -> bytes:
    parts = []
    if event_id is not None:
        parts.append(f"id: {event_id}")
    if event:
        parts.append(f"event: {event}")
    parts.append("data: " + json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    return ("\n".join(parts) + "\n\n").encode()


class RunRelay:
    def __init__(self, hermes_url: str, client_getter: Callable[[], Any], *,
                 limits: RelayLimits | None = None, clock: Callable[[], float] = time.time) -> None:
        self.hermes_url = hermes_url.rstrip("/")
        self._client_getter = client_getter
        self.limits = limits or RelayLimits()
        self.clock = clock
        self.runs: dict[str, RelayedRun] = {}

    # -- registry ----------------------------------------------------------------

    def track(self, run_id: str, *, owner: str, profile: str | None, key: str) -> RelayedRun:
        existing = self.runs.get(run_id)
        if existing is not None:
            return existing
        self.sweep()
        prefix = "" if not profile or profile == "default" else f"/p/{profile}"
        run = RelayedRun(run_id=run_id, owner=owner, profile=profile, path_prefix=prefix, key=key,
                         created_at=self.clock())
        self.runs[run_id] = run
        run.task = asyncio.get_running_loop().create_task(self._follow(run), name=f"relay-{run_id}")
        return run

    def get(self, run_id: str) -> RelayedRun | None:
        return self.runs.get(run_id)

    def sweep(self) -> None:
        now = self.clock()
        for run_id, run in list(self.runs.items()):
            if run.finished and now - (run.finished_at or now) > self.limits.retention_seconds:
                self.runs.pop(run_id, None)
        if len(self.runs) >= self.limits.max_runs:
            finished = sorted((r for r in self.runs.values() if r.finished), key=lambda r: r.finished_at or 0)
            for run in finished[: len(self.runs) - self.limits.max_runs + 1]:
                self.runs.pop(run.run_id, None)

    async def shutdown(self) -> None:
        for run in self.runs.values():  # release subscribers waiting for the next event
            run.changed.set()
        tasks = [r.task for r in self.runs.values() if r.task and not r.task.done()]
        for task in tasks:
            task.cancel()
        for task in tasks:
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass

    # -- event intake ------------------------------------------------------------

    def _append(self, run: RelayedRun, payload: dict[str, Any], *, sse_event: str | None = None) -> None:
        seq = run.next_seq
        run.next_seq += 1
        payload = dict(payload)
        payload["seq"] = seq
        name = str(payload.get("event") or "")
        run.events.append((seq, sse_frame(payload, event_id=seq, event=sse_event), name))
        if name == "message.delta":
            run.delta_text[seq] = str(payload.get("delta") or "")
        while len(run.events) > self.limits.max_events:
            old_seq, _, old_name = run.events.popleft()
            run.evicted_through = old_seq
            if old_name == "message.delta":
                run.evicted_text += run.delta_text.pop(old_seq, "")
        run.changed.set()
        run.changed = asyncio.Event()

    def _hermes_event(self, run: RelayedRun, payload: dict[str, Any]) -> bool:
        """Record one event from Hermes' stream. Returns True when it was terminal."""
        event_run = payload.get("run_id")
        if event_run is not None and event_run != run.run_id:
            log.warning("dropping event for %s on %s's stream", event_run, run.run_id)
            return False
        name = str(payload.get("event") or "")
        if not name:
            return False
        hermes_seq = payload.get("seq")
        if isinstance(hermes_seq, int) and not isinstance(hermes_seq, bool):
            if run.upstream_seq is not None and hermes_seq <= run.upstream_seq:
                return False  # replayed by Hermes after we resumed: already relayed
            run.upstream_seq = hermes_seq
        if name == "replay.truncated":
            # Hermes evicted events we never received; its final output still arrives with run.completed.
            self._upstream(run, "truncated", "Hermes dropped some events before the relay could read them.")
            return False
        run.last_event_at = self.clock()
        run.hermes_last_event = name
        if name == "approval.request":
            run.last_status_approval = str(payload.get("request_id") or payload.get("command") or "")
        self._append(run, payload)
        if name in TERMINAL_EVENTS:
            run.hermes_status = name.split(".", 1)[1]
            return True
        return False

    def _upstream(self, run: RelayedRun, state: str, detail: str | None = None) -> None:
        if run.upstream == state:
            return
        run.upstream = state
        payload: dict[str, Any] = {"event": "brainbox.upstream", "run_id": run.run_id, "state": state}
        if detail:
            payload["detail"] = detail
        self._append(run, payload)

    def _finish(self, run: RelayedRun) -> None:
        if run.finished_at is None:
            run.finished_at = self.clock()
            run.upstream = "closed"
            run.changed.set()
            run.changed = asyncio.Event()

    # -- following Hermes --------------------------------------------------------

    def _headers(self, run: RelayedRun, accept: str) -> dict[str, str]:
        return {"Authorization": f"Bearer {run.key}", "Accept": accept}

    async def _status(self, run: RelayedRun) -> tuple[int, Any]:
        client = self._client_getter()
        url = f"{self.hermes_url}{run.path_prefix}/v1/runs/{run.run_id}"
        try:
            async with client.get(url, headers=self._headers(run, "application/json"), allow_redirects=False) as resp:
                try:
                    data = await resp.json(content_type=None)
                except (ValueError, UnicodeDecodeError):
                    data = None
                return resp.status, data
        except (OSError, asyncio.TimeoutError) as exc:
            log.info("status for %s failed: %s", run.run_id, exc)
            return 0, None

    async def _stream(self, run: RelayedRun) -> str:
        """Read Hermes' SSE stream. Returns 'terminal', 'not_found' or 'dropped'."""
        client = self._client_getter()
        url = f"{self.hermes_url}{run.path_prefix}/v1/runs/{run.run_id}/events"
        headers = self._headers(run, "text/event-stream")
        if run.upstream_seq is not None:
            headers["Last-Event-ID"] = str(run.upstream_seq)
        async with client.get(url, headers=headers, allow_redirects=False) as resp:
            if resp.status == 404:
                return "not_found"
            if resp.status >= 300:
                log.warning("Hermes refused the event stream for %s: %s", run.run_id, resp.status)
                return "dropped"
            self._upstream(run, "live")
            data_lines: list[str] = []
            async for raw in resp.content:
                run.upstream_alive_at = self.clock()
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if line == "":
                    if data_lines:
                        text = "\n".join(data_lines)
                        data_lines = []
                        try:
                            payload = json.loads(text)
                        except ValueError:
                            continue
                        if isinstance(payload, dict) and self._hermes_event(run, payload):
                            return "terminal"
                    continue
                if line.startswith(":"):
                    continue  # Hermes keepalive comment
                if line.startswith("data:"):
                    data_lines.append(line[5:].lstrip(" ") if line[5:6] == " " else line[5:])
            return "dropped"

    async def _refresh_status_forever(self, run: RelayedRun) -> None:
        while not run.finished:
            await asyncio.sleep(self.limits.status_refresh_seconds)
            status, data = await self._status(run)
            if status == 200 and isinstance(data, dict):
                run.hermes_status = str(data.get("status") or "") or run.hermes_status

    async def _follow(self, run: RelayedRun) -> None:
        refresher = asyncio.get_running_loop().create_task(self._refresh_status_forever(run))
        try:
            outcome = "not_found"
            for attempt in range(self.limits.subscribe_attempts):
                try:
                    outcome = await self._stream(run)
                except (OSError, asyncio.TimeoutError) as exc:
                    log.info("Hermes stream for %s broke: %s", run.run_id, exc)
                    outcome = "dropped"
                except asyncio.CancelledError:
                    raise
                except Exception as exc:  # aiohttp payload errors: the stream was cut
                    log.info("Hermes stream for %s ended abruptly: %s", run.run_id, exc)
                    outcome = "dropped"
                if outcome != "not_found" or run.next_seq > 1:
                    break
                await asyncio.sleep(0.3 * (attempt + 1))
            # Newer Hermes resumes a stream from Last-Event-ID: re-open it before giving up on live events.
            resumes = 0
            while outcome == "dropped" and run.upstream_seq is not None and resumes < self.limits.subscribe_attempts:
                resumes += 1
                self._upstream(run, "reconnecting", "Reconnecting to Hermes' event stream.")
                await asyncio.sleep(0.5 * resumes)
                try:
                    outcome = await self._stream(run)
                except Exception as exc:  # noqa: BLE001 — OSError, timeouts, aiohttp payload errors
                    log.info("Hermes stream for %s broke again: %s", run.run_id, exc)
                    outcome = "dropped"
            if outcome == "terminal":
                return
            # 284d220 deletes a run's queue when its consumer disconnects, so the stream can't be
            # re-opened: follow the run by status and relay the terminal state Hermes reports.
            self._upstream(run, "polling", "Hermes' live stream ended early; following the run by status.")
            await self._poll_until_terminal(run)
        except asyncio.CancelledError:
            raise
        finally:
            refresher.cancel()
            self._finish(run)

    async def _poll_until_terminal(self, run: RelayedRun) -> None:
        failures = 0
        while True:
            status, data = await self._status(run)
            if status == 404:
                self._upstream(run, "gone", "Hermes no longer tracks this run.")
                return
            if status == 200 and isinstance(data, dict):
                failures = 0
                state = str(data.get("status") or "")
                run.hermes_status = state or run.hermes_status
                run.hermes_last_event = data.get("last_event") or run.hermes_last_event
                if state in TERMINAL_STATUSES:
                    payload: dict[str, Any] = {"event": f"run.{state}", "run_id": run.run_id, "source": "status",
                                               "timestamp": data.get("updated_at") or self.clock()}
                    for key in ("output", "error", "usage", "pending_steer"):
                        if data.get(key) is not None:
                            payload[key] = data[key]
                    run.last_event_at = self.clock()
                    self._append(run, payload)
                    return
                if state == "waiting_for_approval" and isinstance(data.get("approval"), dict):
                    # The approval event itself may have been lost with the stream.
                    approval = dict(data["approval"])
                    approval.update({"event": "approval.request", "run_id": run.run_id, "source": "status"})
                    marker = str(approval.get("request_id") or approval.get("command") or "")
                    if run.last_status_approval != marker:
                        run.last_status_approval = marker
                        self._append(run, approval)
            else:
                failures += 1
                if failures >= 200:  # ~10 minutes of Hermes being unreachable
                    self._upstream(run, "gone", "Hermes stopped answering about this run.")
                    return
            await asyncio.sleep(self.limits.status_poll_seconds)

    # -- serving the app ---------------------------------------------------------

    async def serve(self, run: RelayedRun, response: Any, after: int, *, is_closing: Callable[[], bool]) -> None:
        """Write frames after `after` to an already-prepared SSE response until the run ends."""
        await response.write(b"retry: 3000\n\n")
        cursor = max(0, after)
        if cursor < run.evicted_through:
            await response.write(run.snapshot_frame())
            cursor = run.evicted_through
        last_write = self.clock()
        while True:
            waiter = run.changed
            frames = run.frames_after(cursor)
            for seq, frame in frames:
                await response.write(frame)
                cursor = seq
            if frames:
                last_write = self.clock()
            if run.finished and cursor >= run.last_seq:
                await response.write(b": stream closed\n\n")
                return
            if is_closing():
                return
            timeout = max(0.5, self.limits.heartbeat_seconds - (self.clock() - last_write))
            try:
                await asyncio.wait_for(waiter.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                await response.write(run.heartbeat_frame(self.clock()))
                last_write = self.clock()
