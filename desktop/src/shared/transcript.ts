// One chat's state, built only from what Hermes' gateway reports.
// A TypeScript port of Packages/HermesKit/Sources/HermesKit/Chat/Transcript.swift — keep the two in step.

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type JsonObject = { [key: string]: Json };

export interface GatewayEvent {
  type: string;
  sessionId?: string;
  seq?: number;
  payload: Json;
}

export interface ToolActivity {
  id: string;
  name: string;
  context: string;
  args: Json;
  status: "running" | "done" | "failed";
  duration?: number;
  output: string;
  inlineDiff?: string;
  approvalNote?: string;
}

export interface ClarifyQuestion {
  id: string;
  question: string;
  choices: string[];
  multiSelect: boolean;
}

export type RequestKind =
  | { kind: "approval"; command: string; description: string; choices: string[] }
  | { kind: "clarify"; question: string; choices: string[]; multiSelect: boolean }
  | { kind: "clarifyBatch"; questions: ClarifyQuestion[] }
  | { kind: "sudo" }
  | { kind: "secret"; prompt: string; envVar: string };

export interface PendingRequest {
  requestId: string;
  request: RequestKind;
  /** Set once answered (or expired) so the card shows the outcome. */
  resolution?: string;
  /** Newer Hermes asks with a JSON-RPC request (answered by id) instead of an event + `*.respond`. */
  serverRequestId?: Json;
  questionId?: string;
}

export type ChatItemKind =
  | { kind: "user"; text: string; attachments: string[] }
  | { kind: "assistant"; text: string; reasoning?: string; streaming: boolean }
  | { kind: "tool"; tool: ToolActivity }
  | { kind: "request"; request: PendingRequest }
  | { kind: "command"; name: string; output: string }
  | { kind: "side"; label: string; title: string; text: string; done: boolean }
  | { kind: "notice"; text: string; level: string }
  | { kind: "error"; text: string };

export type ChatItem = ChatItemKind & { id: string; date: number };

export interface TodoItem {
  id: string;
  content: string;
  status: string;
}

export interface UsageInfo {
  model?: string;
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  contextPercent?: number;
  costUSD?: number;
}

export interface TranscriptState {
  items: ChatItem[];
  title?: string;
  busy: boolean;
  status?: string;
  todos: TodoItem[];
  usage?: UsageInfo;
  model?: string;
  lastSeq: number;
  lastCompletedText?: string;
}

// ---------------------------------------------------------------- JSON helpers

export function get(value: Json | undefined, key: string): Json | undefined {
  if (value && typeof value === "object" && !Array.isArray(value)) return (value as JsonObject)[key];
  return undefined;
}
export const str = (v: Json | undefined): string | undefined => (typeof v === "string" ? v : undefined);
export const num = (v: Json | undefined): number | undefined => (typeof v === "number" ? v : undefined);
export const bool = (v: Json | undefined): boolean | undefined => (typeof v === "boolean" ? v : undefined);
export const arr = (v: Json | undefined): Json[] | undefined => (Array.isArray(v) ? v : undefined);
export const strings = (v: Json | undefined): string[] => (arr(v) ?? []).filter((x): x is string => typeof x === "string");

export function displayText(v: Json | undefined): string {
  if (v === undefined || v === null) return "";
  if (typeof v === "string") return v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  return JSON.stringify(v, null, 2);
}

let counter = 0;
const newId = (prefix: string) => `${prefix}${Date.now().toString(36)}-${(counter++).toString(36)}`;

function cleanStatus(text: string): string {
  const t = text.trim();
  return t.length > 80 ? t.slice(0, 80) + "…" : t;
}

function usageFrom(v: Json | undefined): UsageInfo | undefined {
  if (!v || typeof v !== "object" || Array.isArray(v)) return undefined;
  const input = num(get(v, "input")) ?? num(get(v, "prompt")) ?? 0;
  const output = num(get(v, "output")) ?? num(get(v, "completion")) ?? 0;
  return {
    model: str(get(v, "model")),
    inputTokens: input,
    outputTokens: output,
    totalTokens: num(get(v, "total")) ?? input + output,
    contextPercent: num(get(v, "context_percent")),
    costUSD: num(get(v, "cost_usd")) ?? num(get(v, "cost")),
  };
}

