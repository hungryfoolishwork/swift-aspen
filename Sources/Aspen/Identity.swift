import Foundation
import IrohLib

public struct Identity: Sendable {
    public let secretKey: SecretKey
    public var endpointId: String { secretKey.public().description }

    public static func loadOrCreate(dir: URL) throws -> Identity {
        let keyFile = dir.appendingPathComponent("identity.key")
        if let data = try? Data(contentsOf: keyFile),
           let key = try? SecretKey.fromBytes(bytes: data) {
            return Identity(secretKey: key)
        }
        let key = SecretKey.generate()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try key.toBytes().write(to: keyFile, options: .completeFileProtection)
        return Identity(secretKey: key)
    }
}
