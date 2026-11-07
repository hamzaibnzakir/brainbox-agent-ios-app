// The window: title bar, navigation rail, chats sidebar, the current page and a status bar.
// Hermes' screen is ONE mounted viewer that either docks beside the chat or fills the window, so
// switching between the two never drops the stream (dropping it would hand control back).
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { TranscriptState } from "../shared/transcript";
import { isScreenTool } from "../shared/transcript";
import { AppState, bb, isReadOnly, LinkState, SessionSummary } from "./api";
import { ChatPane } from "./components/Chat";
import { Onboarding, SettingsPage } from "./components/Connect";
import { Palette, PaletteAction } from "./components/Palette";
import { AgentsPage, FilesPage, MemoryPage, ServerPage, SkillsPage } from "./components/Panels";
import { ScreenPane } from "./components/Screen";
import { Sidebar } from "./components/Sidebar";
import { TerminalPane } from "./components/Terminal";
import { Icon, IconName } from "./ui/icons";
import { Dialog, DialogSpec } from "./ui/kit";

type View = "chat" | "screen" | "terminal" | "agents" | "skills" | "memory" | "files" | "server" | "settings";

const NAV: { view: View; icon: IconName; label: string; key?: string }[] = [
  { view: "chat", icon: "chat", label: "Chats", key: "1" },
  { view: "screen", icon: "monitor", label: "Hermes' screen", key: "2" },
  { view: "terminal", icon: "terminal", label: "Terminal", key: "3" },
  { view: "agents", icon: "clock", label: "Scheduled jobs", key: "4" },
  { view: "skills", icon: "sparkles", label: "Skills", key: "5" },
  { view: "memory", icon: "brain", label: "Memory", key: "6" },
  { view: "files", icon: "folder", label: "Files", key: "7" },
  { view: "server", icon: "server", label: "Server", key: "8" },
];

const emptyTranscript: TranscriptState = { items: [], busy: false, todos: [], lastSeq: 0 };
const DOCK_KEY = "bb.dockWidth";

