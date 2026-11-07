// The PC's Hermes engine: one SSH connection, the gateway, and the chats open on it.
// Port of HermesKit/Engine/HermesEngine.swift: chats are keyed by Hermes' stored session id; after
// any drop the engine reconnects, re-attaches each open chat (`session.resume`) and fills the gap
// from `session.events.since`, skipping events it already applied (by seq).
import { EventEmitter } from "node:events";
import {
  GatewayEvent, Json, PendingRequest, Transcript, TranscriptState, arr, bool, displayText, get, str, stripBoxDrawing,
} from "../../shared/transcript";
import { BackendError, BackendRecord, RemoteBackend } from "./backend";
import { ClientOptions, HermesClient } from "./client";
import { RPCError, parseEvent } from "./rpc";
import { SSHError, hostId } from "./ssh";

export interface EnginePersistence {
  loadBackend(hostId: string): BackendRecord | undefined;
  saveBackend(hostId: string, record: BackendRecord | undefined): void;
}

export interface ServerInfo {
  target: string;
  hostFingerprint: string;
  version?: string;
  hermesPath: string;
  reusedBackend: boolean;
}

export type LinkState =
  | { kind: "idle" }
  | { kind: "connecting"; step: string }
  | { kind: "connected"; info: ServerInfo }
  | { kind: "reconnecting"; attempt: number; reason: string }
  | { kind: "failed"; message: string };

export interface Attachment {
  filename: string;
  data: Buffer;
  isImage: boolean;
}

interface Chat {
  liveId: string;
  transcript: Transcript;
}

const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

/** Events: "state" (LinkState), "transcript" (chat, state), "turnFinished" (chat, title, text),
 *  "needsAttention" (chat, title, request), "event" (GatewayEvent), "prefill" (chat, text). */
export class HermesEngine extends EventEmitter {
  state: LinkState = { kind: "idle" };
  client?: HermesClient;
  private options?: ClientOptions;
  private wantConnected = false;
  private reconnectTimer?: NodeJS.Timeout;
  private chats = new Map<string, Chat>();
  private liveToChat = new Map<string, string>();
  private batchAnswers = new Map<string, Record<string, Json>>();

  constructor(private persistence: EnginePersistence) {
    super();
    this.setMaxListeners(50);
  }

  private setState(s: LinkState) {
    this.state = s;
    this.emit("state", s);
  }

  private publish(key: string, chat: Chat) {
    this.emit("transcript", key, chat.transcript.snapshot());
  }

  // ------------------------------------------------------------ connection

  async connect(options: ClientOptions) {
    this.options = options;
    this.wantConnected = true;
    clearTimeout(this.reconnectTimer);
    await this.establish(false);
  }

  disconnect() {
    this.wantConnected = false;
    clearTimeout(this.reconnectTimer);
    const c = this.client;
    this.client = undefined;
    c?.close();
    this.setState({ kind: "idle" });
  }

  /** Stops the backend this PC started on the server, then disconnects. */
  async stopBackend() {
    if (this.client && this.options) {
      await new RemoteBackend(this.client.ssh, this.options.ownershipId).stop(this.client.backend.record);
      this.persistence.saveBackend(hostId(this.options.target), undefined);
    }
    this.disconnect();
  }

  /** Window shown again / network back: keep a link that answers, otherwise rebuild at once. */
  async ensureAlive(): Promise<boolean> {
    if (!this.wantConnected) return false;
    if (this.client && await this.client.isAlive(2000)) return true;
    clearTimeout(this.reconnectTimer);
    const c = this.client;
    this.client = undefined;
    c?.close();
    await this.establish(true, "Reconnecting");
    return false;
  }

