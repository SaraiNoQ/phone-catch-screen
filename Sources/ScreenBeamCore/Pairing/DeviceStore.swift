import Foundation

/// A phone that has completed pairing.
///
/// The token itself is never stored — only its SHA-256. The phone holds the
/// plaintext; this side can verify a presented token but cannot reproduce it, so
/// a leaked `devices.json` does not hand over access.
public struct PairedDevice: Codable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public let tokenHash: String
    public let createdAt: Date
    public var lastSeenAt: Date?
    public var userAgent: String?

    /// Outward-facing shape. Deliberately omits `tokenHash`.
    public var json: [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "name": name,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
        ]
        if let lastSeenAt {
            object["lastSeenAt"] = ISO8601DateFormatter().string(from: lastSeenAt)
        }
        if let userAgent {
            object["userAgent"] = userAgent
        }
        return object
    }
}

/// Persisted set of paired devices.
public final class DeviceStore: @unchecked Sendable {
    /// Keeps the file bounded; pairing is a rare, deliberate act.
    public static let maxDevices = 16

    private let lock = NSLock()
    private var devices: [PairedDevice] = []

    /// Where the credentials live. Exposed because it is genuinely useful to
    /// report (backup, audit, troubleshooting) — not just for tests.
    public let fileURL: URL

    private struct Envelope: Codable {
        var version: Int
        var devices: [PairedDevice]
    }

    public init(fileURL: URL = BeamPaths.devicesFile) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Reads

    public func all() -> [PairedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return devices
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return devices.isEmpty
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return devices.count
    }

    public func device(id: String) -> PairedDevice? {
        lock.lock()
        defer { lock.unlock() }
        return devices.first { $0.id == id }
    }

    /// Looks a presented token up by hashing it. Returns nil for anything unknown.
    public func device(forToken token: String) -> PairedDevice? {
        let hash = SecureToken.sha256Hex(SecureToken.normalize(token))

        lock.lock()
        defer { lock.unlock() }
        // The comparison is against a stored hash, so a plain equality check
        // leaks nothing useful — but the constant-time helper costs nothing and
        // keeps the habit consistent.
        return devices.first { SecureToken.constantTimeEquals($0.tokenHash, hash) }
    }

    // MARK: - Writes

    public enum StoreError: Error, CustomStringConvertible {
        case tooManyDevices(Int)

        public var description: String {
            switch self {
            case .tooManyDevices(let limit):
                return "已配对设备达到上限（\(limit) 台），请先解除不再使用的设备。"
            }
        }
    }

    /// Creates a device and returns the plaintext token **exactly once** — it is
    /// not recoverable afterwards.
    @discardableResult
    public func add(name: String, userAgent: String?) throws -> (device: PairedDevice, token: String) {
        let token = SecureToken.hex(bytes: 32)
        let device = PairedDevice(
            // Short random id, plus a readable prefix so it is obvious in a log.
            id: "d-" + SecureToken.hex(bytes: 4),
            name: name.isEmpty ? "未命名设备" : name,
            tokenHash: SecureToken.sha256Hex(SecureToken.normalize(token)),
            createdAt: Date(),
            lastSeenAt: nil,
            userAgent: userAgent
        )

        lock.lock()
        guard devices.count < Self.maxDevices else {
            lock.unlock()
            throw StoreError.tooManyDevices(Self.maxDevices)
        }
        devices.append(device)
        let snapshot = devices
        lock.unlock()

        save(snapshot)
        return (device, token)
    }

    /// Records activity. Deliberately does not persist on every request — the
    /// timestamp is only for display, and writing on each call would turn a
    /// read-only poll into disk I/O.
    public func touch(id: String) {
        lock.lock()
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].lastSeenAt = Date()
        }
        lock.unlock()
    }

    @discardableResult
    public func revoke(id: String) -> Bool {
        lock.lock()
        let before = devices.count
        devices.removeAll { $0.id == id }
        let removed = devices.count != before
        let snapshot = devices
        lock.unlock()

        if removed { save(snapshot) }
        return removed
    }

    public func revokeAll() {
        lock.lock()
        devices.removeAll()
        lock.unlock()
        save([])
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            Log.warn("devices.json 解析失败，按空设备列表处理：\(fileURL.path)")
            return
        }
        devices = envelope.devices
    }

    private func save(_ snapshot: [PairedDevice]) {
        do {
            try BeamPaths.ensureDirectories()
            let envelope = Envelope(version: 1, devices: snapshot)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(envelope)
            try data.write(to: fileURL, options: .atomic)

            // Credentials on disk: owner-only. `Data.write` creates with the
            // process umask, which is normally fine but not guaranteed.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            Log.error("写入 devices.json 失败：\(error)")
        }
    }
}
