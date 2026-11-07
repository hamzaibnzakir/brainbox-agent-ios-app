// The conversation: header, thread, plan, composer. The transcript itself is built in the main
// process (shared/transcript.ts) from Hermes' events; this file only renders it and sends input.
import DOMPurify from "dompurify";
import { marked, Renderer } from "marked";
import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { ChatItem, ClarifyQuestion, PendingRequest, TranscriptState } from "../../shared/transcript";
import { bb } from "../api";
import { Icon, IconName } from "../ui/icons";
import { Menu, MenuItem, relTime } from "../ui/kit";

// ---------------------------------------------------------------- markdown

const escapeHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

const KEYWORDS = new Set(("const let var function return if else for while do switch case break continue new class extends import from export default " +
  "async await try catch finally throw typeof instanceof in of def lambda pass yield with as elif not and or is None True False null undefined true false " +
  "self this super struct enum interface type public private protected static fn impl mut use pub package func go defer select chan echo then fi done esac local").split(" "));

/** A small, safe highlighter: tokenises raw text, escapes every token. */
function highlight(code: string, lang: string): string {
  if (code.length > 60_000) return escapeHtml(code);
  const hash = /^(py|python|sh|bash|shell|zsh|yaml|yml|toml|ruby|rb|r|dockerfile|make|conf|ini)$/i.test(lang);
  const re = hash
    ? /(#[^\n]*)|("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][\w]*)/g
    : /(\/\/[^\n]*|\/\*[\s\S]*?\*\/)|("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_$][\w$]*)/g;
  let out = "";
  let last = 0;
  for (const m of code.matchAll(re)) {
    out += escapeHtml(code.slice(last, m.index));
    const [tok, c, s, n, w] = m;
    if (c) out += `<span class="tk-c">${escapeHtml(tok)}</span>`;
    else if (s) out += `<span class="tk-s">${escapeHtml(tok)}</span>`;
    else if (n) out += `<span class="tk-n">${tok}</span>`;
    else if (w && KEYWORDS.has(w)) out += `<span class="tk-k">${w}</span>`;
    else out += escapeHtml(tok);
    last = m.index! + tok.length;
  }
  return out + escapeHtml(code.slice(last));
}

const renderer = new Renderer();
renderer.code = ({ text, lang }) => {
  const l = (lang ?? "").trim().split(/\s/)[0] ?? "";
  return `<pre><div class="code-head"><span>${escapeHtml(l || "text")}</span><button type="button" data-copy="1">Copy</button></div><code>${highlight(text, l)}</code></pre>`;
};
marked.setOptions({ gfm: true, breaks: false, renderer });
DOMPurify.addHook("afterSanitizeAttributes", (node) => {
  if (node.tagName === "A") { node.setAttribute("target", "_blank"); node.setAttribute("rel", "noopener noreferrer"); }
});

export const Markdown = memo(function Markdown({ text }: { text: string }) {
  const html = useMemo(() => DOMPurify.sanitize(marked.parse(text, { async: false }) as string, { ADD_ATTR: ["data-copy"] }), [text]);
  const onClick = (e: React.MouseEvent) => {
    const btn = (e.target as HTMLElement).closest("button[data-copy]");
    if (!btn) return;
    const code = btn.closest("pre")?.querySelector("code")?.textContent ?? "";
    bb.invoke("copy", code).then(() => { btn.textContent = "Copied"; setTimeout(() => { btn.textContent = "Copy"; }, 1400); });
  };
  return <div className="md" onClick={onClick} dangerouslySetInnerHTML={{ __html: html }} />;
});

// ---------------------------------------------------------------- pane

export interface ChatProps {
  chat?: string;
  transcript: TranscriptState;
  connected: boolean;
  readOnly?: string;
  title: string;
  say: (t: string) => void;
  newChat: () => Promise<string | undefined>;
  prefill?: string;
  clearPrefill: () => void;
  screenPrompt?: { text: string; urgent: boolean };
  onScreenPrompt: () => void;
  onSent: () => void;
  dockOpen: boolean;
  toggleDock: () => void;
  onRename: () => void;
  onDelete: () => void;
  focusKey: number;
}

export function ChatPane(props: ChatProps) {
  const { chat, transcript, connected } = props;
  const scroller = useRef<HTMLDivElement>(null);
  const pinned = useRef(true);
  const [away, setAway] = useState(false);
  const [menu, setMenu] = useState<{ x: number; y: number }>();

  const toBottom = useCallback((smooth = false) => {
    const el = scroller.current;
    if (!el) return;
    el.scrollTo({ top: el.scrollHeight, behavior: smooth ? "smooth" : "auto" });
    pinned.current = true;
    setAway(false);
  }, []);

  // New chat → start at the bottom. New content → follow it only while pinned to the bottom.
  useLayoutEffect(() => { pinned.current = true; toBottom(); }, [chat, toBottom]);
  useLayoutEffect(() => { if (pinned.current) toBottom(); }, [transcript, toBottom]);

  const onScroll = () => {
    const el = scroller.current!;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 60;
    pinned.current = atBottom;
    setAway(!atBottom);
  };

  const groups = useMemo(() => group(transcript.items), [transcript.items]);
  const last = transcript.items[transcript.items.length - 1];
  const waiting = transcript.busy && (!last || last.kind === "user" || (last.kind === "assistant" && !last.text && !last.reasoning));
  const model = transcript.model ?? transcript.usage?.model;
  const ctx = transcript.usage?.contextPercent;

  return (
    <div className="chat">
      <div className="chat-head">
        <div className="title">
          <div className="t" title={props.title}>{props.title}</div>
          <div className="s">
            {transcript.busy ? <><span className="dot volt pulse" />{transcript.status ?? "Working"}</>
              : <>
                  {props.readOnly ? <><Icon name="lock" size={12} />{props.readOnly} chat · read-only</>
                    : <><Icon name="smartphone" size={12} />Live on all your devices</>}
                  {model && <> · {model}</>}
                  {ctx !== undefined && <> · {ctx}% context</>}
                </>}
          </div>
        </div>
        <button className={"icon-btn" + (props.dockOpen ? " on" : "")} title="Hermes' screen beside the chat (Ctrl+J)" onClick={props.toggleDock}>
          <Icon name="monitor" />
        </button>
        <button className="icon-btn" title="More" disabled={!chat}
                onClick={(e) => { const r = e.currentTarget.getBoundingClientRect(); setMenu({ x: r.right - 200, y: r.bottom + 6 }); }}>
          <Icon name="more" />
        </button>
        {menu && (
          <Menu at={menu} onClose={() => setMenu(undefined)}>
            <MenuItem icon="pencil" label="Rename" disabled={!!props.readOnly} onClick={props.onRename} />
            <MenuItem icon="copy" label="Copy conversation" onClick={() => bb.invoke("copy", asText(transcript.items)).then(() => props.say("Conversation copied"))} />
            <MenuItem icon="refresh" label="Refresh from server" onClick={() => chat && bb.invoke("refreshChat", chat).catch((e) => props.say(e.message))} />
            <div className="pop-sep" />
            <MenuItem icon="trash" label="Delete chat" danger disabled={!!props.readOnly} onClick={props.onDelete} />
          </Menu>
        )}
      </div>

      <div className="scroller" ref={scroller} onScroll={onScroll}>
        {transcript.items.length === 0 ? (
          <EmptyChat connected={connected} onPick={(s) => send(props, s)} />
        ) : (
          <div className="thread">
            {groups.map((g) => g.kind === "tools"
              ? <div key={g.items[0].id} className="msg-assistant"><div className="avatar" style={{ visibility: "hidden" }} /><div className="body-col">{g.items.map((it) => <Item key={it.id} item={it} {...props} />)}</div></div>
              : <Item key={g.item.id} item={g.item} {...props} />)}
            {waiting && (
              <div className="msg-assistant"><div className="avatar">H</div><div className="body-col"><div className="typing"><i /><i /><i /></div></div></div>
            )}
          </div>
        )}
      </div>

      <div className="composer-wrap">
        <div className="composer-inner">
          {away && <button className="jump" onClick={() => toBottom(true)}><Icon name="arrowDown" size={14} />Jump to latest</button>}
          {transcript.todos.length > 0 && <Plan todos={transcript.todos} />}
          {props.screenPrompt && (
            <button className={"prompt-bar" + (props.screenPrompt.urgent ? " urgent" : "")} onClick={props.onScreenPrompt}>
              <Icon name={props.screenPrompt.urgent ? "hand" : "monitor"} size={18} style={{ color: props.screenPrompt.urgent ? "var(--bad)" : "var(--volt)" }} />
              <strong>{props.screenPrompt.text}</strong>
              <Icon name="chevronRight" size={16} />
            </button>
          )}
          {props.readOnly
            ? <div className="notice-line" style={{ alignSelf: "stretch" }}><Icon name="lock" size={12} style={{ display: "inline", verticalAlign: -2 }} /> This {props.readOnly} chat is read-only in Brainbox — reply to it from {props.readOnly}.</div>
            : <Composer {...props} />}
        </div>
      </div>
    </div>
  );
}

type Group = { kind: "one"; item: ChatItem } | { kind: "tools"; items: ChatItem[] };
function group(items: ChatItem[]): Group[] {
  const out: Group[] = [];
  for (const it of items) {
    const prev = out[out.length - 1];
    if (it.kind === "tool") {
      if (prev?.kind === "tools") prev.items.push(it);
      else out.push({ kind: "tools", items: [it] });
    } else out.push({ kind: "one", item: it });
  }
  return out;
}

function asText(items: ChatItem[]) {
  return items.flatMap((i) => i.kind === "user" ? [`You: ${i.text}`] : i.kind === "assistant" && i.text ? [`Hermes: ${i.text}`] : []).join("\n\n");
}

const SUGGESTIONS: { icon: IconName; text: string }[] = [
  { icon: "server", text: "Check the server's health and tell me anything that needs attention" },
  { icon: "globe", text: "Open business.facebook.com in your browser so I can log in" },
  { icon: "clock", text: "Every morning at 8, send me a short brief of what happened overnight" },
  { icon: "folder", text: "Look through ~/projects and summarise what each one is" },
];

function EmptyChat({ connected, onPick }: { connected: boolean; onPick: (s: string) => void }) {
  return (
    <div className="empty-chat">
      <div className="hero">H</div>
      <h2>{connected ? "What should Hermes do?" : "Connecting to Hermes…"}</h2>
      <p>Hermes works on your server. This chat is live on your phone too — start here, pick it up there.
        When Hermes uses its browser, open its screen with <kbd>Ctrl</kbd> <kbd>J</kbd> to watch or take over.</p>
      {connected && (
        <div className="suggestions">
          {SUGGESTIONS.map((s) => (
            <button key={s.text} className="suggestion" onClick={() => onPick(s.text)}><Icon name={s.icon} />{s.text}</button>
          ))}
        </div>
      )}
    </div>
  );
}

function Plan({ todos }: { todos: TranscriptState["todos"] }) {
  const done = todos.filter((t) => t.status === "completed").length;
  const current = todos.find((t) => t.status === "in_progress");
  return (
    <div className="plan">
      <details>
        <summary>
          <Icon name="list" size={14} />
          <span style={{ flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
            Plan · {done}/{todos.length}{current ? ` — ${current.content}` : ""}
          </span>
          <span className="bar"><i style={{ width: `${(done / Math.max(1, todos.length)) * 100}%` }} /></span>
        </summary>
        <ul>
          {todos.map((t) => (
            <li key={t.id} className={t.status}>
              <Icon name={t.status === "completed" ? "check" : t.status === "in_progress" ? "chevronRight" : "info"} size={13} />
              {t.content}
            </li>
          ))}
        </ul>
      </details>
    </div>
  );
}

// ---------------------------------------------------------------- sending

async function send(props: ChatProps, raw: string, files: File[] = []) {
  const text = raw.trim();
  if (!text && files.length === 0) return;
  let chat = props.chat;
  if (!chat) chat = await props.newChat();
  if (!chat) return;
  try {
    if (text.startsWith("/") && files.length === 0) {
      const [name, ...rest] = text.slice(1).split(" ");
      const arg = rest.join(" ");
      if (name === "new" || name === "clear") await props.newChat();
      else if (name === "stop") await bb.invoke("interrupt", chat);
      else if (name === "bg" || name === "background") arg ? await bb.invoke("background", chat, arg) : props.say("Usage: /bg <task>");
      else if (name === "btw") arg ? await bb.invoke("btw", chat, arg) : props.say("Usage: /btw <question>");
      else await bb.invoke("slash", chat, text);
    } else {
      const payload = await Promise.all(files.map(async (f) => ({
        name: f.name, isImage: f.type.startsWith("image/"), data: await toBase64(f),
      })));
      await bb.invoke("send", chat, text, payload);
    }
    props.onSent();
  } catch (e) {
    props.say((e as Error).message);
  }
}

function toBase64(f: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).split(",")[1] ?? "");
    r.onerror = () => reject(r.error);
    r.readAsDataURL(f);
  });
}

