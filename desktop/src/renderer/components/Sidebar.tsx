// Every Hermes chat, newest first, grouped by day; Telegram / cron / other-platform chats are listed
// separately and open read-only. Search filters titles and previews as you type.
import { useMemo, useState } from "react";
import { isReadOnly, SessionSummary } from "../api";
import { Icon } from "../ui/icons";
import { Menu, MenuItem, relTime } from "../ui/kit";

interface Props {
  sessions: SessionSummary[];
  active?: string;
  busy: Set<string>;
  connected: boolean;
  onOpen: (s: SessionSummary) => void;
  onNew: () => void;
  onRename: (s: SessionSummary) => void;
  onDelete: (s: SessionSummary) => void;
  searchRef: React.RefObject<HTMLInputElement | null>;
}

const DAY = 86_400_000;

export function Sidebar(p: Props) {
  const [q, setQ] = useState("");
  const [menu, setMenu] = useState<{ s: SessionSummary; x: number; y: number }>();
  const [showOther, setShowOther] = useState(false);

  const { groups, other } = useMemo(() => {
    const needle = q.trim().toLowerCase();
    const hit = (s: SessionSummary) => !needle || `${s.title} ${s.preview}`.toLowerCase().includes(needle);
    const mine = p.sessions.filter((s) => !isReadOnly(s.source) && hit(s));
    const other = p.sessions.filter((s) => isReadOnly(s.source) && hit(s));
    const start = new Date(); start.setHours(0, 0, 0, 0);
    const t0 = start.getTime();
    const buckets: [string, SessionSummary[]][] = [["Today", []], ["Yesterday", []], ["Previous 7 days", []], ["Previous 30 days", []], ["Older", []]];
    for (const s of mine) {
      const ms = s.startedAt * 1000;
      const i = ms >= t0 ? 0 : ms >= t0 - DAY ? 1 : ms >= t0 - 7 * DAY ? 2 : ms >= t0 - 30 * DAY ? 3 : 4;
      buckets[i][1].push(s);
    }
    return { groups: buckets.filter(([, l]) => l.length), other };
  }, [p.sessions, q]);

  const row = (s: SessionSummary) => {
    const title = s.title.trim() || s.preview.trim() || "Untitled chat";
    return (
      <button key={s.id} className={"session" + (s.id === p.active ? " active" : "")} onClick={() => p.onOpen(s)}
              onContextMenu={(e) => { e.preventDefault(); setMenu({ s, x: e.clientX, y: e.clientY }); }} title={title}>
        <div className="txt">
          <div className="t">{title}</div>
          <div className="p">{isReadOnly(s.source) && <span className="source-tag">{s.source}</span>} {s.preview && s.preview !== title ? s.preview : `${s.messageCount} messages`}</div>
        </div>
        {p.busy.has(s.id) ? <span className="live-dot" title="Hermes is working on this" /> : <span className="when">{relTime(s.startedAt * 1000)}</span>}
        <span className="icon-btn menu-btn" role="button" title="More"
              onClick={(e) => { e.stopPropagation(); const r = e.currentTarget.getBoundingClientRect(); setMenu({ s, x: r.left, y: r.bottom + 4 }); }}>
          <Icon name="more" size={15} />
        </span>
      </button>
    );
  };

  return (
    <aside className="sidebar">
      <div className="sidebar-head">
        <div className="row">
          <h3>Chats</h3>
          <button className="btn small primary" disabled={!p.connected} onClick={p.onNew} title="New chat (Ctrl+N)"><Icon name="plus" size={14} stroke={2.4} />New</button>
        </div>
        <label className="search">
          <Icon name="search" size={14} />
          <input ref={p.searchRef} value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search chats"
                 onKeyDown={(e) => { if (e.key === "Escape") { setQ(""); e.currentTarget.blur(); } }} />
          {q && <button className="icon-btn" style={{ width: 20, height: 20 }} onClick={() => setQ("")}><Icon name="x" size={12} /></button>}
        </label>
      </div>
      <div className="session-list">
        {groups.map(([label, list]) => (
          <div key={label}>
            <div className="group-label">{label}</div>
            {list.map(row)}
          </div>
        ))}
        {other.length > 0 && (
          <div>
            <button className="group-label" style={{ border: 0, background: "transparent", cursor: "pointer", width: "100%" }} onClick={() => setShowOther(!showOther)}>
              <Icon name={showOther || q ? "chevronDown" : "chevronRight"} size={12} />Other apps · {other.length}<Icon name="lock" size={11} />
            </button>
            {(showOther || q) && other.map(row)}
          </div>
        )}
        {p.connected && p.sessions.length === 0 && <div className="sidebar-empty">No chats yet. Start one — it shows up on your phone too.</div>}
        {p.connected && p.sessions.length > 0 && groups.length === 0 && other.length === 0 && <div className="sidebar-empty">Nothing matches “{q}”.</div>}
        {!p.connected && p.sessions.length === 0 && <div className="sidebar-empty">Your chats appear once Brainbox is connected.</div>}
      </div>
      {menu && (
        <Menu at={{ x: menu.x, y: menu.y }} onClose={() => setMenu(undefined)}>
          <MenuItem icon="chat" label="Open" onClick={() => p.onOpen(menu.s)} />
          <MenuItem icon="pencil" label="Rename" disabled={isReadOnly(menu.s.source)} onClick={() => p.onRename(menu.s)} />
          <div className="pop-sep" />
          <MenuItem icon="trash" label="Delete" danger disabled={isReadOnly(menu.s.source)} onClick={() => p.onDelete(menu.s)} />
        </Menu>
      )}
    </aside>
  );
}
