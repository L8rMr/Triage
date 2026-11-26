import Foundation
import CloudKit
import Network
import Security
import CryptoKit
import Darwin

// MARK: - Triage anywhere: iCloud introductions + a direct connection across the internet
//
// 1. This Mac keeps a small record in the user's private iCloud database: its name, a pairing key, its Wi-Fi and
//    Tailscale addresses, and its public internet address (learned from a STUN server).
// 2. A phone signed into the same Apple ID reads it: the Mac shows up anywhere, and pairs without a code.
// 3. To connect from outside, the phone posts its own public address; this Mac (checking every few seconds) sends a
//    few packets toward it from its QUIC port, which opens its router, and answers with a fresh address. The phone then
//    opens QUIC straight to the Mac. Screens, files and keys never pass through iCloud: only these few hundred bytes do.

enum CloudIDs {
    static let container = "iCloud.com.alenlvovich.triage"
    static let zone = CKRecordZone.ID(zoneName: "Triage", ownerName: CKCurrentUserDefaultName)
    static let quicPort: UInt16 = 52385
}

final class CloudPresence: ObservableObject {
    static let shared = CloudPresence()

    @Published private(set) var status = "Starting…"
    @Published private(set) var publicAddress: String?

    private lazy var container = CKContainer(identifier: CloudIDs.container)
    private var db: CKDatabase { container.privateCloudDatabase }
    private var publishTimer: Timer?
    private var pollTimer: Timer?
    private var keepAlive: Timer?
    private var quic: NWListener?
    private var lastPunch: Date?
    private var started = false

    /// Shared with phones through the private database only; proves "same iCloud account" during pairing.
    static var cloudSecret: Data {
        if let s = UserDefaults.standard.string(forKey: "remote.cloudSecret"), let d = Data(base64Encoded: s) { return d }
        let d = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        UserDefaults.standard.set(d.base64EncodedString(), forKey: "remote.cloudSecret")
        return d
    }

    func start() {
        guard !started else { return }
        started = true
        // A build without the iCloud entitlement would crash on CKContainer: check first.
        guard Self.entitled else {
            startQUIC()
            setStatus("This build isn't signed for iCloud. Build with Build Triage.command to turn it on.")
            return
        }
        Task { await setUp() }
    }

    static var entitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let v = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        return (v as? [String])?.contains(CloudIDs.container) == true
    }

    private func setStatus(_ s: String) { DispatchQueue.main.async { self.status = s } }

    private func setUp() async {
        do {
            let st = try await container.accountStatus()
            guard st == .available else { setStatus("Sign in to iCloud on this Mac to reach it from anywhere"); return }
        } catch {
            setStatus("iCloud isn't available: \(error.localizedDescription)")
            return
        }
        _ = try? await db.modifyRecordZones(saving: [CKRecordZone(zoneID: CloudIDs.zone)], deleting: [])
        startQUIC()
        await publish()
        DispatchQueue.main.async {
            self.publishTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { await self?.publish() } }
            // the router forgets idle UDP mappings in about a minute; a tiny STUN ping keeps ours open
            self.keepAlive = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in Task { await self?.refreshAddress() } }
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { await self?.pollPunch() } }
        }
    }

    // MARK: Publishing this Mac

    private func refreshAddress() async {
        guard let a = await Stun.query(localPort: CloudIDs.quicPort) else { return }
        let s = "\(a.host):\(a.port)"
        if s != publicAddress {
            DispatchQueue.main.async { self.publicAddress = s }
            await publish(known: a)
        }
    }

    func publish(known: (host: String, port: Int)? = nil) async {
        let a: (host: String, port: Int)?
        if let known { a = known } else { a = await Stun.query(localPort: CloudIDs.quicPort) }
        if let a { DispatchQueue.main.async { self.publicAddress = "\(a.host):\(a.port)" } }
        let id = RemoteServer.macID
        let rec = CKRecord(recordType: "TriageMac", recordID: CKRecord.ID(recordName: "mac-\(id)", zoneID: CloudIDs.zone))
        rec["macID"] = id
        rec["name"] = Host.current().localizedName ?? "Mac"
        rec["secret"] = Self.cloudSecret
        rec["lan"] = NetAddrs.lan()
        rec["tailscale"] = NetAddrs.tailscale()
        rec["publicHost"] = a?.host
        rec["publicPort"] = a?.port
        rec["port"] = Int(RemoteServer.preferredPort)
        rec["quicPort"] = Int(CloudIDs.quicPort)
        rec["mode"] = RemoteServer.shared.mode.rawValue
        rec["seen"] = Date()
        do {
            _ = try await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys)
            setStatus(a == nil ? "In iCloud · direct internet connection unavailable on this network"
                               : "In iCloud · reachable from anywhere")
        } catch {
            setStatus("Couldn't update iCloud: \(error.localizedDescription)")
        }
    }

    // MARK: A phone knocking from the internet

    private func pollPunch() async {
        guard RemoteServer.shared.mode != .off else { return }
        let id = CKRecord.ID(recordName: "punch-\(RemoteServer.macID)", zoneID: CloudIDs.zone)
        guard let rec = try? await db.record(for: id), (rec["state"] as? String) == "ask",
              let ph = rec["phoneHost"] as? String, let pp = rec["phonePort"] as? Int,
              let at = rec["at"] as? Date, -at.timeIntervalSinceNow < 30 else { return }
        if let last = lastPunch, -last.timeIntervalSinceNow < 1 { return }
        lastPunch = Date()
        // fresh mapping first (the router may have moved us), then open the door toward the phone
        let me = await Stun.query(localPort: CloudIDs.quicPort)
        Punch.knock(from: CloudIDs.quicPort, to: ph, port: pp)
        rec["state"] = "ready"
        rec["macHost"] = me?.host ?? (rec["macHost"] as? String)
        rec["macPort"] = me?.port ?? (rec["macPort"] as? Int)
        _ = try? await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys)
        RemoteServer.shared.record("iPhone", "Opened a direct internet connection")
    }

    // MARK: The internet-facing door: QUIC on a fixed port

    fileprivate func startQUIC() {
        guard quic == nil else { return }
        guard let identity = QuicIdentity.load(), let sid = sec_identity_create(identity) else {
            setStatus("Couldn't create the connection certificate")
            return
        }
        let q = NWProtocolQUIC.Options(alpn: ["triage"])
        sec_protocol_options_set_local_identity(q.securityProtocolOptions, sid)
        q.idleTimeout = 60_000
        let params = NWParameters(quic: q)
        params.allowLocalEndpointReuse = true
        params.defaultProtocolStack.applicationProtocols.insert(NWProtocolFramer.Options(definition: TriageFramer.definition), at: 0)
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: CloudIDs.quicPort)!)
            l.newConnectionHandler = { c in RemoteServer.shared.acceptFramed(c) }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st { self?.setStatus("Internet door closed: \(e.localizedDescription)"); self?.quic = nil }
            }
            l.start(queue: RemoteServer.shared.queue)
            quic = l
        } catch {
            setStatus("Couldn't open the internet door: \(error.localizedDescription)")
        }
    }
}

