import Foundation

/// Dead-simple `--key value` / `--flag` parser.
///
/// SwiftPM ships no argument parser, and adding a dependency for this would be
/// heavier than the whole feature. The convention: a `--name` followed by a token
/// that does not itself start with `--` takes that token as its value; otherwise
/// it is a boolean flag.
struct Arguments {
    let command: String?
    private let options: [String: String]
    private let flags: Set<String>
    let positional: [String]

    init(_ argv: [String]) {
        var command: String?
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []

        var index = 0
        while index < argv.count {
            let token = argv[index]

            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                let next = index + 1 < argv.count ? argv[index + 1] : nil

                if let next, !next.hasPrefix("--") {
                    options[name] = next
                    index += 2
                } else {
                    flags.insert(name)
                    index += 1
                }
            } else if command == nil {
                command = token
                index += 1
            } else {
                positional.append(token)
                index += 1
            }
        }

        self.command = command
        self.options = options
        self.flags = flags
        self.positional = positional
    }

    func string(_ name: String) -> String? { options[name] }
    func has(_ name: String) -> Bool { flags.contains(name) }

    func int(_ name: String) -> Int? { options[name].flatMap(Int.init) }
    func double(_ name: String) -> Double? { options[name].flatMap(Double.init) }
}

/// ANSI helpers that switch themselves off when output is not a terminal (or when
/// `NO_COLOR` is set), so piping into a file or `grep` stays clean.
enum Term {
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        return isatty(STDOUT_FILENO) == 1
    }()

    static var isTTY: Bool { isatty(STDOUT_FILENO) == 1 }

    static func bold(_ text: String) -> String { enabled ? "\u{1B}[1m\(text)\u{1B}[0m" : text }
    static func dim(_ text: String) -> String { enabled ? "\u{1B}[2m\(text)\u{1B}[0m" : text }
    static func accent(_ text: String) -> String { enabled ? "\u{1B}[38;5;191m\(text)\u{1B}[0m" : text }
    static func warn(_ text: String) -> String { enabled ? "\u{1B}[33m\(text)\u{1B}[0m" : text }
    static func error(_ text: String) -> String { enabled ? "\u{1B}[31m\(text)\u{1B}[0m" : text }
    static func ok(_ text: String) -> String { enabled ? "\u{1B}[32m\(text)\u{1B}[0m" : text }
}
