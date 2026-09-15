import Foundation

/// Entry point.
///
/// Uses `@main` with an async `main()` rather than a top-level `main.swift` so
/// the commands can `await` directly — the daemon and the one-shot capture path
/// are both async.
@main
struct ScreenBeamCommand {
    static func main() async {
        await CLI.main(Array(CommandLine.arguments.dropFirst()))
    }
}