  private async establish(isReconnect: boolean, reason = "") {
    if (!this.options) return;
    const options = { ...this.options, knownBackend: this.persistence.loadBackend(hostId(this.options.target)) };
    this.setState(isReconnect ? { kind: "reconnecting", attempt: 1, reason } : { kind: "connecting", step: "Connecting over SSH" });
    try {
      const client = await HermesClient.connect(options, (s) => {
        if (isReconnect) return;
        if (s.step === "ssh") this.setState({ kind: "connecting", step: "Connecting over SSH" });
        else if (s.step === "backend") this.setState({ kind: "connecting", step: s.detail });
        else this.setState({ kind: "connecting", step: "Opening Hermes" });
      });
      this.persistence.saveBackend(hostId(options.target), client.backend.record);
      this.client = client;
      client.rpc.on("event", (e: GatewayEvent) => this.route(e));
      client.rpc.once("close", () => this.lost(client));
      client.ssh.onClose(() => this.lost(client));
      await this.reattachChats();
      this.setState({
        kind: "connected",
        info: {
          target: `${options.target.username}@${options.target.host}`,
          hostFingerprint: client.ssh.hostFingerprint,
          version: client.backend.version,
          hermesPath: client.backend.record.hermesPath,
          reusedBackend: client.backend.reused,
        },
      });
    } catch (err) {
      this.client = undefined;
      const fatal = (err instanceof SSHError && (err.code === "hostKeyChanged" || err.code === "auth")) ||
        (err instanceof BackendError && err.code === "gated");
      if (fatal) {
        this.wantConnected = false;
        this.setState({ kind: "failed", message: errorText(err) });
      } else if (isReconnect || this.state.kind === "connected") {
        this.scheduleReconnect(errorText(err), 1);
      } else {
        this.setState({ kind: "failed", message: errorText(err) });
      }
    }
  }

  private scheduleReconnect(reason: string, attempt: number) {
    if (!this.wantConnected) return;
    this.setState({ kind: "reconnecting", attempt, reason });
    clearTimeout(this.reconnectTimer);
    const delay = Math.min(30_000, 2 ** Math.min(attempt, 5) * 500);
    this.reconnectTimer = setTimeout(async () => {
      if (!this.wantConnected) return;
      await this.establish(true, "Reconnecting");
      if (this.state.kind === "reconnecting") this.scheduleReconnect("Still reconnecting", attempt + 1);
    }, delay);
  }

  private lost(dropped: HermesClient) {
    if (this.client !== dropped) return;
    this.client = undefined;
    dropped.close();
    this.scheduleReconnect("Connection lost", 1);
  }

  // ------------------------------------------------------------ events

  private route(event: GatewayEvent) {
    this.emit("event", event);
    if (!event.sessionId) return;
    const key = this.liveToChat.get(event.sessionId);
    const chat = key ? this.chats.get(key) : undefined;
    if (!key || !chat) return;
    const wasBusy = chat.transcript.busy;
    const before = new Set(chat.transcript.pendingRequests.map((r) => r.requestId));
    if (!chat.transcript.apply(event)) return;
    this.publish(key, chat);
    // Another device on this backend started the turn: fetch its prompt so both screens match.
    if (chat.transcript.remoteTurn && (event.type === "message.start" || event.type === "message.complete")) {
      void this.fetchRemotePrompt(key, chat);
    }
    const title = chat.transcript.title ?? "Hermes";
    if (event.type === "message.complete" && wasBusy) this.emit("turnFinished", key, title, chat.transcript.lastCompletedText ?? "");
    for (const r of chat.transcript.pendingRequests) if (!before.has(r.requestId)) this.emit("needsAttention", key, title, r);
    // Desktop-window tools (preview, window reads) don't exist here: answer so the agent moves on.
    const unsupported: Record<string, [string, string]> = {
      "terminal.read.request": ["terminal.read.respond", "text"],
      "preview.read.request": ["preview.read.respond", "text"],
      "preview.act.request": ["preview.act.respond", "text"],
      "window.read.request": ["window.read.respond", "text"],
      "tour.request": ["tour.respond", "text"],
    };
    const reply = unsupported[event.type];
    const rid = str(get(event.payload, "request_id"));
    if (reply && rid && this.client) this.client.call(reply[0], { request_id: rid, [reply[1]]: "" }).catch(() => {});
  }

