import Foundation
import IrohLib

public struct Identity: Sendable {
    public let secretKey: SecretKey
    public var endpointId: String { secretKey.public().description }

    public static func loadOrCreate(dir: URL) throws -> Identity {
        let keyFile = dir.appendingPathComponent("identity.key")
        // Generate only when no key exists. A key that exists but can't be
        // read (e.g. Data Protection while the machine is locked) must throw —
        // falling back to a fresh key would silently change the endpoint id.
        if FileManager.default.fileExists(atPath: keyFile.path) {
            let data = try Data(contentsOf: keyFile)
            return Identity(secretKey: try SecretKey.fromBytes(bytes: data))
        }
        let key = SecretKey.generate()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Key must stay readable while the machine is locked, or background
        // syncs die and restarts re-key.
        try key.toBytes().write(to: keyFile, options: .completeFileProtectionUntilFirstUserAuthentication)
        return Identity(secretKey: key)
    }
}