let catalog: [string, string][] | undefined;
const LOCAL_COMMANDS: [string, string][] = [
  ["/new", "Start a new chat"], ["/stop", "Stop the current reply"],
  ["/bg", "Run a task in the background (usage: /bg <task>)"], ["/btw", "Ask a side question without derailing the chat"],
];

interface ModelProvider { slug: string; name: string; is_current?: boolean; authenticated?: boolean; models: string[] }

function Composer(props: ChatProps) {
  const { transcript, connected, chat } = props;
  const [text, setText] = useState("");
  const [files, setFiles] = useState<File[]>([]);
  const [drag, setDrag] = useState(false);
  const [commands, setCommands] = useState<[string, string][]>(catalog ?? LOCAL_COMMANDS);
  const [sel, setSel] = useState(0);
  const [slashClosed, setSlashClosed] = useState(false);
  const [models, setModels] = useState<ModelProvider[]>();
  const [showModels, setShowModels] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);
  const area = useRef<HTMLTextAreaElement>(null);
  const history = useRef<string[]>([]);
  const historyAt = useRef(-1);

  useEffect(() => {
    if (props.prefill !== undefined) { setText(props.prefill); props.clearPrefill(); area.current?.focus(); }
  }, [props.prefill]);
  useEffect(() => { area.current?.focus(); }, [chat, props.focusKey]);
  useLayoutEffect(() => {
    const el = area.current;
    if (el) { el.style.height = "auto"; el.style.height = Math.min(el.scrollHeight, 260) + "px"; }
  }, [text]);
  useEffect(() => {
    if (!connected || catalog) return;
    bb.invoke<{ pairs?: [string, string][] }>("call", undefined, "commands.catalog", {})
      .then((r) => {
        const seen = new Set<string>();
        catalog = [...LOCAL_COMMANDS, ...(r.pairs ?? [])].filter(([k]) => !seen.has(k) && !!seen.add(k));
        setCommands(catalog);
      }).catch(() => {});
  }, [connected]);

  const slashQuery = !slashClosed && /^\/\S*$/.test(text) ? text.toLowerCase() : undefined;
  const matches = useMemo(() => slashQuery === undefined ? [] : commands.filter(([k]) => k.toLowerCase().startsWith(slashQuery)).slice(0, 40),
    [slashQuery, commands]);
  useEffect(() => { setSel(0); }, [slashQuery]);

  const submit = () => {
    if (!connected) return;
    const t = text;
    const f = files;
    if (!t.trim() && f.length === 0) return;
    if (t.trim()) { history.current = [t, ...history.current.filter((h) => h !== t)].slice(0, 50); }
    historyAt.current = -1;
    setText("");
    setFiles([]);
    send(props, t, f);
  };

  const complete = (cmd: string) => { setText(cmd + " "); setSlashClosed(true); area.current?.focus(); };

  const onKey = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (matches.length > 0) {
      if (e.key === "ArrowDown") { e.preventDefault(); setSel((sel + 1) % matches.length); return; }
      if (e.key === "ArrowUp") { e.preventDefault(); setSel((sel - 1 + matches.length) % matches.length); return; }
      if (e.key === "Tab" || (e.key === "Enter" && !e.shiftKey && matches[sel][0] !== text.trim())) { e.preventDefault(); complete(matches[sel][0]); return; }
      if (e.key === "Escape") { e.preventDefault(); setSlashClosed(true); return; }
    }
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); submit(); return; }
    if (e.key === "ArrowUp" && !text && history.current.length) {
      e.preventDefault();
      historyAt.current = Math.min(historyAt.current + 1, history.current.length - 1);
      setText(history.current[historyAt.current]);
    } else if (e.key === "ArrowDown" && historyAt.current >= 0) {
      e.preventDefault();
      historyAt.current -= 1;
      setText(historyAt.current >= 0 ? history.current[historyAt.current] : "");
    } else if (e.key === "Escape" && transcript.busy && chat) {
      bb.invoke("interrupt", chat).catch(() => {});
    }
  };

  const loadModels = async () => {
    setShowModels(!showModels);
    if (models) return;
    try {
      const r = await bb.invoke<{ providers?: ModelProvider[] }>("call", chat, "model.options", {});
      setModels((r.providers ?? []).filter((p) => p.authenticated !== false || p.is_current));
    } catch (e) { props.say((e as Error).message); setShowModels(false); }
  };
  const pickModel = async (name: string, slug: string) => {
    setShowModels(false);
    if (!chat) return;
    try {
      await bb.invoke("call", chat, "config.set", { key: "model", value: `${name} --provider ${slug}` });
      props.say(`Model: ${name}`);
      setModels(undefined);
    } catch (e) { props.say((e as Error).message); }
  };

  const addFiles = (list: FileList | File[] | null | undefined) => {
    const arr = Array.from(list ?? []).filter((f) => f.size <= 25 * 1024 * 1024);
    if (arr.length) setFiles((cur) => [...cur, ...arr]);
  };

  const model = transcript.model ?? transcript.usage?.model;

  return (
    <>
      <div className={"composer" + (drag ? " drag" : "")}
           onDragOver={(e) => { if (e.dataTransfer.types.includes("Files")) { e.preventDefault(); setDrag(true); } }}
           onDragLeave={() => setDrag(false)}
           onDrop={(e) => { e.preventDefault(); setDrag(false); addFiles(e.dataTransfer.files); }}>
        {matches.length > 0 && (
          <div className="popover up" role="listbox">
            {matches.map(([k, d], i) => (
              <button key={k} className={"pop-item" + (i === sel ? " sel" : "")} onMouseEnter={() => setSel(i)} onMouseDown={(e) => { e.preventDefault(); complete(k); }}
                      ref={(el) => { if (i === sel) el?.scrollIntoView({ block: "nearest" }); }}>
                <span className="k">{k}</span><span className="d">{d}</span>
              </button>
            ))}
          </div>
        )}
        {showModels && (
          <div className="popover model">
            {!models && <div className="pop-label">Loading models…</div>}
            {models?.map((p) => (
              <div key={p.slug}>
                <div className="pop-label">{p.name}</div>
                {p.models.map((m) => (
                  <button key={m} className="pop-item" onClick={() => pickModel(m, p.slug)}>
                    <Icon name="cpu" size={14} /><span className="d" style={{ color: "var(--ink)" }}>{m}</span>
                    {p.is_current && m === model && <Icon name="check" size={14} style={{ color: "var(--volt)" }} />}
                  </button>
                ))}
              </div>
            ))}
          </div>
        )}
        {files.length > 0 && (
          <div className="attachments">
            {files.map((f, i) => (
              <span key={i} className="chip" title={f.name}>
                <Icon name={f.type.startsWith("image/") ? "sparkles" : "file"} size={13} /><span>{f.name}</span>
                <button className="icon-btn" style={{ width: 18, height: 18 }} onClick={() => setFiles(files.filter((_, j) => j !== i))}><Icon name="x" size={12} /></button>
              </span>
            ))}
          </div>
        )}
        <textarea ref={area} rows={1} value={text} spellCheck
                  placeholder={connected ? "Message Hermes…" : "Waiting for the connection…"}
                  onChange={(e) => { setText(e.target.value); setSlashClosed(false); }}
                  onKeyDown={onKey}
                  onPaste={(e) => { if (e.clipboardData.files.length) { e.preventDefault(); addFiles(e.clipboardData.files); } }} />
        <div className="tools-row">
          <button className="icon-btn" title="Attach files (or drop / paste them)" disabled={!connected} onClick={() => fileInput.current?.click()}><Icon name="paperclip" /></button>
          <input ref={fileInput} type="file" multiple hidden onChange={(e) => { addFiles(e.target.files); e.target.value = ""; }} />
          <button className="icon-btn" title="Commands" disabled={!connected} onClick={() => { setText("/"); setSlashClosed(false); area.current?.focus(); }}><Icon name="command" /></button>
          <button className="chip" title="Model for this chat" disabled={!connected || !chat} onClick={loadModels}>
            <Icon name="cpu" size={13} /><span>{model ?? "Model"}</span><Icon name="chevronDown" size={12} />
          </button>
          <span className="spacer" />
          {transcript.busy
            ? <button className="send-btn stop" title="Stop (Esc)" onClick={() => chat && bb.invoke("interrupt", chat).catch((e) => props.say(e.message))}><Icon name="stop" size={14} stroke={3} /></button>
            : <button className="send-btn" title="Send (Enter)" disabled={!connected || (!text.trim() && files.length === 0)} onClick={submit}><Icon name="send" size={17} stroke={2.4} /></button>}
        </div>
      </div>
      <div className="composer-hint">
        <span><kbd>Enter</kbd> send</span><span><kbd>Shift</kbd><kbd>Enter</kbd> new line</span><span><kbd>/</kbd> commands</span><span><kbd>Ctrl</kbd><kbd>K</kbd> everything</span>
      </div>
    </>
  );
}

