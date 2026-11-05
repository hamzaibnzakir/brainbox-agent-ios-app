import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { TranscriptState } from "../shared/transcript";
import { isScreenTool } from "../shared/transcript";
import { AppState, bb, isReadOnly, LinkState, SessionSummary } from "./api";
import { ChatPane } from "./components/Chat";
import { ConnectView } from "./components/Connect";
import { ScreenPane } from "./components/Screen";
import { TerminalPane } from "./components/Terminal";

type View = "workspace" | "chat" | "screen" | "terminal";

const emptyTranscript: TranscriptState = { items: [], busy: false, todos: [], lastSeq: 0 };

export function App() {
  const [state, setState] = useState<AppState>();
  const [link, setLink] = useState<LinkState>({ kind: "idle" });
  const [transcripts, setTranscripts] = useState<Record<string, TranscriptState>>({});
  const [chat, setChat] = useState<string>();
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [view, setView] = useState<View>("workspace");
  const [visited, setVisited] = useState<Set<View>>(new Set(["workspace"]));
  const [toast, setToast] = useState<string>();
  const [screenAsk, setScreenAsk] = useState<string>();
  const [prefill, setPrefill] = useState<{ chat: string; text: string }>();
  const [showConnection, setShowConnection] = useState(false);
  const restored = useRef(false);

  const say = useCallback((text: string) => setToast(text), []);
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(undefined), 3500);
    return () => clearTimeout(t);
  }, [toast]);

  const reload = useCallback(async () => {
    const s = await bb.invoke<AppState>("state");
    setState(s);
    setLink(s.link);
    setTranscripts(s.transcripts);
    document.documentElement.dataset.theme = s.prefs.theme === "system" ? "" : s.prefs.theme;
    return s;
  }, []);

  const refreshSessions = useCallback(async () => {
    try { setSessions(await bb.invoke<SessionSummary[]>("sessions")); } catch { /* shown by the banner */ }
  }, []);

  const openChat = useCallback(async (id: string) => {
    try {
      const t = await bb.invoke<TranscriptState>("openChat", id);
      setTranscripts((all) => ({ ...all, [id]: t }));
      setChat(id);
    } catch (e) { say((e as Error).message); }
  }, [say]);

  const newChat = useCallback(async () => {
    try {
      const id = await bb.invoke<string>("newChat");
      setChat(id);
      return id;
    } catch (e) { say((e as Error).message); return undefined; }
  }, [say]);

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
      bb.on("bb:gateway-event", (e: { type: string }) => { if (e.type === "sessions.changed") refreshSessions(); }),
      bb.on("bb:prefill", (id: string, text: string) => setPrefill({ chat: id, text })),
      bb.on("bb:screen-ask", (id: string) => setScreenAsk(id)),
      bb.on("bb:navigate", (to: { chat?: string; view?: View }) => {
        if (to.chat) openChat(to.chat);
        if (to.view === "screen") show("workspace");
      }),
    ];
    return () => offs.forEach((off) => off());
  }, [reload, refreshSessions, openChat]);

  // A finished turn refreshes the list (titles, previews).
  const busyNow = chat ? transcripts[chat]?.busy : false;
  const wasBusy = useRef(false);
  useEffect(() => {
    if (wasBusy.current && !busyNow) refreshSessions();
    wasBusy.current = !!busyNow;
  }, [busyNow, refreshSessions]);

  const show = (v: View) => {
    setView(v);
    setVisited((s) => new Set(s).add(v));
  };

  const transcript = (chat && transcripts[chat]) || emptyTranscript;
  const connected = link.kind === "connected";
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

  if (!state) return null;
  if (!state.profile || showConnection) {
    return (
      <ConnectView state={state} link={link} onboarding={!state.profile}
                   onDone={async () => { setShowConnection(false); await reload(); }}
                   onClose={state.profile ? () => setShowConnection(false) : undefined} say={say} />
    );
  }

  const screenVisible = view === "workspace" || view === "screen";
  const chatVisible = view === "workspace" || view === "chat";

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="sidebar-head">
          <div className="brand"><div className="brand-dot">B</div>Brainbox<span style={{ flex: 1 }} /><LinkPill link={link} /></div>
          <button className="btn primary" disabled={!connected} onClick={() => newChat()}>New chat</button>
        </div>
        <div className="sessions">
          {sessions.map((s) => (
            <button key={s.id} className={"session" + (s.id === chat ? " active" : "")} onClick={() => openChat(s.id)}>
              <div className="t">{s.title.trim() || s.preview.trim() || "Untitled chat"}</div>
              <div className="p">{isReadOnly(s.source) ? `${s.source} · read-only · ` : ""}{s.preview}</div>
            </button>
          ))}
          {connected && sessions.length === 0 && <div className="notice" style={{ padding: 16 }}>No chats yet.</div>}
        </div>
        <div className="sidebar-foot">
          <button className="btn ghost" onClick={() => setShowConnection(true)}>Connection</button>
          <span style={{ flex: 1 }} />
          <span className="notice" style={{ alignSelf: "center" }}>v{state.version}</span>
        </div>
      </aside>

      <main className="main">
        <div className="topbar">
          <div style={{ minWidth: 0 }}>
            <div className="title">{transcript.title ?? (chat ? "New chat" : state.profile.name)}</div>
            <div className="sub">{subtitle(link, transcript)}</div>
          </div>
          <div className="tabs" role="tablist">
            {(["workspace", "chat", "screen", "terminal"] as View[]).map((v) => (
              <button key={v} role="tab" className={"tab" + (view === v ? " on" : "")} onClick={() => show(v)}>
                {v === "workspace" ? "Workspace" : v[0].toUpperCase() + v.slice(1)}
              </button>
            ))}
          </div>
        </div>
        <LinkBanner link={link} />
        <div className={"content" + (view === "workspace" ? " split" : "")}>
          <div className="pane" style={{ display: chatVisible ? "flex" : "none", flex: view === "workspace" ? "0 0 44%" : 1 }}>
            <ChatPane chat={chat} transcript={transcript} connected={connected} say={say}
                      newChat={newChat} prefill={prefill?.chat === chat ? prefill?.text : undefined}
                      clearPrefill={() => setPrefill(undefined)}
                      screenPrompt={screenPrompt}
                      onScreenPrompt={() => { setScreenAsk(undefined); show(view === "chat" ? "screen" : view); }}
                      onSent={() => { if (screenAsk === chat) setScreenAsk(undefined); }} />
          </div>
          {(visited.has("workspace") || visited.has("screen")) && (
            <div className="pane" style={{ display: screenVisible ? "flex" : "none" }}>
              <ScreenPane connected={connected} active={screenVisible} say={say} />
            </div>
          )}
          {visited.has("terminal") && (
            <div className="pane" style={{ display: view === "terminal" ? "flex" : "none" }}>
              <TerminalPane connected={connected} active={view === "terminal"} />
            </div>
          )}
        </div>
      </main>
      {toast && <div className="toast" onClick={() => setToast(undefined)}>{toast}</div>}
    </div>
  );
}