  private async fetchRemotePrompt(key: string, chat: Chat, attempt = 0) {
    const client = this.client;
    if (!client) return;
    const r = await client.call("session.history", { session_id: chat.liveId }, 20_000).catch(() => null);
    if (this.chats.get(key) !== chat || !chat.transcript.remoteTurn) return;
    if (chat.transcript.placeRemotePrompt(arr(get(r, "messages")) ?? [])) this.publish(key, chat);
    else if (!chat.transcript.busy && attempt < 4) setTimeout(() => void this.fetchRemotePrompt(key, chat, attempt + 1), 600 * (attempt + 1));
  }

  /** Catches every open chat up with other devices (window back in front). */
  async refreshAll() {
    await Promise.all([...this.chats.keys()].map((k) => this.refresh(k).catch(() => {})));
  }

  /** Brings an idle chat up to date with what other devices did (window focus, chat reopened). */
  async refresh(key: string) {
    const chat = this.chats.get(key);
    const client = this.client;
    if (!chat || !client || chat.transcript.busy) return;
    const r = await client.call("session.history", { session_id: chat.liveId }, 20_000).catch(() => null);
    const messages = arr(get(r, "messages"));
    if (!messages || chat.transcript.busy || this.chats.get(key) !== chat) return;
    const shown = chat.transcript.items.filter((i) => i.kind === "user" || i.kind === "assistant").length;
    const stored = messages.filter((m) => { const role = str(get(m, "role")); return role === "user" || (role === "assistant" && (str(get(m, "text")) ?? "")); }).length;
    if (stored !== shown) {
      chat.transcript.hydrate(messages);
      this.publish(key, chat);
    }
  }

  private applyOpenRequests(chat: Chat, live: string, frames: Json[]) {
    for (const f of frames) {
      const id = get(f, "id");
      const method = str(get(f, "method"));
      if (id !== undefined && method) {
        chat.transcript.apply({ type: "server.request", sessionId: live, payload: { id, method, params: get(f, "params") ?? null } });
      }
    }
  }

  private async reattachChats() {
    const client = this.client;
    if (!client) return;
    await Promise.all([...this.chats.entries()].map(async ([key, chat]) => {
      let resumed: Json;
      try {
        resumed = await client.call("session.resume", { session_id: key }, 60_000);
      } catch {
        return;
      }
      const live = str(get(resumed, "session_id")) ?? chat.liveId;
      const since = await client.call("session.events.since", { session_id: live, last_seen: chat.transcript.lastSeq }).catch(() => null);
      this.liveToChat.delete(chat.liveId);
      this.liveToChat.set(live, key);
      chat.liveId = live;
      for (const raw of arr(get(since, "events")) ?? []) {
        const e = parseEvent(raw);
        if (e) chat.transcript.apply(e);
      }
      this.applyOpenRequests(chat, live, [...(arr(get(resumed, "open_requests")) ?? []), ...(arr(get(since, "open_requests")) ?? [])]);
      // A turn that ended while we were away and isn't in the replay window.
      if (chat.transcript.busy && bool(get(resumed, "running")) === false && bool(get(resumed, "inflight")) !== true) {
        chat.transcript.busy = false;
        chat.transcript.status = undefined;
        chat.transcript.hydrate(arr(get(resumed, "messages")) ?? []);
      }
      this.publish(key, chat);
    }));
  }

  // ------------------------------------------------------------ chats

  private requireClient(): HermesClient {
    if (!this.client) throw RPCError.disconnected();
    return this.client;
  }

  private chat(key: string): Chat {
    const chat = this.chats.get(key);
    if (!chat) throw new RPCError(-1, "That chat isn't open.");
    return chat;
  }

  transcript(key: string): TranscriptState | undefined { return this.chats.get(key)?.transcript.snapshot(); }

