// HTTP and WebSocket to `hermes serve` through SSH direct-tcpip channels. Nothing listens on
// the PC: every request dials a fresh channel to the backend's loopback port on the server.
import http from "node:http";
import net from "node:net";
import type { Duplex } from "node:stream";
import WebSocket from "ws";

/** Anything that opens a byte stream to a port on the server: an SSH connection (direct-tcpip
 *  channel) or, in Tailscale mode, a plain TCP connection over the tailnet. */
export interface PortForwarder { forward(port: number): Promise<Duplex> }

/** Tailscale mode: Hermes is reached straight over the tailnet (WireGuard-encrypted); `tailscale
 *  serve --tcp` forwards the port to Hermes on the server's 127.0.0.1. */
export class DirectForwarder implements PortForwarder {
  constructor(public readonly host: string, private readonly timeoutMs = 6000) {}
  forward(port: number): Promise<Duplex> {
    return new Promise((resolve, reject) => {
      const socket = net.connect({ host: this.host, port, noDelay: true });
      socket.setKeepAlive(true, 10_000);
      const timer = setTimeout(() => { socket.destroy(); reject(new DirectError(this.host, port, "timed out")); }, this.timeoutMs);
      socket.once("connect", () => { clearTimeout(timer); resolve(socket); });
      socket.once("error", (err) => { clearTimeout(timer); reject(new DirectError(this.host, port, err.message)); });
    });
  }
}

export class DirectError extends Error {
  constructor(public host: string, public port: number, public detail: string) {
    super(`Can't reach Hermes at ${host}:${port} over Tailscale. Check that Tailscale is switched on (on this PC and on the server) and that the Brainbox service is running on the server.`);
  }
}

export interface TunnelResponse {
  status: number;
  headers: http.IncomingHttpHeaders;
  body: Buffer;
  text: string;
}

export class TunnelHTTPError extends Error {
  constructor(public status: number, public body: string) {
    super(describeHTTPError(status, body));
  }
}

export function describeHTTPError(status: number, body: string): string {
  try {
    const json = JSON.parse(body);
    const detail = json?.detail ?? json?.error?.message ?? json?.error;
    if (typeof detail === "string") return `Hermes said: ${detail} (${status})`;
  } catch { /* not JSON */ }
  if (status === 401 || status === 403) return `Hermes refused the session token (${status}). Reconnect to start a fresh session.`;
  if (status === 404) return "This Hermes version doesn't have that feature (404).";
  const trimmed = body.trim();
  return `Hermes returned ${status}${trimmed ? `: ${trimmed.slice(0, 200)}` : "."}`;
}

/** Node's http client treats its connection as a net.Socket and calls a few socket-only methods on
 *  it; an SSH channel is a plain Duplex, so give it harmless versions of those. */
function asSocket(channel: Duplex): Duplex {
  const c = channel as Duplex & Record<string, unknown>;
  for (const name of ["setTimeout", "setNoDelay", "setKeepAlive", "ref", "unref"]) {
    if (typeof c[name] !== "function") c[name] = () => c;
  }
  return channel;
}

/** Dials the backend port through SSH, one channel per stream. */
export class Tunnel {
  constructor(public readonly ssh: PortForwarder, public readonly port: number, public readonly token: string) {}

  async request(method: string, path: string, opts: { body?: Buffer | string; headers?: Record<string, string>; timeoutMs?: number } = {}): Promise<TunnelResponse> {
    const channel = await this.ssh.forward(this.port);
    return new Promise((resolve, reject) => {
      const headers: Record<string, string> = { "X-Hermes-Session-Token": this.token, Connection: "close", ...(opts.headers ?? {}) };
      const body = typeof opts.body === "string" ? Buffer.from(opts.body) : opts.body;
      if (body) headers["Content-Length"] = String(body.length);
      const req = http.request({
        host: "127.0.0.1", method, path, headers,  // no `agent`: Node only uses createConnection without one
        createConnection: () => asSocket(channel) as never,
      }, (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (c: Buffer) => chunks.push(c));
        res.on("end", () => {
          const buf = Buffer.concat(chunks);
          resolve({ status: res.statusCode ?? 0, headers: res.headers, body: buf, text: buf.toString("utf8") });
        });
        res.on("error", reject);
      });
      req.setTimeout(opts.timeoutMs ?? 60_000, () => req.destroy(new Error(`Timed out waiting for Hermes to answer ${path.split("?")[0]}`)));
      req.on("error", reject);
      req.end(body);
    });
  }

  async json(method: string, path: string, body?: unknown, timeoutMs?: number): Promise<unknown> {
    const res = await this.request(method, path, {
      body: body === undefined ? undefined : JSON.stringify(body),
      headers: body === undefined ? {} : { "Content-Type": "application/json" },
      timeoutMs,
    });
    if (res.status < 200 || res.status >= 300) throw new TunnelHTTPError(res.status, res.text);
    if (!res.body.length) return null;
    try { return JSON.parse(res.text); } catch { return res.text; }
  }

  /** A WebSocket over a fresh channel. Rejects with the HTTP status on a failed upgrade. */
  async websocket(path: string): Promise<WebSocket> {
    const channel = await this.ssh.forward(this.port);
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(`ws://127.0.0.1${path}`, {
        createConnection: () => asSocket(channel) as never,
        perMessageDeflate: false,
        maxPayload: 256 * 1024 * 1024,
        handshakeTimeout: 20_000,
      });
      ws.binaryType = "nodebuffer";
      const fail = (err: Error) => { ws.removeAllListeners("open"); reject(err); };
      ws.once("unexpected-response", (_req, res) => {
        const chunks: Buffer[] = [];
        res.on("data", (c: Buffer) => chunks.push(c));
        res.on("end", () => fail(new WebSocketHandshakeError(res.statusCode ?? 0, Buffer.concat(chunks).toString("utf8"))));
      });
      ws.once("error", fail);
      ws.once("open", () => { ws.removeListener("error", fail); resolve(ws); });
    });
  }
}

export class WebSocketHandshakeError extends Error {
  constructor(public status: number, public body: string) {
    super(status === 401 || status === 403
      ? "Hermes refused the session token. Reconnecting will start a fresh session."
      : `Couldn't open Hermes' live channel (${status}) ${body.slice(0, 120)}`);
  }
}