function questionsFrom(v: Json | undefined): ClarifyQuestion[] {
  return (arr(v) ?? []).map((q) => ({
    id: str(get(q, "qid")) ?? newId("q"),
    question: str(get(q, "question")) ?? "",
    choices: strings(get(q, "choices")),
    multiSelect: bool(get(q, "multi_select")) ?? false,
  }));
}

// ---------------------------------------------------------------- Transcript

export class Transcript implements TranscriptState {
  items: ChatItem[] = [];
  title?: string;
  busy = false;
  status?: string;
  todos: TodoItem[] = [];
  usage?: UsageInfo;
  model?: string;
  lastSeq = 0;
  lastCompletedText?: string;

  /** The running turn was started by another device (phone / another PC): its prompt isn't here yet. */
  remoteTurn = false;
  private turnStart = 0;
  /** Prompts this device sent whose turn hasn't started yet (Hermes queues a prompt sent mid-reply). */
  private localPending = 0;
  private streamingId?: string;
  private seen = new Set<number>();

  snapshot(): TranscriptState {
    return {
      items: this.items.map((i) => ({ ...i })) as ChatItem[],
      title: this.title,
      busy: this.busy,
      status: this.status,
      todos: [...this.todos],
      usage: this.usage,
      model: this.model,
      lastSeq: this.lastSeq,
      lastCompletedText: this.lastCompletedText,
    };
  }

  get pendingRequests(): PendingRequest[] {
    return this.items.flatMap((i) => (i.kind === "request" && !i.request.resolution ? [i.request] : []));
  }

  /** Rebuilds from `session.resume`'s `messages` (role/text/name/context/args rows). */
  hydrate(messages: Json[]): void {
    this.items = [];
    this.streamingId = undefined;
    messages.forEach((m, index) => {
      const role = str(get(m, "role")) ?? "";
      const text = str(get(m, "text")) ?? str(get(m, "content")) ?? "";
      const ts = num(get(m, "timestamp"));
      const date = ts ? ts * 1000 : Date.now();
      const row = get(m, "row_id");
      const id = row !== undefined && row !== null ? `row-${displayText(row)}` : `h-${index}`;
      if (role === "user") this.items.push({ id, date, kind: "user", text, attachments: [] });
      else if (role === "assistant" && text) {
        this.items.push({ id, date, kind: "assistant", text, reasoning: str(get(m, "reasoning")), streaming: false });
      } else if (role === "tool") {
        this.items.push({
          id, date, kind: "tool",
          tool: { id, name: str(get(m, "name")) ?? "tool", context: str(get(m, "context")) ?? "", args: get(m, "args") ?? null,
                  status: "done", output: text },
        });
      } else if (role === "system" && text) this.items.push({ id, date, kind: "notice", text, level: "info" });
    });
  }

