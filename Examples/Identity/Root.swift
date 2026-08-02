import Foundation
import CryptoKit

/// The human's long-lived signing key. It never dials or answers on the
/// network — its only job is to certify device endpoints as "mine". The
/// public key is the human's stable identifier; devices come and go
/// underneath it.
///
/// This example uses direct signing: the root secret must be present on a
/// device to certify it, and moves between devices via export/import.
struct Root {
    let dir: URL
    private(set) var key: Curve25519.Signing.PrivateKey
    private var nextSeq: UInt64

    var id: String { publicKeyData.hexString }
    var publicKeyData: Data { key.publicKey.rawRepresentation }

    /// The secret, base64-encoded for hand-carrying to another device.
    var export: String { key.rawRepresentation.base64EncodedString() }

    enum RootError: Error {
        case badTransfer
    }

    private struct SavedAs: Codable {
        var key: Data
        var nextSeq: UInt64
    }

    static func loadOrCreate(dir: URL) throws -> Root {
        let file = dir.appendingPathComponent("root.json")
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode(SavedAs.self, from: data),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: stored.key) {
                return Root(dir: dir, key: key, nextSeq: stored.nextSeq)
        }
        let root = Root(dir: dir, key: .init(), nextSeq: 1)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try root.save()
        return root
    }

    static func adopt(_ transfer: String, dir: URL) throws -> Root {
        let trimmed = transfer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: trimmed) else {
            throw RootError.badTransfer
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        let root = Root(dir: dir, key: key, nextSeq: 1)
        try root.save()
        return root
    }

    mutating func certify(device: String) throws -> DeviceCert {
        let seq = nextSeq
        nextSeq += 1
        try save()
        let message = DeviceCert.message(root: publicKeyData, device: device, seq: seq)
        return DeviceCert(
            root: publicKeyData,
            device: device,
            seq: seq,
            signature: try key.signature(for: message)
        )
    }

    private func save() throws {
        let stored = SavedAs(key: key.rawRepresentation, nextSeq: nextSeq)
        try JSONEncoder().encode(stored)
            .write(
                to: dir.appendingPathComponent("root.json"),
                options: [.atomic, .completeFileProtection]
            )
    }
}

/// A root's signed statement that a device endpoint belongs to it. Rides
/// along in gossiped state so peers can group devices by human instead of
/// taking the claim on faith. `seq` orders certs for the same device — a
/// re-issued cert supersedes older ones, which is the hook revocation would
/// hang off of.
struct DeviceCert: Codable, Sendable {
    var root: Data      // root public key, raw bytes
    var device: String  // the endpoint id this cert binds to
    var seq: UInt64
    var signature: Data

    var rootId: String { root.hexString }

    static func message(root: Data, device: String, seq: UInt64) -> Data {
        var m = Data("root/device-cert/0".utf8)  // domain separation
        m.append(root)
        m.append(Data(device.utf8))
        withUnsafeBytes(of: seq.bigEndian) { m.append(contentsOf: $0) }
        return m
    }

    /// Valid only if the signature checks out AND the cert names `device` —
    /// binding to the authenticated sender is what stops a peer replaying
    /// someone else's cert as its own.
    func verifies(for device: String) -> Bool {
        guard self.device == device, let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: root) else {
            return false
        }
        return pub.isValidSignature(signature, for: Self.message(root: root, device: device, seq: seq))
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
