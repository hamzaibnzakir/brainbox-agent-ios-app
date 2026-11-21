// Management pages, all straight from Hermes' own REST API on the server (through the SSH tunnel):
// scheduled jobs, skills, memory, files and server health. Same endpoints as the iPhone app's Hub.
import { ReactNode, useCallback, useEffect, useMemo, useState } from "react";
import { bb } from "../api";
import { Icon, IconName } from "../ui/icons";
import { bytes, DialogSpec, duration, EmptyState, relTime, Switch } from "../ui/kit";

type Json = any; // REST payloads are rendered defensively, field by field
const rest = <T = Json>(method: string, path: string, body?: Json) => bb.invoke<T>("rest", method, path, body);
const q = (params: Record<string, string>) => "?" + new URLSearchParams(params).toString();

interface PageProps { connected: boolean; say: (t: string) => void; ask: (d: DialogSpec) => void; home: string; onChat?: (text: string) => void }

function useRemote<T>(load: () => Promise<T>, deps: unknown[], connected: boolean) {
  const [data, setData] = useState<T>();
  const [error, setError] = useState<string>();
  const [loading, setLoading] = useState(false);
  const reload = useCallback(async () => {
    if (!connected) return;
    setLoading(true);
    try { setData(await load()); setError(undefined); } catch (e) { setError((e as Error).message); } finally { setLoading(false); }
  }, [connected, ...deps]);
  useEffect(() => { reload(); }, [reload]);
  return { data, error, loading, reload, setData };
}

function Page({ title, sub, actions, children }: { title: string; sub: string; actions?: ReactNode; children: ReactNode }) {
  return (
    <div className="page">
      <div className="page-inner">
        <div className="page-head"><div className="h"><h1>{title}</h1><p>{sub}</p></div>{actions}</div>
        {children}
      </div>
    </div>
  );
}

function Problem({ error, retry }: { error?: string; retry: () => void }) {
  if (!error) return null;
  return <div className="error-line"><Icon name="alert" size={16} /><span style={{ flex: 1 }}>{error}</span><button className="btn small" onClick={retry}>Retry</button></div>;
}

const Offline = () => <EmptyState icon="server" title="Not connected">Connect to your server to see this.</EmptyState>;

// ---------------------------------------------------------------- scheduled jobs

interface CronJob { id: string; name?: string; prompt?: string; schedule?: string | { display?: string; expr?: string }; schedule_display?: string; state?: string; enabled?: boolean; next_run_at?: string; last_run_at?: string; last_status?: string; deliver?: string }
const jobSchedule = (j: CronJob) => j.schedule_display ?? (typeof j.schedule === "string" ? j.schedule : j.schedule?.display ?? j.schedule?.expr ?? "");
const jobPaused = (j: CronJob) => j.state === "paused" || j.enabled === false;
const parseDate = (s?: string) => (s ? Date.parse(s) || 0 : 0);

const PRESETS: [string, string][] = [["Every hour", "0 * * * *"], ["Every morning 8:00", "0 8 * * *"], ["Weekdays 9:00", "0 9 * * 1-5"], ["Every Monday", "0 9 * * 1"], ["Every 30 min", "*/30 * * * *"]];

