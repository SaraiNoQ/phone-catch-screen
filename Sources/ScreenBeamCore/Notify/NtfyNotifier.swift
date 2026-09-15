import Foundation

/// ntfy — open source, self-hostable, works on iOS and Android via the ntfy app.
///
/// `Click` is the tap-through URL and needs no public reachability, so the viewer
/// page works over the LAN. `Attach` asks the ntfy *server* to fetch the image,
/// which again requires a publicly reachable URL, so it is only used when the
/// image link is not a private address.
struct NtfyNotifier: Notifier {
    let label: String
    let server: String
    let topic: String
    let authToken: String?

    func send(_ payload: NotifyPayload) async throws {
        guard let base = URL(string: server) else {
            throw NotifyError.missingConfiguration("ntfy server 地址无效：\(server)")
        }

        var request = NotifySupport.request(
            url: base.appendingPathComponent(topic),
            method: "POST"
        )
        request.setValue(payload.caption, forHTTPHeaderField: "Title")
        request.setValue("default", forHTTPHeaderField: "Priority")
        request.setValue("camera", forHTTPHeaderField: "Tags")
        request.setValue(payload.viewerURL, forHTTPHeaderField: "Click")
        request.setValue("打开查看", forHTTPHeaderField: "Actions")
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        if Self.isPubliclyReachable(payload.imageURL) {
            request.setValue(payload.imageURL, forHTTPHeaderField: "Attach")
        }

        // The body is the message text; ntfy renders it under the title.
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(payload.caption.utf8)

        try await NotifySupport.send(request)
    }

    /// Private ranges cannot be fetched by a third-party server, so sending them
    /// as `Attach` would just produce a broken preview on the phone.
    static func isPubliclyReachable(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host else { return false }
        if host.hasPrefix("127.") || host == "localhost" || host == "::1" { return false }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return false }
        if host.hasPrefix("100.") { return false } // CGNAT / Tailscale
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) {
                return false
            }
        }
        return true
    }
}
