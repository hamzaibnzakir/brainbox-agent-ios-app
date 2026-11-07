// First run (pair this PC with the server) and Settings (connection, notifications, theme).
import { useState } from "react";
import { AppState, bb, LinkState, Preferences, Profile } from "../api";
import { Icon } from "../ui/icons";
import { DialogSpec, Switch } from "../ui/kit";

function useProfileForm(state: AppState) {
  const p = state.profile;
  const [host, setHost] = useState(p?.target.host ?? "");
  const [user, setUser] = useState(p?.target.username ?? "root");
  const [port, setPort] = useState(String(p?.target.port ?? 22));
  const [name, setName] = useState(p?.name ?? "My VPS");
  const profile = (): Profile => ({ name: name.trim() || host.trim(), target: { host: host.trim(), port: parseInt(port, 10) || 22, username: user.trim() || "root" } });
  const fields = (
    <>
      <div className="row">
        <div className="field" style={{ flex: 2 }}><label>Server address</label>
          <input className="input" value={host} onChange={(e) => setHost(e.target.value)} placeholder="203.0.113.10 or vps.example.com" autoFocus={!p} /></div>
        <div className="field" style={{ maxWidth: 96 }}><label>SSH port</label><input className="input" value={port} onChange={(e) => setPort(e.target.value)} /></div>
      </div>
      <div className="row">
        <div className="field"><label>User</label><input className="input" value={user} onChange={(e) => setUser(e.target.value)} /></div>
        <div className="field"><label>Name</label><input className="input" value={name} onChange={(e) => setName(e.target.value)} /></div>
      </div>
    </>
  );
  return { host, user, profile, fields };
}

export function Onboarding({ state, link, onDone, say }: { state: AppState; link: LinkState; onDone: () => void; say: (t: string) => void }) {
  const form = useProfileForm(state);
  const [busy, setBusy] = useState(false);
  const connect = async () => {
    setBusy(true);
    try { await bb.invoke("saveProfile", form.profile()); onDone(); await bb.invoke("connect"); }
    catch (e) { say((e as Error).message); } finally { setBusy(false); }
  };
  return (
    <div className="onboard">
      <div className="art">
        <div className="logo" style={{ width: 44, height: 44, borderRadius: 14, fontSize: 20, marginBottom: 22 }}>B</div>
        <h1>Your Hermes, on every screen.</h1>
        <p>Brainbox connects this PC to the Hermes agent on your server. The same chats live on your phone and here — start on one, finish on the other.</p>
        <div className="points">
          <div><Icon name="smartphone" />One live conversation across phone and PC</div>
          <div><Icon name="monitor" />Watch Hermes' browser, take over for logins and CAPTCHAs</div>
          <div><Icon name="lock" />SSH key auth only — nothing opened to the internet</div>
        </div>
      </div>
      <div className="form">
        <div><h2 style={{ margin: 0, font: "600 22px/1.2 var(--font-display)" }}>Connect to your server</h2>
          <p className="muted" style={{ margin: "6px 0 0" }}>Two minutes, once. Brainbox starts (or reuses) Hermes on the server over SSH.</p></div>
        <div className="step"><div className="n">1</div><div className="c"><strong>Where is your server?</strong>{form.fields}</div></div>
        <div className="step"><div className="n">2</div><div className="c">
          <strong>Let this PC in</strong>
          <span className="muted" style={{ fontSize: 13 }}>Run this once on the server as {form.user || "root"}. It adds this PC's public key to <code>authorized_keys</code>. The private key never leaves this PC{state.encrypted ? " and is encrypted by Windows" : ""}.</span>
          <div className="codebox">{state.authorizedKeysCommand}</div>
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            <button className="btn" onClick={() => bb.invoke("copy", state.authorizedKeysCommand).then(() => say("Copied — run it once on the server"))}><Icon name="copy" size={14} />Copy command</button>
            <span className="muted" style={{ fontSize: 12 }}>Key {state.keyFingerprint}</span>
          </div>
        </div></div>
        <div className="step"><div className="n">3</div><div className="c">
          <strong>Connect</strong>
          {link.kind === "failed" && <div className="error-line"><Icon name="alert" size={16} />{link.message}</div>}
          {link.kind === "connecting" && <div className="working"><span className="dot volt pulse" />{link.step}</div>}
          <div><button className="btn primary" disabled={!form.host.trim() || busy} onClick={connect}>Connect<Icon name="chevronRight" size={14} /></button></div>
        </div></div>
      </div>
    </div>
  );
}

