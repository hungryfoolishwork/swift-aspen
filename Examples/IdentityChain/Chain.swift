import Foundation
import CryptoKit

/// One signed enrollment: whoever holds `parent` vouches that the device
/// holding `child` (reachable at endpoint `device`) belongs to this identity.
/// The first link in a chain is signed by the root; every later link is
/// signed by an already-enrolled device's key.
struct Link: Codable, Sendable {
    var parent: Data     // signer's public key
    var child: Data      // the enrolled device's signing public key
    var device: String   // the enrolled device's endpoint id
    var seq: UInt64
    var signature: Data

    static func message(parent: Data, child: Data, device: String, seq: UInt64) -> Data {
        var m = Data("example-identitychain/link/0".utf8)  // domain separation
        m.append(parent)
        m.append(child)
        m.append(Data(device.utf8))
        withUnsafeBytes(of: seq.bigEndian) { m.append(contentsOf: $0) }
        return m
    }

    func verifies() -> Bool {
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: parent) else {
            return false
        }
        return pub.isValidSignature(
            signature,
            for: Self.message(parent: parent, child: child, device: device, seq: seq)
        )
    }
}

/// A signed, self-authenticating statement that a device key is burned.
/// Revocation is permanent and timeless — no "valid until", no un-revoke, a
/// recovered device re-enrolls with a fresh key — which is what lets it work
/// without any global ordering. Whether a revocation MATTERS is decided per
/// chain at verification time (see DeviceChain.verifies): only the root or
/// an ancestor on that chain carries authority.
struct Revocation: Codable, Sendable, Equatable {
    var signer: Data   // root key or an ancestor device key
    var revoked: Data  // the device signing key being burned
    var seq: UInt64
    var signature: Data

    static func message(signer: Data, revoked: Data, seq: UInt64) -> Data {
        var m = Data("example-identitychain/revocation/0".utf8)  // domain separation
        m.append(signer)
        m.append(revoked)
        withUnsafeBytes(of: seq.bigEndian) { m.append(contentsOf: $0) }
        return m
    }

    func verifies() -> Bool {
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: signer) else {
            return false
        }
        return pub.isValidSignature(
            signature,
            for: Self.message(signer: signer, revoked: revoked, seq: seq)
        )
    }
}

/// A device's proof of membership: links from the root down to this device.
/// The first link's parent IS the root public key — the human's stable id.
/// Unlike the direct-signing example, verifying means walking the whole
/// chain, and trust is transitive: every device on the path vouched for the
/// next one.
struct DeviceChain: Codable, Sendable {
    var links: [Link]

    var rootKey: Data? { links.first?.parent }
    var rootId: String? { rootKey?.hexString }

    /// Every signature valid, every link's parent is the previous link's
    /// child, and the final link names `device` — binding the whole chain to
    /// the authenticated sender so it can't be replayed by another endpoint.
    ///
    /// Revocation authority is path-relative and flows only downward: a
    /// revocation of a key on this chain counts only if its signer appears
    /// EARLIER on this same chain (or is the root). Ancestors can cut off
    /// what they vouched for; descendants, siblings, and strangers cannot
    /// touch what's above them — so a stolen leaf can't revoke the tree, and
    /// a revoked device's own revocations die with its place on the path.
    /// The remaining honest limits: a revocation only protects peers it has
    /// reached, and a compromised root/founder is unrecoverable.
    func verifies(for device: String, revocations: [Revocation] = []) -> Bool {
        guard let first = links.first, let last = links.last else { return false }
        guard last.device == device else { return false }
        var expectedParent = first.parent
        var authorized = [first.parent]  // grows as the walk descends
        for link in links {
            guard link.parent == expectedParent, link.verifies() else { return false }
            let cut = revocations.contains { r in
                r.revoked == link.child && authorized.contains(r.signer) && r.verifies()
            }
            if cut { return false }
            authorized.append(link.child)
            expectedParent = link.child
        }
        return true
    }
}

/// What a new device hands an enrolled one to ask in: public material only.
struct EnrollmentRequest: Codable, Sendable {
    var device: String  // endpoint id
    var key: Data       // device signing public key
}

/// What comes back: the approver's chain extended with a link for the new
/// device. Still public material only — no secret ever moves.
struct EnrollmentGrant: Codable, Sendable {
    var chain: DeviceChain
}

