import Foundation

/// Bark — the common iOS push app in China, self-hostable or via `api.day.app`.
///
/// Note on the image: Bark renders the `image` field by having *its own server*
/// fetch that URL. A plain `http://192.168.x.x/...` link is therefore useless
/// unless your Bark server sits on the same LAN. So the reliable mechanism here
/// is the `url` field: tapping the notification opens the live viewer, which
/// pulls frames directly from this Mac. `image` is only attached when you have
/// configured a publicly reachable `server.publicBaseURL`.
struct BarkNotifier: Notifier {
    let label: String
    let server: String
    let deviceKey: String
    let sound: String?
    let sendImageLink: Bool

    func send(_ payload: NotifyPayload) async throws {
        guard let base = URL(string: server) else {
            throw NotifyError.missingConfiguration("Bark server 地址无效：\(server)")
        }

        var body: [String: Any] = [
            // The key can go in the body or the path; body keeps one code path
            // for both `api.day.app` and self-hosted instances.
            "device_key": deviceKey,
            "title": BeamPaths.appDisplayName,
            "body": payload.caption,
            // Tap target. Also the only thing that works without a public URL.
            "url": payload.viewerURL,
            "group": BeamPaths.appDisplayName,
            "isArchive": 1,
        ]
        if let sound { body["sound"] = sound }
        if sendImageLink { body["image"] = payload.imageURL }

        var request = NotifySupport.request(url: base.appendingPathComponent("push"))
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try NotifySupport.jsonBody(body)

        let data = try await NotifySupport.send(request)

        // Bark answers 200 with a JSON envelope even when it refuses the push,
        // so the status code alone is not enough to call this a success.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = object["code"] as? Int, code != 200 {
            let message = object["message"] as? String ?? "未知错误"
            throw NotifyError.invalidResponse("Bark 返回 code=\(code)：\(message)")
        }
    }
}