// MARK: - Length-prefixed messages over a QUIC stream (same messages the WebSocket carries on Wi-Fi)

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

// MARK: - STUN: "what does the internet see me as?"

enum Stun {
    static let servers: [(String, UInt16)] = [("stun.l.google.com", 19302), ("stun.cloudflare.com", 3478), ("stun1.l.google.com", 19302)]

    static func query(localPort: UInt16) async -> (host: String, port: Int)? {
        for (h, p) in servers {
            if let r = await once(h, p, localPort) { return r }
        }
        return nil
    }

    private final class Once: @unchecked Sendable {
        let lock = NSLock(); var done = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    private static func once(_ host: String, _ port: UInt16, _ local: UInt16) async -> (host: String, port: Int)? {
        await withCheckedContinuation { cont in
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: NWEndpoint.Port(rawValue: local)!)
            let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
            let gate = Once()
            let finish: ((host: String, port: Int)?) -> Void = { r in
                guard gate.take() else { return }
                c.cancel()
                cont.resume(returning: r)
            }
            var req = Data([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42])
            req.append(Data((0..<12).map { _ in UInt8.random(in: 0...255) }))
            c.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    c.send(content: req, completion: .contentProcessed { _ in })
                    c.receiveMessage { d, _, _, _ in finish(d.flatMap(parse)) }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            c.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { finish(nil) }
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

// MARK: - Opening our router toward the phone

enum Punch {
    /// A few small UDP packets from our QUIC port toward the phone's public address. Our router now expects
    /// traffic from there, so the phone's QUIC handshake gets in. The socket closes quickly so QUIC answers it.
    static func knock(from local: UInt16, to host: String, port: Int) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: NWEndpoint.Port(rawValue: local)!)
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        c.stateUpdateHandler = { st in
            guard case .ready = st else { return }
            for i in 0..<4 {
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * 0.12) {
                    c.send(content: Data("triage-knock".utf8), completion: .contentProcessed { _ in })
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { c.cancel() }
        }
        c.start(queue: .global(qos: .userInteractive))
    }
}

// MARK: - Addresses this Mac can be reached at

enum NetAddrs {
    private static func ipv4s() -> [(iface: String, ip: String)] {
        var out: [(String, String)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (Int32(ifa.ifa_flags) & IFF_UP) != 0, (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    out.append((String(cString: ifa.ifa_name), String(cString: host)))
                }
            }
            p = ifa.ifa_next
        }
        return out
    }

    static func lan() -> [String] {
        ipv4s().filter { !$0.ip.hasPrefix("100.") && !$0.ip.hasPrefix("169.254.") }.map(\.ip)
    }

    /// Tailscale hands out 100.64.0.0/10.
    static func tailscale() -> String? {
        ipv4s().first { a in
            let parts = a.ip.split(separator: ".").compactMap { Int($0) }
            return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
        }?.ip
    }
}

// MARK: - The certificate QUIC needs (made once, kept in Application Support)

enum QuicIdentity {
    static func load() -> SecIdentity? {
        let dir = Shell.supportDir
        let p12 = dir.appendingPathComponent("remote-quic.p12")
        let fm = FileManager.default
        if !fm.fileExists(atPath: p12.path) {
            let key = dir.appendingPathComponent("quic-key.pem"), cert = dir.appendingPathComponent("quic-cert.pem")
            run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", cert.path, "-days", "3650", "-subj", "/CN=Triage"])
            run(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path, "-passout", "pass:triage"])
            try? fm.removeItem(at: key); try? fm.removeItem(at: cert)
        }
        guard let data = try? Data(contentsOf: p12) else { return nil }
        var opts: [String: Any] = [kSecImportExportPassphrase as String: "triage"]
        if #available(macOS 15.0, *) { opts[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, opts as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first, let id = first[kSecImportItemIdentity as String] else { return nil }
        return (id as! SecIdentity)
    }

    private static func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
