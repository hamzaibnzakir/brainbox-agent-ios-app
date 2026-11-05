import BrainboxCore
import Foundation

// The bot's browser as a phone page: Hermes' headed Chromium (the one on its Bot Screen) streamed
// tab-only through the Chrome DevTools Protocol, with touch and typing coming back the same way.
//
// * Chromium writes its DevTools port to `<user-data-dir>/DevToolsActivePort`; Hermes' bot browser
//   uses `<HERMES_HOME>/bot-desktop/browser-profile` (tools/bot_desktop/browser.py). The port is on
//   the server's loopback, reached through SSH direct-tcpip like everything else — nothing is exposed.
// * Watching streams the page as the agent sees it. Taking over (with Hermes' screen lease, so the
//   agent's browser tools pause) switches the tab to phone mode: an iPhone-sized, touch-enabled
//   viewport with a mobile user agent, so sites render their mobile layout. Handing back clears every
//   override explicitly (Chromium keeps device metrics after a session detaches).

/// One DevTools event.
public struct CDPEvent: Sendable {
    public var method: String
    public var params: JSONValue
}

public struct CDPError: Error, LocalizedError, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var errorDescription: String? { "Browser: \(message)" }
    public static let timedOut = CDPError(code: -1, message: "the browser didn't answer in time")
    public static let closed = CDPError(code: -2, message: "the browser connection closed")
}