  /** Applies one event. Returns false for a duplicate (already-applied `seq`). */
  apply(event: GatewayEvent): boolean {
    if (event.seq !== undefined) {
      if (this.seen.has(event.seq)) return false;
      this.seen.add(event.seq);
      if (this.seen.size > 4000) this.seen = new Set([...this.seen].sort((a, b) => a - b).slice(-2000));
      this.lastSeq = Math.max(this.lastSeq, event.seq);
    }
    const p = event.payload;
    switch (event.type) {
      case "message.start":
        // A turn for a prompt we sent, or one another device started?
        this.remoteTurn = this.localPending === 0;
        if (this.localPending > 0) this.localPending -= 1;
        // An interrupted reply never gets its message.complete: close it, the new turn starts fresh.
        this.finishStreaming();
        this.turnStart = this.items.length;
        this.busy = true;
        this.status = "Thinking";
        break;
      case "thinking.delta": {
        const text = str(get(p, "text")) ?? "";
        this.status = text ? cleanStatus(text) : this.busy ? "Working" : undefined;
        break;
      }
      case "reasoning.delta":
        this.appendReasoning(str(get(p, "text")) ?? "");
        break;
      case "message.delta":
        this.appendText(str(get(p, "text")) ?? "");
        this.status = "Responding";
        break;
      case "message.interim": {
        const text = str(get(p, "text"));
        if (bool(get(p, "already_streamed")) !== true && text) this.appendText(text);
        this.finishStreaming();
        break;
      }
      case "reasoning.available": {
        const text = str(get(p, "text"));
        if (text) this.setReasoning(text);
        break;
      }
      case "message.complete": {
        const text = str(get(p, "text")) ?? "";
        this.completeAssistant(text);
        const usage = usageFrom(get(p, "usage"));
        if (usage) this.usage = usage;
        this.busy = false;
        this.status = undefined;
        this.lastCompletedText = text;
        break;
      }
      case "tool.generating":
        this.finishStreaming();
        this.status = `Preparing ${str(get(p, "name")) ?? "a tool"}`;
        break;
      case "tool.start": {
        this.finishStreaming();
        const id = str(get(p, "tool_id")) ?? newId("t");
        const tool: ToolActivity = {
          id, name: str(get(p, "name")) ?? "tool", context: str(get(p, "context")) ?? "", args: get(p, "args") ?? null,
          status: "running", output: "",
        };
        this.upsert({ id: "tool-" + id, date: Date.now(), kind: "tool", tool });
        this.status = `Running ${tool.name}`;
        break;
      }
      case "tool.progress": {
        const id = str(get(p, "tool_id"));
        if (id) this.updateTool(id, (t) => { t.output += str(get(p, "text")) ?? str(get(p, "preview")) ?? ""; });
        break;
      }
      case "tool.complete": {
        const id = str(get(p, "tool_id")) ?? "";
        const result = get(p, "result") ?? null;
        const err = get(result, "error");
        const exit = num(get(result, "exit_code"));
        const failed = (err !== undefined && err !== null && displayText(err) !== "") || (exit !== undefined && exit !== 0);
        const output = str(get(result, "output")) ?? (result === null ? "" : displayText(result));
        const found = this.updateTool(id, (t) => {
          t.status = failed ? "failed" : "done";
          t.duration = num(get(p, "duration_s"));
          t.output = output;
          t.inlineDiff = str(get(p, "inline_diff"));
          t.approvalNote = str(get(result, "approval"));
        });
        if (!found) {
          this.items.push({
            id: "tool-" + id, date: Date.now(), kind: "tool",
            tool: { id, name: str(get(p, "name")) ?? "tool", context: "", args: get(p, "args") ?? null, status: failed ? "failed" : "done",
                    duration: num(get(p, "duration_s")), output, inlineDiff: str(get(p, "inline_diff")), approvalNote: str(get(result, "approval")) },
          });
        }
        this.status = this.busy ? "Working" : undefined;
        break;
      }
      case "approval.request": {
        this.finishStreaming();
        const request: PendingRequest = {
          requestId: str(get(p, "request_id")) ?? newId("r"),
          request: { kind: "approval", command: str(get(p, "command")) ?? "", description: str(get(p, "description")) ?? "",
                     choices: strings(get(p, "choices")).length ? strings(get(p, "choices")) : ["once", "deny"] },
        };
        this.upsert({ id: "req-" + request.requestId, date: Date.now(), kind: "request", request });
        this.status = "Waiting for your approval";
        break;
      }
      case "clarify.request": {
        this.finishStreaming();
        const rid = str(get(p, "request_id")) ?? newId("r");
        const questions = arr(get(p, "questions"));
        const request: RequestKind = questions
          ? { kind: "clarifyBatch", questions: questionsFrom(questions) }
          : { kind: "clarify", question: str(get(p, "question")) ?? "", choices: strings(get(p, "choices")),
              multiSelect: bool(get(p, "multi_select")) ?? false };
        this.upsert({ id: "req-" + rid, date: Date.now(), kind: "request", request: { requestId: rid, request } });
        this.status = "Hermes has a question";
        break;
      }
      case "sudo.request": {
        const rid = str(get(p, "request_id")) ?? newId("r");
        this.upsert({ id: "req-" + rid, date: Date.now(), kind: "request", request: { requestId: rid, request: { kind: "sudo" } } });
        break;
      }
      case "secret.request": {
        const rid = str(get(p, "request_id")) ?? newId("r");
        this.upsert({
          id: "req-" + rid, date: Date.now(), kind: "request",
          request: { requestId: rid, request: { kind: "secret", prompt: str(get(p, "prompt")) ?? "", envVar: str(get(p, "env_var")) ?? "" } },
        });
        break;
      }
      case "server.request": {
        this.finishStreaming();
        const id = get(p, "id");
        const method = str(get(p, "method"));
        if (id === undefined || !method) break;
        const params = get(p, "params") ?? null;
        const rid = displayText(id);
        let request: PendingRequest | undefined;
        if (method === "approval") {
          request = {
            requestId: rid, serverRequestId: id,
            request: { kind: "approval", command: str(get(params, "command")) ?? "", description: str(get(params, "description")) ?? "",
                       choices: strings(get(params, "choices")).length ? strings(get(params, "choices")) : ["once", "deny"] },
          };
          this.status = "Waiting for your approval";
        } else if (method === "clarify") {
          const qs = questionsFrom(get(params, "questions"));
          request = qs.length === 1
            ? { requestId: rid, serverRequestId: id, questionId: qs[0].id,
                request: { kind: "clarify", question: qs[0].question, choices: qs[0].choices, multiSelect: qs[0].multiSelect } }
            : { requestId: rid, serverRequestId: id, request: { kind: "clarifyBatch", questions: qs } };
          this.status = "Hermes has a question";
        } else if (method === "sudo") {
          request = { requestId: rid, serverRequestId: id, request: { kind: "sudo" } };
        } else if (method === "secret") {
          request = { requestId: rid, serverRequestId: id,
                      request: { kind: "secret", prompt: str(get(params, "prompt")) ?? "", envVar: str(get(params, "env_var")) ?? "" } };
        }
        if (request) this.upsert({ id: "req-" + rid, date: Date.now(), kind: "request", request });
        break;
      }
      case "request.cancel": {
        const id = get(p, "id");
        if (id !== undefined) this.resolve(displayText(id), "Withdrawn");
        break;
      }
      case "clarify.expire":
      case "approval.expire": {
        const rid = str(get(p, "request_id"));
        if (rid) this.resolve(rid, "Expired");
        break;
      }
      case "status.update": {
        const text = str(get(p, "text"));
        if (text) this.status = cleanStatus(text);
        break;
      }
      case "todo.updated": {
        const list = arr(get(p, "todos")) ?? arr(p) ?? [];
        this.todos = list.map((t, i) => ({
          id: get(t, "id") !== undefined ? displayText(get(t, "id")) : String(i),
          content: str(get(t, "content")) ?? str(get(t, "text")) ?? "",
          status: str(get(t, "status")) ?? "pending",
        }));
        break;
      }
      case "session.title": {
        const t = str(get(p, "title"));
        if (t) this.title = t;
        break;
      }
      case "session.usage": {
        const usage = usageFrom(get(p, "usage") ?? p);
        if (usage) this.usage = usage;
        break;
      }
      case "session.info": {
        const m = str(get(p, "model"));
        if (m) this.model = m;
        break;
      }
      case "btw.complete":
        this.items.push({ id: newId("btw-"), date: Date.now(), kind: "side", label: "btw",
                          title: str(get(p, "question")) ?? "Side question", text: str(get(p, "text")) ?? "", done: true });
        break;
      case "background.complete": {
        const task = str(get(p, "task_id")) ?? "";
        const idx = this.items.map((i) => i.id).lastIndexOf("bg-" + task);
        if (idx >= 0 && this.items[idx].kind === "side") {
          const side = this.items[idx] as Extract<ChatItem, { kind: "side" }>;
          this.items[idx] = { ...side, text: str(get(p, "text")) ?? "", done: true };
        } else {
          this.items.push({ id: "bg-" + task, date: Date.now(), kind: "side", label: "background", title: "Background task",
                            text: str(get(p, "text")) ?? "", done: true });
        }
        break;
      }
      case "notification.show":
      case "notice": {
        const text = str(get(p, "text"));
        if (text) this.items.push({ id: newId("n-"), date: Date.now(), kind: "notice", text, level: str(get(p, "level")) ?? "info" });
        break;
      }
      case "error":
        this.finishStreaming();
        this.items.push({ id: newId("e-"), date: Date.now(), kind: "error",
                          text: str(get(p, "message")) ?? str(get(p, "text")) ?? "Hermes reported an error." });
        this.busy = false;
        this.status = undefined;
        break;
      default:
        break;
    }
    return true;
  }

