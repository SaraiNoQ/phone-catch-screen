import Foundation

/// Escape hatch for anything not covered above — Slack, Discord, n8n, a homegrown
/// endpoint.
///
/// The body is a template so you can shape it to whatever the target expects:
///
///     {"text": "{{text}}", "image": "{{image_url}}"}
///
/// `{{image_base64}}` inlines the frame as a data payload; it is only computed
/// when the template actually references it, since base64 inflates the payload by
/// roughly a third.
struct WebhookNotifier: Notifier {
    let label: String
    let url: String
    let method: String
    let headers: [String: String]
    let bodyTemplate: String?

    private static let defaultTemplate = #"{"text":"{{text}}","image_url":"{{image_url}}"}"#

    func send(_ payload: NotifyPayload) async throws {
        guard let endpoint = URL(string: url) else {
            throw NotifyError.missingConfiguration("webhook 地址无效：\(url)")
        }

        let template = bodyTemplate ?? Self.defaultTemplate
        let body = render(template, payload: payload)

        var request = NotifySupport.request(url: endpoint, method: method.uppercased())
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = Data(body.utf8)

        try await NotifySupport.send(request)
    }

    private func render(_ template: String, payload: NotifyPayload) -> String {
        var text = template
            .replacingOccurrences(of: "{{text}}", with: NotifySupport.jsonEscape(payload.caption))
            .replacingOccurrences(of: "{{image_url}}", with: NotifySupport.jsonEscape(payload.imageURL))
            .replacingOccurrences(of: "{{viewer_url}}", with: NotifySupport.jsonEscape(payload.viewerURL))
            .replacingOccurrences(of: "{{source}}", with: NotifySupport.jsonEscape(payload.shot.source))
            .replacingOccurrences(of: "{{host}}", with: NotifySupport.jsonEscape(payload.hostName))
            .replacingOccurrences(of: "{{time}}", with: NotifySupport.jsonEscape(
                CaptionTemplate.formatter("yyyy-MM-dd HH:mm:ss").string(from: payload.shot.createdAt)
            ))

        if template.contains("{{image_base64}}") {
            let encoded = payload.shot.payload.base64EncodedString()
            let dataURI = "data:\(payload.shot.format.mimeType);base64,\(encoded)"
            text = text.replacingOccurrences(of: "{{image_base64}}", with: dataURI)
        }
        return text
    }
}