/// Compact JSON with integral numbers written as integers (Chromium rejects `"id": 1.0`).
enum CDPJSON {
    static func encode(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n.isFinite, n.rounded() == n, abs(n) < 9.0e15 { return String(Int64(n)) }
            return n.isFinite ? String(n) : "0"
        case .string(let s): return string(s)
        case .array(let a): return "[" + a.map(encode).joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { string($0) + ":" + encode(o[$0]!) }.joined(separator: ",") + "}"
        }
    }

    static func string(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

/// A DevTools session on one page target (JSON over a WebSocket through the SSH tunnel).
public final class CDPSession: @unchecked Sendable {
    private let socket: TunnelWebSocket
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var isClosed = false
    public let events: AsyncStream<CDPEvent>
    private let continuation: AsyncStream<CDPEvent>.Continuation

    init(socket: TunnelWebSocket) {
        self.socket = socket
        (events, continuation) = AsyncStream.makeStream(of: CDPEvent.self, bufferingPolicy: .bufferingNewest(64))
        Task { [weak self] in await self?.readLoop() }
    }

    public var closed: Bool { lock.withLock { isClosed } }

    private func readLoop() async {
        do {
            for try await frame in socket.frames {
                guard case .text(let text) = frame, let data = text.data(using: .utf8),
                      let msg = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
                if let id = msg["id"]?.intValue {
                    let c = lock.withLock { pending.removeValue(forKey: id) }
                    if let error = msg["error"] {
                        c?.resume(throwing: CDPError(code: error["code"]?.intValue ?? -3, message: error["message"]?.stringValue ?? "error"))
                    } else {
                        c?.resume(returning: msg["result"] ?? .null)
                    }
                } else if let method = msg["method"]?.stringValue {
                    continuation.yield(CDPEvent(method: method, params: msg["params"] ?? .null))
                }
            }
        } catch {}
        finish()
    }

    private func finish() {
        let waiting: [CheckedContinuation<JSONValue, Error>] = lock.withLock {
            if isClosed { return [] }
            isClosed = true
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        for w in waiting { w.resume(throwing: CDPError.closed) }
        lock.withLock { outbox?.finish() }
        continuation.finish()
    }

    @discardableResult
    public func call(_ method: String, _ params: [String: JSONValue] = [:], timeout: TimeInterval = 15) async throws -> JSONValue {
        let id: Int = try lock.withLock {
            if isClosed { throw CDPError.closed }
            nextID += 1
            return nextID
        }
        let text = "{\"id\":\(id),\"method\":\(CDPJSON.string(method)),\"params\":\(CDPJSON.encode(.object(params)))}"
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let c = self.lock.withLock { self.pending.removeValue(forKey: id) }
            c?.resume(throwing: CDPError.timedOut)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { c in
            let queued: Bool = lock.withLock {
                pending[id] = c
                if let outbox, case .enqueued = outbox.yield(text) { return true }
                return false
            }
            if !queued {
                Task {
                    do { try await self.socket.send(text: text) } catch {
                        let c = self.lock.withLock { self.pending.removeValue(forKey: id) }
                        c?.resume(throwing: CDPError.closed)
                    }
                }
            }
        }
    }

    private var outbox: AsyncStream<String>.Continuation?
    private var writer: Task<Void, Never>?

    /// Fire-and-forget (input events). Messages go out strictly in call order (a tap's touchStart
    /// before its touchEnd) and don't wait for replies, so input stays fast on a slow link.
    public func send(_ method: String, _ params: [String: JSONValue] = [:]) {
        let queued: (AsyncStream<String>.Continuation, Int)? = lock.withLock {
            if isClosed { return nil }
            if outbox == nil {
                let (stream, c) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
                outbox = c
                let socket = self.socket
                writer = Task { for await text in stream { try? await socket.send(text: text) } }
            }
            nextID += 1
            return outbox.map { ($0, nextID) }
        }
        guard let (continuation, id) = queued else { return }
        continuation.yield("{\"id\":\(id),\"method\":\(CDPJSON.string(method)),\"params\":\(CDPJSON.encode(.object(params)))}")
    }

    public func close() {
        socket.close()
        finish()
    }
}

/// A page in the bot's browser.
public struct BrowserTab: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var url: String
    /// Path of the page's DevTools WebSocket (`/devtools/page/<id>`).
    public var socketPath: String

    public static func list(from json: JSONValue) -> [BrowserTab] {
        (json.arrayValue ?? []).compactMap { t in
            guard t["type"]?.stringValue == "page", let id = t["id"]?.stringValue,
                  let ws = t["webSocketDebuggerUrl"]?.stringValue else { return nil }
            let url = t["url"]?.stringValue ?? ""
            if url.hasPrefix("chrome://") || url.hasPrefix("devtools://") || url.hasPrefix("chrome-extension://") { return nil }
            let path = ws.range(of: "/devtools/").map { String(ws[$0.lowerBound...]) } ?? "/devtools/page/\(id)"
            return BrowserTab(id: id, title: t["title"]?.stringValue ?? url, url: url, socketPath: path)
        }
    }
}

/// One streamed frame of the page.
public struct BrowserFrame: Sendable {
    public var jpeg: Data
    /// The page's viewport in CSS pixels (what touch coordinates are in).
    public var cssWidth: Double
    public var cssHeight: Double
    public var scrollY: Double
}

public enum LiveBrowserError: Error, LocalizedError, Equatable {
    case noBrowser
    case noTab

    public var errorDescription: String? {
        switch self {
        case .noBrowser: return "Hermes' browser isn't open. It opens when Hermes browses, or start it from the screen's dock."
        case .noTab: return "Hermes' browser has no open page."
        }
    }
}

/// Phone-mode settings for a take over: the viewport the page lays out in.
public struct PhoneViewport: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var scale: Double
    public var mobile: Bool

    public init(width: Int, height: Int, scale: Double = 2, mobile: Bool = true) {
        self.width = width
        self.height = height
        self.scale = scale
        self.mobile = mobile
    }

    public static let iPhoneUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
}

/// The bot's browser, page-only, over SSH.
public final class LiveBrowser: @unchecked Sendable {
    public let client: HermesClient
    public private(set) var port: Int = 0
    public private(set) var tab: BrowserTab?
    private var session: CDPSession?
    private var pump: Task<Void, Never>?
    private let lock = NSLock()
    private var phone: PhoneViewport?
    private var lastViewport = (w: 0.0, h: 0.0)

