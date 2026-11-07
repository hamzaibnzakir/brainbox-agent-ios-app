import BrainboxCore
import Foundation
import HermesKit
import Observation
import UIKit
import WebKit

/// One live view of Hermes' Bot Screen: the ticketed RFB socket (through SSH), the noVNC page
/// that draws it, and who holds control.
///
/// Bytes never touch the network from the web view: Swift owns the socket and passes RFB to the
/// page as base64 (`BBViewer.recv`), and the page hands keyboard/pointer bytes back through the
/// `bb` message handler (see scripts/novnc/viewer-entry.js). Hermes enforces control itself: it
/// drops input from any viewer that doesn't hold the lease, so "watching" can never type.
@MainActor
@Observable
final class ScreenSession {
    enum Phase: Equatable {
        case checking
        /// Hermes too old, or the host has a real display.
        case unsupported(String)
        /// TigerVNC/Xfce aren't on the server yet.
        case notInstalled(command: String?, missing: [String])
        /// Installed but off. `blocker` says why Start would refuse (low memory).
        case stopped(blocker: String?)
        case starting
        case connecting
        case live
        case failed(String)
    }

    var phase: Phase = .checking
    var status: ScreenStatus?
    var lease = ScreenLease()
    /// This viewer took control on the current connection.
    var inControl = false
    var busy = false
    var notice: String?
    var fitToScreen = true

    /// Someone else (Hermes Desktop, another phone) holds control.
    var someoneElseInControl: Bool { lease.holder == .human && !inControl }

    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var screen: BotScreen?
    @ObservationIgnored private var socket: TunnelWebSocket?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var viewerID: String?
    @ObservationIgnored private var viewerClient: ObjectIdentifier?
    @ObservationIgnored private var pageReady = false
    @ObservationIgnored private var viewerStarted = false
    @ObservationIgnored private var inbox: [String] = []
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var reconnects = 0

    // MARK: Lifecycle

    func open(model: AppModel) async {
        self.model = model
        closing = false
        if AppModel.isDemo {
            // No server in demo mode: show the screen as installed and off.
            status = ScreenStatus(installed: true, running: false)
            phase = .stopped(blocker: nil)
            return
        }
        await refresh()
        if status?.running == true, socket == nil { await connect() }
    }

    /// Leaving the screen closes the socket cleanly, which hands control back to Hermes if this
    /// viewer held it (a dropped link would keep it, by Hermes' design).
    func close() {
        closing = true
        pump?.cancel()
        pump = nil
        if let socket {
            self.socket = nil
            Task { await socket.close(code: 1000, reason: "viewer closed") }
        }
        js("BBViewer.stop()")
        viewerStarted = false
        inControl = false
    }

    func refresh() async {
        guard let model else { return }
        do {
            let client = try await model.client()
            let screen = client.screen
            self.screen = screen
            apply(try await screen.status())
        } catch {
            fail(error)
        }
    }

    private func apply(_ status: ScreenStatus) {
        self.status = status
        lease = status.lease
        if lease.holder == .agent { inControl = false }
        if !status.supported {
            phase = .unsupported(ScreenError.unsupportedHost.localizedDescription)
        } else if !status.installed {
            phase = .notInstalled(command: status.installCommand, missing: status.missing)
        } else if !status.running {
            phase = .stopped(blocker: status.blocker)
            dropSocket()
        } else if case .live = phase {
            // keep
        } else if socket == nil, case .connecting = phase {
            // connect() is on its way
        } else if socket == nil {
            phase = .connecting
        }
    }

