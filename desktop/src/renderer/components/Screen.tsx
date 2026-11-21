// Hermes' screen (Bot Screen): watch the bot's browser live, take over with your own keyboard and
// mouse for a login / CAPTCHA / 2FA / payment step, then hand back. Same screen and control lock as
// the iPhone app and Hermes Desktop. The page never touches the network: the main process owns the
// ticketed socket (through SSH) and passes RFB bytes over IPC (see main.ts ScreenSession).
import RFB from "@novnc/novnc";
import React, { useCallback, useEffect, useRef, useState } from "react";
import { bb, ScreenLease, ScreenStatus } from "../api";
import { Icon } from "../ui/icons";

type Phase =
  | { kind: "checking" }
  | { kind: "unsupported"; message: string }
  | { kind: "notInstalled"; command?: string; missing: string[] }
  | { kind: "stopped"; blocker?: string }
  | { kind: "starting" }
  | { kind: "connecting" }
  | { kind: "live" }
  | { kind: "failed"; message: string };

/** A WebSocket-shaped channel noVNC attaches to; bytes go through the preload bridge. */
class BridgeChannel {
  binaryType = "arraybuffer";
  protocol = "";
  readyState = "open";
  onopen: ((e: unknown) => void) | null = null;
  onmessage: ((e: { data: ArrayBuffer }) => void) | null = null;
  onclose: ((e: { code: number; reason: string; wasClean: boolean }) => void) | null = null;
  onerror: ((e: unknown) => void) | null = null;
  send(data: ArrayBuffer | Uint8Array) {
    if (this.readyState !== "open") return;
    const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    bb.screenInput(bytes.slice()); // copy now: noVNC reuses its send buffer
  }
  close() {
    if (this.readyState === "closed") return;
    this.readyState = "closed";
    bb.invoke("screen.close").catch(() => {});
  }
  deliver(bytes: Uint8Array) {
    if (this.readyState === "open" && this.onmessage) {
      this.onmessage({ data: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer });
    }
  }
  closed(code: number, reason: string) {
    if (this.readyState === "closed" && !this.onclose) return;
    this.readyState = "closed";
    this.onclose?.({ code, reason, wasClean: code === 1000 });
  }
}