  call(key: string | undefined, method: string, params: Record<string, Json> = {}, timeoutMs = 60_000) {
    const client = this.requireClient();
    const p = { ...params };
    if (key && p.session_id === undefined) p.session_id = this.chat(key).liveId;
    return client.call(method, p, timeoutMs);
  }

  async newChat(): Promise<string> {
    const client = this.requireClient();
    const r = await client.call("session.create", {});
    const live = str(get(r, "session_id"));
    if (!live) throw new RPCError(-1, "Hermes didn't create a session.");
    const key = str(get(r, "stored_session_id")) ?? live;
    const chat: Chat = { liveId: live, transcript: new Transcript() };
    chat.transcript.model = str(get(get(r, "info"), "model"));
    this.chats.set(key, chat);
    this.liveToChat.set(live, key);
    this.publish(key, chat);
    return key;
  }

  async open(stored: string): Promise<TranscriptState> {
    const client = this.requireClient();
    const existing = this.chats.get(stored);
    if (existing) return existing.transcript.snapshot();
    const r = await client.call("session.resume", { session_id: stored }, 90_000);
    const live = str(get(r, "session_id"));
    if (!live) throw new RPCError(-1, "Hermes couldn't open that session.");
    const chat: Chat = { liveId: live, transcript: new Transcript() };
    chat.transcript.hydrate(arr(get(r, "messages")) ?? []);
    chat.transcript.model = str(get(get(r, "info"), "model"));
    chat.transcript.busy = bool(get(r, "running")) === true || bool(get(r, "inflight")) === true;
    this.applyOpenRequests(chat, live, arr(get(r, "open_requests")) ?? []);
    this.chats.set(stored, chat);
    this.liveToChat.set(live, stored);
    this.publish(stored, chat);
    return chat.transcript.snapshot();
  }

  async closeChat(key: string) {
    const chat = this.chats.get(key);
    if (!chat) return;
    this.chats.delete(key);
    this.liveToChat.delete(chat.liveId);
    if (!chat.transcript.busy && this.client) await this.client.call("session.close", { session_id: chat.liveId }).catch(() => {});
  }

  async send(key: string, text: string, attachments: Attachment[] = []) {
    const client = this.requireClient();
    const chat = this.chat(key);
    for (const a of attachments) {
      if (a.isImage) {
        const ext = (a.filename.split(".").pop() ?? "jpg").toLowerCase();
        await client.call("image.attach_bytes", { session_id: chat.liveId, data: a.data.toString("base64"), ext, filename: a.filename }, 120_000);
      } else {
        await client.call("file.attach", { session_id: chat.liveId, data_url: "data:application/octet-stream;base64," + a.data.toString("base64"), name: a.filename }, 120_000);
      }
    }
    chat.transcript.addUser(text, attachments.map((a) => a.filename));
    this.publish(key, chat);
    try {
      await client.call("prompt.submit", { session_id: chat.liveId, text });
    } catch (err) {
      chat.transcript.sendFailed();
      chat.transcript.addError(errorText(err) || "Couldn't send.");
      this.publish(key, chat);
      throw err;
    }
  }

  async interrupt(key: string) {
    const chat = this.chat(key);
    await this.requireClient().call("session.interrupt", { session_id: chat.liveId });
    chat.transcript.status = "Stopping";
    this.publish(key, chat);
  }

