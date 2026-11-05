import DOMPurify from "dompurify";
import { marked } from "marked";
import { useEffect, useMemo, useRef, useState } from "react";
import type { ChatItem, ClarifyQuestion, PendingRequest, TranscriptState } from "../../shared/transcript";
import { bb } from "../api";

marked.setOptions({ gfm: true, breaks: false });
DOMPurify.addHook("afterSanitizeAttributes", (node) => {
  if (node.tagName === "A") { node.setAttribute("target", "_blank"); node.setAttribute("rel", "noopener noreferrer"); }
});

export function Markdown({ text }: { text: string }) {
  const html = useMemo(() => DOMPurify.sanitize(marked.parse(text, { async: false }) as string), [text]);
  return <div className="md" dangerouslySetInnerHTML={{ __html: html }} />;
}

interface Props {
  chat?: string;
  transcript: TranscriptState;
  connected: boolean;
  say: (t: string) => void;
  newChat: () => Promise<string | undefined>;
  prefill?: string;
  clearPrefill: () => void;
  screenPrompt?: { text: string; urgent: boolean };
  onScreenPrompt: () => void;
  onSent: () => void;
}

export function ChatPane(props: Props) {
  const { chat, transcript, connected } = props;
  const scroller = useRef<HTMLDivElement>(null);
  const pinned = useRef(true);

  useEffect(() => {
    const el = scroller.current;
    if (el && pinned.current) el.scrollTop = el.scrollHeight;
  }, [transcript]);

  return (
    <>
      <div className="messages" ref={scroller}
           onScroll={(e) => { const el = e.currentTarget; pinned.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80; }}>
        {transcript.items.length === 0 && (
          <div className="empty">
            <h2>{connected ? "What should Hermes do?" : "Connecting to Hermes…"}</h2>
            <span>Hermes runs on your server. When it opens its browser you can watch it live in the Workspace, take over for a login or CAPTCHA, then hand back.</span>
            {connected && (
              <div className="chips">
                {["Check the server's health", "Open business.facebook.com in your browser", "/help"].map((s) => (
                  <button key={s} className="chip" onClick={() => send(props, s)}>{s}</button>
                ))}
              </div>
            )}
          </div>
        )}
        {transcript.items.map((item) => <Item key={item.id} item={item} chat={chat} say={props.say} />)}
      </div>
      {transcript.todos.length > 0 && (
        <details className="card todos" open>
          <summary>Plan · {transcript.todos.filter((t) => t.status === "completed").length}/{transcript.todos.length}</summary>
          <ul style={{ margin: "6px 0 0", padding: 0 }}>
            {transcript.todos.map((t) => <li key={t.id} className={t.status}>{t.status === "completed" ? "✓" : t.status === "in_progress" ? "▸" : "○"} {t.content}</li>)}
          </ul>
        </details>
      )}
      <Composer {...props} />
    </>
  );
}

async function send(props: Props, raw: string, files: File[] = []) {
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
        name: f.name, isImage: f.type.startsWith("image/"),
        data: btoa(Array.from(new Uint8Array(await f.arrayBuffer()), (b) => String.fromCharCode(b)).join("")),
      })));
      await bb.invoke("send", chat, text, payload);
    }
    props.onSent();
  } catch (e) {
    props.say((e as Error).message);
  }
}

function Composer(props: Props) {
  const [text, setText] = useState("");
  const [files, setFiles] = useState<File[]>([]);
  const fileInput = useRef<HTMLInputElement>(null);
  const area = useRef<HTMLTextAreaElement>(null);
  const { transcript, connected } = props;

  useEffect(() => {
    if (props.prefill !== undefined) { setText(props.prefill); props.clearPrefill(); area.current?.focus(); }
  }, [props.prefill]);
  useEffect(() => {
    const el = area.current;
    if (el) { el.style.height = "auto"; el.style.height = Math.min(el.scrollHeight, 220) + "px"; }
  }, [text]);

  const submit = () => {
    const t = text;
    const f = files;
    setText("");
    setFiles([]);
    send(props, t, f);
  };

  return (
    <div className="composer">
      {props.screenPrompt && (
        <button className={"prompt-bar" + (props.screenPrompt.urgent ? " urgent" : "")} onClick={props.onScreenPrompt}>
          <span className={"pill " + (props.screenPrompt.urgent ? "bad" : "volt")}>{props.screenPrompt.urgent ? "✋" : "🖥"}</span>
          <strong style={{ flex: 1 }}>{props.screenPrompt.text}</strong>
          <span className="notice">›</span>
        </button>
      )}
      {files.length > 0 && (
        <div className="chips">
          {files.map((f, i) => <span key={i} className="chip" onClick={() => setFiles(files.filter((_, j) => j !== i))}>📎 {f.name} ✕</span>)}
        </div>
      )}
      <div className="composer-box">
        <button className="btn ghost small" title="Attach files" onClick={() => fileInput.current?.click()} disabled={!connected}>📎</button>
        <input ref={fileInput} type="file" multiple hidden onChange={(e) => { setFiles([...files, ...Array.from(e.target.files ?? [])]); e.target.value = ""; }} />
        <textarea ref={area} rows={1} value={text} placeholder={connected ? "Message Hermes — / for commands" : "Waiting for the connection…"}
                  onChange={(e) => setText(e.target.value)}
                  onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); submit(); } }} />
        {transcript.busy
          ? <button className="btn danger small" onClick={() => props.chat && bb.invoke("interrupt", props.chat).catch((e) => props.say(e.message))}>Stop</button>
          : <button className="btn primary small" disabled={!connected || (!text.trim() && files.length === 0)} onClick={submit}>Send</button>}
      </div>
      <div className="status-line">
        {transcript.busy && <span className="pill volt"><span className="dot pulse" />{transcript.status ?? "Working"}</span>}
        {transcript.usage && <span>{transcript.usage.totalTokens.toLocaleString()} tokens</span>}
      </div>
    </div>
  );
}