    /// Latest frames, newest wins (the view never queues stale frames).
    public let frames: AsyncStream<BrowserFrame>
    private let frameSink: AsyncStream<BrowserFrame>.Continuation
    /// Navigation and title changes.
    public let changes: AsyncStream<BrowserTab>
    private let changeSink: AsyncStream<BrowserTab>.Continuation

    public init(client: HermesClient) {
        self.client = client
        (frames, frameSink) = AsyncStream.makeStream(of: BrowserFrame.self, bufferingPolicy: .bufferingNewest(1))
        (changes, changeSink) = AsyncStream.makeStream(of: BrowserTab.self, bufferingPolicy: .bufferingNewest(4))
    }

    /// Where Chromium wrote its DevTools port: the bot browser's profile first, then any profile's.
    static let locateScript = """
    for f in "$HOME/.hermes/bot-desktop/browser-profile/DevToolsActivePort" $(ls -t "$HOME"/.hermes/profiles/*/bot-desktop/browser-profile/DevToolsActivePort "$HOME"/.hermes/*/bot-desktop/browser-profile/DevToolsActivePort 2>/dev/null); do
      if [ -f "$f" ]; then p=$(head -n1 "$f"); case "$p" in ''|*[!0-9]*) ;; *) echo "PORT=$p"; exit 0;; esac; fi
    done
    echo NOPORT
    """

    public func locate() async throws -> Int {
        let result = try await client.ssh.exec(Self.locateScript, timeout: 20)
        guard let line = result.output.split(separator: "\n").first(where: { $0.hasPrefix("PORT=") }),
              let port = Int(line.dropFirst(5)) else { throw LiveBrowserError.noBrowser }
        self.port = port
        return port
    }

    public func tabs() async throws -> [BrowserTab] {
        if port == 0 { _ = try await locate() }
        let http = TunnelHTTPClient(dialer: SSHPortDialer(ssh: client.ssh, port: port))
        let response: TunnelResponse
        do {
            response = try await http.send("GET", "/json/list", timeout: 10)
        } catch {
            port = 0
            throw LiveBrowserError.noBrowser
        }
        guard response.status == 200, let json = try? JSONDecoder().decode(JSONValue.self, from: response.body) else {
            throw LiveBrowserError.noBrowser
        }
        return BrowserTab.list(from: json)
    }

    /// Attaches to `tab` (or the most recently used page) and starts streaming.
    public func open(_ tab: BrowserTab? = nil, maxWidth: Int = 900, maxHeight: Int = 1800) async throws {
        close()
        let all = try await tabs()
        guard let target = tab ?? all.first else { throw LiveBrowserError.noTab }
        let socket = try await TunnelWebSocket.connect(dialer: SSHPortDialer(ssh: client.ssh, port: port), path: target.socketPath)
        let session = CDPSession(socket: socket)
        lock.withLock {
            self.session = session
            self.tab = target
        }
        pump = Task { [weak self] in
            for await event in session.events { self?.handle(event, session: session) }
        }
        try await session.call("Page.enable")
        try await session.call("Page.startScreencast", ["format": "jpeg", "quality": 65, "maxWidth": .number(Double(maxWidth)),
                                                       "maxHeight": .number(Double(maxHeight)), "everyNthFrame": 1])
    }

    private func handle(_ event: CDPEvent, session: CDPSession) {
        switch event.method {
        case "Page.screencastFrame":
            if let sid = event.params["sessionId"]?.intValue { session.send("Page.screencastFrameAck", ["sessionId": .number(Double(sid))]) }
            guard let b64 = event.params["data"]?.stringValue, let jpeg = Data(base64Encoded: b64) else { return }
            let meta = event.params["metadata"] ?? .null
            let w = meta["deviceWidth"]?.doubleValue ?? 0, h = meta["deviceHeight"]?.doubleValue ?? 0
            lock.withLock { lastViewport = (w, h) }
            frameSink.yield(BrowserFrame(jpeg: jpeg, cssWidth: w, cssHeight: h, scrollY: meta["scrollOffsetY"]?.doubleValue ?? 0))
        case "Page.frameNavigated":
            let frame = event.params["frame"] ?? .null
            guard frame["parentId"] == nil, var tab = lock.withLock({ self.tab }) else { return }
            tab.url = frame["url"]?.stringValue ?? tab.url
            lock.withLock { self.tab = tab }
            changeSink.yield(tab)
        case "Page.domContentEventFired", "Page.loadEventFired":
            Task { [weak self] in
                guard let self, let s = self.lock.withLock({ self.session }) else { return }
                if let title = try? await s.call("Runtime.evaluate", ["expression": "document.title", "returnByValue": true])["result"]?["value"]?.stringValue,
                   var tab = self.lock.withLock({ self.tab }) {
                    tab.title = title
                    self.lock.withLock { self.tab = tab }
                    self.changeSink.yield(tab)
                }
            }
        default:
            break
        }
    }

