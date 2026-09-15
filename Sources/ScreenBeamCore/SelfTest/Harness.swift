import Foundation

// MARK: - Harness

/// A self-contained test harness.
///
/// `swift test` needs XCTest (from full Xcode) or swift-testing, and neither
/// ships with the Command Line Tools — so a test target would be unrunnable on a
/// CLT-only machine, which is exactly the machine this is built for. Instead the
/// cases live in the module and run from `screenbeam selftest`.
///
/// The value on offer here is regression safety for the pieces where a bug is
/// silent: a QR code that looks right but scans wrong, and a request parser whose
/// failure mode is a dropped or truncated capture.

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw TestFailure(message: message()) }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) throws {
    if lhs != rhs {
        throw TestFailure(message: "\(label)：期望 \(rhs)，实际 \(lhs)")
    }
}

func checkClose(_ lhs: Double, _ rhs: Double, _ tolerance: Double, _ label: String) throws {
    if abs(lhs - rhs) > tolerance {
        throw TestFailure(message: "\(label)：期望 \(rhs) ±\(tolerance)，实际 \(lhs)")
    }
}

func checkUnwrap<T>(_ value: T?, _ label: String) throws -> T {
    guard let value else { throw TestFailure(message: "\(label)：值为 nil") }
    return value
}

/// Asserts that `body` throws. Deliberately does not inspect *which* error: the
/// point is only that malformed input is refused rather than accepted.
func checkThrows(_ label: String, _ body: () throws -> Void) throws {
    var threw = false
    do { try body() } catch { threw = true }
    if !threw { throw TestFailure(message: "\(label)：预期抛出错误，但没有") }
}

// MARK: - Runner

public enum SelfTest {
    public struct Case {
        public let name: String
        /// nil when the case passed.
        public let failure: String?
        public var passed: Bool { failure == nil }
    }

    /// Runs every case. Blocks the caller for a few hundred milliseconds; the
    /// slowest cases are the QR image decode and the 500-id uniqueness check.
    public static func run(filter: String? = nil) -> [Case] {
        registeredCases()
            .filter { name, _ in
                guard let filter else { return true }
                return name.localizedCaseInsensitiveContains(filter)
            }
            .map { name, body in
                do {
                    try body()
                    return Case(name: name, failure: nil)
                } catch {
                    return Case(name: name, failure: String(describing: error))
                }
            }
    }
}

private func registeredCases() -> [(String, () throws -> Void)] {
    ParserCases.all
        + QRCases.all
        + CaptureCases.all
        + ConfigCases.all
        + DeliveryCases.all
        + PairingCases.all
}
