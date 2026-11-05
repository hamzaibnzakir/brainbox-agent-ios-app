// A live connection to Hermes: SSH, the backend it runs, the REST tunnel and the JSON-RPC gateway.
// Port of HermesClient.swift (same fast path: try the saved backend first, then locate/verify/spawn).
import { GatewayEvent, Json } from "../../shared/transcript";
import { BackendError, BackendHandle, BackendRecord, BackendStep, RemoteBackend } from "./backend";
import { GatewayRPC, RPCError } from "./rpc";
import { HostKeyStore, Identity, SSHConnection, SSHTarget } from "./ssh";
import { Tunnel, WebSocketHandshakeError } from "./tunnel";

export interface ClientOptions {
  target: SSHTarget;
  identity: Identity;
  hostKeys: HostKeyStore;
  ownershipId: string;
  knownBackend?: BackendRecord;
  desktopMode?: boolean;
}

export type ConnectStep = { step: "ssh" } | { step: "backend"; detail: BackendStep } | { step: "gateway" };

export class HermesClient {
  private constructor(
    public readonly ssh: SSHConnection,
    public readonly backend: BackendHandle,
    public readonly tunnel: Tunnel,
    public readonly rpc: GatewayRPC,
    public readonly ready?: GatewayEvent,
  ) {}

  static async connect(opts: ClientOptions, progress: (s: ConnectStep) => void = () => {}): Promise<HermesClient> {
    progress({ step: "ssh" });
    const ssh = await SSHConnection.connect(opts.target, opts.identity, opts.hostKeys);
    if (opts.knownBackend) {
      progress({ step: "gateway" });
      try {
        return await HermesClient.attach(ssh, { record: opts.knownBackend, reused: true, version: opts.knownBackend.version }, 2000);
      } catch { /* fall through to the full check */ }
    }
    try {
      const backend = await new RemoteBackend(ssh, opts.ownershipId, opts.desktopMode)
        .ensure(opts.knownBackend, (detail) => progress({ step: "backend", detail }));
      progress({ step: "gateway" });
      return await HermesClient.attach(ssh, backend);
    } catch (err) {
      ssh.close();
      throw err;
    }
  }

  static async attach(ssh: SSHConnection, backend: BackendHandle, readyTimeoutMs = 3000): Promise<HermesClient> {
    const tunnel = new Tunnel(ssh, backend.record.port, backend.record.token);
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
    return new HermesClient(ssh, backend, tunnel, rpc, ready);
  }

  async isAlive(timeoutMs = 2000): Promise<boolean> {
    if (!this.ssh.isActive || this.rpc.closed) return false;
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