// ---------------------------------------------------------------- items

function Item({ item, chat, say }: { item: ChatItem } & ChatProps) {
  switch (item.kind) {
    case "user":
      return (
        <div className="msg-user">
          <div className="bubble">{item.text}</div>
          {item.attachments.length > 0 && <div className="att">{item.attachments.map((a) => <span key={a} className="chip"><Icon name="paperclip" size={12} /><span>{a}</span></span>)}</div>}
          <div className="msg-meta">
            {relTime(item.date)}
            <button className="icon-btn" style={{ width: 22, height: 22 }} title="Copy" onClick={() => bb.invoke("copy", item.text).then(() => say("Copied"))}><Icon name="copy" size={12} /></button>
          </div>
        </div>
      );
    case "assistant":
      return (
        <div className={"msg-assistant" + (item.streaming ? " streaming" : "")}>
          <div className="avatar">H</div>
          <div className="body-col">
            {item.reasoning && (
              <details className="reasoning">
                <summary><Icon name="chevronRight" size={13} className="chev" /><Icon name="brain" size={13} />{item.streaming && !item.text ? "Thinking…" : "Reasoning"}</summary>
                <div className="r-body">{item.reasoning}</div>
              </details>
            )}
            {item.text && <Markdown text={item.text} />}
            {!item.streaming && item.text && (
              <div className="msg-meta">
                {relTime(item.date)}
                <button className="icon-btn" style={{ width: 22, height: 22 }} title="Copy" onClick={() => bb.invoke("copy", item.text).then(() => say("Copied"))}><Icon name="copy" size={12} /></button>
              </div>
            )}
          </div>
        </div>
      );
    case "tool": {
      const t = item.tool;
      return (
        <details className="tool" open={t.status === "failed"}>
          <summary>
            <span className={"ti " + t.status}>
              {t.status === "running" ? <Icon name="refresh" size={12} className="spin" /> : t.status === "failed" ? <Icon name="x" size={12} stroke={2.6} /> : <Icon name="check" size={12} stroke={2.6} />}
            </span>
            <span className="name">{t.name}</span>
            <span className="ctx">{t.context}</span>
            {t.duration !== undefined && <span className="dur">{t.duration.toFixed(1)}s</span>}
            {(t.inlineDiff || t.output) && <Icon name="chevronRight" size={14} className="chev" style={{ color: "var(--ink4)" }} />}
          </summary>
          {(t.inlineDiff || t.output) && <pre>{t.inlineDiff || t.output}</pre>}
          {t.approvalNote && <div className="note">{t.approvalNote}</div>}
        </details>
      );
    }
    case "request":
      return <RequestCard request={item.request} chat={chat} say={say} />;
    case "command":
      return (
        <div className="command">
          <div className="head"><Icon name="terminal" size={13} />{item.name}</div>
          {item.output && <pre>{item.output}</pre>}
        </div>
      );
    case "side":
      return (
        <div className="side-card">
          <div className="lbl">{item.label === "btw" ? "Side question" : "Background task"} · {item.title}</div>
          {item.done ? <Markdown text={item.text || "(no answer)"} /> : <div className="working"><span className="dot volt pulse" />Working…</div>}
        </div>
      );
    case "notice":
      return <div className="notice-line">{item.text}</div>;
    case "error":
      return <div className="error-line"><Icon name="alert" size={16} />{item.text}</div>;
  }
}

