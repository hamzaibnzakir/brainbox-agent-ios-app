// Small shared pieces: context menus, dialogs, switches, time formatting.
import { ReactNode, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Icon, IconName } from "./icons";

export function relTime(ms: number): string {
  if (!ms) return "";
  const d = Date.now() - ms;
  if (d < 45_000) return "just now";
  if (d < 3_600_000) return `${Math.round(d / 60_000)}m ago`;
  const date = new Date(ms);
  const today = new Date();
  if (date.toDateString() === today.toDateString()) return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const yest = new Date(today); yest.setDate(today.getDate() - 1);
  if (date.toDateString() === yest.toDateString()) return "Yesterday";
  if (d < 6 * 86_400_000) return date.toLocaleDateString([], { weekday: "short" });
  return date.toLocaleDateString([], { month: "short", day: "numeric", year: date.getFullYear() === today.getFullYear() ? undefined : "numeric" });
}

export function bytes(n?: number): string {
  if (n === undefined || n === null || Number.isNaN(n)) return "—";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v >= 100 || i === 0 ? v.toFixed(0) : v.toFixed(1)} ${u[i]}`;
}

export function duration(seconds?: number): string {
  if (!seconds && seconds !== 0) return "—";
  const d = Math.floor(seconds / 86400), h = Math.floor((seconds % 86400) / 3600), m = Math.floor((seconds % 3600) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
}

/** A floating menu at a point; closes on outside click, Escape or scroll. */
export function Menu({ at, onClose, children }: { at: { x: number; y: number }; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState(at);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    setPos({ x: Math.max(8, Math.min(at.x, innerWidth - r.width - 8)), y: Math.max(8, Math.min(at.y, innerHeight - r.height - 8)) });
  }, [at.x, at.y]);
  useEffect(() => {
    const down = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) onClose(); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    const t = setTimeout(() => { addEventListener("mousedown", down); addEventListener("keydown", key); addEventListener("blur", onClose); }, 0);
    return () => { clearTimeout(t); removeEventListener("mousedown", down); removeEventListener("keydown", key); removeEventListener("blur", onClose); };
  }, [onClose]);
  return (
    <div ref={ref} className="popover menu" style={{ left: pos.x, top: pos.y }} onClick={onClose} role="menu">
      {children}
    </div>
  );
}

export function MenuItem({ icon, label, onClick, danger, disabled, hint }: { icon: IconName; label: string; onClick: () => void; danger?: boolean; disabled?: boolean; hint?: string }) {
  return (
    <button className={"pop-item" + (danger ? " danger" : "")} disabled={disabled} style={disabled ? { opacity: 0.4 } : undefined}
            onClick={(e) => { if (disabled) { e.stopPropagation(); return; } onClick(); }} role="menuitem">
      <Icon name={icon} size={14} /><span style={{ flex: 1 }}>{label}</span>{hint && <kbd>{hint}</kbd>}
    </button>
  );
}

export function Switch({ checked, onChange, disabled }: { checked: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <label className="switch" style={disabled ? { opacity: 0.5 } : undefined}>
      <input type="checkbox" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} />
      <span />
    </label>
  );
}

export type DialogSpec =
  | { kind: "confirm"; title: string; body?: string; confirm: string; danger?: boolean; resolve: (ok: boolean) => void }
  | { kind: "prompt"; title: string; body?: string; value: string; confirm: string; placeholder?: string; resolve: (v: string | undefined) => void };

export function Dialog({ spec, onDone }: { spec: DialogSpec; onDone: () => void }) {
  const [value, setValue] = useState(spec.kind === "prompt" ? spec.value : "");
  const finish = (ok: boolean) => {
    if (spec.kind === "confirm") spec.resolve(ok);
    else spec.resolve(ok ? value : undefined);
    onDone();
  };
  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") finish(false); };
    addEventListener("keydown", key);
    return () => removeEventListener("keydown", key);
  });
  return (
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) finish(false); }}>
      <div className="dialog" role="dialog">
        <h3>{spec.title}</h3>
        {spec.body && <p>{spec.body}</p>}
        {spec.kind === "prompt" && (
          <input className="input" autoFocus value={value} placeholder={spec.placeholder} onChange={(e) => setValue(e.target.value)}
                 onFocus={(e) => e.currentTarget.select()} onKeyDown={(e) => { if (e.key === "Enter") finish(true); }} />
        )}
        <div className="actions">
          <button className="btn ghost" onClick={() => finish(false)}>Cancel</button>
          <button className={"btn " + (spec.kind === "confirm" && spec.danger ? "danger" : "primary")} autoFocus={spec.kind === "confirm"} onClick={() => finish(true)}>{spec.confirm}</button>
        </div>
      </div>
    </div>
  );
}

export function EmptyState({ icon, title, children, action }: { icon: IconName; title: string; children?: ReactNode; action?: ReactNode }) {
  return (
    <div className="empty-state">
      <div className="glyph"><Icon name={icon} size={22} /></div>
      <strong>{title}</strong>
      {children && <p>{children}</p>}
      {action}
    </div>
  );
}