  // ------------------------------------------------------------ local echoes

  /** Shows the prompt another device sent, above the reply it started (from `session.history`). */
  placeRemotePrompt(messages: Json[]): boolean {
    if (!this.remoteTurn) return false;
    const last = [...messages].reverse().find((m) => str(get(m, "role")) === "user");
    const text = last ? str(get(last, "text")) ?? str(get(last, "content")) : undefined;
    if (text === undefined) return false;
    this.remoteTurn = false;
    const before = this.items[this.turnStart - 1];
    if (before?.kind === "user" && before.text === text) return true;
    const ts = num(get(last, "timestamp"));
    this.items.splice(Math.min(this.turnStart, this.items.length), 0,
      { id: newId("u-"), date: ts ? ts * 1000 : Date.now(), kind: "user", text, attachments: [] });
    return true;
  }

  addUser(text: string, attachments: string[] = []): void {
    // Sent while a reply is still streaming: Hermes queues it, and the reply keeps growing above.
    if (!this.busy) this.finishStreaming();
    this.items.push({ id: newId("u-"), date: Date.now(), kind: "user", text, attachments });
    this.localPending += 1;
    if (!this.busy) this.status = "Sending";
    this.busy = true;
  }

  /** The prompt never reached Hermes. */
  sendFailed(): void {
    if (this.localPending > 0) this.localPending -= 1;
  }