export function AgentsPage(p: PageProps) {
  const jobs = useRemote(() => rest<CronJob[] | { jobs: CronJob[] }>("GET", "/api/cron/jobs"), [], p.connected);
  const [editing, setEditing] = useState<CronJob | "new">();
  const list: CronJob[] = Array.isArray(jobs.data) ? jobs.data : jobs.data?.jobs ?? [];

  const act = async (j: CronJob, action: "pause" | "resume" | "trigger") => {
    try { await rest("POST", `/api/cron/jobs/${encodeURIComponent(j.id)}/${action}`); p.say(action === "trigger" ? "Running now" : action === "pause" ? "Paused" : "Resumed"); jobs.reload(); }
    catch (e) { p.say((e as Error).message); }
  };
  const remove = (j: CronJob) => p.ask({
    kind: "confirm", title: `Delete “${j.name || "this job"}”?`, body: "It stops running. Its past results stay in your chats.", confirm: "Delete", danger: true,
    resolve: async (ok) => { if (!ok) return; try { await rest("DELETE", `/api/cron/jobs/${encodeURIComponent(j.id)}`); jobs.reload(); } catch (e) { p.say((e as Error).message); } },
  });

  if (!p.connected) return <Page title="Scheduled jobs" sub="Things Hermes does on its own, on a schedule."><Offline /></Page>;
  return (
    <Page title="Scheduled jobs" sub="Things Hermes does on its own, on a schedule — a morning brief, a server check, a weekly report."
          actions={<><button className="btn ghost" onClick={jobs.reload}><Icon name="refresh" size={14} />Refresh</button><button className="btn primary" onClick={() => setEditing("new")}><Icon name="plus" size={14} />New job</button></>}>
      <Problem error={jobs.error} retry={jobs.reload} />
      {list.length === 0 && !jobs.loading && !jobs.error ? (
        <div className="list"><EmptyState icon="clock" title="No scheduled jobs" action={<button className="btn primary" onClick={() => setEditing("new")}>Create one</button>}>
          Tell Hermes what to do and when. It runs on your server, even when this PC and your phone are off.
        </EmptyState></div>
      ) : (
        <div className="list">
          {list.map((j) => (
            <div key={j.id} className="list-row">
              <div className={"ico" + (jobPaused(j) ? "" : " volt")}><Icon name="clock" size={16} /></div>
              <div className="main-col">
                <div className="t">{j.name || j.prompt?.slice(0, 60) || j.id}</div>
                <div className="d"><code style={{ fontSize: 11.5 }}>{jobSchedule(j)}</code>{parseDate(j.next_run_at) ? ` · next ${new Date(parseDate(j.next_run_at)).toLocaleString([], { weekday: "short", hour: "numeric", minute: "2-digit" })}` : ""}{parseDate(j.last_run_at) ? ` · last ${relTime(parseDate(j.last_run_at))}` : ""}</div>
              </div>
              <span className={"pill " + (jobPaused(j) ? "muted" : "good")}>{jobPaused(j) ? "Paused" : "Scheduled"}</span>
              <div className="acts">
                <button className="icon-btn" title="Run now" onClick={() => act(j, "trigger")}><Icon name="zap" size={15} /></button>
                <button className="icon-btn" title={jobPaused(j) ? "Resume" : "Pause"} onClick={() => act(j, jobPaused(j) ? "resume" : "pause")}><Icon name={jobPaused(j) ? "play" : "pause"} size={15} /></button>
                <button className="icon-btn" title="Edit" onClick={() => setEditing(j)}><Icon name="pencil" size={15} /></button>
                <button className="icon-btn" title="Delete" onClick={() => remove(j)}><Icon name="trash" size={15} /></button>
              </div>
            </div>
          ))}
        </div>
      )}
      {editing && <JobEditor job={editing === "new" ? undefined : editing} say={p.say} onClose={(changed) => { setEditing(undefined); if (changed) jobs.reload(); }} />}
    </Page>
  );
}

