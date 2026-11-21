// Ctrl+K: jump to any chat, page or action by typing.
import { useEffect, useMemo, useRef, useState } from "react";
import { Icon, IconName } from "../ui/icons";

export interface PaletteAction { id: string; icon: IconName; label: string; hint?: string; group: string; run: () => void }

export function Palette({ actions, onClose }: { actions: PaletteAction[]; onClose: () => void }) {
  const [q, setQ] = useState("");
  const [sel, setSel] = useState(0);
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => { input.current?.focus(); }, []);

  const results = useMemo(() => {
    const words = q.toLowerCase().split(/\s+/).filter(Boolean);
    const scored = actions
      .map((a) => {
        const hay = `${a.label} ${a.group}`.toLowerCase();
        if (!words.every((w) => hay.includes(w))) return undefined;
        const label = a.label.toLowerCase();
        const at = (w: string) => (label.startsWith(w) ? 0 : label.split(/[^a-z0-9]+/).some((x) => x.startsWith(w)) ? 1 : 2);
        const groupRank = a.group === "Pages" ? 0 : a.group === "Actions" ? 1 : 2;
        const score = words.length ? Math.max(...words.map(at)) * 10 + groupRank : 0;
        return { a, score };
      })
      .filter((x): x is { a: PaletteAction; score: number } => !!x);
    scored.sort((x, y) => x.score - y.score); // stable: keeps list order within a rank
    return scored.map((x) => x.a).slice(0, 60);
  }, [q, actions]);
  useEffect(() => setSel(0), [q]);

  const run = (a?: PaletteAction) => { if (!a) return; onClose(); a.run(); };

  let lastGroup = "";
  return (
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="palette" role="dialog">
        <div className="pin">
          <Icon name="search" size={17} />
          <input ref={input} value={q} placeholder="Search chats, pages and actions…" onChange={(e) => setQ(e.target.value)}
                 onKeyDown={(e) => {
                   if (e.key === "ArrowDown") { e.preventDefault(); setSel((sel + 1) % Math.max(1, results.length)); }
                   else if (e.key === "ArrowUp") { e.preventDefault(); setSel((sel - 1 + results.length) % Math.max(1, results.length)); }
                   else if (e.key === "Enter") { e.preventDefault(); run(results[sel]); }
                   else if (e.key === "Escape") { e.preventDefault(); onClose(); }
                 }} />
          <kbd>Esc</kbd>
        </div>
        <div className="results">
          {results.length === 0 && <div className="pop-label" style={{ padding: 16, textTransform: "none" }}>No matches</div>}
          {results.map((a, i) => {
            const head = a.group !== lastGroup ? a.group : undefined;
            lastGroup = a.group;
            return (
              <div key={a.id}>
                {head && <div className="pop-label">{head}</div>}
                <button className={"pop-item" + (i === sel ? " sel" : "")} onMouseMove={() => setSel(i)} onClick={() => run(a)}
                        ref={(el) => { if (i === sel) el?.scrollIntoView({ block: "nearest" }); }}>
                  <Icon name={a.icon} size={15} /><span style={{ flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{a.label}</span>
                  {a.hint && <kbd>{a.hint}</kbd>}
                </button>
              </div>
            );
          })}
        </div>
        <div className="foot"><span><kbd>↑</kbd><kbd>↓</kbd> move</span><span><kbd>Enter</kbd> open</span><span><kbd>Esc</kbd> close</span></div>
      </div>
    </div>
  );
}