  addCommand(name: string, output: string): void {
    this.items.push({ id: newId("c-"), date: Date.now(), kind: "command", name, output });
  }

  addSide(id: string, label: string, title: string): void {
    this.items.push({ id, date: Date.now(), kind: "side", label, title, text: "", done: false });
  }

  addNotice(text: string, level = "info"): void {
    this.items.push({ id: newId("n-"), date: Date.now(), kind: "notice", text, level });
  }

  addError(text: string): void {
    this.items.push({ id: newId("e-"), date: Date.now(), kind: "error", text });
    this.busy = false;
    this.status = undefined;
  }

  resolve(requestId: string, resolution: string): void {
    const idx = this.items.findIndex((i) => i.id === "req-" + requestId);
    if (idx < 0) return;
    const item = this.items[idx];
    if (item.kind !== "request") return;
    this.items[idx] = { ...item, request: { ...item.request, resolution } };
    if (this.pendingRequests.length === 0 && this.busy) this.status = "Working";
  }

  // ------------------------------------------------------------ internals

  private appendText(delta: string): void {
    if (!delta) return;
    const idx = this.streamingId ? this.items.findIndex((i) => i.id === this.streamingId) : -1;
    const item = idx >= 0 ? this.items[idx] : undefined;
    if (item && item.kind === "assistant") {
      this.items[idx] = { ...item, text: item.text + delta, streaming: true };
    } else {
      const id = newId("a-");
      this.streamingId = id;
      this.items.push({ id, date: Date.now(), kind: "assistant", text: delta.replace(/^[\r\n]+/, ""), streaming: true });
    }
  }

  private appendReasoning(delta: string): void {
    if (!delta) return;
    const idx = this.streamingId ? this.items.findIndex((i) => i.id === this.streamingId) : -1;
    const item = idx >= 0 ? this.items[idx] : undefined;
    if (item && item.kind === "assistant") {
      this.items[idx] = { ...item, reasoning: (item.reasoning ?? "") + delta };
    } else {
      const id = newId("a-");
      this.streamingId = id;
      this.items.push({ id, date: Date.now(), kind: "assistant", text: "", reasoning: delta, streaming: true });
    }
  }