function JobEditor({ job, say, onClose }: { job?: CronJob; say: (t: string) => void; onClose: (changed: boolean) => void }) {
  const [name, setName] = useState(job?.name ?? "");
  const [prompt, setPrompt] = useState(job?.prompt ?? "");
  const [schedule, setSchedule] = useState(job ? jobSchedule(job) : "0 8 * * *");
  const [deliver, setDeliver] = useState(job?.deliver ?? "local");
  const [targets, setTargets] = useState<{ id: string; name: string }[]>([]);
  const [saving, setSaving] = useState(false);
  useEffect(() => { rest<{ targets?: { id: string; name: string }[] }>("GET", "/api/cron/delivery-targets").then((r) => setTargets(r?.targets ?? [])).catch(() => {}); }, []);
  const save = async () => {
    setSaving(true);
    try {
      if (job) await rest("PUT", `/api/cron/jobs/${encodeURIComponent(job.id)}`, { updates: { name, prompt, schedule, deliver } });
      else await rest("POST", "/api/cron/jobs", { name: name || prompt.slice(0, 40), prompt, schedule, deliver });
      say(job ? "Saved" : "Job created");
      onClose(true);
    } catch (e) { say((e as Error).message); } finally { setSaving(false); }
  };
  return (
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(false); }}>
      <div className="dialog wide">
        <h3>{job ? "Edit job" : "New scheduled job"}</h3>
        <div className="field"><label>Name</label><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="Morning brief" /></div>
        <div className="field"><label>What should Hermes do?</label><textarea className="input" rows={4} value={prompt} onChange={(e) => setPrompt(e.target.value)} placeholder="Summarise overnight emails and server alerts, then send me the three things that matter." autoFocus /></div>
        <div className="field"><label>When (cron, or “every 2h”)</label><input className="input" style={{ fontFamily: "var(--mono)" }} value={schedule} onChange={(e) => setSchedule(e.target.value)} /></div>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>{PRESETS.map(([l, v]) => <button key={v} className={"chip" + (schedule === v ? " on" : "")} style={schedule === v ? { borderColor: "var(--volt)", color: "var(--volt)" } : undefined} onClick={() => setSchedule(v)}>{l}</button>)}</div>
        {targets.length > 0 && (
          <div className="field"><label>Send results to</label>
            <select className="input" value={deliver} onChange={(e) => setDeliver(e.target.value)}>{targets.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</select>
          </div>
        )}
        <div className="actions">
          <button className="btn ghost" onClick={() => onClose(false)}>Cancel</button>
          <button className="btn primary" disabled={saving || !prompt.trim() || !schedule.trim()} onClick={save}>{job ? "Save" : "Create job"}</button>
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- skills

interface Skill { name: string; description?: string; category?: string; enabled?: boolean; usage?: number; provenance?: string }

export function SkillsPage(p: PageProps) {
  const skills = useRemote(() => rest<Skill[]>("GET", "/api/skills"), [], p.connected);
  const [filter, setFilter] = useState("");
  const [cat, setCat] = useState("all");
  const [open, setOpen] = useState<Skill>();
  const list = skills.data ?? [];
  const cats = useMemo(() => ["all", ...Array.from(new Set(list.map((s) => s.category || "other"))).sort()], [list]);
  const shown = list.filter((s) => (cat === "all" || (s.category || "other") === cat) && `${s.name} ${s.description}`.toLowerCase().includes(filter.toLowerCase()));

  const toggle = async (s: Skill, on: boolean) => {
    skills.setData(list.map((x) => (x.name === s.name ? { ...x, enabled: on } : x)));
    try { await rest("PUT", "/api/skills/toggle", { name: s.name, enabled: on }); }
    catch (e) { p.say((e as Error).message); skills.reload(); }
  };

  if (!p.connected) return <Page title="Skills" sub="What Hermes knows how to do."><Offline /></Page>;
  return (
    <Page title="Skills" sub={`${list.filter((s) => s.enabled !== false).length} of ${list.length} skills on. Hermes picks the right one for each task; turn off what you never want it to use.`}
          actions={<label className="search" style={{ width: 260 }}><Icon name="search" size={14} /><input value={filter} onChange={(e) => setFilter(e.target.value)} placeholder="Search skills" /></label>}>
      <Problem error={skills.error} retry={skills.reload} />
      <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
        {cats.map((c) => <button key={c} className="chip" style={c === cat ? { borderColor: "var(--volt)", color: "var(--volt)", background: "var(--volt-soft)" } : undefined} onClick={() => setCat(c)}><span>{c === "all" ? "All" : c.replace(/-/g, " ")}</span></button>)}
      </div>
      <div className="grid cards">
        {shown.map((s) => (
          <div key={s.name} className="skill-card">
            <div className="top">
              <Icon name="sparkles" size={15} style={{ color: s.enabled === false ? "var(--ink4)" : "var(--volt)" }} />
              <div className="n" title={s.name}>{s.name}</div>
              <Switch checked={s.enabled !== false} onChange={(v) => toggle(s, v)} />
            </div>
            <div className="desc">{s.description || "No description."}</div>
            <div className="foot">
              <span className="source-tag">{(s.category || "other").replace(/-/g, " ")}</span>
              {s.provenance && s.provenance !== "bundled" && <span className="source-tag">{s.provenance}</span>}
              <span style={{ flex: 1 }} />
              <button className="btn small ghost" onClick={() => setOpen(s)}>View</button>
            </div>
          </div>
        ))}
      </div>
      {open && <SkillViewer skill={open} onClose={() => setOpen(undefined)} onUse={p.onChat} />}
    </Page>
  );
}

function SkillViewer({ skill, onClose, onUse }: { skill: Skill; onClose: () => void; onUse?: (t: string) => void }) {
  const [text, setText] = useState<string>();
  useEffect(() => { rest<{ content?: string }>("GET", "/api/skills/content" + q({ name: skill.name })).then((r) => setText(r?.content ?? ""), (e) => setText(`Couldn't load: ${(e as Error).message}`)); }, [skill.name]);
  return (
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="dialog wide" style={{ maxHeight: "76vh" }}>
        <h3 style={{ fontFamily: "var(--mono)" }}>{skill.name}</h3>
        <p>{skill.description}</p>
        <pre className="codebox" style={{ flex: 1, minHeight: 120, maxHeight: "46vh", overflow: "auto", margin: 0, whiteSpace: "pre-wrap" }}>{text ?? "Loading…"}</pre>
        <div className="actions">
          {onUse && <button className="btn" onClick={() => { onClose(); onUse(`Use the ${skill.name} skill to `); }}>Use in a chat</button>}
          <button className="btn primary" onClick={onClose}>Done</button>
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- memory

export function MemoryPage(p: PageProps) {
  const status = useRemote(() => rest("GET", "/api/memory"), [], p.connected);
  const [tab, setTab] = useState<"memory" | "user">("memory");
  const path = `${p.home}/.hermes/memories/${tab === "memory" ? "MEMORY.md" : "USER.md"}`;
  const file = useRemote(() => rest<{ content?: string }>("GET", "/api/fs/read-text" + q({ path })).catch(() => ({ content: "" })), [path], p.connected);
  const [draft, setDraft] = useState<string>();
  useEffect(() => setDraft(undefined), [path]);
  const text = draft ?? file.data?.content ?? "";
  const dirty = draft !== undefined && draft !== (file.data?.content ?? "");

  const save = async () => {
    try { await rest("POST", "/api/fs/write-text", { path, content: text }); p.say("Saved"); setDraft(undefined); file.reload(); }
    catch (e) { p.say((e as Error).message); }
  };
  const reset = () => p.ask({
    kind: "confirm", title: tab === "memory" ? "Erase Hermes' notes?" : "Erase what Hermes knows about you?", danger: true, confirm: "Erase",
    body: "Hermes starts this file from scratch. This can't be undone.",
    resolve: async (ok) => { if (!ok) return; try { await rest("POST", "/api/memory/reset", { target: tab }); p.say("Erased"); file.reload(); status.reload(); } catch (e) { p.say((e as Error).message); } },
  });

  if (!p.connected) return <Page title="Memory" sub="What Hermes remembers."><Offline /></Page>;
  const providers: Json[] = status.data?.providers ?? [];
  const active = status.data?.active || "built-in";
  return (
    <Page title="Memory" sub="What Hermes remembers between chats. Edit it like a document — Hermes reads it at the start of every conversation."
          actions={<div className="tabs"><button className={"tab" + (tab === "memory" ? " on" : "")} onClick={() => setTab("memory")}>Hermes' notes</button><button className={"tab" + (tab === "user" ? " on" : "")} onClick={() => setTab("user")}>About you</button></div>}>
      <Problem error={status.error} retry={status.reload} />
      <div className="card" style={{ padding: 0, display: "flex", flexDirection: "column", height: "min(56vh, 560px)", overflow: "hidden" }}>
        <div className="editor-head">
          <Icon name={tab === "memory" ? "brain" : "info"} size={15} style={{ color: "var(--volt)" }} />
          <div className="p">{path.replace(p.home, "~")}</div>
          {dirty && <span className="pill warn">Unsaved</span>}
          <button className="btn small ghost" onClick={reset}><Icon name="trash" size={13} />Erase</button>
          <button className="btn small primary" disabled={!dirty} onClick={save}><Icon name="save" size={13} />Save</button>
        </div>
        <textarea className="editor" value={text} spellCheck={false} placeholder={file.loading ? "Loading…" : "Empty — Hermes adds to this as it learns."}
                  onChange={(e) => setDraft(e.target.value)}
                  onKeyDown={(e) => { if ((e.ctrlKey || e.metaKey) && e.key === "s") { e.preventDefault(); if (dirty) save(); } }} />
      </div>
      <div className="list-head"><h2>Memory provider</h2><span className="pill volt">{active}</span></div>
      <div className="list">
        {providers.length === 0 && <div className="list-row"><div className="main-col"><div className="d">Only the built-in memory files are available.</div></div></div>}
        {providers.map((pr) => (
          <div key={pr.name} className="list-row">
            <div className={"ico" + (pr.name === status.data?.active ? " volt" : "")}><Icon name="layers" size={15} /></div>
            <div className="main-col"><div className="t">{pr.name}</div><div className="d">{pr.description}</div></div>
            <span className={"pill " + (pr.available ? "good" : pr.status === "needs_config" ? "warn" : "muted")}>{pr.available ? "Available" : String(pr.status ?? "unavailable").replace(/_/g, " ")}</span>
          </div>
        ))}
      </div>
    </Page>
  );
}

// ---------------------------------------------------------------- files

interface Entry { name: string; path: string; isDirectory: boolean; size?: number }

export function FilesPage(p: PageProps) {
  const [cwd, setCwd] = useState<string>();
  const [selected, setSelected] = useState<string>();
  const [content, setContent] = useState<string>();
  const [draft, setDraft] = useState<string>();
  const [hidden, setHidden] = useState(false);
  useEffect(() => { if (p.connected && !cwd) rest<{ cwd?: string }>("GET", "/api/fs/default-cwd").then((r) => setCwd(r?.cwd || p.home), () => setCwd(p.home)); }, [p.connected]);
  const listing = useRemote(async () => (cwd ? rest<{ entries?: Entry[] }>("GET", "/api/fs/list" + q({ path: cwd })) : undefined), [cwd], p.connected);
  const entries = (listing.data?.entries ?? []).filter((e) => hidden || !e.name.startsWith(".")).sort((a, b) => (a.isDirectory === b.isDirectory ? a.name.localeCompare(b.name) : a.isDirectory ? -1 : 1));

  const openFile = async (e: Entry) => {
    if (e.isDirectory) { setCwd(e.path); return; }
    setSelected(e.path); setDraft(undefined); setContent(undefined);
    try { const r = await rest<{ content?: string }>("GET", "/api/fs/read-text" + q({ path: e.path })); setContent(r?.content ?? ""); }
    catch (err) { setContent(`⚠ ${(err as Error).message}`); }
  };
  const save = async () => {
    if (!selected || draft === undefined) return;
    try { await rest("POST", "/api/fs/write-text", { path: selected, content: draft }); setContent(draft); setDraft(undefined); p.say("Saved"); }
    catch (e) { p.say((e as Error).message); }
  };
  const crumbs = (cwd ?? "").split("/").filter(Boolean);
  const dirty = draft !== undefined && draft !== content;

  if (!p.connected) return <Page title="Files" sub="Your server's files."><Offline /></Page>;
  return (
    <div className="split-page">
      <div className="left">
        <div className="path-bar">
          <button onClick={() => setCwd("/")} title="/"><Icon name="server" size={13} /></button>
          {crumbs.map((c, i) => (
            <span key={i} style={{ display: "contents" }}><span className="sep">/</span><button onClick={() => setCwd("/" + crumbs.slice(0, i + 1).join("/"))}>{c}</button></span>
          ))}
          <span style={{ flex: 1 }} />
          <button title={hidden ? "Hide dotfiles" : "Show dotfiles"} onClick={() => setHidden(!hidden)} style={hidden ? { color: "var(--volt)" } : undefined}>.*</button>
          <button title="Home" onClick={() => setCwd(p.home)}><Icon name="home" size={13} /></button>
        </div>
        <div className="scroll">
          {cwd && cwd !== "/" && <button className="file-row dir" onClick={() => setCwd(cwd.replace(/\/[^/]+\/?$/, "") || "/")}><Icon name="chevronLeft" size={15} /><span>..</span></button>}
          {listing.error && <div style={{ padding: 12 }}><Problem error={listing.error} retry={listing.reload} /></div>}
          {entries.map((e) => (
            <button key={e.path} className={"file-row" + (e.isDirectory ? " dir" : "") + (selected === e.path ? " sel" : "")} onClick={() => openFile(e)} title={e.path}>
              <Icon name={e.isDirectory ? "folder" : "file"} size={15} /><span>{e.name}</span>
            </button>
          ))}
          {!listing.loading && !listing.error && entries.length === 0 && (
            (listing.data?.entries?.length ?? 0) > 0
              ? <div className="sidebar-empty">{listing.data!.entries!.length} hidden items · <button className="btn small ghost" onClick={() => setHidden(true)}>Show them</button></div>
              : <div className="sidebar-empty">Empty folder</div>
          )}
        </div>
      </div>
      <div className="right">
        {selected ? (
          <>
            <div className="editor-head">
              <Icon name="file" size={15} style={{ color: "var(--ink3)" }} />
              <div className="p" title={selected}>{selected}</div>
              {dirty && <span className="pill warn">Unsaved</span>}
              <button className="btn small ghost" onClick={() => bb.invoke("copy", selected).then(() => p.say("Path copied"))}><Icon name="copy" size={13} />Path</button>
              {p.onChat && <button className="btn small ghost" onClick={() => p.onChat!(`Look at ${selected} and `)}><Icon name="chat" size={13} />Ask Hermes</button>}
              <button className="btn small primary" disabled={!dirty} onClick={save}><Icon name="save" size={13} />Save</button>
            </div>
            <textarea className="editor" value={draft ?? content ?? "Loading…"} spellCheck={false} onChange={(e) => setDraft(e.target.value)}
                      onKeyDown={(e) => { if ((e.ctrlKey || e.metaKey) && e.key === "s") { e.preventDefault(); save(); } }} />
          </>
        ) : (
          <div style={{ flex: 1, display: "grid", placeItems: "center" }}>
            <EmptyState icon="folder" title="Pick a file">Browse your server on the left. Text files open here and can be edited and saved.</EmptyState>
          </div>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- server

export function ServerPage(p: PageProps & { version?: string; target?: string }) {
  const stats = useRemote(() => rest("GET", "/api/system/stats"), [], p.connected);
  const status = useRemote(() => rest("GET", "/api/status"), [], p.connected);
  const model = useRemote(() => rest("GET", "/api/model/info"), [], p.connected);
  useEffect(() => {
    if (!p.connected) return;
    const t = setInterval(() => stats.reload(), 5000);
    return () => clearInterval(t);
  }, [p.connected, stats.reload]);
  const s = stats.data ?? {};
  const st = status.data ?? {};
  const mem = s.memory ?? {};
  const disk = s.disk ?? {};
  const level = (pct?: number) => (pct ?? 0) > 90 ? "bad" : (pct ?? 0) > 75 ? "warn" : "";
  const comps: [string, Json][] = Object.entries(st.components ?? {});

  if (!p.connected) return <Page title="Server" sub="Your VPS and Hermes."><Offline /></Page>;
  return (
    <Page title="Server" sub={`${p.target ?? ""} · ${s.os ?? ""} ${s.arch ?? ""} · up ${duration(s.uptime_seconds)}`}
          actions={<button className="btn ghost" onClick={() => { stats.reload(); status.reload(); }}><Icon name="refresh" size={14} />Refresh</button>}>
      <Problem error={stats.error ?? status.error} retry={() => { stats.reload(); status.reload(); }} />
      <div className="grid stats">
        <Stat icon="cpu" label="CPU" value={`${Math.round(s.cpu_percent ?? 0)}%`} sub={`${s.cpu_count ?? "?"} cores · load ${(s.load_avg ?? []).map((x: number) => x.toFixed(2)).join(" ")}`} pct={s.cpu_percent} level={level(s.cpu_percent)} />
        <Stat icon="layers" label="Memory" value={`${Math.round(mem.percent ?? 0)}%`} sub={`${bytes(mem.used)} of ${bytes(mem.total)}`} pct={mem.percent} level={level(mem.percent)} />
        <Stat icon="server" label="Disk" value={`${Math.round(disk.percent ?? 0)}%`} sub={`${bytes(disk.free)} free of ${bytes(disk.total)}`} pct={disk.percent} level={level(disk.percent)} />
        <Stat icon="bot" label="Hermes" value={p.version ?? st.version ?? "?"} sub={`${st.active_sessions ?? 0} active chat${st.active_sessions === 1 ? "" : "s"} · ${bytes(s.process?.rss)} RAM`} />
      </div>
      <div className="list-head"><h2>Model</h2></div>
      <div className="list">
        <div className="list-row">
          <div className="ico volt"><Icon name="cpu" size={15} /></div>
          <div className="main-col"><div className="t">{model.data?.model ?? "—"}</div><div className="d">{model.data?.provider ?? ""}{model.data?.effective_context_length ? ` · ${Math.round(model.data.effective_context_length / 1000)}k context` : ""}</div></div>
        </div>
      </div>
      <div className="list-head"><h2>Components</h2><span className={"pill " + (st.overall === "ok" ? "good" : st.overall === "degraded" ? "warn" : "muted")}>{st.overall ?? "—"}</span></div>
      <div className="list">
        {comps.map(([name, c]) => (
          <div key={name} className="list-row">
            <span className={"dot " + (c?.status === "ok" ? "good" : c?.status === "degraded" ? "warn" : c?.status ? "bad" : "muted")} />
            <div className="main-col"><div className="t" style={{ textTransform: "capitalize" }}>{name}</div><div className="d">{[c?.state, c?.selftest && `self-test ${c.selftest}`, c?.configured !== undefined && `${c.connected ?? 0}/${c.configured} connected`].filter(Boolean).join(" · ") || c?.status}</div></div>
            <span className="muted" style={{ fontSize: 12 }}>{c?.status}</span>
          </div>
        ))}
        {st.gateway_running === false && (
          <div className="list-row"><Icon name="info" size={15} style={{ color: "var(--ink3)" }} /><div className="main-col"><div className="d">The messaging gateway (Telegram etc.) isn't running under this backend. Brainbox never starts or stops it.</div></div></div>
        )}
      </div>
    </Page>
  );
}

function Stat({ icon, label, value, sub, pct, level }: { icon: IconName; label: string; value: string; sub: string; pct?: number; level?: string }) {
  return (
    <div className="stat">
      <div className="l"><Icon name={icon} size={14} />{label}</div>
      <div className="v" title={value}>{value}</div>
      {pct !== undefined && <div className="bar-line"><i className={level} style={{ width: `${Math.min(100, Math.max(2, pct))}%` }} /></div>}
      <div className="s" title={sub}>{sub}</div>
    </div>
  );
}