export function SettingsPage({ state, link, say, ask, onSaved }: { state: AppState; link: LinkState; say: (t: string) => void; ask: (d: DialogSpec) => void; onSaved: () => void }) {
  const form = useProfileForm(state);
  const [prefs, setPrefs] = useState<Preferences>(state.prefs);
  const [command, setCommand] = useState(state.authorizedKeysCommand);
  const setPref = async (patch: Partial<Preferences>) => {
    const next = { ...prefs, ...patch };
    setPrefs(next);
    await bb.invoke("savePrefs", next);
    onSaved();
  };
  const reconnect = async () => {
    try { await bb.invoke("saveProfile", form.profile()); onSaved(); await bb.invoke("connect"); say("Reconnecting"); }
    catch (e) { say((e as Error).message); }
  };
  const info = link.kind === "connected" ? link.info : undefined;

  return (
    <div className="page">
      <div className="page-inner" style={{ maxWidth: 780 }}>
        <div className="page-head"><div className="h"><h1>Settings</h1><p>Connection, notifications and appearance.</p></div></div>

        <div className="section">
          <h2>Connection</h2>
          <div className="card" style={{ display: "flex", flexDirection: "column", gap: 12 }}>
            {form.fields}
            <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
              <button className="btn primary" disabled={!form.host.trim()} onClick={reconnect}>Save and reconnect</button>
              {link.kind === "connected"
                ? <button className="btn ghost" onClick={() => bb.invoke("disconnect")}>Disconnect</button>
                : <button className="btn ghost" onClick={() => bb.invoke("connect").catch(() => {})}>Connect</button>}
              <span style={{ flex: 1 }} />
              {info ? <span className="pill good"><span className="dot" />Connected · Hermes {info.version ?? "?"}</span>
                : link.kind === "failed" ? <span className="pill bad">Offline</span> : <span className="pill warn">{link.kind === "connecting" ? link.step : "Not connected"}</span>}
            </div>
            {link.kind === "failed" && <div className="error-line"><Icon name="alert" size={16} />{link.message}</div>}
          </div>
          {info && (
            <div className="list">
              <Row t="Server" d={`${info.target} · ${info.hermesPath}`} />
              <Row t="Server key" d={info.hostFingerprint} />
              <Row t="Shared with your phone" d={info.reusedBackend ? "This PC joined the Hermes backend your other devices use." : "This PC started the shared Hermes backend; your phone joins it."} />
            </div>
          )}
        </div>

        <div className="section">
          <h2>This PC's key</h2>
          <div className="card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <span className="muted" style={{ fontSize: 13 }}>To let this PC into another server, run this there once.</span>
            <div className="codebox">{command}</div>
            <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
              <button className="btn small" onClick={() => bb.invoke("copy", command).then(() => say("Copied"))}><Icon name="copy" size={13} />Copy</button>
              <button className="btn small ghost" onClick={() => ask({
                kind: "confirm", title: "Replace this PC's SSH key?", body: "The old key stops working until you add the new one on the server.", confirm: "Replace key", danger: true,
                resolve: async (ok) => { if (!ok) return; const r = await bb.invoke<{ authorizedKeysCommand: string }>("regenerateKey"); setCommand(r.authorizedKeysCommand); say("New key created. Add it on the server, then reconnect."); },
              })}>New key</button>
              <span style={{ flex: 1 }} />
              <span className="muted" style={{ fontSize: 12 }}>{state.keyFingerprint}</span>
            </div>
          </div>
        </div>

        <div className="section">
          <h2>Notifications</h2>
          <div className="list">
            <Toggle t="When a reply is ready" d="While Brainbox is in the background." v={prefs.notifyOnFinish} on={(v) => setPref({ notifyOnFinish: v })} />
            <Toggle t="When Hermes needs you" d="Approvals, questions, and steps only you can do on its screen." v={prefs.notifyOnApproval} on={(v) => setPref({ notifyOnApproval: v })} />
          </div>
        </div>

        <div className="section">
          <h2>Appearance</h2>
          <div className="list">
            <div className="setting">
              <div className="txt"><div className="t">Theme</div><div className="d">Dark matches the phone app.</div></div>
              <div className="tabs">
                {(["dark", "light", "system"] as const).map((t) => <button key={t} className={"tab" + (prefs.theme === t ? " on" : "")} onClick={() => setPref({ theme: t })}>{t[0].toUpperCase() + t.slice(1)}</button>)}
              </div>
            </div>
          </div>
        </div>

        <div className="section">
          <h2>Advanced</h2>
          <div className="list">
            <Toggle t="Desktop-compatible backend" d="Only for servers with dashboard.public_url set (a web login in front of Hermes)." v={prefs.desktopBackend} on={(v) => setPref({ desktopBackend: v })} />
            <div className="setting">
              <div className="txt"><div className="t">Restart backend</div><div className="d">After updating Hermes on the server. Your phone reconnects to the new one by itself.</div></div>
              <button className="btn small" onClick={() => bb.invoke("restartBackend").then(() => say("Backend restarted"), (e) => say(e.message))}>Restart</button>
            </div>
            <div className="setting">
              <div className="txt"><div className="t">Reset trusted server key</div><div className="d">Only if you rebuilt the server. The next connection trusts the key it sees.</div></div>
              <button className="btn small ghost" onClick={() => bb.invoke("forgetHostKey").then(() => say("Trusted server key cleared"))}>Reset</button>
            </div>
          </div>
          <span className="muted" style={{ fontSize: 12 }}>Brainbox {state.version} · {state.encrypted ? "secrets encrypted by the OS keystore" : "secrets in a private file (no keyring found)"}</span>
        </div>
      </div>
    </div>
  );
}

function Row({ t, d }: { t: string; d: string }) {
  return <div className="setting"><div className="txt"><div className="t">{t}</div><div className="d" style={{ userSelect: "text", wordBreak: "break-all" }}>{d}</div></div></div>;
}

function Toggle({ t, d, v, on }: { t: string; d: string; v: boolean; on: (v: boolean) => void }) {
  return <div className="setting"><div className="txt"><div className="t">{t}</div><div className="d">{d}</div></div><Switch checked={v} onChange={on} /></div>;
}
