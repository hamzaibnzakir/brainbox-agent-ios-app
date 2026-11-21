// A live connection to Hermes: SSH, the backend it runs, the REST tunnel and the JSON-RPC gateway.
// Port of HermesClient.swift (same fast path: try the saved backend first, then locate/verify/spawn).
import { GatewayEvent, Json } from "../../shared/transcript";
import { BackendError, BackendHandle, BackendRecord, BackendStep, RemoteBackend } from "./backend";
import { GatewayRPC, RPCError } from "./rpc";
import { HostKeyStore, Identity, SSHConnection, SSHLink, SSHTarget } from "./ssh";
import { DirectForwarder, PortForwarder, Tunnel, WebSocketHandshakeError } from "./tunnel";

/** Tailscale mode: Hermes runs as the brainbox-hermes service on the server's 127.0.0.1; `tailscale
 *  serve` forwards `port` on the tailnet to it; `token` is its fixed access token. */
export interface DirectEndpoint { host: string; port: number; token: string }

export class DirectTokenError extends Error {
  constructor() { super("Hermes refused the access token. Copy it again from the server (cat /etc/brainbox/token) into Connection settings."); }
}

export interface ClientOptions {
  target: SSHTarget;
  identity: Identity;
  hostKeys: HostKeyStore;
  ownershipId: string;
  knownBackend?: BackendRecord;
  desktopMode?: boolean;
  /** Tailscale mode: talk to Hermes directly (SSH only for the terminal). */
  direct?: DirectEndpoint;
}

export type ConnectStep = { step: "ssh" } | { step: "backend"; detail: BackendStep } | { step: "gateway" };

export class HermesClient {
  private constructor(
    public readonly ssh: SSHLink,
    public readonly backend: BackendHandle,
    public readonly tunnel: Tunnel,
    public readonly rpc: GatewayRPC,
    public readonly ready: GatewayEvent | undefined,
    public readonly isDirect: boolean,
  ) {}

  static async connect(opts: ClientOptions, progress: (s: ConnectStep) => void = () => {}): Promise<HermesClient> {
    if (opts.direct) {
      progress({ step: "gateway" });
      const d = opts.direct;
      const link = new SSHLink(opts.target, opts.identity, opts.hostKeys);
      const record: BackendRecord = { pid: 0, port: d.port, nonce: "", token: d.token, hermesPath: "brainbox-hermes.service", shared: true };
      try {
        return await HermesClient.open(link, new DirectForwarder(d.host), { record, reused: true }, 3000, true);
      } catch (err) {
        if (err instanceof BackendError && err.code === "gated") throw new DirectTokenError();
        throw err;
      }
    }
    progress({ step: "ssh" });
    const ssh = await SSHConnection.connect(opts.target, opts.identity, opts.hostKeys);
    // Fast path: the shared backend we used last time. A per-device one from an older build goes
    // through ensure() so it is retired in favour of the shared one.
    if (opts.knownBackend?.shared) {
      progress({ step: "gateway" });
      try {
        return await HermesClient.attach(ssh, { record: opts.knownBackend, reused: true, version: opts.knownBackend.version }, 2000, opts);
      } catch { /* fall through to the full check */ }
    }
    try {
      const backend = await new RemoteBackend(ssh, opts.ownershipId, opts.desktopMode)
        .ensure(opts.knownBackend, (detail) => progress({ step: "backend", detail }));
      progress({ step: "gateway" });
      return await HermesClient.attach(ssh, backend, 3000, opts);
    } catch (err) {
      ssh.close();
      throw err;
    }
  }

  static async attach(ssh: SSHConnection, backend: BackendHandle, readyTimeoutMs = 3000, opts?: ClientOptions): Promise<HermesClient> {
    const link = new SSHLink(opts?.target ?? ssh.target, opts?.identity ?? { privateKey: "", publicLine: "" }, opts?.hostKeys ?? { pinned: () => undefined, pin: () => {} }, ssh);
    return HermesClient.open(link, ssh, backend, readyTimeoutMs, false);
  }

  private static async open(link: SSHLink, forwarder: PortForwarder, backend: BackendHandle, readyTimeoutMs: number, isDirect: boolean): Promise<HermesClient> {
    const tunnel = new Tunnel(forwarder, backend.record.port, backend.record.token);
    let ws;
    try {
      ws = await tunnel.websocket(`/api/ws?token=${encodeURIComponent(backend.record.token)}`);
    } catch (err) {
      if (err instanceof WebSocketHandshakeError && (err.status === 401 || err.status === 403)) {
        throw new BackendError("gated", "Hermes put its dashboard login in front of the private backend (your config sets dashboard.public_url). Turn on Connection › Desktop-compatible backend and connect again.");
      }
      throw err;
    }
    const rpc = new GatewayRPC(ws);
    // Newer Hermes only sends approvals/questions to clients that say they answer them.
    const caps = rpc.call("client.capabilities", { server_requests: true }, 10_000).catch(() => null);
    const ready = await rpc.waitForReady(readyTimeoutMs);
    await caps;
    try {
      await rpc.call("ping", {}, 8000);
    } catch (err) {
      if (err instanceof RPCError && (err.code === -32000 || err.code === -32001)) { rpc.close(); throw err; }
      // Older backends without `ping` answer "unknown method": still alive.
    }
    if (isDirect && !backend.version) {
      try {
        const h = await tunnel.json("GET", "/api/health", undefined, 8000) as { version?: string; displayVersion?: string };
        backend = { ...backend, version: h?.version && h.version !== "unknown" ? h.version : h?.displayVersion ?? h?.version };
      } catch { /* version is cosmetic */ }
    }
    return new HermesClient(link, backend, tunnel, rpc, ready, isDirect);
  }

  async isAlive(timeoutMs = 2000): Promise<boolean> {
    if ((!this.isDirect && !this.ssh.isActive) || this.rpc.closed) return false;
    try {
      await this.rpc.call("ping", {}, timeoutMs);
      return true;
    } catch (err) {
      return !(err instanceof RPCError && (err.code === -32000 || err.code === -32001));
    }
  }

  call(method: string, params: Record<string, Json> = {}, timeoutMs = 60_000) {
    return this.rpc.call(method, params, timeoutMs);
  }

  close() {
    this.rpc.close();
    this.ssh.close();
  }
}