function RequestCard({ request, chat, say }: { request: PendingRequest; chat?: string; say: (t: string) => void }) {
  const [value, setValue] = useState("");
  const answer = (a: string, questionId?: string) => {
    if (!chat) return;
    bb.invoke("respond", chat, request.requestId, a, questionId).catch((e) => say(e.message));
  };
  const r = request.request;
  const done = request.resolution;
  return (
    <div className={"req" + (done ? " done" : "")}>
      {r.kind === "approval" && (
        <>
          <div className="q"><Icon name="alert" size={16} style={{ color: "var(--warn)" }} />Approve this command?</div>
          {r.description && <div style={{ color: "var(--ink2)", fontSize: 13 }}>{r.description}</div>}
          <div className="cmd">{r.command}</div>
          {!done && (
            <div className="choices">
              {r.choices.map((c) => (
                <button key={c} className={"btn small " + (c === "deny" ? "danger" : c === "once" ? "primary" : "")} onClick={() => answer(c)}>
                  {c === "once" ? "Approve once" : c === "session" ? "Approve for this chat" : c === "always" ? "Always approve" : c === "deny" ? "Deny" : c}
                </button>
              ))}
            </div>
          )}
        </>
      )}
      {r.kind === "clarify" && <Question q={{ id: request.questionId ?? "q1", question: r.question, choices: r.choices, multiSelect: r.multiSelect }}
                                         done={!!done} onAnswer={(a) => answer(a, request.questionId)} />}
      {r.kind === "clarifyBatch" && r.questions.map((q) => <Question key={q.id} q={q} done={!!done} onAnswer={(a) => answer(a, q.id)} />)}
      {(r.kind === "sudo" || r.kind === "secret") && (
        <>
          <div className="q"><Icon name="lock" size={16} style={{ color: "var(--volt)" }} />{r.kind === "sudo" ? "Hermes needs the sudo password" : r.prompt || `Hermes needs ${r.envVar}`}</div>
          {!done && (
            <div className="row" style={{ alignItems: "center" }}>
              <input className="input" type="password" value={value} onChange={(e) => setValue(e.target.value)} autoComplete="off" autoFocus
                     onKeyDown={(e) => { if (e.key === "Enter") { answer(value); setValue(""); } }} />
              <button className="btn primary small" onClick={() => { answer(value); setValue(""); }}>Send</button>
              <button className="btn ghost small" onClick={() => answer("")}>Skip</button>
            </div>
          )}
        </>
      )}
      {done && <div className="resolved"><Icon name="check" size={13} />{done}</div>}
    </div>
  );
}

function Question({ q, done, onAnswer }: { q: ClarifyQuestion; done: boolean; onAnswer: (a: string) => void }) {
  const [text, setText] = useState("");
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
      <div className="q"><Icon name="info" size={16} style={{ color: "var(--volt)" }} />{q.question}</div>
      {!done && (
        <>
          {q.choices.length > 0 && <div className="choices">{q.choices.map((c) => <button key={c} className="btn small" onClick={() => onAnswer(c)}>{c}</button>)}</div>}
          <div className="row">
            <input className="input" value={text} placeholder="Type an answer" onChange={(e) => setText(e.target.value)}
                   onKeyDown={(e) => { if (e.key === "Enter" && text.trim()) onAnswer(text.trim()); }} />
            <button className="btn small" style={{ height: 36 }} disabled={!text.trim()} onClick={() => onAnswer(text.trim())}>Answer</button>
          </div>
        </>
      )}
    </div>
  );
}
