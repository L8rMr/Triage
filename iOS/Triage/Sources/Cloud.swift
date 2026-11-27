import Foundation
import CloudKit
import Network
import Security

// MARK: - Your Macs, from your iCloud (same Apple ID = no code, found anywhere)

enum CloudIDs {
    static let container = "iCloud.com.alenlvovich.triage"
    static let zone = CKRecordZone.ID(zoneName: "Triage", ownerName: CKCurrentUserDefaultName)
}

struct CloudMac: Identifiable, Equatable {
    let id: String            // the Mac's macID
    let name: String
    let secret: Data
    let lan: [String]
    let tailscale: String?
    let publicHost: String?
    let publicPort: Int?
    let port: Int
    let mode: String
    let seen: Date
    /// The router's TCP door to the Mac's WebSocket port, when it opened one (sent inside "mode": "full;tcp=52384").
    var tcpPort: Int? { mode.split(separator: ";").first { $0.hasPrefix("tcp=") }.flatMap { Int($0.dropFirst(4)) } }
}

final class CloudDirectory: ObservableObject {
    static let shared = CloudDirectory()
    @Published private(set) var macs: [CloudMac] = []
    @Published private(set) var status = ""

    private lazy var container = CKContainer(identifier: CloudIDs.container)
    private var db: CKDatabase { container.privateCloudDatabase }

    /// Pairing keys learned from iCloud, by macID (the Mac checks them during the handshake).
    static func secret(for macID: String) -> Data? { Keychain.get("cloud-\(macID)") }
    static var knownMacIDs: [String] { UserDefaults.standard.stringArray(forKey: "cloud.macIDs") ?? [] }

    func refreshSoon() { Task { try? await Task.sleep(for: .seconds(2)); await refresh() } }

    func refresh() async {
        do {
            guard try await container.accountStatus() == .available else {
                await MainActor.run { status = "Sign in to iCloud to find your Macs anywhere" }
                return
            }
            let changes = try await db.recordZoneChanges(inZoneWith: CloudIDs.zone, since: nil)
            var found: [CloudMac] = []
            for (_, result) in changes.modificationResultsByID {
                guard case .success(let mod) = result else { continue }
                let r = mod.record
                guard r.recordType == "TriageMac", let id = r["macID"] as? String, let secret = r["secret"] as? Data else { continue }
                found.append(CloudMac(id: id, name: r["name"] as? String ?? "Mac", secret: secret, lan: r["lan"] as? [String] ?? [],
                                      tailscale: r["tailscale"] as? String, publicHost: r["publicHost"] as? String,
                                      publicPort: r["publicPort"] as? Int, port: r["port"] as? Int ?? 52384,
                                      mode: r["mode"] as? String ?? "full", seen: r["seen"] as? Date ?? .distantPast))
                Keychain.set(secret, for: "cloud-\(id)")
            }
            found.sort { $0.seen > $1.seen }
            UserDefaults.standard.set(found.map(\.id), forKey: "cloud.macIDs")
            await MainActor.run { macs = found; status = found.isEmpty ? "No Macs in your iCloud yet" : "" }
        } catch {
            await MainActor.run { status = "iCloud: \(error.localizedDescription)" }
        }
    }

    /// Ask the Mac (through iCloud) to open its router toward us, and wait for its fresh address.
    func knock(_ mac: CloudMac, from me: (host: String, port: Int)) async throws -> (host: String, port: Int) {
        let id = CKRecord.ID(recordName: "punch-\(mac.id)", zoneID: CloudIDs.zone)
        let rec = CKRecord(recordType: "TriagePunch", recordID: id)
        rec["phoneHost"] = me.host
        rec["phonePort"] = me.port
        rec["state"] = "ask"
        rec["at"] = Date()
        try await CloudSave.one(rec, in: db)
        // the Mac checks every few seconds
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(500))
            if let r = try? await db.record(for: id), (r["state"] as? String) == "ready",
               let h = (r["macHost"] as? String) ?? mac.publicHost, let p = (r["macPort"] as? Int) ?? mac.publicPort {
                return (h, p)
            }
        }
        throw LinkError("\(mac.name) didn't answer. Make sure it's awake with Triage open.")
    }
}

// MARK: - Length-prefixed messages over QUIC (mirror of the Mac's framer)

final class TriageFramer: NWProtocolFramerImplementation {
    static let label = "Triage"
    static let definition = NWProtocolFramer.Definition(implementation: TriageFramer.self)