function Item({ item, chat, say }: { item: ChatItem; chat?: string; say: (t: string) => void }) {
  switch (item.kind) {
    case "user":
      return <div className="msg-user">{item.text}{item.attachments.length > 0 && <div className="att">📎 {item.attachments.join(", ")}</div>}</div>;
    case "assistant":
      return (
        <div className="msg-assistant">
          {item.reasoning && <details className="reasoning"><summary>Reasoning</summary><div style={{ whiteSpace: "pre-wrap" }}>{item.reasoning}</div></details>}
          {item.text && <Markdown text={item.text} />}
        </div>
      );
    case "tool": {
      const t = item.tool;
      const pill = t.status === "running" ? "volt" : t.status === "failed" ? "bad" : "good";
      return (
        <details className="tool" open={t.status === "failed"}>
          <summary>
            <span className={"pill " + pill}>{t.status === "running" ? <span className="dot pulse" /> : t.status === "failed" ? "✕" : "✓"}</span>
            <span className="name">{t.name}</span>
            <span className="ctx">{t.context}</span>
            {t.duration !== undefined && <span className="notice">{t.duration.toFixed(1)}s</span>}
          </summary>
          {(t.inlineDiff || t.output) && <pre>{t.inlineDiff || t.output}</pre>}
          {t.approvalNote && <div className="notice" style={{ padding: "0 12px 8px" }}>{t.approvalNote}</div>}
        </details>
      );
    }
    case "request":
      return <RequestCard request={item.request} chat={chat} say={say} />;
    case "command":
      return <div className="command"><span className="pill muted">{item.name}</span><pre>{item.output}</pre></div>;
    case "side":
      return (
        <div className="side">
          <div className="notice" style={{ textAlign: "left" }}>{item.label === "btw" ? "Side question" : "Background task"} · {item.title}</div>
          {item.done ? <Markdown text={item.text || "(no answer)"} /> : <span className="notice">Working…</span>}
        </div>
      );
    case "notice":
      return <div className="notice">{item.text}</div>;
    case "error":
      return <div className="error">{item.text}</div>;
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
          <div className="q">Approve this command?</div>
          {r.description && <div>{r.description}</div>}
          <div className="cmd">{r.command}</div>
          {!done && (
            <div className="choices">
              {r.choices.map((c) => (
                <button key={c} className={"btn small " + (c === "deny" ? "danger" : c === "once" ? "primary" : "")} onClick={() => answer(c)}>
                  {c === "once" ? "Approve once" : c === "session" ? "Approve for this session" : c === "always" ? "Always approve" : c === "deny" ? "Deny" : c}
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
          <div className="q">{r.kind === "sudo" ? "Hermes needs the sudo password" : r.prompt || `Hermes needs ${r.envVar}`}</div>
          {!done && (
            <div className="row" style={{ alignItems: "center" }}>
              <input className="input" type="password" value={value} onChange={(e) => setValue(e.target.value)} autoComplete="off"
                     onKeyDown={(e) => { if (e.key === "Enter") { answer(value); setValue(""); } }} />
              <div style={{ flex: "0 0 auto", display: "flex", gap: 8 }}>
                <button className="btn primary small" onClick={() => { answer(value); setValue(""); }}>Send</button>
                <button className="btn ghost small" onClick={() => answer("")}>Skip</button>
              </div>
            </div>
          )}
        </>
      )}
      {done && <span className="notice" style={{ textAlign: "left" }}>{done}</span>}
    </div>
  );
}

function Question({ q, done, onAnswer }: { q: ClarifyQuestion; done: boolean; onAnswer: (a: string) => void }) {
  const [text, setText] = useState("");
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <div className="q">{q.question}</div>
      {!done && (
        <>
          {q.choices.length > 0 && <div className="choices">{q.choices.map((c) => <button key={c} className="btn small" onClick={() => onAnswer(c)}>{c}</button>)}</div>}
          <div className="row">
            <input className="input" value={text} placeholder="Type an answer" onChange={(e) => setText(e.target.value)}
                   onKeyDown={(e) => { if (e.key === "Enter" && text.trim()) onAnswer(text.trim()); }} />
            <button className="btn small" style={{ flex: "0 0 auto" }} disabled={!text.trim()} onClick={() => onAnswer(text.trim())}>Answer</button>
          </div>
        </>
      )}
    </div>
  );
}
