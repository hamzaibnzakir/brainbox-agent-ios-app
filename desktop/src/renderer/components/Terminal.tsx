// A real login shell on the server over the same SSH connection (xterm.js on a PTY channel).
import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import { useEffect, useRef, useState } from "react";
import { bb } from "../api";

export function TerminalPane({ connected, active }: { connected: boolean; active: boolean }) {
  const host = useRef<HTMLDivElement>(null);
  const term = useRef<Terminal | undefined>(undefined);
  const fit = useRef<FitAddon | undefined>(undefined);
  const shell = useRef<number | undefined>(undefined);
  const [closed, setClosed] = useState<string>();

  const open = async () => {
    const t = term.current!;
    setClosed(undefined);
    try {
      fit.current?.fit();
      shell.current = await bb.invoke<number>("term.open", t.cols, t.rows);
      t.focus();
    } catch (e) {
      setClosed((e as Error).message);
    }
  };

  useEffect(() => {
    const t = new Terminal({
      fontFamily: '"Cascadia Code", "Cascadia Mono", Consolas, monospace', fontSize: 13, cursorBlink: true,
      theme: { background: "#0b0c0f", foreground: "#e8e8ec", cursor: "#8c82ff", selectionBackground: "#8c82ff55" },
      allowProposedApi: false, scrollback: 5000,
    });
    const f = new FitAddon();
    t.loadAddon(f);
    t.open(host.current!);
    term.current = t;
    fit.current = f;
    t.onData((d) => { if (shell.current !== undefined) bb.termInput(shell.current, d); });
    t.onResize(({ cols, rows }) => { if (shell.current !== undefined) bb.invoke("term.resize", shell.current, cols, rows).catch(() => {}); });
    const offs = [
      bb.on("bb:term-data", (id: number, data: string) => { if (id === shell.current) t.write(data); }),
      bb.on("bb:term-exit", (id: number) => { if (id === shell.current) { shell.current = undefined; setClosed("The shell closed."); } }),
    ];
    const ro = new ResizeObserver(() => { try { f.fit(); } catch { /* hidden */ } });
    ro.observe(host.current!);
    return () => {
      offs.forEach((off) => off());
      ro.disconnect();
      if (shell.current !== undefined) bb.invoke("term.close", shell.current).catch(() => {});
      t.dispose();
    };
  }, []);

  useEffect(() => {
    if (connected && shell.current === undefined && term.current) open();
  }, [connected]);
  useEffect(() => { if (active) { try { fit.current?.fit(); } catch { /* */ } term.current?.focus(); } }, [active]);

  return (
    <div className="term-wrap">
      {closed && (
        <div className="banner">
          <span style={{ flex: 1 }}>{closed}</span>
          {connected && <button className="btn small" onClick={open}>New shell</button>}
        </div>
      )}
      <div className="terminal"><div ref={host} style={{ height: "100%" }} /></div>
    </div>
  );
}
