import Crypto
import Foundation
import NIOSSH

/// The phone's SSH identity: an Ed25519 key generated on the device.
///
/// The private half is only ever held in memory here and persisted by the app
/// in the Keychain (`rawRepresentation`); the public half is what the user adds
/// to `~/.ssh/authorized_keys` on the server.
public struct SSHIdentity: @unchecked Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    /// A brand-new random identity.
    public static func generate() -> SSHIdentity {
        SSHIdentity(privateKey: Curve25519.Signing.PrivateKey())
    }

    /// Restores an identity from the 32-byte raw private key the app stored.
    public init(rawRepresentation: Data) throws {
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { privateKey.rawRepresentation }

    var nioPrivateKey: NIOSSHPrivateKey { NIOSSHPrivateKey(ed25519Key: privateKey) }

    /// `ssh-ed25519 AAAA… <comment>` — one line for `authorized_keys`.
    public func authorizedKeysLine(comment: String = "brainbox-mobile") -> String {
        let base = String(openSSHPublicKey: nioPrivateKey.publicKey)
        let safe = comment.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return safe.isEmpty ? base : base + " " + safe
    }

    /// `SHA256:…` fingerprint, the same text `ssh-keygen -lf` prints.
    public var fingerprint: String { SSHFingerprint.of(openSSHKey: String(openSSHPublicKey: nioPrivateKey.publicKey)) }
}

public enum SSHFingerprint {
    /// OpenSSH-style `SHA256:<base64 without padding>` of a key's wire blob.
    public static func of(openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "SHA256:?" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}