    private func current() throws -> CDPSession {
        guard let s = lock.withLock({ session }), !s.closed else { throw CDPError.closed }
        return s
    }

    // MARK: Phone mode

    /// Lays the page out as a phone: `viewport` in CSS px, touch on, mobile user agent; reloads so
    /// the site serves its mobile layout. `mobile: false` keeps the desktop site at that size.
    public func enterPhoneMode(_ viewport: PhoneViewport) async throws {
        let s = try current()
        lock.withLock { phone = viewport }
        try await s.call("Emulation.setDeviceMetricsOverride", [
            "width": .number(Double(viewport.width)), "height": .number(Double(viewport.height)),
            "deviceScaleFactor": .number(viewport.scale), "mobile": .bool(viewport.mobile),
            "screenWidth": .number(Double(viewport.width)), "screenHeight": .number(Double(viewport.height)),
        ])
        try await s.call("Emulation.setTouchEmulationEnabled", ["enabled": true, "maxTouchPoints": 5])
        if viewport.mobile {
            try await s.call("Emulation.setUserAgentOverride", ["userAgent": .string(PhoneViewport.iPhoneUserAgent), "platform": "iPhone"])
        }
        try await s.call("Page.reload", [:])
    }

    /// Back to the desktop page the agent works with.
    public func leavePhoneMode() async {
        guard let s = lock.withLock({ session }), !s.closed else { return }
        let wasMobile = lock.withLock { () -> Bool in defer { phone = nil }; return phone?.mobile == true }
        _ = try? await s.call("Emulation.clearDeviceMetricsOverride")
        _ = try? await s.call("Emulation.setTouchEmulationEnabled", ["enabled": false])
        _ = try? await s.call("Emulation.setUserAgentOverride", ["userAgent": ""])
        if wasMobile { _ = try? await s.call("Page.reload", [:]) }
    }

    public var inPhoneMode: Bool { lock.withLock { phone != nil } }

    // MARK: Input (CSS pixel coordinates of the streamed viewport)

    public enum TouchPhase: String, Sendable { case start = "touchStart", move = "touchMove", end = "touchEnd", cancel = "touchCancel" }

    public func touch(_ phase: TouchPhase, points: [(x: Double, y: Double)]) {
        guard let s = try? current() else { return }
        let pts: [JSONValue] = phase == .end || phase == .cancel ? [] : points.map { ["x": .number($0.x), "y": .number($0.y)] }
        s.send("Input.dispatchTouchEvent", ["type": .string(phase.rawValue), "touchPoints": .array(pts)])
    }

    public func tap(x: Double, y: Double) {
        touch(.start, points: [(x, y)])
        touch(.end, points: [])
    }

    /// A click with the mouse (desktop pages not in phone mode).
    public func click(x: Double, y: Double) {
        guard let s = try? current() else { return }
        for type in ["mouseMoved", "mousePressed", "mouseReleased"] {
            var p: [String: JSONValue] = ["type": .string(type), "x": .number(x), "y": .number(y)]
            if type != "mouseMoved" { p["button"] = "left"; p["clickCount"] = 1 }
            s.send("Input.dispatchMouseEvent", p)
        }
    }

