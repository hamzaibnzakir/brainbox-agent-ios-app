import { useState } from "react";
import { AppState, bb, LinkState, Profile } from "../api";

/** Pairing and connection settings: where to SSH, this PC's key, and the backend options. */
export function ConnectView({ state, link, onboarding, onDone, onClose, say }: {
  state: AppState; link: LinkState; onboarding: boolean; onDone: () => void; onClose?: () => void; say: (t: string) => void;
}) {
  const p = state.profile;
  const [name, setName] = useState(p?.name ?? "My VPS");
  const [host, setHost] = useState(p?.target.host ?? "");
  const [user, setUser] = useState(p?.target.username ?? "root");
  const [port, setPort] = useState(String(p?.target.port ?? 22));
  const [command, setCommand] = useState(state.authorizedKeysCommand);
  const [prefs, setPrefs] = useState(state.prefs);
  const [busy, setBusy] = useState(false);

  const save = async () => {
    const profile: Profile = { name: name.trim() || host.trim(), target: { host: host.trim(), port: parseInt(port, 10) || 22, username: user.trim() || "root" } };
    setBusy(true);
    try {
      await bb.invoke("saveProfile", profile);
      await bb.invoke("savePrefs", prefs);
      onDone();
      await bb.invoke("connect");
    } catch (e) {
      say((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const copy = async () => { await bb.invoke("copy", command); say("Copied — run it once on the server."); };

  return (
    <div className="connect">
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <div className="brand-dot" style={{ width: 40, height: 40, fontSize: 20 }}>B</div>
        <h1 style={{ flex: 1 }}>{onboarding ? "Connect to Hermes" : "Connection"}</h1>
        {onClose && <button className="btn ghost" onClick={onClose}>Close</button>}
      </div>
      <p style={{ color: "var(--ink2)", margin: 0 }}>
        Brainbox connects to your server over SSH, the way Hermes Desktop does: it starts (or reuses) Hermes on the
        server and talks to it through that SSH connection. Nothing new is opened to the internet.
      </p>

      <div className="card" style={{ display: "flex", flexDirection: "column", gap: 12 }}>
        <div className="row">
          <div className="field" style={{ flex: 2 }}><label>Host or IP</label>
            <input className="input" value={host} onChange={(e) => setHost(e.target.value)} placeholder="203.0.113.10 or vps.example.com" autoFocus={onboarding} /></div>
          <div className="field"><label>Port</label><input className="input" value={port} onChange={(e) => setPort(e.target.value)} /></div>
        </div>
        <div className="row">
          <div className="field"><label>User</label><input className="input" value={user} onChange={(e) => setUser(e.target.value)} /></div>
          <div className="field"><label>Name</label><input className="input" value={name} onChange={(e) => setName(e.target.value)} /></div>
        </div>
      </div>

      <div className="card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        <strong>Let this PC in (once)</strong>
        <span style={{ color: "var(--ink2)" }}>
          Run this on the server as {user || "root"}. It adds this PC's <em>public</em> key to authorized_keys; the private key
          was generated here and stays {state.encrypted ? "encrypted by Windows on this PC" : "on this PC"}.
        </span>
        <div className="codebox">{command}</div>
        <div style={{ display: "flex", gap: 8 }}>
          <button className="btn" onClick={copy}>Copy command</button>
          <span style={{ flex: 1 }} />
          <span className="notice" style={{ alignSelf: "center" }}>Key {state.keyFingerprint}</span>
        </div>
      </div>

      <div className="card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        <strong>Options</strong>
        <label><input type="checkbox" checked={prefs.notifyOnFinish} onChange={(e) => setPrefs({ ...prefs, notifyOnFinish: e.target.checked })} /> Notify me when a reply is ready (while Brainbox is in the background)</label>
        <label><input type="checkbox" checked={prefs.notifyOnApproval} onChange={(e) => setPrefs({ ...prefs, notifyOnApproval: e.target.checked })} /> Notify me when Hermes needs approval or needs me on its screen</label>
        <label><input type="checkbox" checked={prefs.desktopBackend} onChange={(e) => setPrefs({ ...prefs, desktopBackend: e.target.checked })} /> Desktop-compatible backend (only for servers with <code>dashboard.public_url</code> set)</label>
        <label>Theme&nbsp;
          <select className="input" style={{ width: "auto", display: "inline-block" }} value={prefs.theme}
                  onChange={(e) => setPrefs({ ...prefs, theme: e.target.value as typeof prefs.theme })}>
            <option value="system">System</option><option value="light">Light</option><option value="dark">Dark</option>
          </select>
        </label>
      </div>

      {link.kind === "failed" && <div className="banner bad" style={{ margin: 0 }}>{link.message}</div>}
      {link.kind === "connected" && (
        <div className="banner" style={{ margin: 0 }}>
          Connected to {link.info.target} · Hermes {link.info.version ?? "?"} · server key {link.info.hostFingerprint}
        </div>
      )}

      <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        <button className="btn primary" disabled={!host.trim() || busy} onClick={save}>{onboarding ? "Connect" : "Save and reconnect"}</button>
        {!onboarding && (
          <>
            <button className="btn" onClick={() => bb.invoke("restartBackend").then(() => say("Backend restarted."), (e) => say(e.message))}>Restart backend</button>
            <button className="btn" onClick={() => bb.invoke("forgetHostKey").then(() => say("Trusted server key cleared. The next connection trusts the key it sees."))}>Reset trusted server key</button>
            <button className="btn ghost" onClick={async () => {
              if (!confirm("Replace this PC's SSH key? The old key stops working until you add the new one on the server.")) return;
              const r = await bb.invoke<{ authorizedKeysCommand: string }>("regenerateKey");
              setCommand(r.authorizedKeysCommand);
              say("New key created. Add it on the server, then reconnect.");
            }}>New SSH key</button>
            <button className="btn ghost" onClick={() => bb.invoke("disconnect")}>Disconnect</button>
          </>
        )}
      </div>
      <p className="notice" style={{ textAlign: "left" }}>
        After updating Hermes on the server, use <strong>Restart backend</strong> so this PC runs the new version.
      </p>
    </div>
  );
}