export function App() {
  const [state, setState] = useState<AppState>();
  const [link, setLink] = useState<LinkState>({ kind: "idle" });
  const [transcripts, setTranscripts] = useState<Record<string, TranscriptState>>({});
  const [chat, setChat] = useState<string>();
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [view, setView] = useState<View>("chat");
  const [visited, setVisited] = useState<Set<View>>(new Set(["chat"]));
  const [dockOpen, setDockOpen] = useState(false);
  const [dockWidth, setDockWidth] = useState(() => { try { return Number(localStorage.getItem(DOCK_KEY)) || 560; } catch { return 560; } });
  const [sidebar, setSidebar] = useState(true);
  const [palette, setPalette] = useState(false);
  const [dialog, setDialog] = useState<DialogSpec>();
  const [toast, setToast] = useState<string>();
  const [screenAsk, setScreenAsk] = useState<string>();
  const [prefill, setPrefill] = useState<{ chat?: string; text: string }>();
  const [focusKey, setFocusKey] = useState(0);
  const restored = useRef(false);
  const searchRef = useRef<HTMLInputElement>(null);
  const dragging = useRef(false);

  const say = useCallback((text: string) => setToast(text), []);
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(undefined), 3200);
    return () => clearTimeout(t);
  }, [toast]);

  const applyTheme = useCallback((theme: string) => {
    const light = theme === "light" || (theme === "system" && matchMedia("(prefers-color-scheme: light)").matches);
    document.documentElement.dataset.theme = light ? "light" : "dark";
    bb.invoke("titleBar", light ? "#f4f3ef" : "#0b0c0f", light ? "#3a3a40" : "#a9a9b3").catch(() => {});
  }, []);

  const reload = useCallback(async () => {
    const s = await bb.invoke<AppState>("state");
    setState(s);
    setLink(s.link);
    setTranscripts(s.transcripts);
    applyTheme(s.prefs.theme);
    return s;
  }, [applyTheme]);

  const refreshSessions = useCallback(async () => {
    try { setSessions(await bb.invoke<SessionSummary[]>("sessions")); } catch { /* the banner says why */ }
  }, []);

  const show = useCallback((v: View) => {
    setView(v);
    setVisited((s) => (s.has(v) ? s : new Set(s).add(v)));
  }, []);

  const openChat = useCallback(async (id: string) => {
    show("chat");
    setChat(id);
    try {
      const t = await bb.invoke<TranscriptState>("openChat", id);
      setTranscripts((all) => ({ ...all, [id]: t }));
      bb.invoke("refreshChat", id).catch(() => {});
    } catch (e) { say((e as Error).message); }
  }, [say, show]);

  const newChat = useCallback(async () => {
    show("chat");
    try {
      const id = await bb.invoke<string>("newChat");
      setChat(id);
      setFocusKey((k) => k + 1);
      return id;
    } catch (e) { say((e as Error).message); return undefined; }
  }, [say, show]);

  useEffect(() => {
    reload();
    const offs = [
      bb.on("bb:state", (s: LinkState) => setLink(s)),
      bb.on("bb:transcript", (id: string, t: TranscriptState) => setTranscripts((all) => ({ ...all, [id]: t }))),
      bb.on("bb:connected", async () => {
        await refreshSessions();
        if (!restored.current) {
          restored.current = true;
          const s = await bb.invoke<AppState>("state");
          if (s.lastChat) openChat(s.lastChat);
        }
      }),
      bb.on("bb:gateway-event", (e: { type: string }) => { if (e.type === "sessions.changed" || e.type === "session.title") refreshSessions(); }),
      bb.on("bb:prefill", (id: string, text: string) => setPrefill({ chat: id, text })),
      bb.on("bb:screen-ask", (id: string) => setScreenAsk(id)),
      bb.on("bb:navigate", (to: { chat?: string; view?: View }) => {
        if (to.chat) openChat(to.chat);
        if (to.view === "screen") setDockOpen(true);
      }),
    ];
    const mq = matchMedia("(prefers-color-scheme: light)");
    const onScheme = () => setState((s) => { if (s) applyTheme(s.prefs.theme); return s; });
    mq.addEventListener("change", onScheme);
    return () => { offs.forEach((off) => off()); mq.removeEventListener("change", onScheme); };
  }, [reload, refreshSessions, openChat, applyTheme]);

  // Lists refresh when any open chat finishes a turn (titles, previews) — including turns from the phone.
  const busyIds = useMemo(() => new Set(Object.entries(transcripts).filter(([, t]) => t.busy).map(([id]) => id)), [transcripts]);
  const busyKey = [...busyIds].sort().join(",");
  const lastBusy = useRef("");
  useEffect(() => {
    if (lastBusy.current && lastBusy.current !== busyKey) refreshSessions();
    lastBusy.current = busyKey;
  }, [busyKey, refreshSessions]);
  useEffect(() => {
    const t = setInterval(() => { if (document.visibilityState === "visible") refreshSessions(); }, 30_000);
    return () => clearInterval(t);
  }, [refreshSessions]);

  const transcript = (chat && transcripts[chat]) || emptyTranscript;
  const connected = link.kind === "connected";
  const session = sessions.find((s) => s.id === chat);
  const readOnly = session && isReadOnly(session.source) ? session.source : undefined;
  const title = transcript.title ?? (session?.title.trim() || session?.preview.trim()) ?? (chat ? "New chat" : "Brainbox");

  const screenPrompt = useMemo(() => {
    if (chat && screenAsk === chat) return { text: "Hermes needs you on its screen — take over", urgent: true };
    if (transcript.busy) {
      for (let i = transcript.items.length - 1; i >= 0; i--) {
        const it = transcript.items[i];
        if (it.kind === "user") break;
        if (it.kind === "tool" && it.tool.status === "running") {
          return isScreenTool(it.tool.name) ? { text: "Hermes is using its browser — watch live", urgent: false } : undefined;
        }
      }
    }
    return undefined;
  }, [chat, screenAsk, transcript]);

  const rename = useCallback((id: string, current: string) => setDialog({
    kind: "prompt", title: "Rename chat", value: current, confirm: "Rename",
    resolve: async (v) => {
      if (!v?.trim()) return;
      try { await bb.invoke("renameSession", id, v.trim()); refreshSessions(); } catch (e) { say((e as Error).message); }
    },
  }), [refreshSessions, say]);
  const remove = useCallback((s: { id: string; source: string; title: string }) => setDialog({
    kind: "confirm", title: "Delete this chat?", body: `“${s.title || "Untitled chat"}” is removed from Hermes on the server — on your phone too.`, confirm: "Delete", danger: true,
    resolve: async (ok) => {
      if (!ok) return;
      try {
        await bb.invoke("closeChat", s.id).catch(() => {});
        await bb.invoke("deleteSession", s.id, s.source);
        if (chat === s.id) setChat(undefined);
        refreshSessions();
      } catch (e) { say((e as Error).message); }
    },
  }), [chat, refreshSessions, say]);

  const askHermes = useCallback((text: string) => { show("chat"); setPrefill({ chat, text }); setFocusKey((k) => k + 1); }, [chat, show]);

  // Keyboard: Ctrl+K palette, Ctrl+N new chat, Ctrl+J screen beside chat, Ctrl+B chats list, Ctrl+1…8 pages.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.ctrlKey || e.metaKey) || e.altKey) return;
      const k = e.key.toLowerCase();
      if (k === "k" || (k === "p" && e.shiftKey)) { e.preventDefault(); setPalette((p) => !p); }
      else if (k === "n" && !e.shiftKey) { e.preventDefault(); if (connected) newChat(); }
      else if (k === "j") { e.preventDefault(); if (view === "screen") show("chat"); else { show("chat"); setDockOpen((d) => !d); } }
      else if (k === "b") { e.preventDefault(); setSidebar((s) => !s); }
      else if (k === ",") { e.preventDefault(); show("settings"); }
      else if (k === "f" && e.shiftKey) { e.preventDefault(); show("chat"); setSidebar(true); setTimeout(() => searchRef.current?.focus(), 0); }
      else if (/^[1-8]$/.test(k)) { e.preventDefault(); show(NAV[Number(k) - 1].view); }
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, [connected, newChat, show, view]);

  const actions: PaletteAction[] = useMemo(() => [
    { id: "new", icon: "plus", label: "New chat", hint: "Ctrl N", group: "Actions", run: () => newChat() },
    { id: "dock", icon: "monitor", label: dockOpen ? "Close Hermes' screen beside the chat" : "Open Hermes' screen beside the chat", hint: "Ctrl J", group: "Actions", run: () => { show("chat"); setDockOpen(!dockOpen); } },
    { id: "side", icon: "sidebar", label: sidebar ? "Hide chats list" : "Show chats list", hint: "Ctrl B", group: "Actions", run: () => setSidebar(!sidebar) },
    { id: "reconnect", icon: "refresh", label: "Reconnect to the server", group: "Actions", run: () => bb.invoke("connect").catch((e) => say(e.message)) },
    ...(chat && transcript.busy ? [{ id: "stop", icon: "stop" as IconName, label: "Stop the current reply", group: "Actions", run: () => bb.invoke("interrupt", chat).catch(() => {}) }] : []),
    ...NAV.map((n) => ({ id: "go-" + n.view, icon: n.icon, label: `Go to ${n.label}`, hint: n.key ? `Ctrl ${n.key}` : undefined, group: "Pages", run: () => show(n.view) })),
    { id: "go-settings", icon: "settings", label: "Go to Settings", hint: "Ctrl ,", group: "Pages", run: () => show("settings") },
    ...sessions.slice(0, 300).map((s) => ({ id: "s-" + s.id, icon: (isReadOnly(s.source) ? "lock" : "chat") as IconName, label: s.title.trim() || s.preview.trim() || "Untitled chat", group: "Chats", run: () => openChat(s.id) })),
  ], [chat, dockOpen, newChat, openChat, say, sessions, show, sidebar, transcript.busy]);

  // Resizable dock.
  const startDrag = (e: React.MouseEvent) => {
    e.preventDefault();
    dragging.current = true;
    const startX = e.clientX;
    const startW = dockWidth;
    let w = startW;
    const move = (ev: MouseEvent) => { w = Math.max(380, Math.min(innerWidth - 520, startW + (startX - ev.clientX))); setDockWidth(w); };
    const up = () => {
      dragging.current = false;
      removeEventListener("mousemove", move);
      removeEventListener("mouseup", up);
      try { localStorage.setItem(DOCK_KEY, String(w)); } catch { /* private storage */ }
    };
    addEventListener("mousemove", move);
    addEventListener("mouseup", up);
  };

  if (!state) return <div className="app" />;

  if (!state.profile) {
    return (
      <div className="app">
        <TitleBar onPalette={undefined} />
        <Onboarding state={state} link={link} onDone={reload} say={say} />
        {toast && <div className="toast" onClick={() => setToast(undefined)}>{toast}</div>}
      </div>
    );
  }

  const screenLive = !!screenPrompt;
  const screenShown = view === "screen" || (view === "chat" && dockOpen);
  const pageProps = { connected, say, ask: setDialog, home: state.profile.target.username === "root" ? "/root" : `/home/${state.profile.target.username}`, onChat: askHermes };

  return (
    <div className="app">
      <TitleBar onPalette={() => setPalette(true)} />
      <div className="body">
        <nav className="rail">
          {NAV.map((n) => (
            <button key={n.view} className={"rail-btn" + (view === n.view ? " on" : "")} data-tip={`${n.label}${n.key ? `  ·  Ctrl ${n.key}` : ""}`}
                    onClick={() => (n.view === "chat" && view === "chat" ? setSidebar(!sidebar) : show(n.view))}>
              <Icon name={n.icon} size={19} />
              {n.view === "screen" && screenLive && <span className={"badge" + (screenPrompt?.urgent ? "" : " live")} />}
              {n.view === "chat" && view !== "chat" && busyIds.size > 0 && <span className="badge live" />}
            </button>
          ))}
          <span className="rail-spacer" />
          <button className={"rail-btn" + (view === "settings" ? " on" : "")} data-tip="Settings  ·  Ctrl ," onClick={() => show("settings")}>
            <Icon name="settings" size={19} />
            {link.kind === "failed" && <span className="badge" />}
          </button>
        </nav>

        {view === "chat" && sidebar && (
          <Sidebar sessions={sessions} active={chat} busy={busyIds} connected={connected} searchRef={searchRef}
                   onOpen={(s) => openChat(s.id)} onNew={newChat}
                   onRename={(s) => rename(s.id, s.title)} onDelete={(s) => remove(s)} />
        )}

        <main className="main">
          <LinkBanner link={link} />
          <div className="view">
            {view === "chat" && (
              <ChatPane chat={chat} transcript={transcript} connected={connected} readOnly={readOnly} title={title} say={say}
                        newChat={newChat} prefill={prefill && (!prefill.chat || prefill.chat === chat) ? prefill.text : undefined}
                        clearPrefill={() => setPrefill(undefined)}
                        screenPrompt={screenPrompt}
                        onScreenPrompt={() => { setScreenAsk(undefined); setDockOpen(true); }}
                        onSent={() => { if (screenAsk === chat) setScreenAsk(undefined); }}
                        dockOpen={dockOpen} toggleDock={() => setDockOpen(!dockOpen)}
                        onRename={() => chat && rename(chat, title)}
                        onDelete={() => chat && remove({ id: chat, source: session?.source ?? "", title })}
                        focusKey={focusKey} />
            )}
            {view === "chat" && dockOpen && <div className={"split-handle" + (dragging.current ? " drag" : "")} onMouseDown={startDrag} />}
            {(visited.has("screen") || dockOpen) && (
              <div className="dock" style={{ display: screenShown ? "flex" : "none", ...(view === "screen" ? { flex: 1 } : { width: dockWidth, flex: `0 0 ${dockWidth}px` }) }}>
                <ScreenPane connected={connected} active={screenShown} say={say} onClose={view === "chat" ? () => setDockOpen(false) : undefined} />
              </div>
            )}
            {visited.has("terminal") && (
              <div className="view" style={{ display: view === "terminal" ? "flex" : "none" }}>
                <TerminalPane connected={connected} active={view === "terminal"} />
              </div>
            )}
            {view === "agents" && <AgentsPage {...pageProps} />}
            {view === "skills" && <SkillsPage {...pageProps} />}
            {view === "memory" && <MemoryPage {...pageProps} />}
            {view === "files" && <FilesPage {...pageProps} />}
            {view === "server" && <ServerPage {...pageProps} version={link.kind === "connected" ? link.info.version : undefined} target={link.kind === "connected" ? link.info.target : undefined} />}
            {view === "settings" && <SettingsPage state={state} link={link} say={say} ask={setDialog} onSaved={reload} />}
          </div>
        </main>
      </div>
      <StatusBar link={link} transcript={view === "chat" ? transcript : undefined} busy={busyIds.size} onLink={() => show("settings")} />
      {palette && <Palette actions={actions} onClose={() => setPalette(false)} />}
      {dialog && <Dialog spec={dialog} onDone={() => setDialog(undefined)} />}
      {toast && <div className="toast" onClick={() => setToast(undefined)}>{toast}</div>}
    </div>
  );
}