function subtitle(link: LinkState, t: TranscriptState) {
  if (t.busy && t.status) return t.status;
  const parts: string[] = [];
  if (t.model ?? t.usage?.model) parts.push((t.model ?? t.usage?.model)!);
  if (t.usage?.contextPercent !== undefined) parts.push(`${t.usage.contextPercent}% context`);
  if (link.kind === "connected" && link.info.version) parts.push(`Hermes ${link.info.version}`);
  return parts.join(" · ") || (link.kind === "connected" ? "Ready" : "Offline");
}

export function LinkPill({ link }: { link: LinkState }) {
  switch (link.kind) {
    case "connected": return <span className="pill good"><span className="dot" />Online</span>;
    case "connecting": return <span className="pill warn"><span className="dot pulse" />Connecting</span>;
    case "reconnecting": return <span className="pill warn"><span className="dot pulse" />Reconnecting</span>;
    case "failed": return <span className="pill bad"><span className="dot" />Offline</span>;
    default: return <span className="pill muted"><span className="dot" />Not connected</span>;
  }
}

function LinkBanner({ link }: { link: LinkState }) {
  if (link.kind === "connected") return null;
  if (link.kind === "failed") {
    return (
      <div className="banner bad">
        <span style={{ flex: 1 }}>{link.message}</span>
        <button className="btn small" onClick={() => bb.invoke("connect").catch(() => {})}>Retry</button>
      </div>
    );
  }
  if (link.kind === "idle") {
    return (
      <div className="banner">
        <span style={{ flex: 1 }}>Not connected.</span>
        <button className="btn small" onClick={() => bb.invoke("connect").catch(() => {})}>Connect</button>
      </div>
    );
  }
  const text = link.kind === "connecting" ? link.step : link.attempt > 1 ? `${link.reason} (try ${link.attempt})` : link.reason;
  return <div className="banner"><span className="pill warn"><span className="dot pulse" /></span><span>{text}</span></div>;
}
