// Hermes' JSON-RPC 2.0 gateway (`tui_gateway`) over a WebSocket. Port of GatewayRPC.swift.
import { EventEmitter } from "node:events";
import WebSocket from "ws";
import { GatewayEvent, Json, get, num, str } from "../../shared/transcript";

export class RPCError extends Error {
  constructor(public code: number, message: string, public data?: Json) {
    super(message || `Hermes error ${code}`);
  }
  get isUnknownMethod() { return this.code === -32601; }
  static timedOut() { return new RPCError(-32000, "Hermes didn't answer in time."); }
  static disconnected() { return new RPCError(-32001, "Lost the live connection to Hermes."); }
}

export function parseEvent(params: Json | undefined): GatewayEvent | undefined {
  const type = str(get(params, "type"));
  if (!type) return undefined;
  const sid = str(get(params, "session_id"));
  return { type, sessionId: sid || undefined, seq: num(get(params, "seq")), payload: get(params, "payload") ?? null };
}

/** Server→client requests the app answers; everything else (desktop-window bridges) is declined. */
const ANSWERABLE = new Set(["approval", "clarify", "sudo", "secret"]);

export class GatewayRPC extends EventEmitter {
  private nextId = 0;
  private pending = new Map<number, { resolve: (v: Json) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }>();
  private readyEvent?: GatewayEvent;
  closed = false;

  constructor(private ws: WebSocket) {
    super();
    this.setMaxListeners(50);
    ws.on("message", (data, isBinary) => { if (!isBinary) this.handle(data.toString()); });
    ws.on("close", () => this.finish());
    ws.on("error", () => this.finish());
  }

  private handle(text: string) {
    let frame: Json;
    try { frame = JSON.parse(text); } catch { return; }
    const method = str(get(frame, "method"));
    if (method) {
      if (method === "event") {
        const event = parseEvent(get(frame, "params"));
        if (!event) return;
        if (event.type === "gateway.ready") { this.readyEvent = event; this.emit("ready", event); }
        this.emit("event", event);
      } else if (get(frame, "id") !== undefined) {
        this.serverRequest(get(frame, "id")!, method, get(frame, "params") ?? null);
      }
      return;
    }
    const id = num(get(frame, "id"));
    if (id === undefined) return;
    const waiter = this.pending.get(id);
    if (!waiter) return;
    this.pending.delete(id);
    clearTimeout(waiter.timer);
    const error = get(frame, "error");
    if (error !== undefined && error !== null) {
      waiter.reject(new RPCError(num(get(error, "code")) ?? -1, str(get(error, "message")) ?? "Hermes error", get(error, "data")));
    } else {
      waiter.resolve(get(frame, "result") ?? null);
    }
  }

  private serverRequest(id: Json, method: string, params: Json) {
    if (!ANSWERABLE.has(method)) {
      // 4404 = "no window is showing this chat": the agent stops waiting at once.
      this.fail(id, 4404, `Brainbox (desktop) can't show ${method}.`).catch(() => {});
      return;
    }
    this.emit("event", { type: "server.request", sessionId: str(get(params, "session_id")), payload: { id, method, params } } as GatewayEvent);
  }

  waitForReady(timeoutMs = 5000): Promise<GatewayEvent | undefined> {
    if (this.readyEvent || this.closed) return Promise.resolve(this.readyEvent);
    return new Promise((resolve) => {
      const timer = setTimeout(() => { this.off("ready", onReady); resolve(undefined); }, timeoutMs);
      const onReady = (e: GatewayEvent) => { clearTimeout(timer); resolve(e); };
      this.once("ready", onReady);
    });
  }

  private send(frame: Json): Promise<void> {
    return new Promise((resolve, reject) => {
      if (this.closed || this.ws.readyState !== WebSocket.OPEN) return reject(RPCError.disconnected());
      this.ws.send(JSON.stringify(frame), (err) => (err ? reject(err) : resolve()));
    });
  }

  call(method: string, params: Record<string, Json> = {}, timeoutMs = 60_000): Promise<Json> {
    if (this.closed) return Promise.reject(RPCError.disconnected());
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(RPCError.timedOut()); }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.send({ jsonrpc: "2.0", id, method, params }).catch((err) => {
        if (this.pending.delete(id)) { clearTimeout(timer); reject(err); }
      });
    });
  }

  reply(requestId: Json, result: Json) { return this.send({ jsonrpc: "2.0", id: requestId, result }); }
  fail(requestId: Json, code: number, message: string) { return this.send({ jsonrpc: "2.0", id: requestId, error: { code, message } }); }

  private finish() {
    if (this.closed) return;
    this.closed = true;
    for (const [, w] of this.pending) { clearTimeout(w.timer); w.reject(RPCError.disconnected()); }
    this.pending.clear();
    this.emit("close");
  }

  close() {
    try { this.ws.close(1000); } catch { /* already gone */ }
    this.ws.terminate();
    this.finish();
  }
}