function TitleBar({ onPalette }: { onPalette?: () => void }) {
  return (
    <header className="titlebar">
      <div className="brand"><div className="logo">B</div>Brainbox</div>
      {onPalette && (
        <button className="palette-trigger" onClick={onPalette}>
          <Icon name="search" size={13} /><span>Search chats, pages, actions…</span><kbd>Ctrl</kbd><kbd>K</kbd>
        </button>
      )}
    </header>
  );
}

function StatusBar({ link, transcript, busy, onLink }: { link: LinkState; transcript?: TranscriptState; busy: number; onLink: () => void }) {
  const ctx = transcript?.usage?.contextPercent;
  const model = transcript?.model ?? transcript?.usage?.model;
  return (
    <footer className="statusbar">
      <span className="item click" onClick={onLink}>
        {link.kind === "connected" ? <><span className="dot good" />{link.info.target}</>
          : link.kind === "connecting" ? <><span className="dot warn pulse" />{link.step}</>
          : link.kind === "reconnecting" ? <><span className="dot warn pulse" />Reconnecting{link.attempt > 1 ? ` (try ${link.attempt})` : ""}</>
          : link.kind === "failed" ? <><span className="dot bad" />Offline</>
          : <><span className="dot muted" />Not connected</>}
      </span>
      {link.kind === "connected" && <span className="item"><Icon name="smartphone" size={12} />Shared with your phone</span>}
      {busy > 0 && <span className="item"><span className="dot volt pulse" />{busy} working</span>}
      <span className="spacer" />
      {model && <span className="item"><Icon name="cpu" size={12} />{model}</span>}
      {ctx !== undefined && <span className="item" title={`${ctx}% of the context window used`}>Context <span className="meter"><i style={{ width: `${Math.min(100, ctx)}%`, background: ctx > 85 ? "var(--bad)" : ctx > 65 ? "var(--warn)" : undefined }} /></span>{ctx}%</span>}
      {transcript?.usage && <span className="item">{transcript.usage.totalTokens.toLocaleString()} tokens</span>}
      {link.kind === "connected" && link.info.version && <span className="item">Hermes {link.info.version}</span>}
    </footer>
  );
}

function LinkBanner({ link }: { link: LinkState }) {
  if (link.kind === "connected" || link.kind === "connecting") return null;
  if (link.kind === "failed") {
    return (
      <div className="banner bad">
        <Icon name="alert" size={14} /><span>{link.message}</span>
        <button className="btn small" onClick={() => bb.invoke("connect").catch(() => {})}>Retry</button>
      </div>
    );
  }
  if (link.kind === "idle") {
    return (
      <div className="banner">
        <Icon name="info" size={14} /><span>Not connected.</span>
        <button className="btn small" onClick={() => bb.invoke("connect").catch(() => {})}>Connect</button>
      </div>
    );
  }
  return <div className="banner"><span className="dot warn pulse" /><span>{link.attempt > 1 ? `${link.reason} (try ${link.attempt})` : link.reason} — your chats stay here and catch up when the link is back.</span></div>;
}
