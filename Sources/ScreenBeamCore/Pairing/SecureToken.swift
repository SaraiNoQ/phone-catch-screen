import CryptoKit
import Foundation
import Security

/// Random material and comparison helpers for the pairing credentials.
///
/// Everything here goes through `SecRandomCopyBytes` rather than
/// `SystemRandomNumberGenerator` where it matters: the latter is fine for
/// jitter and ids, but a credential should come from the platform CSPRNG.
public enum SecureToken {

    /// Cryptographically random lowercase hex, `bytes * 2` characters long.
    public static func hex(bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)

        if SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer) != errSecSuccess {
            // Failure here is essentially unheard of. Fall back to the other
            // system CSPRNG rather than crashing — still unpredictable, still
            // not a hardcoded value.
            var rng = SystemRandomNumberGenerator()
            for index in buffer.indices {
                buffer[index] = UInt8.random(in: 0...255, using: &rng)
            }
        }
        return buffer.map { String(format: "%02x", $0) }.joined()
    }

    /// A numeric code meant to be read off a screen and typed by a human.
    ///
    /// Uses rejection sampling rather than a modulo: 250 is the largest multiple
    /// of 10 below 256, so bytes in `0..<250` map uniformly onto `0...9` and the
    /// rest are discarded. `byte % 10` alone would bias the low digits.
    public static func digits(_ count: Int) -> String {
        // Hoisted: `random(using:)` takes the generator inout, so it cannot be a
        // temporary.
        var fallback = SystemRandomNumberGenerator()
        var out = ""

        while out.count < count {
            var byte: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else {
                // Guarantees termination even if the CSPRNG is unavailable.
                out += String(Int.random(in: 0...9, using: &fallback))
                continue
            }
            guard byte < 250 else { continue }
            out.append(String(byte % 10))
        }
        return out
    }

    public static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Tokens travel through URLs, QR codes and copy-paste, so trim surrounding
    /// whitespace and case-fold before comparing. Entropy is unaffected: 32 hex
    /// characters is 128 bits whether or not case is significant.
    public static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Length is compared first (and leaked, which is unavoidable) but the
    /// contents are not, so a caller cannot recover a secret one character at a
    /// time by timing the response.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }

        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}
