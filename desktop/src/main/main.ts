// Brainbox for Windows — Electron main process.
// Owns the Hermes engine (SSH, backend, gateway), Hermes' screen socket and terminal shells; the
// window only ever talks to it through the narrow `bb` bridge in preload.ts.
import { app, BrowserWindow, clipboard, ipcMain, Notification, powerMonitor, shell } from "electron";
import path from "node:path";
import type { ClientChannel } from "ssh2";
import type WebSocket from "ws";
import { Json, TranscriptState, asksForTakeover, get, str, PendingRequest } from "../shared/transcript";
import { HermesEngine, LinkState } from "./hermes/engine";
import { BotScreen, ScreenError } from "./hermes/screen";
import { authorizedKeysCommand, hostId, identityFingerprint, Identity } from "./hermes/ssh";
import { Preferences, Profile, Store } from "./store";
import { HermesClient } from "./hermes/client";

const E2E = process.env.BRAINBOX_E2E === "1";
if (process.env.BRAINBOX_USER_DATA) app.setPath("userData", process.env.BRAINBOX_USER_DATA);
app.setAppUserModelId("app.brainbox.desktop");

let win: BrowserWindow | undefined;
let store: Store;
let engine: HermesEngine;
const transcripts = new Map<string, TranscriptState>();

const send = (channel: string, ...args: unknown[]) => {
  if (win && !win.isDestroyed()) win.webContents.send(channel, ...args);
};
const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

// ---------------------------------------------------------------- notifications

function notify(title: string, body: string, onClick: () => void) {
  if (win?.isFocused() || !Notification.isSupported()) return;
  const n = new Notification({ title, body: body.slice(0, 240), silent: false });
  n.on("click", () => { win?.show(); win?.focus(); onClick(); });
  n.show();
}

function wireEngine() {
  engine.on("state", (s: LinkState) => {
    send("bb:state", s);
    if (s.kind === "connected") send("bb:connected");
  });
  engine.on("transcript", (chat: string, t: TranscriptState) => {
    transcripts.set(chat, t);
    send("bb:transcript", chat, t);
  });
  engine.on("turnFinished", (chat: string, title: string, text: string) => {
    const t = transcripts.get(chat);
    if (t && asksForTakeover(text, t)) {
      send("bb:screen-ask", chat);
      if (store.prefs.notifyOnApproval) notify("Hermes needs you on its screen", text || `${title}: take over to finish the step, then hand back.`, () => send("bb:navigate", { chat, view: "screen" }));
    } else if (store.prefs.notifyOnFinish) {
      notify(title, text || "Hermes finished.", () => send("bb:navigate", { chat, view: "chat" }));
    }
  });
  engine.on("needsAttention", (chat: string, title: string, r: PendingRequest) => {
    if (!store.prefs.notifyOnApproval) return;
    const body = r.request.kind === "approval" ? `${r.request.description ? r.request.description + ": " : ""}${r.request.command}`
      : r.request.kind === "clarify" ? r.request.question : r.request.kind === "secret" ? r.request.prompt : "Hermes is waiting for you.";
    notify(r.request.kind === "approval" ? "Approve command?" : `${title} needs you`, body, () => send("bb:navigate", { chat, view: "chat" }));
  });
  engine.on("event", (e: { type: string; payload: Json }) => {
    if (e.type.startsWith("display.") || e.type === "sessions.changed") send("bb:gateway-event", e);
  });
  engine.on("prefill", (chat: string, text: string) => send("bb:prefill", chat, text));
}

async function connect() {
  const profile = store.profile;
  if (!profile) return;
  await engine.connect({
    target: profile.target, identity: store.identity(), hostKeys: store, ownershipId: store.ownershipId,
    desktopMode: store.prefs.desktopBackend,
  });
}

// ---------------------------------------------------------------- Hermes' screen

/** One live view of the Bot Screen (the window shows at most one). */
class ScreenSession {
  private ws?: WebSocket;
  private viewerId?: string;
  private viewerClient?: HermesClient;

  private screen(): BotScreen {
    const client = engine.client;
    if (!client) throw new Error("Not connected to Hermes.");
    if (this.viewerClient !== client) { this.viewerId = undefined; this.viewerClient = client; }
    return new BotScreen(client);
  }

  status() { return this.screen().status(); }
  start() { return this.screen().start(); }
  stop(force: boolean) { this.close(); return this.screen().stop(force); }
  thumbnail() { return this.screen().thumbnail(); }

  async open() {
    this.close();
    const screen = this.screen();
    const ticket = await screen.observe(this.viewerId);
    this.viewerId = ticket.viewerId;
    const ws = await screen.openStream(ticket);
    this.ws = ws;
    ws.on("message", (data: Buffer, isBinary: boolean) => { if (isBinary && this.ws === ws) send("bb:screen-data", new Uint8Array(data)); });
    ws.on("close", (code: number, reason: Buffer) => {
      if (this.ws !== ws) return;
      this.ws = undefined;
      const err = ScreenError.fromClose(code, reason.toString());
      send("bb:screen-closed", { code, reason: reason.toString(), error: err?.code, message: err?.message });
    });
    ws.on("error", () => { /* the close event reports it */ });
    return { viewerId: ticket.viewerId, status: ticket.status };
  }

