import Foundation

/// Whether an SSH destination is on a Tailscale tailnet: a `100.64.0.0/10` address (the CGNAT
/// range Tailscale assigns), a Tailscale ULA (`fd7a:115c:a1e0::/48`) or a MagicDNS name
/// (`*.ts.net`). Such a host is reachable only while the Tailscale app is connected on this
/// device, which is what the Hosts screen says when a dial to one fails.
nonisolated public enum Tailscale {
    /// The words shown when a tailnet host cannot be reached.
    public static let connectHint = "This host is on a Tailscale network. Open Tailscale on this device and make sure it's connected."

    /// A bare host name or address (no user or port). Case-insensitive; a trailing dot and
    /// IPv6 brackets are ignored.
    public static func isTailnet(host: String) -> Bool {
        var host = host.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        if let ipv4 = ipv4(host) {
            // 100.64.0.0/10: first octet 100, second 64…127.
            return ipv4.0 == 100 && (64...127).contains(ipv4.1)
        }
        if host.contains(":") { return isTailnetIPv6(host) }
        // MagicDNS: `<machine>.<tailnet>.ts.net`; the name must end in `.ts.net` exactly.
        return host.hasSuffix(".ts.net") && host.count > ".ts.net".count
    }

    /// An SSH destination as typed: `[ssh ][user@]host[:port]`, `user@[v6]:port`.
    public static func isTailnet(destination: String) -> Bool {
        isTailnet(host: host(ofDestination: destination))
    }

    /// A saved endpoint: its host name, else the ssh_config alias it came from.
    public static func isTailnet(_ endpoint: SSHEndpoint) -> Bool {
        isTailnet(host: endpoint.host) || endpoint.alias.map { isTailnet(host: $0) } == true
    }

    /// The host part of `[ssh ][user@]host[:port]`.
    static func host(ofDestination text: String) -> String {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.hasPrefix("ssh ") { rest = rest.dropFirst(4).drop(while: { $0 == " " }) }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if rest.hasPrefix("[") {
            // `[v6]` or `[v6]:port`.
            guard let close = rest.firstIndex(of: "]") else { return String(rest) }
            return String(rest[rest.index(after: rest.startIndex)..<close])
        }
        // A single colon separates the port; more than one is a bare IPv6 address.
        if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            rest = rest[..<colon]
        }
        return String(rest)
    }

    private static func ipv4(_ host: String) -> (Int, Int, Int, Int)? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), let value = Int(part), (0...255).contains(value) else {
                return nil
            }
            octets.append(value)
        }
        return (octets[0], octets[1], octets[2], octets[3])
    }

    /// `fd7a:115c:a1e0::/48`, Tailscale's IPv6 range.
    private static func isTailnetIPv6(_ host: String) -> Bool {
        let address = host.split(separator: "%").first.map(String.init) ?? host
        var storage = in6_addr()
        guard inet_pton(AF_INET6, address, &storage) == 1 else { return false }
        let bytes = withUnsafeBytes(of: storage) { Array($0) }
        return bytes.count == 16 && bytes[0] == 0xfd && bytes[1] == 0x7a && bytes[2] == 0x11 && bytes[3] == 0x5c
            && bytes[4] == 0xa1 && bytes[5] == 0xe0
    }
}
