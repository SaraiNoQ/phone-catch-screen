import Foundation

/// Bounded, newest-first buffer of recent frames.
///
/// Memory is bounded by `capacity`, which matters because each Retina frame at
/// the default settings is a few hundred kilobytes and the daemon may run for
/// weeks. Disk history is opt-in and pruned by age.
public final class ShotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var shots: [Shot] = []
    private var addsSincePrune = 0

    private let capacity: Int
    private let saveDirectory: URL?
    private let retentionMinutes: Int
    private let fileQueue = DispatchQueue(label: "com.sarainoq.screenbeam.store.files", qos: .utility)

    /// Pruning walks a directory, so it runs every N captures rather than on each one.
    private static let pruneInterval = 20

    public init(capacity: Int, saveDirectory: String?, retentionMinutes: Int) {
        self.capacity = max(1, capacity)
        self.saveDirectory = saveDirectory.flatMap { path -> URL? in
            let expanded = (path as NSString).expandingTildeInPath
            guard !expanded.isEmpty else { return nil }
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        self.retentionMinutes = max(1, retentionMinutes)

        if let directory = self.saveDirectory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            Log.info("截图历史将保存到：\(directory.path)")
        }
    }

    public func nextID(for date: Date = Date()) -> String {
        ShotID.make(date: date)
    }

    public func add(_ shot: Shot) {
        lock.lock()
        shots.insert(shot, at: 0)
        if shots.count > capacity {
            shots.removeLast(shots.count - capacity)
        }
        addsSincePrune += 1
        let shouldPrune = addsSincePrune >= Self.pruneInterval
        if shouldPrune { addsSincePrune = 0 }
        lock.unlock()

        persist(shot)

        if shouldPrune, let directory = saveDirectory {
            let retention = retentionMinutes
            fileQueue.async { Self.prune(directory: directory, retentionMinutes: retention) }
        }
    }

    public func latest() -> Shot? {
        lock.lock()
        defer { lock.unlock() }
        return shots.first
    }

    public func shot(id: String) -> Shot? {
        lock.lock()
        defer { lock.unlock() }
        return shots.first { $0.id == id }
    }

    /// Newest first, metadata only — used by the `/api/frames` listing.
    public func recent(limit: Int) -> [Shot] {
        lock.lock()
        defer { lock.unlock() }
        return Array(shots.prefix(max(0, limit)))
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return shots.count
    }

    // MARK: - Disk history

    private func persist(_ shot: Shot) {
        guard let directory = saveDirectory else { return }
        let url = directory
            .appendingPathComponent(shot.id)
            .appendingPathExtension(shot.format.fileExtension)
        let payload = shot.payload
        fileQueue.async {
            do {
                try payload.write(to: url, options: .atomic)
            } catch {
                Log.warn("写入截图文件失败：\(error)")
            }
        }
    }

    private static func prune(directory: URL, retentionMinutes: Int) {
        let cutoff = Date().addingTimeInterval(-Double(retentionMinutes) * 60)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return }

        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
