import Foundation

public struct PairingCode: Sendable {
    public let value: String
    public let expiresAt: Date

    public var remainingSeconds: Int {
        max(0, Int(expiresAt.timeIntervalSinceNow.rounded()))
    }

    public var json: [String: Any] {
        [
            "code": value,
            "expiresAt": ISO8601DateFormatter().string(from: expiresAt),
            "expiresInSeconds": remainingSeconds,
        ]
    }
}

/// Issues and redeems the short numeric code used to bring a new phone in.
///
/// The threat to design against is a brute force from elsewhere on the LAN: a
/// six-digit code is only a million possibilities, which is trivial to exhaust
/// if you can guess freely. So the code is single-use, short-lived, and burns
/// itself after a handful of wrong answers.
public final class PairingSession: @unchecked Sendable {
    public enum Redeem: Equatable {
        case ok
        case noCode
        case expired
        case tooManyAttempts
        /// Wrong code. `remaining` is how many tries this caller has left.
        case mismatch(remaining: Int)
    }

    private let lock = NSLock()

    private var code: String?
    private var expiresAt: Date?
    /// Set when the code is destroyed by excessive guessing, so the caller gets a
    /// meaningful error instead of "no code".
    private var burned = false

    private var failuresByPeer: [String: Int] = [:]
    private var totalFailures = 0

    private let digitCount: Int
    private let ttl: TimeInterval
    private let maxFailuresPerPeer: Int
    /// Backstop against an attacker rotating source addresses to sidestep the
    /// per-peer budget.
    private let maxTotalFailures: Int

    public init(
        digits: Int = 6,
        ttl: TimeInterval = 300,
        maxFailuresPerPeer: Int = 5,
        maxTotalFailures: Int = 50
    ) {
        self.digitCount = digits
        self.ttl = ttl
        self.maxFailuresPerPeer = maxFailuresPerPeer
        self.maxTotalFailures = maxTotalFailures
    }

    // MARK: - Issue

    /// Issues a fresh code, replacing and invalidating any previous one.
    @discardableResult
    public func issue() -> PairingCode {
        let value = SecureToken.digits(digitCount)
        let expiry = Date().addingTimeInterval(ttl)

        lock.lock()
        code = value
        expiresAt = expiry
        burned = false
        failuresByPeer.removeAll()
        totalFailures = 0
        lock.unlock()

        return PairingCode(value: value, expiresAt: expiry)
    }

    /// The code currently on offer, or nil when there is none / it has expired.
    public func current() -> PairingCode? {
        lock.lock()
        defer { lock.unlock() }

        guard let offered = code, let expiry = expiresAt, !burned else { return nil }
        guard Date() < expiry else {
            clearLocked()
            return nil
        }
        return PairingCode(value: offered, expiresAt: expiry)
    }

    public var hasPendingCode: Bool {
        current() != nil
    }

    // MARK: - Redeem

    public func redeem(_ candidate: String, peer: String) -> Redeem {
        lock.lock()
        defer { lock.unlock() }

        if burned { return .tooManyAttempts }
        // Named distinctly from the properties so the assignments below cannot
        // accidentally target a shadowed binding.
        guard let offered = code, let expiry = expiresAt else { return .noCode }

        if Date() >= expiry {
            clearLocked()
            return .expired
        }

        let attempts = failuresByPeer[peer, default: 0]
        if attempts >= maxFailuresPerPeer {
            return .tooManyAttempts
        }

        if SecureToken.constantTimeEquals(SecureToken.normalize(candidate), offered) {
            // Single use: the same code can never pair a second device.
            clearLocked()
            return .ok
        }

        failuresByPeer[peer] = attempts + 1
        totalFailures += 1

        if totalFailures >= maxTotalFailures {
            // Someone is guessing hard enough that the code is no longer worth
            // trusting. Destroy it and make them start over.
            clearLocked()
            burned = true
            Log.warn("配对码因连续错误次数过多已作废，请重新生成。")
            return .tooManyAttempts
        }

        return .mismatch(remaining: max(0, maxFailuresPerPeer - attempts - 1))
    }

    public func clear() {
        lock.lock()
        clearLocked()
        lock.unlock()
    }

    /// Caller must hold `lock`.
    private func clearLocked() {
        code = nil
        expiresAt = nil
        burned = false
        failuresByPeer.removeAll()
        totalFailures = 0
    }
}

public enum PairingError: Error, CustomStringConvertible {
    case noCode
    case expired
    case tooManyAttempts
    case mismatch(remaining: Int)

    public var description: String {
        switch self {
        case .noCode:
            return "当前没有有效的配对码，请在 Mac 上执行 screenbeam pair 生成。"
        case .expired:
            return "配对码已过期，请在 Mac 上重新生成。"
        case .tooManyAttempts:
            return "尝试次数过多，配对码已作废，请在 Mac 上重新生成。"
        case .mismatch(let remaining):
            // Deliberately reports the remaining budget: the person typing made a
            // typo, and knowing how many tries are left is more useful than a
            // blanket refusal. It gives a guesser nothing they cannot count.
            return "配对码不正确，还可以尝试 \(remaining) 次。"
        }
    }

    public var httpStatus: Int {
        switch self {
        case .noCode, .expired, .tooManyAttempts: return 410 // Gone
        case .mismatch: return 401
        }
    }
}