    required init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        var len = UInt32(messageLength).bigEndian
        framer.writeOutput(data: Data(bytes: &len, count: 4))
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var len: UInt32 = 0
            let got = framer.parseInput(minimumIncompleteLength: 4, maximumLength: 4) { buf, _ in
                guard let buf, buf.count >= 4 else { return 0 }
                var v: UInt32 = 0
                memcpy(&v, buf.baseAddress!, 4)
                len = UInt32(bigEndian: v)
                return 4
            }
            guard got else { return 4 }
            let msg = NWProtocolFramer.Message(definition: Self.definition)
            if !framer.deliverInputNoCopy(length: Int(len), message: msg, isComplete: true) { return 0 }
        }
    }

    static var context: NWConnection.ContentContext {
        NWConnection.ContentContext(identifier: "triage", metadata: [NWProtocolFramer.Message(definition: definition)])
    }
}

// MARK: - STUN

enum Stun {
    static let servers: [(String, UInt16)] = [("stun.l.google.com", 19302), ("stun.cloudflare.com", 3478), ("stun1.l.google.com", 19302)]

    struct Seen { let host: String; let port: Int; let local: NWEndpoint }

    /// Our public address as the internet sees it, plus the exact local address/port the answer came back to
    /// (QUIC then leaves from that same spot, so the router mapping matches). Works on IPv4, IPv6 and NAT64 networks.
    static func query() async -> Seen? {
        for (h, p) in servers {
            if let r = await once(h, p) { return r }
        }
        return nil
    }

    private final class Once: @unchecked Sendable {
        let lock = NSLock(); var done = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    private static func once(_ host: String, _ port: UInt16) async -> Seen? {
        await withCheckedContinuation { cont in
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            params.preferNoProxies = true
            // Ask over IPv4 on purpose (the Mac's address is IPv4): on IPv6-only carriers the phone still gets the
            // carrier's IPv4 mapping this way, through NAT64.
            let target: NWEndpoint.Host = ipv4(host).map { .ipv4($0) } ?? NWEndpoint.Host(host)
            let c = NWConnection(host: target, port: NWEndpoint.Port(rawValue: port)!, using: params)
            let gate = Once()
            let finish: (Seen?) -> Void = { r in
                guard gate.take() else { return }
                c.cancel()
                cont.resume(returning: r)
            }
            var req = Data([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42])
            req.append(Data((0..<12).map { _ in UInt8.random(in: 0...255) }))
            c.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    let local = c.currentPath?.localEndpoint
                    c.send(content: req, completion: .contentProcessed { _ in })
                    c.receiveMessage { d, _, _, _ in
                        guard let local, let m = d.flatMap(parse) else { finish(nil); return }
                        finish(Seen(host: m.host, port: m.port, local: local))
                    }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            c.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(nil) }
        }
    }

    private static func ipv4(_ name: String) -> IPv4Address? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(res) }
        guard let sa = r.pointee.ai_addr else { return nil }
        return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            withUnsafeBytes(of: sin.pointee.sin_addr) { IPv4Address(Data($0)) }
        }
    }

    static func parse(_ d: Data) -> (host: String, port: Int)? {
        let b = [UInt8](d)
        guard b.count >= 20 else { return nil }
        var i = 20
        while i + 4 <= b.count {
            let t = Int(b[i]) << 8 | Int(b[i + 1]), l = Int(b[i + 2]) << 8 | Int(b[i + 3]), v = i + 4
            if (t == 0x0020 || t == 0x0001), l >= 8, v + 8 <= b.count, b[v + 1] == 0x01 {
                var port = Int(b[v + 2]) << 8 | Int(b[v + 3])
                var ip = [b[v + 4], b[v + 5], b[v + 6], b[v + 7]]
                if t == 0x0020 {
                    port ^= 0x2112
                    ip = zip(ip, [UInt8(0x21), 0x12, 0xA4, 0x42]).map { $0 ^ $1 }
                }
                return (ip.map { String($0) }.joined(separator: "."), port)
            }
            i = v + ((l + 3) & ~3)
        }
        return nil
    }
}

// MARK: Which network the phone is on (Wi-Fi addresses are pointless on cellular)

final class PathWatch {
    static let shared = PathWatch()
    private let monitor = NWPathMonitor()
    private(set) var onWiFi = true
    var changed: (() -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            let wifi = p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet)
            let was = self.onWiFi
            self.onWiFi = wifi
            if was != wifi { DispatchQueue.main.async { self.changed?() } }
        }
        monitor.start(queue: DispatchQueue(label: "triage.path"))
    }
}


/// CloudKit reports a failed record inside the result, not by throwing: surface it.
enum CloudSave {
    static func one(_ rec: CKRecord, in db: CKDatabase) async throws {
        let r = try await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys)
        if case .failure(let e)? = r.saveResults[rec.recordID] { throw e }
    }
}
