import Foundation

/// Serialises access to a resource from async contexts.
///
/// `actor` alone is not enough: an actor method that `await`s is re-entrant, so
/// two concurrent captures would still overlap. This holds an explicit queue of
/// continuations instead, which is what we want for the capture path.
public actor AsyncMutex {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // Resume exactly one waiter and keep the lock held on its behalf.
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` with the lock held, releasing it even if `body` throws.
    public func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