    private func fail(_ error: Error) {
        if let screenError = error as? ScreenError, screenError == .unsupportedHermes {
            phase = .unsupported(screenError.localizedDescription)
        } else if let screenError = error as? ScreenError, screenError == .notRunning {
            phase = .stopped(blocker: nil)
        } else {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: Screen on / off

    func startScreen() async {
        guard let screen, !busy else { return }
        busy = true
        defer { busy = false }
        phase = .starting
        do {
            apply(try await screen.start())
            await connect()
        } catch {
            fail(error)
        }
    }

    func stopScreen() async {
        guard let screen, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            close()
            closing = false
            apply(try await screen.stop(force: someoneElseInControl))
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: Socket

    func connect() async {
        guard let model, !closing else { return }
        do {
            let client = try await model.client()
            // Viewer ids belong to one gateway connection; after a reconnect Hermes mints a new one.
            if viewerClient != ObjectIdentifier(client) {
                viewerID = nil
                inControl = false
                viewerClient = ObjectIdentifier(client)
            }
            let screen = client.screen
            self.screen = screen
            phase = .connecting
            let ticket = try await screen.observe(viewerID: viewerID)
            viewerID = ticket.viewerID
            apply(ticket.status)
            if lease.holder == .agent { inControl = false }
            let socket = try await screen.openStream(ticket)
            dropSocket()
            self.socket = socket
            viewerStarted = false
            inbox.removeAll()
            pump = Task { [weak self] in await self?.read(socket) }
            startViewerIfReady()
        } catch {
            fail(error)
        }
    }

    private func read(_ socket: TunnelWebSocket) async {
        var code = 1000
        var reason = ""
        do {
            for try await frame in socket.frames {
                if case .binary(let data) = frame { deliver(data.base64EncodedString()) }
            }
        } catch WebSocketError.closed(let c, let r) {
            code = c
            reason = r
        } catch {
            code = 1006
            reason = error.localizedDescription
        }
        ended(socket, code: code, reason: reason)
    }

    private func ended(_ ended: TunnelWebSocket, code: Int, reason: String) {
        guard socket === ended else { return }
        socket = nil
        js("BBViewer.closed(\(code), '')")
        viewerStarted = false
        guard !closing else { return }
        switch ScreenError.fromClose(code: code, reason: reason) {
        case .controlTaken?:
            inControl = false
            notice = ScreenError.controlTaken.localizedDescription
            Task { await connect() }
        case .screenGone?:
            phase = .stopped(blocker: nil)
            Task { await refresh() }
        case .ticketRejected?, nil:
            // A spent ticket or a clean server close: fetch a fresh ticket, but don't loop forever.
            reconnects += 1
            if reconnects <= 3 { Task { await connect() } } else { phase = .failed(ScreenError.ticketRejected.localizedDescription) }
        case .some(let error):
            phase = .failed(error.localizedDescription)
        }
    }

    private func dropSocket() {
        pump?.cancel()
        pump = nil
        if let socket {
            self.socket = nil
            socket.close()
        }
    }

    // MARK: Bridge (page <-> socket)

    func pageDidLoad() {
        pageReady = true
        startViewerIfReady()
    }

    private func startViewerIfReady() {
        guard pageReady, socket != nil, !viewerStarted else { return }
        viewerStarted = true
        js("BBViewer.stop(); BBViewer.start({viewOnly: \(inControl ? "false" : "true")}); BBViewer.setScale(\(fitToScreen))")
        let queued = inbox
        inbox.removeAll()
        for chunk in queued { js("BBViewer.recv('\(chunk)')") }
    }

    private func deliver(_ base64: String) {
        if viewerStarted { js("BBViewer.recv('\(base64)')") } else { inbox.append(base64) }
    }

    /// A message from the page (`window.webkit.messageHandlers.bb`).
    func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            pageDidLoad()
        case "send":
            guard let text = message["data"] as? String, let data = Data(base64Encoded: text) else { return }
            if socket?.enqueue(binary: data) != true, inControl {
                notice = "Lost the screen connection — that input didn't arrive."
            }
        case "close":
            if let socket {
                self.socket = nil
                Task { await socket.close(code: 1000) }
            }
        case "state":
            switch message["state"] as? String {
            case "connected":
                phase = .live
                reconnects = 0
            case "failed":
                phase = .failed((message["reason"] as? String) ?? "The screen viewer failed.")
            default:
                break
            }
        default:
            break
        }
    }

    private func js(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: Control

    /// Take over: your touches and typing drive the screen; Hermes' browser and computer tools
    /// stop until you hand back.
    func takeOver() async {
        guard let screen, !busy else { return }
        if model?.preferences.lockWithFaceID == true,
           !(await Biometrics.authenticate(reason: "Take control of Hermes' screen")) {
            notice = "Face ID is needed to take control."
            return
        }
        busy = true
        defer { busy = false }
        do {
            guard let viewerID else { throw ScreenError.staleViewer }
            lease = try await screen.takeOver(viewerID: viewerID)
            inControl = true
            js("BBViewer.setViewOnly(false)")
            Haptic.success()
        } catch ScreenError.staleViewer {
            notice = ScreenError.staleViewer.localizedDescription
            await connect()
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Hand back to Hermes. `force` clears a hold left by another viewer or an earlier connection.
    func handBack(force: Bool = false) async {
        guard let screen, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            lease = try await screen.handBack(viewerID: force ? nil : viewerID, force: force)
            inControl = false
            js("BBViewer.setViewOnly(true)")
            Haptic.tap()
        } catch ScreenError.staleViewer {
            notice = "This phone's hold is from an earlier connection. Use Hand back (force)."
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Lease and screen changes made anywhere (Hermes Desktop, another phone, the server).
    func handle(_ event: GatewayEvent) {
        guard let screenEvent = ScreenEvent(event) else { return }
        switch screenEvent {
        case .lease(_, let new):
            lease = new
            if new.holder == .agent, inControl {
                inControl = false
                js("BBViewer.setViewOnly(true)")
            }
        case .status(let new):
            apply(new)
            if new.running, socket == nil, !closing, !busy { Task { await connect() } }
        }
    }

    // MARK: Input from the phone's keyboard bar

    func type(_ text: String) {
        guard inControl, !text.isEmpty else { return }
        js("BBViewer.type(\(Self.jsString(text)))")
    }

    func key(_ name: String) {
        guard inControl else { return }
        js("BBViewer.key(\(Self.jsString(name)))")
    }

    func paste(_ text: String) {
        guard inControl, !text.isEmpty else { return }
        js("BBViewer.paste(\(Self.jsString(text)))")
    }

    func setFit(_ fit: Bool) {
        fitToScreen = fit
        js("BBViewer.setScale(\(fit))")
    }

    /// A JavaScript string literal (JSON-escaped).
    static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}

/// Receives the page's messages. A separate object so the web view doesn't retain the session.
final class ScreenBridge: NSObject, WKScriptMessageHandler {
    weak var session: ScreenSession?

    init(session: ScreenSession) {
        self.session = session
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { session?.receive(body) }
    }
}