  private setReasoning(text: string): void {
    const idx = this.lastAssistantIndex();
    if (idx === undefined) return;
    const item = this.items[idx];
    if (item.kind !== "assistant") return;
    if (text.trim() === item.text.trim()) return; // some providers report the answer itself as reasoning
    if (!item.reasoning) this.items[idx] = { ...item, reasoning: text };
  }

  private lastAssistantIndex(): number | undefined {
    if (this.streamingId) {
      const idx = this.items.findIndex((i) => i.id === this.streamingId);
      if (idx >= 0) return idx;
    }
    const last = this.items.length - 1;
    return last >= 0 && this.items[last].kind === "assistant" ? last : undefined;
  }

  private finishStreaming(): void {
    if (!this.streamingId) return;
    const id = this.streamingId;
    this.streamingId = undefined;
    const idx = this.items.findIndex((i) => i.id === id);
    const item = idx >= 0 ? this.items[idx] : undefined;
    if (!item || item.kind !== "assistant") return;
    const trimmed = item.text.trim();
    if (!trimmed && !item.reasoning) this.items.splice(idx, 1);
    else this.items[idx] = { ...item, text: trimmed, streaming: false };
  }

  /** `message.complete`'s text is the turn's final answer: authoritative for the last segment. */
  private completeAssistant(final: string): void {
    const finalTrimmed = final.trim();
    const idx = this.streamingId ? this.items.findIndex((i) => i.id === this.streamingId) : -1;
    const item = idx >= 0 ? this.items[idx] : undefined;
    if (item && item.kind === "assistant") {
      this.items[idx] = { ...item, text: finalTrimmed || item.text.trim(), streaming: false };
    } else if (finalTrimmed && !this.turnAlreadyShows(finalTrimmed)) {
      this.items.push({ id: newId("a-"), date: Date.now(), kind: "assistant", text: finalTrimmed, streaming: false });
    }
    this.streamingId = undefined;
  }

  private turnAlreadyShows(text: string): boolean {
    for (let i = this.items.length - 1; i >= 0; i--) {
      const item = this.items[i];
      if (item.kind === "user") return false;
      if (item.kind === "assistant" && item.text.trim() === text) return true;
    }
    return false;
  }

  private upsert(item: ChatItem): void {
    const idx = this.items.findIndex((i) => i.id === item.id);
    if (idx >= 0) this.items[idx] = item;
    else this.items.push(item);
  }

  private updateTool(id: string, change: (t: ToolActivity) => void): boolean {
    const idx = this.items.findIndex((i) => i.id === "tool-" + id);
    const item = idx >= 0 ? this.items[idx] : undefined;
    if (!item || item.kind !== "tool") return false;
    const tool = { ...item.tool };
    change(tool);
    this.items[idx] = { ...item, tool };
    return true;
  }
}

/** A tool that drives the screen (`browser_*`, `computer_use`), so the app can offer to watch. */
export function isScreenTool(name: string): boolean {
  const n = name.toLowerCase();
  return n.startsWith("browser") || n.startsWith("computer_use") || n === "computer";
}

/** The turn drove the browser and its reply asks the person to step in (login, CAPTCHA, 2FA…). */
export function asksForTakeover(text: string, state: TranscriptState): boolean {
  let usedScreen = false;
  for (let i = state.items.length - 1; i >= 0; i--) {
    const item = state.items[i];
    if (item.kind === "user") break;
    if (item.kind === "tool" && isScreenTool(item.tool.name)) { usedScreen = true; break; }
  }
  if (!usedScreen) return false;
  const t = text.toLowerCase();
  return ["captcha", "2fa", "two-factor", "two factor", "verification code", "one-time code", "security check",
          "verify you", "verify that you", "log in", "login", "sign in", "sign-in", "take over", "takeover",
          "hand back", "payment", "confirm it's you", "human verification"].some((c) => t.includes(c));
}

/** Hermes' CLI output uses box-drawing banners; keep the text readable. */
export function stripBoxDrawing(text: string): string {
  return text.split("\n")
    .filter((line) => line === "" || ![...line].every((c) => "+-=|─━═ ".includes(c)))
    .map((line) => (line.startsWith("|") && line.endsWith("|") ? line.slice(1, -1).trim() : line))
    .join("\n")
    .trim();
}