    public func scroll(x: Double, y: Double, deltaY: Double) {
        guard let s = try? current() else { return }
        s.send("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": .number(x), "y": .number(y), "deltaX": 0, "deltaY": .number(deltaY)])
    }

    /// Text typed on the phone's keyboard, into whatever field has focus.
    public func insert(text: String) {
        guard !text.isEmpty, let s = try? current() else { return }
        s.send("Input.insertText", ["text": .string(text)])
    }

    public enum Key: String, Sendable { case backspace, enter, tab, escape, left, right, up, down }

    public func press(_ key: Key) {
        guard let s = try? current() else { return }
        let (name, code, vk, text): (String, String, Int, String?) = {
            switch key {
            case .backspace: return ("Backspace", "Backspace", 8, nil)
            case .enter: return ("Enter", "Enter", 13, "\r")
            case .tab: return ("Tab", "Tab", 9, nil)
            case .escape: return ("Escape", "Escape", 27, nil)
            case .left: return ("ArrowLeft", "ArrowLeft", 37, nil)
            case .up: return ("ArrowUp", "ArrowUp", 38, nil)
            case .right: return ("ArrowRight", "ArrowRight", 39, nil)
            case .down: return ("ArrowDown", "ArrowDown", 40, nil)
            }
        }()
        var down: [String: JSONValue] = ["type": text == nil ? "rawKeyDown" : "keyDown", "key": .string(name), "code": .string(code),
                                         "windowsVirtualKeyCode": .number(Double(vk))]
        if let text { down["text"] = .string(text) }
        s.send("Input.dispatchKeyEvent", down)
        s.send("Input.dispatchKeyEvent", ["type": "keyUp", "key": .string(name), "code": .string(code), "windowsVirtualKeyCode": .number(Double(vk))])
    }

    /// Whether a text field has focus (so the phone raises its keyboard).
    public func editableFocused() async -> Bool {
        guard let s = try? current() else { return false }
        let r = try? await s.call("Runtime.evaluate", ["expression": .string(
            "(()=>{const e=document.activeElement;return !!e&&(e.isContentEditable||((e.tagName==='INPUT'||e.tagName==='TEXTAREA')&&!['button','submit','checkbox','radio','range','color','file','image','reset'].includes((e.type||'').toLowerCase())))})()"),
            "returnByValue": true])
        return r?["result"]?["value"]?.boolValue == true
    }

    /// Runs JavaScript in the page and returns its value.
    public func evaluate(_ expression: String) async throws -> JSONValue {
        let r = try await current().call("Runtime.evaluate", ["expression": .string(expression), "returnByValue": true, "awaitPromise": true])
        return r["result"]?["value"] ?? .null
    }

    // MARK: Navigation

    public func navigate(_ text: String) async throws {
        let s = try current()
        try await s.call("Page.navigate", ["url": .string(Self.url(from: text))])
    }

    public func reload() { (try? current())?.send("Page.reload") }

    public func goBack() async {
        guard let s = try? current(), let history = try? await s.call("Page.getNavigationHistory") else { return }
        let index = history["currentIndex"]?.intValue ?? 0
        guard index > 0, let entry = history["entries"]?.arrayValue?[index - 1], let id = entry["id"]?.intValue else { return }
        _ = try? await s.call("Page.navigateToHistoryEntry", ["entryId": .number(Double(id))])
    }

    /// What the address bar means: a URL, a bare domain, or a search.
    public static func url(from text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("about:") { return t }
        if !t.contains(" "), t.contains("."), !t.hasPrefix(".") { return "https://" + t }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        return "https://www.google.com/search?q=" + (t.addingPercentEncoding(withAllowedCharacters: allowed) ?? t)
    }

    /// Stops streaming and puts the page back the way the agent left it.
    public func stop() async {
        if inPhoneMode { await leavePhoneMode() }
        if let s = lock.withLock({ session }) { _ = try? await s.call("Page.stopScreencast", [:], timeout: 3) }
        close()
    }

    public func close() {
        pump?.cancel()
        pump = nil
        let s = lock.withLock { () -> CDPSession? in defer { session = nil }; return session }
        s?.close()
    }
}
