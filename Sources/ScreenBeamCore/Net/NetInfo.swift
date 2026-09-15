import Darwin
import Foundation

public struct NetworkInterface: Sendable {
    public let name: String
    public let address: String

    public var isLoopback: Bool {
        address.hasPrefix("127.") || address == "::1"
    }

    /// Tailscale and other VPNs show up as `utun*`. Worth calling out separately
    /// because a `100.x.y.z` address is reachable from your phone anywhere, not
    /// just on the home Wi-Fi.
    public var isTunnel: Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
    }

    public var isLikelyLAN: Bool {
        name.hasPrefix("en") || name.hasPrefix("bridge")
    }
}

public enum NetInfo {
    public static func ipv4Interfaces() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var results: [NetworkInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let current = cursor {
            let entry = current.pointee
            defer { cursor = entry.ifa_next }

            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }

            let address = String(cString: host)
            guard !address.isEmpty else { continue }

            let interface = NetworkInterface(name: String(cString: entry.ifa_name), address: address)
            if !results.contains(where: { $0.name == interface.name && $0.address == interface.address }) {
                results.append(interface)
            }
        }

        // Order by usefulness: real LAN first, then tunnels, then everything else.
        return results.sorted { lhs, rhs in
            func rank(_ item: NetworkInterface) -> Int {
                if item.isLikelyLAN { return 0 }
                if item.isTunnel { return 1 }
                if item.isLoopback { return 3 }
                return 2
            }
            let (lr, rr) = (rank(lhs), rank(rhs))
            if lr != rr { return lr < rr }
            return lhs.name < rhs.name
        }
    }

    /// Best address to hand a phone on the same network.
    public static func primaryLANAddress() -> String? {
        ipv4Interfaces().first { $0.isLikelyLAN && !$0.isLoopback }?.address
    }

    /// A `100.64.0.0/10` address usually means Tailscale — reachable from anywhere.
    public static func tailscaleAddress() -> String? {
        ipv4Interfaces().first { interface in
            guard interface.isTunnel, let octet = firstOctet(interface.address) else { return false }
            return octet == 100
        }?.address
    }

    private static func firstOctet(_ address: String) -> Int? {
        Int(address.split(separator: ".").first.map(String.init) ?? "")
    }

    public static var hostName: String {
        var name = [CChar](repeating: 0, count: 256)
        if gethostname(&name, name.count) == 0 {
            let value = String(cString: name)
            let trimmed = value.split(separator: ".").first.map(String.init) ?? value
            if !trimmed.isEmpty { return trimmed }
        }
        return "mac"
    }
}
