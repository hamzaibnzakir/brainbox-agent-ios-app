import SwiftUI
import LocalAuthentication
import Network
import BrainboxCore

/// Face ID / Touch ID / passcode gate for sensitive actions and app lock.
@MainActor
@Observable
final class BiometricGate {
    private(set) var isLocked = false
    private(set) var lastAuthenticatedAt: Date?
    var lastErrorMessage: String?

    private let policyProvider: () -> SecurityPolicy
    private let bypass: Bool
    private var backgroundedAt: Date?
    private var inFlight = false

    init(policy: @escaping () -> SecurityPolicy, bypass: Bool) {
        self.policyProvider = policy
        self.bypass = bypass
    }

    var biometryName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return "Passcode" }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    var biometrySymbol: String {
        switch biometryName {
        case "Face ID": return "faceid"
        case "Touch ID": return "touchid"
        case "Optic ID": return "opticid"
        default: return "lock.fill"
        }
    }

    /// Returns true when the action may proceed.
    func authorize(_ action: SensitiveAction) async -> Bool {
        if bypass { return true }
        guard policyProvider().requiresAuthentication(for: action, lastAuthenticatedAt: lastAuthenticatedAt) else { return true }
        return await evaluate(reason: action.reason)
    }

    func noteBackgrounded() {
        backgroundedAt = Date()
    }

    func noteForegrounded() {
        if !bypass, policyProvider().shouldLock(backgroundedAt: backgroundedAt) {
            isLocked = true
        }
        backgroundedAt = nil
    }

    func lockNow() {
        guard !bypass, policyProvider().biometricsEnabled else { return }
        isLocked = true
    }

    func unlock() async {
        if await evaluate(reason: "Unlock Brainbox Agent") {
            withAnimation(Motion.gentle) { isLocked = false }
        }
    }

    private func evaluate(reason: String) async -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        defer { inFlight = false }
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        var error: NSError?
        // .deviceOwnerAuthentication = biometrics with passcode fallback.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastErrorMessage = "This device has no passcode or biometrics set up, so sensitive actions can't be confirmed. Set a passcode in iOS Settings, or turn off \(biometryName) protection in Settings → Security."
            return false
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok {
                lastAuthenticatedAt = Date()
                lastErrorMessage = nil
            }
            return ok
        } catch {
            let code = (error as? LAError)?.code
            if code != .userCancel && code != .appCancel && code != .systemCancel {
                lastErrorMessage = error.localizedDescription
            }
            return false
        }
    }
}

/// Publishes connectivity so the app can show offline state, keep cached
/// data visible and reconnect the moment the network returns.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    private(set) var isExpensive = false
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.brainbox.network")
    var onReconnect: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor in
                guard let self else { return }
                let cameBack = online && !self.isOnline
                self.isOnline = online
                self.isExpensive = expensive
                if cameBack { self.onReconnect?() }
            }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}
