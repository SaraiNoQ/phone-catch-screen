import Foundation
import ScreenBeamCore

/// Prints how to reach this Mac from the phone.
///
/// Two different things get shown depending on what the operator needs:
/// `showPairing` when a new phone is being brought in, and `show` for the
/// addresses themselves.
enum AccessInfo {

    /// Admin URL — carries the *master* token, so it grants full control. The
    /// viewer accepts it, but phones should pair instead; that keeps the master
    /// credential off the phone entirely.
    static func adminURL(config: BeamConfig, port: UInt16) -> String {
        "\(baseURL(config: config, port: port))/?token=\(config.server.token)"
    }

    static func baseURL(config: BeamConfig, port: UInt16) -> String {
        let host = config.server.publicBaseURL.flatMap { $0.isEmpty ? nil : $0 }
            ?? "http://\(NetInfo.primaryLANAddress() ?? "127.0.0.1"):\(port)"
        return host.hasSuffix("/") ? String(host.dropLast()) : host
    }

    // MARK: - Pairing

    /// The pairing URL carries the code in the *fragment*: browsers never send
    /// fragments to the server, so the code stays out of request logs.
    static func pairingURL(code: String, config: BeamConfig, port: UInt16) -> String {
        "\(baseURL(config: config, port: port))/#pair=\(code)"
    }

    static func showPairing(
        code: String,
        expiresInSeconds: Int,
        config: BeamConfig,
        port: UInt16,
        inverted: Bool = false
    ) {
        let url = pairingURL(code: code, config: config, port: port)

        print("")
        print("  " + Term.bold("配对码") + Term.dim("   剩余 \(expiresInSeconds) 秒 · 仅可使用一次"))

        if Term.isTTY, let qr = TerminalQRCode.render(url, style: inverted ? .inverted : .standard) {
            for line in qr.split(separator: "\n", omittingEmptySubsequences: false) {
                print("      \(line)")
            }
        }

        print("")
        // Spaced out so it can be read aloud or typed without losing your place.
        print("      " + Term.accent(code.map(String.init).joined(separator: " ")))
        print("")
        print("  " + Term.dim("手机相机扫码，或在手机上打开："))
        print("  " + Term.accent(url))
        print("")
    }

    // MARK: - Addresses

    static func show(
        config: BeamConfig,
        port: UInt16,
        pairedDevices: Int,
        showCode: Bool = true,
        inverted: Bool = false
    ) {
        print("")
        print(Term.bold("  PHONE·CATCH·SCREEN") + Term.dim("  —  手机访问"))
        print("")

        if pairedDevices == 0 {
            print("  " + Term.warn("还没有配对任何设备。"))
            print("  " + Term.dim("在 Mac 上执行 ") + Term.accent("screenbeam pair") + Term.dim(" 生成配对码。"))
            print("")
        } else {
            print("  " + Term.dim("已配对设备  ") + "\(pairedDevices) 台")
            print("  " + Term.dim("增配新设备  ") + Term.accent("screenbeam pair"))
            print("  " + Term.dim("设备列表    ") + Term.accent("screenbeam devices"))
            print("")
        }

        let admin = adminURL(config: config, port: port)
        if showCode && Term.isTTY,
           let qr = TerminalQRCode.render(admin, style: inverted ? .inverted : .standard) {
            for line in qr.split(separator: "\n", omittingEmptySubsequences: false) {
                print("      \(line)")
            }
            print("")
        }

        print("  " + Term.dim("管理入口  ") + Term.accent(admin))
        print("  " + Term.dim("本机      ") + "http://127.0.0.1:\(port)/?token=\(config.server.token)")
        print("")

        let interfaces = NetInfo.ipv4Interfaces().filter { !$0.isLoopback }
        if interfaces.isEmpty {
            print("  " + Term.warn("没有检测到局域网地址，手机可能无法连接。"))
        } else {
            for interface in interfaces {
                let tag = interface.isTunnel ? Term.dim(" (隧道/VPN)") : ""
                print("  " + Term.dim("网络      ") + "\(interface.name)  \(interface.address)\(tag)")
            }
        }

        if config.server.isLoopbackOnly {
            print("")
            print("  " + Term.warn("当前 server.host = \(config.server.host)，仅允许本机访问。"))
            print("  " + Term.warn("要让手机连上，请把 config.json 里的 host 改为 0.0.0.0 并重启。"))
        }

        print("")
    }
}