enum ChainError: Error {
    case noRoot
    case badBlob
    case notEnrolled
    case selfEnrollment
    case notForThisDevice
    case unknownDevice
}

/// This device's signing key (distinct from the iroh endpoint key — the
/// transport key shouldn't double as the identity key) plus, on the founding
/// device only, the root secret. Enrollment never moves the root: after
/// signing the first link it could even be deleted, at the cost of never
/// founding another chain.
struct Keyring {
    let dir: URL
    private(set) var deviceKey: Curve25519.Signing.PrivateKey
    private(set) var rootKey: Curve25519.Signing.PrivateKey?
    private var nextSeq: UInt64

    var devicePublicKey: Data { deviceKey.publicKey.rawRepresentation }

    private struct SavedAs: Codable {
        var deviceKey: Data
        var rootKey: Data?
        var nextSeq: UInt64
    }

    static func loadOrCreate(dir: URL) throws -> Keyring {
        let file = dir.appendingPathComponent("keyring.json")
        // Generate only when no keyring exists — an unreadable one must throw,
        // not silently re-key the device.
        if FileManager.default.fileExists(atPath: file.path) {
            let stored = try JSONDecoder().decode(SavedAs.self, from: try Data(contentsOf: file))
            return Keyring(
                dir: dir,
                deviceKey: try Curve25519.Signing.PrivateKey(rawRepresentation: stored.deviceKey),
                rootKey: try stored.rootKey.map { try Curve25519.Signing.PrivateKey(rawRepresentation: $0) },
                nextSeq: stored.nextSeq
            )
        }
        let keyring = Keyring(dir: dir, deviceKey: .init(), rootKey: .init(), nextSeq: 1)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try keyring.save()
        return keyring
    }

    /// The one and only use of the root secret: certify the founding device.
    mutating func selfChain(device: String) throws -> DeviceChain {
        guard let rootKey else { throw ChainError.noRoot }
        let parent = rootKey.publicKey.rawRepresentation
        let seq = nextSeq
        nextSeq += 1
        try save()
        let message = Link.message(parent: parent, child: devicePublicKey, device: device, seq: seq)
        return DeviceChain(links: [Link(
            parent: parent,
            child: devicePublicKey,
            device: device,
            seq: seq,
            signature: try rootKey.signature(for: message)
        )])
    }

    /// Extend my chain to vouch for a new device — signed with the device
    /// key. The root secret is not needed and usually not present.
    mutating func extend(_ chain: DeviceChain, to request: EnrollmentRequest) throws -> DeviceChain {
        let seq = nextSeq
        nextSeq += 1
        try save()
        let message = Link.message(parent: devicePublicKey, child: request.key, device: request.device, seq: seq)
        return DeviceChain(links: chain.links + [Link(
            parent: devicePublicKey,
            child: request.key,
            device: request.device,
            seq: seq,
            signature: try deviceKey.signature(for: message)
        )])
    }

    /// Burn a key. Signed with the root secret when we hold the root of our
    /// own chain (authorized against every chain of this identity), otherwise
    /// with the device key (authorized only for devices enrolled below us).
    mutating func revoke(key revoked: Data, chainRoot: Data?) throws -> Revocation {
        let signingKey: Curve25519.Signing.PrivateKey
        if let rootKey, rootKey.publicKey.rawRepresentation == chainRoot {
            signingKey = rootKey
        } else {
            signingKey = deviceKey
        }
        let signer = signingKey.publicKey.rawRepresentation
        let seq = nextSeq
        nextSeq += 1
        try save()
        let message = Revocation.message(signer: signer, revoked: revoked, seq: seq)
        return Revocation(
            signer: signer,
            revoked: revoked,
            seq: seq,
            signature: try signingKey.signature(for: message)
        )
    }

    private func save() throws {
        let stored = SavedAs(
            deviceKey: deviceKey.rawRepresentation,
            rootKey: rootKey?.rawRepresentation,
            nextSeq: nextSeq
        )
        // Not .completeFileProtection: must stay readable while the machine
        // is locked, or background syncs die and restarts re-key.
        try JSONEncoder().encode(stored)
            .write(
                to: dir.appendingPathComponent("keyring.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
