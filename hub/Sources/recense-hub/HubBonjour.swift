import Foundation
import dnssd

// Derived from Spec: FEAT-18 (H1a). Tells the local network "recense.local and <name>.recense.local are at this
// Mac's address" (multicast DNS), so a browser finds the hub with no DNS server and no internet.

final class HubBonjour {
    private var conn: DNSServiceRef?
    private var records: [DNSRecordRef] = []
    private var service: DNSServiceRef?
    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    /// The first non-loopback IPv4 address, preferring Wi-Fi/Ethernet (en0, en1...).
    static func ipv4() -> [UInt8]? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var best: (rank: Int, addr: [UInt8])?
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let name = String(cString: cur.pointee.ifa_name)
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               cur.pointee.ifa_flags & UInt32(IFF_UP) != 0, cur.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
               name.hasPrefix("en") {
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let bytes = [UInt8(a >> 24), UInt8((a >> 16) & 255), UInt8((a >> 8) & 255), UInt8(a & 255)]
                let rank = name == "en0" ? 0 : 1
                if bytes[0] != 169, best == nil || rank < best!.rank { best = (rank, bytes) }   // 169.254 = no real network
            }
            p = cur.pointee.ifa_next
        }
        return best?.addr
    }

    func start(names: [String], port: UInt16) -> Bool {
        guard let ip = HubBonjour.ipv4() else { return false }
        var c: DNSServiceRef?
        guard DNSServiceCreateConnection(&c) == kDNSServiceErr_NoError, let sd = c else { return false }
        conn = sd
        DNSServiceSetDispatchQueue(sd, queue)
        for n in names {
            var rec: DNSRecordRef?
            let err = ip.withUnsafeBytes { raw in
                DNSServiceRegisterRecord(sd, &rec, DNSServiceFlags(kDNSServiceFlagsUnique), 0, n + ".", UInt16(kDNSServiceType_A),
                                         UInt16(kDNSServiceClass_IN), 4, raw.baseAddress, 120, { _, _, _, e, _ in
                    if e != kDNSServiceErr_NoError { FileHandle.standardError.write(Data("hub: name registration failed (\(e))\n".utf8)) }
                }, nil)
            }
            if err != kDNSServiceErr_NoError { FileHandle.standardError.write(Data("hub: could not publish \(n) (\(err))\n".utf8)); return false }
            if let r = rec { records.append(r) }
        }
        var svc: DNSServiceRef? = sd
        let be = port.bigEndian
        _ = DNSServiceRegister(&svc, DNSServiceFlags(kDNSServiceFlagsShareConnection), 0, "Recense hub", "_https._tcp", nil, nil, be, 0, nil, nil, nil)
        service = svc
        print("hub: announcing \(names.joined(separator: ", ")) at \(ip.map(String.init).joined(separator: "."))")
        return true
    }
}