export function ScreenPane({ connected, active, say, onClose }: { connected: boolean; active: boolean; say: (t: string) => void; onClose?: () => void }) {
  const [phase, setPhase] = useState<Phase>({ kind: "checking" });
  const [status, setStatus] = useState<ScreenStatus>();
  const [lease, setLease] = useState<ScreenLease>({ holder: "agent", since: 0, epoch: 0, reason: "" });
  const [inControl, setInControl] = useState(false);
  const [fit, setFit] = useState(true);
  const [busy, setBusy] = useState(false);
  const host = useRef<HTMLDivElement>(null);
  const rfb = useRef<RFB | null>(null);
  const channel = useRef<BridgeChannel | null>(null);
  const control = useRef(false);
  const reconnects = useRef(0);
  const opening = useRef(false);

  const apply = useCallback((s: ScreenStatus) => {
    setStatus(s);
    setLease(s.lease);
    if (s.lease.holder === "agent") { control.current = false; setInControl(false); }
    if (!s.supported) setPhase({ kind: "unsupported", message: "This server already has a real display, so Hermes doesn't run a Bot Screen on it." });
    else if (!s.installed) setPhase({ kind: "notInstalled", command: s.installCommand, missing: s.missing });
    else if (!s.running) { teardown(false); setPhase({ kind: "stopped", blocker: s.blocker }); }
  }, []);

  const fail = useCallback((e: unknown) => {
    const err = e as Error & { code?: string };
    if (err.code === "unsupportedHermes") setPhase({ kind: "unsupported", message: err.message });
    else if (err.code === "notRunning") setPhase({ kind: "stopped" });
    else setPhase({ kind: "failed", message: err.message });
  }, []);

  function teardown(clean = true) {
    const r = rfb.current;
    rfb.current = null;
    const ch = channel.current;
    channel.current = null;
    if (r) { try { r.disconnect(); } catch { /* already gone */ } }
    else if (clean && ch) ch.close();
  }

  const open = useCallback(async () => {
    if (opening.current) return;
    opening.current = true;
    try {
      setPhase({ kind: "connecting" });
      teardown();
      const r = await bb.invoke<{ viewerId: string; status: ScreenStatus }>("screen.open");
      apply(r.status);
      if (!r.status.running) return;
      const ch = new BridgeChannel();
      channel.current = ch;
      const view = new RFB(host.current!, ch, { shared: true });
      view.viewOnly = !control.current;
      view.scaleViewport = fit;
      view.clipViewport = !fit;
      view.dragViewport = false;
      view.resizeSession = false;
      view.showDotCursor = true;
      view.focusOnClick = true;
      view.qualityLevel = 7;
      view.compressionLevel = 2;
      view.background = "#0b0c0f";
      view.addEventListener("connect", () => { setPhase({ kind: "live" }); reconnects.current = 0; });
      view.addEventListener("securityfailure", (e: CustomEvent) => setPhase({ kind: "failed", message: String(e.detail?.reason ?? "The screen refused the viewer.") }));
      rfb.current = view;
    } catch (e) {
      fail(e);
    } finally {
      opening.current = false;
    }
  }, [apply, fail, fit]);

  const refresh = useCallback(async () => {
    try {
      const s = await bb.invoke<ScreenStatus>("screen.status");
      apply(s);
      if (s.supported && s.installed && s.running && !channel.current) await open();
    } catch (e) {
      fail(e);
    }
  }, [apply, fail, open]);

  // Bytes and closes from the main process.
  useEffect(() => {
    const offs = [
      bb.on("bb:screen-data", (bytes: Uint8Array) => channel.current?.deliver(bytes)),
      bb.on("bb:screen-closed", (info: { code: number; reason: string; error?: string; message?: string }) => {
        const ch = channel.current;
        rfb.current = null;
        channel.current = null;
        ch?.closed(info.code, info.reason);
        if (info.error === "controlTaken") {
          control.current = false;
          setInControl(false);
          say(info.message ?? "Someone else took control. You're watching now.");
          open();
        } else if (info.error === "screenGone") {
          setPhase({ kind: "stopped" });
          refresh();
        } else if (info.code !== 1000) {
          reconnects.current += 1;
          if (reconnects.current <= 3) setTimeout(() => open(), 500);
          else setPhase({ kind: "failed", message: info.message ?? "The screen connection keeps dropping." });
        }
      }),
      bb.on("bb:screen-input-lost", () => { if (control.current) say("Lost the screen connection — that input didn't arrive."); }),
      bb.on("bb:gateway-event", (e: { type: string; payload: { lease?: ScreenLease; running?: boolean } & Partial<ScreenStatus> }) => {
        if (e.type === "display.lease" && e.payload.lease) {
          setLease(e.payload.lease);
          if (e.payload.lease.holder === "agent" && control.current) {
            control.current = false;
            setInControl(false);
            if (rfb.current) rfb.current.viewOnly = true;
          }
        } else if (e.type === "display.status") {
          refresh();
        }
      }),
    ];
    return () => offs.forEach((off) => off());
  }, [open, refresh, say]);

  // (Re)connect when the link comes up; close cleanly when the pane goes away (hands control back).
  useEffect(() => {
    if (connected) refresh();
    else { teardown(false); setPhase({ kind: "checking" }); }
  }, [connected]);
  useEffect(() => () => teardown(), []);

  useEffect(() => {
    if (rfb.current) { rfb.current.scaleViewport = fit; rfb.current.clipViewport = !fit; rfb.current.dragViewport = !fit; }
  }, [fit]);
  useEffect(() => { if (active && inControl) rfb.current?.focus(); }, [active, inControl]);

  const takeOver = async () => {
    setBusy(true);
    try {
      const l = await bb.invoke<ScreenLease>("screen.takeOver");
      setLease(l);
      control.current = true;
      setInControl(true);
      if (rfb.current) { rfb.current.viewOnly = false; rfb.current.focus(); }
    } catch (e) {
      const err = e as Error & { code?: string };
      say(err.message);
      if (err.code === "staleViewer") open();
    } finally {
      setBusy(false);
    }
  };

  const handBack = async (force = false) => {
    setBusy(true);
    try {
      setLease(await bb.invoke<ScreenLease>("screen.handBack", force));
      control.current = false;
      setInControl(false);
      if (rfb.current) { rfb.current.viewOnly = true; rfb.current.blur(); }
    } catch (e) {
      say((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const someoneElse = lease.holder === "human" && !inControl;
  const live = phase.kind === "live";

  return (
    <div className="screen">
      <div className="screen-bar">
        <div className="who">
          {inControl ? <span className="pill bad"><Icon name="hand" size={12} />You're in control</span>
            : someoneElse ? <span className="pill warn"><Icon name="hand" size={12} />Someone else is in control</span>
            : live ? <span className="pill volt"><span className="dot pulse" />Hermes is in control</span>
            : <span className="pill muted">{phaseLabel(phase)}</span>}
          <span className="sub">{live ? (inControl ? "Your keyboard and mouse drive the screen" : "Watching live") : "Hermes' screen"}</span>
        </div>
        {live && <button className="icon-btn" title={fit ? "Actual size" : "Fit to window"} onClick={() => setFit(!fit)}><Icon name="maximize" size={15} /></button>}
        {live && inControl && <button className="icon-btn" title="Send Ctrl+Alt+Del" onClick={() => rfb.current?.sendCtrlAltDel()}><Icon name="keyboard" size={15} /></button>}
        {status?.running && <button className="icon-btn" title="Turn the screen off" disabled={busy}
                                   onClick={async () => { if (confirm("Turn Hermes' screen off?")) { teardown(); try { apply(await bb.invoke<ScreenStatus>("screen.stop", someoneElse)); } catch (e) { say((e as Error).message); } } }}><Icon name="power" size={15} /></button>}
        {someoneElse && <button className="btn small ghost" disabled={busy} onClick={() => handBack(true)}>Hand back (force)</button>}
        {live && (inControl
          ? <button className="btn small good" disabled={busy} onClick={() => handBack()}><Icon name="check" size={13} />Hand back</button>
          : <button className="btn small danger" disabled={busy} onClick={takeOver}><Icon name="hand" size={13} />Take over</button>)}
        {onClose && <button className="icon-btn" title="Close (Ctrl+J)" onClick={onClose}><Icon name="x" size={15} /></button>}
      </div>
      <div className={"screen-view" + (inControl ? " control" : "")}>
        <div className="vnc" ref={host} style={{ visibility: live || phase.kind === "connecting" ? "visible" : "hidden" }} />
        {!live && <Overlay phase={phase} busy={busy} say={say}
                           onStart={async () => { setBusy(true); setPhase({ kind: "starting" }); try { apply(await bb.invoke<ScreenStatus>("screen.start")); await open(); } catch (e) { fail(e); } finally { setBusy(false); } }}
                           onRetry={refresh} />}
      </div>
    </div>
  );
}

function phaseLabel(p: Phase) {
  switch (p.kind) {
    case "checking": return "Checking";
    case "connecting": return "Connecting";
    case "starting": return "Starting the screen";
    case "stopped": return "Screen off";
    case "notInstalled": return "Not installed";
    case "unsupported": return "Unavailable";
    case "failed": return "Problem";
    default: return "Live";
  }
}

function Overlay({ phase, busy, onStart, onRetry, say }: { phase: Phase; busy: boolean; onStart: () => void; onRetry: () => void; say: (t: string) => void }) {
  let body: React.ReactElement;
  switch (phase.kind) {
    case "checking": case "connecting": case "starting":
      body = <span>{phase.kind === "starting" ? "Starting the screen…" : phase.kind === "connecting" ? "Connecting to the screen…" : "Checking Hermes' screen…"}</span>;
      break;
    case "unsupported":
      body = <><strong>Screen not available</strong><span>{phase.message}</span></>;
      break;
    case "notInstalled":
      body = (
        <>
          <strong>The screen needs a few packages on the server</strong>
          <span>Hermes runs a private desktop (TigerVNC + Xfce) for the bot's browser. Install them once on the server, then check again. Missing: {phase.missing.join(", ")}.</span>
          {phase.command && <div className="codebox">{phase.command}</div>}
          <div style={{ display: "flex", gap: 8 }}>
            {phase.command && <button className="btn" onClick={() => bb.invoke("copy", phase.command).then(() => say("Copied"))}>Copy command</button>}
            <button className="btn" onClick={onRetry}>Check again</button>
          </div>
        </>
      );
      break;
    case "stopped":
      body = (
        <>
          <strong>The screen is off</strong>
          <span>{phase.blocker ?? "Start it to watch Hermes' browser live. It stops again by itself when nobody has used it for a while."}</span>
          <button className="btn primary" disabled={busy || !!phase.blocker} onClick={onStart}>Start screen</button>
        </>
      );
      break;
    case "failed":
      body = <><strong>Problem</strong><span>{phase.message}</span><button className="btn" onClick={onRetry}>Retry</button></>;
      break;
    default:
      body = <></>;
  }
  return <div className="screen-overlay"><div className="box"><div className="glyph"><Icon name="monitor" size={24} /></div>{body}</div></div>;
}
