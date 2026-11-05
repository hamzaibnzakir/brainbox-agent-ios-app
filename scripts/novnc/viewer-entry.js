// Brainbox screen viewer: noVNC's RFB client on a channel bridged to Swift.
//
// The phone opens Hermes' screen socket (/api/display/ws, raw RFB as binary frames) itself, over
// SSH, so the web view never touches the network. Bytes cross the bridge as base64:
//   Swift -> JS : BBViewer.recv(base64), BBViewer.closed(code, reason)
//   JS -> Swift : webkit.messageHandlers.bb.postMessage({type: "send"|"close"|"state"|..., ...})
import RFB from "../core/rfb.js";

const native = (msg) => {
  try { window.webkit.messageHandlers.bb.postMessage(msg); } catch (e) { /* not in the app */ }
};

function toBase64(bytes) {
  let binary = "";
  const step = 0x8000;
  for (let i = 0; i < bytes.length; i += step) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + step));
  }
  return btoa(binary);
}

function fromBase64(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

// A WebSocket-shaped object noVNC can attach to (see core/websock.js rawChannelProps).
class BridgeChannel {
  constructor() {
    this.binaryType = "arraybuffer";
    this.protocol = "";
    this.readyState = "open"; // Swift opens the socket before the viewer starts
    this.onopen = null;
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;
  }
  send(data) {
    if (this.readyState !== "open") return;
    const bytes = data instanceof ArrayBuffer ? new Uint8Array(data)
      : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    native({ type: "send", data: toBase64(bytes) }); // copy now: noVNC reuses its send buffer
  }
  close() {
    if (this.readyState === "closed") return;
    this.readyState = "closed";
    native({ type: "close" });
  }
}

// X keysyms for the keys the phone's keyboard bar sends.
const KEYS = {
  Enter: 0xff0d, Backspace: 0xff08, Tab: 0xff09, Escape: 0xff1b, Delete: 0xffff,
  ArrowLeft: 0xff51, ArrowUp: 0xff52, ArrowRight: 0xff53, ArrowDown: 0xff54,
  Home: 0xff50, End: 0xff57, PageUp: 0xff55, PageDown: 0xff56,
  Control: 0xffe3, Alt: 0xffe9, Shift: 0xffe1, Meta: 0xffeb,
};

const CODES = { Control: "ControlLeft", Alt: "AltLeft", Shift: "ShiftLeft", Meta: "MetaLeft" };

function keysymFor(ch) {
  const cp = ch.codePointAt(0);
  if (ch === "\n") return KEYS.Enter;
  if (ch === "\t") return KEYS.Tab;
  if (cp >= 0x20 && cp <= 0x7e) return cp;          // Latin-1 printable = keysym
  if (cp >= 0xa0 && cp <= 0xff) return cp;
  return 0x01000000 + cp;                           // Unicode keysym
}

const BBViewer = {
  rfb: null,
  channel: null,

  start(options) {
    const target = document.getElementById("screen");
    this.channel = new BridgeChannel();
    const rfb = new RFB(target, this.channel, { shared: true });
    rfb.viewOnly = !!options.viewOnly;
    rfb.scaleViewport = true;
    rfb.clipViewport = false;
    rfb.resizeSession = false;      // the screen's size is Hermes' (bot_desktop.geometry)
    rfb.showDotCursor = true;
    rfb.focusOnClick = false;       // the phone shows its own keyboard bar
    rfb.qualityLevel = options.quality ?? 6;
    rfb.compressionLevel = options.compression ?? 2;
    rfb.background = "#0b0c0f";
    rfb.addEventListener("connect", () => native({ type: "state", state: "connected" }));
    rfb.addEventListener("disconnect", (e) => native({ type: "state", state: "disconnected", clean: !!e.detail.clean }));
    rfb.addEventListener("securityfailure", (e) => native({ type: "state", state: "failed", reason: String(e.detail.reason || e.detail.status) }));
    rfb.addEventListener("credentialsrequired", () => native({ type: "state", state: "failed", reason: "The screen asked for a VNC password; Hermes' screen never should." }));
    rfb.addEventListener("desktopname", (e) => native({ type: "name", name: e.detail.name }));
    this.rfb = rfb;
  },

  recv(b64) {
    const ch = this.channel;
    if (!ch || ch.readyState !== "open" || !ch.onmessage) return;
    const bytes = fromBase64(b64);
    ch.onmessage({ data: bytes.buffer });
  },

  closed(code, reason) {
    const ch = this.channel;
    if (!ch) return;
    ch.readyState = "closed";
    if (ch.onclose) ch.onclose({ code, reason, wasClean: code === 1000 });
  },

  setViewOnly(on) { if (this.rfb) this.rfb.viewOnly = !!on; },
  setScale(fit) { if (this.rfb) { this.rfb.scaleViewport = !!fit; this.rfb.clipViewport = !fit; this.rfb.dragViewport = !fit; } },

  key(name, down) {
    if (!this.rfb || this.rfb.viewOnly) return;
    const sym = KEYS[name];
    if (sym === undefined) return;
    const code = CODES[name] || name;   // KeyboardEvent.code, for Xvnc's raw-keycode path
    if (down === undefined) { this.rfb.sendKey(sym, code); } else { this.rfb.sendKey(sym, code, !!down); }
  },

  type(text) {
    if (!this.rfb || this.rfb.viewOnly) return;
    for (const ch of text) this.rfb.sendKey(keysymFor(ch), null);
  },

  paste(text) { if (this.rfb && !this.rfb.viewOnly) this.rfb.clipboardPasteFrom(text); },
  ctrlAltDel() { if (this.rfb && !this.rfb.viewOnly) this.rfb.sendCtrlAltDel(); },
  stop() { if (this.rfb) { try { this.rfb.disconnect(); } catch (e) {} this.rfb = null; } },
};

window.BBViewer = BBViewer;
native({ type: "ready" });