  /** Answers an approval / clarify / sudo / secret card, in whichever style this Hermes asked. */
  async respond(key: string, requestId: string, answer: string, questionId?: string) {
    const client = this.requireClient();
    const chat = this.chat(key);
    const request = chat.transcript.items.flatMap((i) => (i.kind === "request" && i.request.requestId === requestId ? [i.request] : []))[0];
    if (!request) throw new RPCError(-1, "That question isn't open any more.");
    const kind = request.request.kind;
    const label = kind === "approval" ? (answer === "deny" ? "Denied" : `Approved (${answer})`)
      : kind === "sudo" || kind === "secret" ? (answer ? "Sent" : "Skipped") : answer;

    if (request.serverRequestId !== undefined) {
      let result: Json;
      if (kind === "approval") result = { choice: answer };
      else if (kind === "clarify") result = { answers: { [request.questionId ?? questionId ?? "q1"]: answer } };
      else if (kind === "clarifyBatch") {
        const qs = (request.request as { questions: { id: string }[] }).questions;
        const answers = { ...(this.batchAnswers.get(requestId) ?? {}), [questionId ?? qs[0]?.id ?? "q1"]: answer };
        this.batchAnswers.set(requestId, answers);
        if (Object.keys(answers).length < qs.length) return;
        this.batchAnswers.delete(requestId);
        result = { answers };
      } else result = { value: answer };
      await client.rpc.reply(request.serverRequestId, result);
      chat.transcript.resolve(requestId, label);
      this.publish(key, chat);
      return;
    }

    const params: Record<string, Json> = { session_id: chat.liveId, request_id: requestId };
    const method = kind === "approval" ? "approval.respond" : kind === "sudo" ? "sudo.respond" : kind === "secret" ? "secret.respond" : "clarify.respond";
    if (kind === "approval") params.choice = answer;
    else if (kind === "sudo") params.password = answer;
    else if (kind === "secret") params.value = answer;
    else { params.answer = answer; if (questionId) params.question_id = questionId; }
    const r = await client.call(method, params);
    if (str(get(r, "status")) === "expired") chat.transcript.resolve(requestId, "Expired");
    else if (!questionId || !(arr(get(r, "remaining"))?.length)) chat.transcript.resolve(requestId, label);
    this.publish(key, chat);
  }

  /** Runs a slash command the way Desktop does; skill and queue commands come back as a message to send. */
  async slash(key: string, line: string): Promise<void> {
    const client = this.requireClient();
    const chat = this.chat(key);
    const trimmed = line.trim();
    const name = trimmed.slice(1).split(" ")[0] ?? "";
    const arg = trimmed.includes(" ") ? trimmed.slice(trimmed.indexOf(" ") + 1) : "";
    let r: Json;
    try {
      r = await client.call("slash.exec", { session_id: chat.liveId, command: trimmed }, 120_000);
    } catch (err) {
      if (err instanceof RPCError && (err.code === 4018 || (err.code === 4004 && arg))) {
        r = await client.call("command.dispatch", { session_id: chat.liveId, name, arg }, 120_000);
      } else throw err;
    }
    const type = str(get(r, "type"));
    if (type === "alias" && str(get(r, "target"))) {
      const target = str(get(r, "target"))!;
      return this.slash(key, target.startsWith("/") ? target : "/" + target);
    }
    const notice = str(get(r, "notice"));
    if (notice) chat.transcript.addNotice(notice);
    if (type === "send") {
      const message = str(get(r, "message")) ?? "";
      if (message) {
        chat.transcript.addUser(trimmed);
        this.publish(key, chat);
        await client.call("prompt.submit", { session_id: chat.liveId, text: message });
      }
    } else if (type === "prefill") {
      this.emit("prefill", key, str(get(r, "message")) ?? "");
    } else {
      chat.transcript.addCommand(trimmed, stripBoxDrawing(str(get(r, "output")) ?? displayText(r)));
    }
    this.publish(key, chat);
  }

  async background(key: string, text: string) {
    const chat = this.chat(key);
    const r = await this.requireClient().call("prompt.background", { session_id: chat.liveId, text });
    chat.transcript.addSide("bg-" + (str(get(r, "task_id")) ?? Date.now().toString(36)), "background", text);
    this.publish(key, chat);
  }

  async btw(key: string, text: string) {
    const chat = this.chat(key);
    await this.requireClient().call("prompt.btw", { session_id: chat.liveId, text });
    chat.transcript.status = "Answering your side question";
    this.publish(key, chat);
  }

  pending(key: string): PendingRequest[] { return this.chats.get(key)?.transcript.pendingRequests ?? []; }
}