  /** Input bytes from the viewer, in order. False when the socket is gone (the user is told). */
  input(bytes: Uint8Array): boolean {
    const ws = this.ws;
    if (!ws || ws.readyState !== 1) return false;
    ws.send(Buffer.from(bytes), { binary: true });
    return true;
  }

  /** A clean close: Hermes hands control back if this viewer held it. */
  close() {
    const ws = this.ws;
    this.ws = undefined;
    if (ws && ws.readyState <= 1) ws.close(1000, "viewer closed");
  }

  async takeOver() {
    if (!this.viewerId) throw new ScreenError("staleViewer");
    return this.screen().takeOver(this.viewerId, "Brainbox (Windows)");
  }

  handBack(force: boolean) { return this.screen().handBack(force ? undefined : this.viewerId, force); }
}

const screen = new ScreenSession();

// ---------------------------------------------------------------- terminal

const shells = new Map<number, ClientChannel>();
let nextShell = 1;

// ---------------------------------------------------------------- IPC

type Handler = (...args: never[]) => unknown;
function handle(name: string, fn: Handler) {
  ipcMain.handle(name, async (_e, ...args) => {
    try {
      return { ok: true, value: await (fn as (...a: unknown[]) => unknown)(...args) };
    } catch (err) {
      return { ok: false, error: message(err), code: (err as { code?: string }).code };
    }
  });
}

