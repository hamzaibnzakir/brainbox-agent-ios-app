// End to end against a real sshd + `hermes serve` (+ Bot Screen when HERMES_E2E_SCREEN=1).
// Same environment as the phone's LiveHermesTests: HERMES_E2E_SSH_HOST/PORT/USER/KEY.
import { describe, expect, it } from "vitest";
import WebSocket from "ws";
import { HermesClient } from "../src/main/hermes/client";
import { BackendRecord, makeOwnershipId } from "../src/main/hermes/backend";
import { HermesEngine } from "../src/main/hermes/engine";
import { BotScreen, ScreenError } from "../src/main/hermes/screen";
import { MemoryHostKeys, SSHConnection, SSHError } from "../src/main/hermes/ssh";
import { TranscriptState } from "../src/shared/transcript";
import { e2eEnv, waitFor } from "./helpers";
import { generateIdentity } from "../src/main/hermes/ssh";

const env = e2eEnv();
const live = env ? describe : describe.skip;
const ownershipId = makeOwnershipId();
const hostKeys = new MemoryHostKeys();
const records: Record<string, BackendRecord | undefined> = {};
const persistence = { loadBackend: (id: string) => records[id], saveBackend: (id: string, r?: BackendRecord) => { records[id] = r; } };

live("desktop engine ↔ SSH ↔ real Hermes", () => {
  it("exec, refused key and changed host key", async () => {
    const ssh = await SSHConnection.connect(env!.target, env!.identity, hostKeys);
    const r = await ssh.exec("echo hello-$((40+2)); echo oops >&2; exit 3");
    expect(r.output.trim()).toBe("hello-42");
    expect(r.errorOutput.trim()).toBe("oops");
    expect(r.code).toBe(3);
    expect((await ssh.exec("cat | tr a-z A-Z", { stdin: "secret" })).output).toBe("SECRET");
    ssh.close();
    await expect(SSHConnection.connect(env!.target, generateIdentity(), hostKeys)).rejects.toMatchObject({ code: "auth" });
    const wrong = new MemoryHostKeys({ [env!.target.port === 22 ? env!.target.host : `[${env!.target.host}]:${env!.target.port}`]: Buffer.from("nope").toString("base64") });
    await expect(SSHConnection.connect(env!.target, env!.identity, wrong)).rejects.toBeInstanceOf(SSHError);
  });

  it("starts a backend, chats, approves a tool and reuses the backend", async () => {
    const engine = new HermesEngine(persistence);
    const states: string[] = [];
    engine.on("state", (s) => states.push(s.kind));
    await engine.connect({ target: env!.target, identity: env!.identity, hostKeys, ownershipId });
    expect(engine.state.kind).toBe("connected");
    const health = await engine.client!.tunnel.json("GET", "/api/health") as { ok?: boolean };
    expect(health.ok).toBe(true);

    const chat = await engine.newChat();
    let latest: TranscriptState | undefined;
    engine.on("transcript", (key: string, t: TranscriptState) => { if (key === chat) latest = t; });
    const finished: string[] = [];
    engine.on("turnFinished", (key: string, _title: string, text: string) => { if (key === chat) finished.push(text); });

    await engine.send(chat, "hello desktop");
    await waitFor(() => finished.length >= 1 || undefined);
    expect(finished[0]).toMatch(/^Echo:.*hello desktop/);
    const last = latest!.items[latest!.items.length - 1];
    expect(last.kind === "assistant" && last.text).toBe(finished[0].trim());

    await engine.send(chat, "run tool: rm -rf /tmp/brainbox-desktop-e2e-none");
    const request = await waitFor(() => engine.pending(chat)[0]);
    expect(request.request.kind).toBe("approval");
    await engine.respond(chat, request.requestId, "once");
    await waitFor(() => finished.length >= 2 || undefined);
    expect(finished[1]).toContain("approved by the user");
    expect(latest!.items.some((i) => i.kind === "tool")).toBe(true);

    await engine.slash(chat, "/help");
    const cmd = latest!.items.find((i) => i.kind === "command");
    expect(cmd?.kind === "command" && cmd.output).toContain("/new");

    const pid = engine.client!.backend.record.pid;
    engine.disconnect();
    const again = new HermesEngine(persistence);
    await again.connect({ target: env!.target, identity: env!.identity, hostKeys, ownershipId });
    expect(again.client!.backend.reused).toBe(true);
    expect(again.client!.backend.record.pid).toBe(pid);
    // The chat reopens with its history.
    const reopened = await again.open(chat);
    expect(reopened.items.some((i) => i.kind === "user" && i.text === "hello desktop")).toBe(true);
    again.disconnect();
  });

  it("Bot Screen: watch, take over, hand back", async () => {
    if (!env!.screen) return;
    const client = await HermesClient.connect({ target: env!.target, identity: env!.identity, hostKeys, ownershipId, knownBackend: Object.values(records)[0] });
    const screen = new BotScreen(client);
    try {
      if (env!.screen === "unsupported") {
        await expect(screen.status()).rejects.toMatchObject({ code: "unsupportedHermes" });
        return;
      }
      let status = await screen.status();
      expect(status.supported).toBe(true);
      expect(status.installed).toBe(true);
      status = await screen.start();
      expect(status.running).toBe(true);

      const leaseEvents: string[] = [];
      client.rpc.on("event", (e) => { if (e.type === "display.lease") leaseEvents.push(String((e.payload as { lease?: { holder?: string } }).lease?.holder)); });

      const ticket = await screen.observe();
      const ws = await screen.openStream(ticket);
      const greeting = await new Promise<Buffer>((resolve) => ws.once("message", (d: Buffer) => resolve(d)));
      expect(greeting.subarray(0, 10).toString()).toBe("RFB 003.00");

      expect((await screen.takeOver(ticket.viewerId)).holder).toBe("human");
      await waitFor(() => leaseEvents.includes("human") || undefined, 15_000);
      expect((await screen.thumbnail()).dataUrl).toBeUndefined();

      // A clean close (1000) hands control back.
      await new Promise<void>((resolve) => { ws.once("close", () => resolve()); ws.close(1000, "viewer closed"); });
      await waitFor(async () => undefined, 10).catch(() => {});
      let holder = "human";
      for (let i = 0; i < 40 && holder === "human"; i++) {
        await new Promise((r) => setTimeout(r, 250));
        holder = (await screen.status()).lease.holder;
      }
      expect(holder).toBe("agent");

      const again = await screen.observe(ticket.viewerId);
      expect(again.viewerId).toBe(ticket.viewerId);
      expect((await screen.takeOver(again.viewerId)).holder).toBe("human");
      expect((await screen.handBack(again.viewerId)).holder).toBe("agent");
      await expect(screen.takeOver("made-up-viewer")).rejects.toMatchObject({ code: "staleViewer" });
      expect(ws.readyState).toBe(WebSocket.CLOSED);
      expect((await screen.stop(true)).running).toBe(false);
    } catch (err) {
      if (err instanceof ScreenError) throw new Error(`${err.code}: ${err.message}`);
      throw err;
    } finally {
      client.close();
    }
  });
});
