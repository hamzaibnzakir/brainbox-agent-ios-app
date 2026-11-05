// Hermes' Bot Screen: the bot's own desktop on the server, watchable by everyone, controllable by
// one human at a time (the lease). Port of HermesKit/Screen/BotScreen.swift; see docs/BOT_SCREEN.md.
import type WebSocket from "ws";
import { Json, arr, bool, get, num, str } from "../../shared/transcript";
import { HermesClient } from "./client";
import { RPCError } from "./rpc";
import { WebSocketHandshakeError } from "./tunnel";

export interface ScreenLease {
  holder: "agent" | "human";
  viewerHash?: string;
  since: number;
  epoch: number;
  reason: string;
}

export interface ScreenStatus {
  profileKey: string;
  supported: boolean;
  installed: boolean;
  missing: string[];
  running: boolean;
  geometry: string;
  installCommand?: string;
  browser?: string;
  blocker?: string;
  placement: string;
  lease: ScreenLease;
}

export interface ScreenTicket {
  ticket: string;
  path: string;
  viewerId: string;
  status: ScreenStatus;
}

export type ScreenErrorCode = "unsupportedHermes" | "unsupportedHost" | "notRunning" | "controlTaken" | "screenGone" | "ticketRejected" | "staleViewer" | "failed";

const MESSAGES: Record<ScreenErrorCode, string> = {
  unsupportedHermes: "This Hermes doesn't have Bot Screen yet. Update Hermes on the server to use the shared screen.",
  unsupportedHost: "This server already has a real display, so Hermes doesn't run a Bot Screen on it.",
  notRunning: "The screen isn't running. Start it first.",
  controlTaken: "Someone else took control of the screen. You're watching now.",
  screenGone: "The screen stopped.",
  ticketRejected: "Hermes refused the screen ticket. Reconnecting will fetch a new one.",
  staleViewer: "This viewer belonged to an earlier connection. Reopen the screen.",
  failed: "The screen failed.",
};

export class ScreenError extends Error {
  constructor(public code: ScreenErrorCode, message?: string) {
    super(message ?? MESSAGES[code]);
  }

  static fromClose(code: number, reason: string): ScreenError | undefined {
    switch (code) {
      case 1000: case 1001: return undefined;
      case 4000: return new ScreenError("controlTaken");
      case 4001: return new ScreenError("screenGone");
      case 4401: return new ScreenError("ticketRejected");
      case 4403: return new ScreenError("failed", `Hermes refused this screen connection (${reason || "not allowed"}).`);
      default: return new ScreenError("failed", `The screen connection closed (${code}${reason ? `: ${reason}` : ""}).`);
    }
  }

  static from(err: unknown): Error {
    if (!(err instanceof RPCError)) return err as Error;
    if (err.isUnknownMethod) return new ScreenError("unsupportedHermes");
    if (str(get(err.data, "code")) === "viewer_mismatch") return new ScreenError("staleViewer");
    if (err.message.includes("not running")) return new ScreenError("notRunning");
    return new ScreenError("failed", err.message);
  }
}

export function parseLease(v: Json | undefined): ScreenLease | undefined {
  if (!v || typeof v !== "object" || Array.isArray(v)) return undefined;
  return {
    holder: str(get(v, "holder")) === "human" ? "human" : "agent",
    viewerHash: str(get(v, "viewer_hash")),
    since: num(get(v, "since")) ?? Date.now() / 1000,
    epoch: num(get(v, "epoch")) ?? 0,
    reason: str(get(v, "reason")) ?? "",
  };
}

export function parseStatus(v: Json): ScreenStatus {
  return {
    profileKey: str(get(v, "profile_key")) ?? str(get(v, "profile")) ?? "",
    supported: bool(get(v, "supported")) ?? false,
    installed: bool(get(v, "installed")) ?? false,
    missing: (arr(get(v, "missing")) ?? []).filter((x): x is string => typeof x === "string"),
    running: bool(get(v, "running")) ?? false,
    geometry: str(get(v, "geometry")) ?? "1440x900",
    installCommand: str(get(v, "install_command")),
    browser: str(get(v, "browser")),
    blocker: str(get(v, "blocker")),
    placement: str(get(v, "placement")) ?? "gateway",
    lease: parseLease(get(v, "lease")) ?? { holder: "agent", since: 0, epoch: 0, reason: "" },
  };
}

export function ticketPath(t: { ticket: string; path: string }): string {
  return `${t.path}${t.path.includes("?") ? "&" : "?"}display_ticket=${encodeURIComponent(t.ticket)}`;
}

/** Bot Screen calls on one live connection. Viewer ids are tied to it: observe again after a reconnect. */
export class BotScreen {
  constructor(private client: HermesClient, private profile?: string) {}

  private async call(method: string, extra: Record<string, Json> = {}, timeoutMs = 30_000): Promise<Json> {
    const params: Record<string, Json> = { ...extra };
    if (this.profile) params.profile = this.profile;
    try {
      return await this.client.call(method, params, timeoutMs);
    } catch (err) {
      throw ScreenError.from(err);
    }
  }

  async status() { return parseStatus(await this.call("display.status")); }
  async start() { return parseStatus(await this.call("display.start", {}, 120_000)); }
  async stop(force = false) { return parseStatus(await this.call("display.stop", force ? { force: true } : {}, 60_000)); }

  async thumbnail(): Promise<{ dataUrl?: string; suppressed?: string }> {
    const r = await this.call("display.thumbnail");
    return { dataUrl: str(get(r, "data_url")), suppressed: str(get(r, "suppressed")) };
  }

  async observe(viewerId?: string): Promise<ScreenTicket> {
    const r = await this.call("display.observe", viewerId ? { viewer_id: viewerId } : {});
    const ticket = str(get(r, "ticket"));
    const viewer = str(get(r, "viewer_id"));
    if (!ticket || !viewer) throw new ScreenError("failed", "Hermes didn't return a screen ticket.");
    return { ticket, path: str(get(r, "path")) ?? "/api/display/ws", viewerId: viewer, status: parseStatus(r) };
  }

  async takeOver(viewerId: string, reason = "Brainbox (desktop)"): Promise<ScreenLease> {
    const r = await this.call("display.lease.acquire", { viewer_id: viewerId, reason });
    return parseLease(get(r, "lease")) ?? { holder: "human", since: Date.now() / 1000, epoch: 0, reason };
  }

  async handBack(viewerId: string | undefined, force = false): Promise<ScreenLease> {
    const extra: Record<string, Json> = {};
    if (viewerId) extra.viewer_id = viewerId;
    if (force) extra.force = true;
    const r = await this.call("display.lease.release", extra);
    return parseLease(get(r, "lease")) ?? { holder: "agent", since: Date.now() / 1000, epoch: 0, reason: "" };
  }

  /** The RFB stream for `ticket` through the SSH tunnel. Binary messages are raw RFB. */
  async openStream(ticket: ScreenTicket): Promise<WebSocket> {
    try {
      return await this.client.tunnel.websocket(ticketPath(ticket));
    } catch (err) {
      if (err instanceof WebSocketHandshakeError) {
        if (err.status === 404) throw new ScreenError("unsupportedHermes");
        throw new ScreenError("failed", `Couldn't open the screen (${err.status}) ${err.body.slice(0, 120)}`);
      }
      throw err;
    }
  }
}