function registerIPC() {
  handle("state", () => {
    const id = store.identity();
    return {
      profile: store.profile, prefs: store.prefs, link: engine.state, encrypted: store.encrypted,
      publicKey: id.publicLine, keyFingerprint: identityFingerprint(id), authorizedKeysCommand: authorizedKeysCommand(id),
      lastChat: store.lastChat, transcripts: Object.fromEntries(transcripts), platform: process.platform,
      version: app.getVersion(),
    };
  });
  handle("saveProfile", (p: Profile) => { store.profile = p; });
  handle("savePrefs", (p: Preferences) => { store.prefs = p; });
  handle("connect", () => connect());
  handle("disconnect", () => engine.disconnect());
  handle("ensureAlive", () => engine.ensureAlive());
  handle("restartBackend", async () => { await engine.stopBackend(); await connect(); });
  handle("forgetHostKey", () => { if (store.profile) store.forgetHostKey(hostId(store.profile.target)); });
  handle("regenerateKey", () => { const id = store.regenerateIdentity(); return { publicKey: id.publicLine, authorizedKeysCommand: authorizedKeysCommand(id) }; });
  handle("copy", (text: string) => clipboard.writeText(text));
  handle("openExternal", (url: string) => { if (/^https?:\/\//.test(url)) return shell.openExternal(url); });

  handle("sessions", async () => {
    const r = await engine.call(undefined, "session.list", { limit: 200 });
    return (get(r, "sessions") as Json[] | undefined ?? []).map((s) => ({
      id: str(get(s, "id")) ?? "",
      title: str(get(s, "title")) ?? "",
      preview: str(get(s, "preview")) ?? "",
      startedAt: (get(s, "started_at") as number | undefined) ?? 0,
      messageCount: (get(s, "message_count") as number | undefined) ?? 0,
      source: str(get(s, "source")) ?? "",
    })).filter((s) => s.id);
  });
  handle("newChat", async () => { const c = await engine.newChat(); store.lastChat = c; return c; });
  handle("openChat", async (id: string) => { const t = await engine.open(id); store.lastChat = id; return t; });
  handle("closeChat", (id: string) => engine.closeChat(id));
  handle("deleteSession", async (id: string, source: string) => {
    if (!["tui", "desktop", "cli", ""].includes(source)) throw new Error(`Brainbox doesn't delete ${source} history.`);
    try {
      await engine.call(undefined, "session.delete", { session_id: id });
    } catch (err) {
      if ((err as { code?: number }).code === 4023) throw new Error("That chat is open on another device (or still running). Close it there, then delete.");
      throw err;
    }
  });
  // session.title needs a live session: attach to the chat first (a no-op when it's already open).
  handle("renameSession", async (id: string, title: string) => { await engine.open(id); return engine.call(id, "session.title", { title }); });
  handle("send", (chat: string, text: string, files: { name: string; data: string; isImage: boolean }[] = []) =>
    engine.send(chat, text, files.map((f) => ({ filename: f.name, data: Buffer.from(f.data, "base64"), isImage: f.isImage }))));
  handle("interrupt", (chat: string) => engine.interrupt(chat));
  handle("respond", (chat: string, requestId: string, answer: string, questionId?: string) => engine.respond(chat, requestId, answer, questionId));
  handle("slash", (chat: string, line: string) => engine.slash(chat, line));
  handle("background", (chat: string, text: string) => engine.background(chat, text));
  handle("btw", (chat: string, text: string) => engine.btw(chat, text));
  handle("call", (chat: string | undefined, method: string, params: Record<string, Json>) => engine.call(chat, method, params));
  // Hermes' REST API (cron, skills, memory, files, server health) through the SSH tunnel.
  handle("rest", (method: string, apiPath: string, body?: Json) => {
    const client = engine.client;
    if (!client) throw new Error("Not connected to Hermes.");
    if (!["GET", "POST", "PUT", "PATCH", "DELETE"].includes(method) || !/^\/api\/(?!ws\b|display\/ws\b)[\w./?=&%:+,-]*$/.test(apiPath)) {
      throw new Error("That request isn't allowed.");
    }
    return client.tunnel.json(method, apiPath, body, 60_000);
  });
  handle("titleBar", (color: string, symbolColor: string) => {
    try { win?.setTitleBarOverlay({ color, symbolColor, height: 40 }); } catch { /* not on this platform */ }
  });
  handle("refreshChat", (chat: string) => engine.refresh(chat));

  handle("screen.status", () => screen.status());
  handle("screen.start", () => screen.start());
  handle("screen.stop", (force: boolean) => screen.stop(force));
  handle("screen.thumbnail", () => screen.thumbnail());
  handle("screen.open", () => screen.open());
  handle("screen.close", () => screen.close());
  handle("screen.takeOver", () => screen.takeOver());
  handle("screen.handBack", (force: boolean) => screen.handBack(force));
  ipcMain.on("bb:screen-input", (e, bytes: Uint8Array) => {
    if (!screen.input(bytes)) e.sender.send("bb:screen-input-lost");
  });

  handle("term.open", async (cols: number, rows: number) => {
    const client = engine.client;
    if (!client) throw new Error("Not connected to Hermes.");
    const ch = await client.ssh.shell(cols, rows);
    const id = nextShell++;
    shells.set(id, ch);
    ch.on("data", (d: Buffer) => send("bb:term-data", id, d.toString("utf8")));
    ch.stderr.on("data", (d: Buffer) => send("bb:term-data", id, d.toString("utf8")));
    ch.on("close", () => { shells.delete(id); send("bb:term-exit", id); });
    return id;
  });
  ipcMain.on("bb:term-input", (_e, id: number, data: string) => {
    const ch = shells.get(id);
    if (!ch || !ch.writable) { send("bb:term-exit", id); return; }
    ch.write(data);
  });
  handle("term.resize", (id: number, cols: number, rows: number) => shells.get(id)?.setWindow(rows, cols, 0, 0));
  handle("term.close", (id: number) => { shells.get(id)?.close(); shells.delete(id); });
}

// ---------------------------------------------------------------- window

function createWindow() {
  win = new BrowserWindow({
    width: 1360, height: 860, minWidth: 900, minHeight: 600,
    title: "Brainbox",
    backgroundColor: "#0c0d10",
    icon: path.join(__dirname, "../../../build/icon.png"),
    autoHideMenuBar: true,
    // Our own title bar (drag region in the page) with the native window buttons on top.
    titleBarStyle: "hidden",
    titleBarOverlay: { color: "#0c0d10", symbolColor: "#a9a9b3", height: 40 },
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: true,
    },
  });
  win.loadFile(path.join(__dirname, "../../renderer/index.html"));
  // Links in replies open in the real browser, never inside the app.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//.test(url)) shell.openExternal(url);
    return { action: "deny" };
  });
  win.webContents.on("will-navigate", (e) => e.preventDefault());
  win.on("focus", () => {
    if (engine.state.kind === "connected") engine.ensureAlive().then((ok) => { if (ok) return engine.refreshAll(); }).catch(() => {});
  });
  win.on("closed", () => { win = undefined; });
}

app.whenReady().then(() => {
  store = new Store(app.getPath("userData"));
  if (E2E && process.env.BRAINBOX_E2E_IDENTITY) store.useIdentity(JSON.parse(process.env.BRAINBOX_E2E_IDENTITY) as Identity);
  if (E2E && process.env.BRAINBOX_E2E_PROFILE) store.profile = JSON.parse(process.env.BRAINBOX_E2E_PROFILE) as Profile;
  engine = new HermesEngine(store);
  wireEngine();
  registerIPC();
  createWindow();
  powerMonitor.on("resume", () => { engine.ensureAlive().catch(() => {}); });
  if (store.profile) connect().catch(() => {});
});

app.on("window-all-closed", () => {
  screen.close();
  for (const ch of shells.values()) ch.close();
  engine?.disconnect();
  app.quit();
});
