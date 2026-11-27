import Foundation
import Network
import CryptoKit
import Security
import UIKit
import SwiftUI

// The phone's side of Triage Remote. Mirrors RemoteServer.swift on the Mac:
// hello ⇄ hello → pair (6-digit code) | auth (stored secret) → ChaChaPoly frames.

struct LinkError: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct FoundMac: Identifiable, Hashable {
    let id: String          // Bonjour service name = the Mac's name
    let endpoint: NWEndpoint
    var quic = false        // the direct internet door (QUIC through a punched hole)
    var localPort: UInt16?  // QUIC must leave from the port STUN saw, or the hole doesn't match
    var local: NWEndpoint?  // …and from the same address family/interface
}

/// One way of reaching the Mac. Tried in order until one answers.
enum Route {
    case lan(FoundMac)                 // Bonjour on this Wi-Fi
    case address(String, String)       // host, label ("Wi-Fi", "Tailscale")
    case direct(CloudMac)              // the Mac's internet address, when its router forwards the port
    case p2p(CloudMac)                 // straight across the internet, both sides opening their routers (iCloud relays the knock)

    var label: String {
        switch self {
        case .lan: return "Wi-Fi"
        case .address(_, let l): return l
        case .direct, .p2p: return "Internet (direct)"
        }
    }
}

final class MacBrowser: ObservableObject {
    @Published private(set) var macs: [FoundMac] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: "_triage._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { r -> FoundMac? in
                if case let .service(name, _, _, _) = r.endpoint { return FoundMac(id: name, endpoint: r.endpoint) }
                return nil
            }.sorted { $0.id < $1.id }
            DispatchQueue.main.async { self?.macs = list }
        }
        b.stateUpdateHandler = { [weak self] st in
            if case .failed = st { DispatchQueue.main.async { self?.browser = nil } }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

final class MacLink: ObservableObject {
    static let shared = MacLink()

    enum Phase: Equatable {
        case idle
        case connecting(String)
        case needsCode(wrong: Bool)
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var macName = ""
    @Published private(set) var mode = "view"
    @Published private(set) var info: MacInfo?
    @Published private(set) var vitals: Vitals?
    @Published private(set) var reconnecting = false
    /// Bumps every time a (re)connection is ready: screens that stream (the remote desktop) restart on it.
    @Published private(set) var session = 0
    /// How we're talking right now: Wi-Fi, Tailscale, Internet (direct).
    @Published private(set) var route = ""

    var canEdit: Bool { mode == "full" }

    /// The Mac we talk to without asking, once paired.
    @Published var rememberedMac: String? = UserDefaults.standard.string(forKey: "link.mac") {
        didSet { UserDefaults.standard.set(rememberedMac, forKey: "link.mac") }
    }

    private let q = DispatchQueue(label: "triage.link")
    private var conn: NWConnection?
    private var target: FoundMac?
    private var eph = P256.KeyAgreement.PrivateKey()
    private var serverPub: P256.KeyAgreement.PublicKey?
    private var nonce = Data()
    private var macID: String?
    private var key: SymmetricKey?
    private var seq = 0
    private var pending: [Int: (Result<[String: Any], LinkError>) -> Void] = [:]
    private var wantConnected = false
    private var attempt = 0
    private var plan: [Route] = []         // what's left to try for this connection
    private var cloudMac: CloudMac?        // known through iCloud: lets every reconnect re-plan its way in
    private var gen = 0                    // bumps on every attempt, so stale timers stay quiet
    private var heard = false              // the Mac said hello on this attempt
    private var label = ""

    let deviceID: String = {
        if let s = UserDefaults.standard.string(forKey: "link.deviceID") { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: "link.deviceID")
        return s
    }()

    /// iOS hides the phone's real name from apps, so it's whatever you call it in Settings.
    var deviceName: String {
        let n = (UserDefaults.standard.string(forKey: "device.name") ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? UIDevice.current.model : n
    }

    // MARK: Connect / disconnect


    static func endpoint(_ host: String) -> NWEndpoint {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = h.split(separator: ":")
        let port = parts.count == 2 ? UInt16(parts[1]) ?? 52384 : 52384
        let name = String(parts.first ?? Substring(h))
        return .hostPort(host: Resolve.routable(name), port: NWEndpoint.Port(rawValue: port)!)
    }

    func connect(host: String) {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return }
        start([.address(h, "Tailscale")], cloud: nil)
    }

    var viaInternet: Bool { route != "Wi-Fi" && !route.isEmpty }

    func connect(_ mac: FoundMac) {
        // Bonjour first; if it's also in iCloud, a dropped Wi-Fi can fall through to the internet.
        let cloud = CloudDirectory.shared.macs.first { $0.name == mac.id }
        start([.lan(mac)] + (cloud.map { Self.plan(for: $0, lan: []) } ?? []), cloud: cloud)
    }

    /// From anywhere: this Wi-Fi, the Mac's own Wi-Fi addresses, then straight across the internet.
    func connect(anywhere mac: CloudMac, lan: [FoundMac]) {
        start(Self.plan(for: mac, lan: lan), cloud: mac)
    }

    static func plan(for mac: CloudMac, lan: [FoundMac]) -> [Route] {
        var p: [Route] = []
        if let m = lan.first(where: { $0.id == mac.name }) { p.append(.lan(m)) }
        if PathWatch.shared.onWiFi { p += mac.lan.prefix(2).map { .address("\($0):\(mac.port)", "Wi-Fi") } }
        // Away: the router's TCP door first (gets through every carrier and relay), then QUIC, then a knock.
        if let h = mac.publicHost, let t = mac.tcpPort { p.append(.address("\(h):\(t)", "Internet (direct)")) }
        if mac.publicHost != nil { p.append(.direct(mac)) }
        p.append(.p2p(mac))
        return p
    }

    /// What happened on the last attempt, way by way (shown when the phone can't get through).
    @Published private(set) var notes: [String] = []
    private func note(_ s: String) { DispatchQueue.main.async { self.notes = Array((self.notes + [s]).suffix(8)) } }

    private func start(_ routes: [Route], cloud: CloudMac?) {
        DispatchQueue.main.async { self.notes = [] }
        q.async {
            self.wantConnected = true
            self.cloudMac = cloud
            self.plan = routes
            self.attempt = 0
            self.next()
        }
    }

    /// Try the next way in. On q.
    private func next() {
        guard wantConnected else { return }
        guard !plan.isEmpty else {
            // nothing left this round: lost() waits a moment, then starts over from the top (fresh addresses)
            lost("Couldn't reach \(macName.isEmpty ? "your Mac" : macName)")
            return
        }
        let r = plan.removeFirst()
        label = r.label
        switch r {
        case .lan(let m): target = m; open()
        case .address(let h, let l):
            guard !h.isEmpty else { next(); return }
            target = FoundMac(id: cloudMac?.name ?? h, endpoint: Self.endpoint(h))
            label = l
            open()
        case .direct(let mac):
            guard let h = mac.publicHost, let pt = mac.publicPort, let port = NWEndpoint.Port(rawValue: UInt16(pt)) else { next(); return }
            target = FoundMac(id: mac.name, endpoint: .hostPort(host: Resolve.routable(h), port: port), quic: true, localPort: nil)
            open()
        case .p2p(let mac):
            let g = gen
            DispatchQueue.main.async { if self.phase != .ready { self.phase = .connecting(mac.name) } else { self.reconnecting = true } }
            Task {
                do {
                    guard let me = await Stun.query() else { throw LinkError("Couldn't learn this network's internet address (STUN blocked)") }
                    self.note("Asked \(mac.name) through iCloud to open its door")
                    let there = try await CloudDirectory.shared.knock(mac, from: (me.host, me.port))
                    self.q.async {
                        guard self.gen == g, self.wantConnected else { return }
                        self.target = FoundMac(id: mac.name, endpoint: .hostPort(host: NWEndpoint.Host(there.host),
                                                                                port: NWEndpoint.Port(rawValue: UInt16(there.port))!),
                                               quic: true, localPort: nil, local: me.local)
                        self.open()
                    }
                } catch {
                    self.q.async { if self.gen == g { self.fellThrough(error.localizedDescription) } }
                }
            }
        }
    }

    /// This way in didn't work. On q.
    private func fellThrough(_ why: String) {
        note("\(label): \(why)")
        if !plan.isEmpty { teardown(); next() } else { lost(why) }
    }

    private func open() {   // on q
        guard let target else { return }
        teardown()
        gen += 1
        heard = false
        let g = gen
        DispatchQueue.main.async {
            self.macName = target.id
            if self.phase != .ready { self.phase = .connecting(target.id) } else { self.reconnecting = true }
        }
        let params: NWParameters
        if target.quic {
            let quic = NWProtocolQUIC.Options(alpn: ["triage"])
            quic.idleTimeout = 60_000
            // The certificate is the Mac's own; who it really is gets proven inside, by the pairing secret.
            sec_protocol_options_set_verify_block(quic.securityProtocolOptions, { _, _, done in done(true) }, q)
            params = NWParameters(quic: quic)
            params.allowLocalEndpointReuse = true
            if let l = target.local { params.requiredLocalEndpoint = l }
            params.defaultProtocolStack.applicationProtocols.insert(NWProtocolFramer.Options(definition: TriageFramer.definition), at: 0)
        } else {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true            // every touch goes out now, not batched: this is what makes the remote feel immediate
            tcp.connectionTimeout = 4
            params = NWParameters(tls: nil, tcp: tcp)
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            ws.maximumMessageSize = 16 << 20
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        }
        params.serviceClass = .interactiveVideo
        // Straight to the Mac: never through iCloud Private Relay or another proxy. Relays open the connection but
        // stall the conversation, and the link is end-to-end encrypted anyway.
        params.preferNoProxies = true
        // Away from home, go out on the phone's real network (cellular or Wi-Fi), not through a VPN tunnel: work VPNs
        // carry the traffic to a corporate network that won't pass it to a home Mac. If the VPN insists on carrying
        // everything, iOS keeps it in the tunnel anyway.
        if label != "Wi-Fi", PathWatch.shared.vpn, let i = PathWatch.shared.physical { params.requiredInterface = i }
        let c = NWConnection(to: target.endpoint, using: params)
        // Quick fail: a way in that hasn't said hello in a few seconds isn't the one; move on.
        if !plan.isEmpty {
            q.asyncAfter(deadline: .now() + (target.quic || label != "Wi-Fi" ? 7 : 3.5)) { [weak self] in
                guard let self, self.gen == g, !self.heard else { return }
                self.fellThrough("Timed out")
            }
        }
        do {
            self.quic = target.quic
            self.eph = P256.KeyAgreement.PrivateKey()
            self.key = nil
            self.seq = 0
            self.conn = c
            c.stateUpdateHandler = { [weak self, weak c] st in
                guard let self, let c, c === self.conn else { return }
                switch st {
                case .ready: self.sendPlain(["t": "hello", "v": 1, "id": self.deviceID, "name": self.deviceName,
                                             "cloud": CloudDirectory.knownMacIDs,
                                             "pub": self.eph.publicKey.rawRepresentation.base64EncodedString()])
                case .failed(let e): self.dropped("Couldn't reach \(target.id): \(e.localizedDescription)")
                case .waiting(let e): self.dropped("Waiting for \(target.id): \(e.localizedDescription)")
                case .cancelled: break
                default: break
                }
            }
            c.start(queue: self.q)
            self.receive(c)
        }
    }
    private var quic = false

    /// A connection ended. Before the Mac answered: try the next way in. After: reconnect. On q.
    private func dropped(_ why: String) {
        if !heard && !plan.isEmpty { fellThrough(why) } else { if !heard { note("\(label): \(why)") }; lost(why) }
    }

    /// Going to the background: hang up politely, come back on resume.
    func suspend() {
        q.async { self.teardown() }
    }

    func resume() {
        q.async {
            guard self.wantConnected, self.target != nil else { return }
            self.attempt = 0
            self.replan()
        }
    }

    /// Start over from the best way in (on q). Wi-Fi came back, or the network changed under us.
    private func replan() {
        if let c = cloudMac {
            let lan: [Route] = target.flatMap { t -> Route? in if case .service = t.endpoint { return .lan(t) }; return nil }.map { [$0] } ?? []
            plan = lan + Self.plan(for: c, lan: [])
            next()
        } else { open() }
    }

    /// Wi-Fi ↔ cellular: don't wait for the old road to time out, take the best one now.
    func networkChanged() {
        q.async {
            guard self.wantConnected, self.conn != nil else { return }
            let onWiFi = PathWatch.shared.onWiFi
            // leaving Wi-Fi kills Wi-Fi routes; arriving on Wi-Fi, Bonjour's upgrade(to:) does the hop
            if !onWiFi && self.label == "Wi-Fi" { self.attempt = 0; self.replan() }
        }
    }

    /// Bonjour just saw our Mac while we're on the long way round: hop onto Wi-Fi without dropping the screen.
    func upgrade(to mac: FoundMac) {
        q.async {
            guard self.wantConnected, self.label != "Wi-Fi" else { return }
            self.plan = (self.cloudMac.map { Self.plan(for: $0, lan: []) } ?? [])
            self.target = mac
            self.label = "Wi-Fi"
            self.open()
        }
    }

    func disconnect() {
        wantConnected = false
        q.async { self.teardown() }
        DispatchQueue.main.async { self.phase = .idle; self.vitals = nil; self.reconnecting = false }
    }

    func forgetMac() {
        if let id = macID { Keychain.delete(id) }
        rememberedMac = nil
        disconnect()
    }

    private func teardown() {         // on q
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        conn = nil
        key = nil
        heard = false
        let p = pending
        pending = [:]
        DispatchQueue.main.async { p.values.forEach { $0(.failure(LinkError("Disconnected"))) } }
    }

    private func lost(_ why: String) {   // on q
        let wasReady = key != nil
        teardown()
        guard wantConnected else { return }
        attempt += 1
        if wasReady || attempt <= 6 {
            DispatchQueue.main.async { if wasReady { self.reconnecting = true } }
            let delay = min(Double(attempt) * 1.5, 8)
            q.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.wantConnected, self.conn == nil else { return }
                self.replan()
            }
        } else {
            DispatchQueue.main.async { self.phase = .failed(why); self.reconnecting = false }
        }
    }

    private func fail(_ why: String, forget: Bool = false) {   // on q
        wantConnected = false
        if forget, let id = macID { Keychain.delete(id) }
        teardown()
        DispatchQueue.main.async { self.phase = .failed(why); self.reconnecting = false }
    }

    // MARK: Wire

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self, weak c] data, ctx, _, err in
            guard let self, let c, c === self.conn else { return }
            if let err { self.dropped(err.localizedDescription); return }
            if let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .close { self.lost("The Mac hung up"); return }
            if let data, !data.isEmpty { self.handle(data) }
            if c === self.conn { self.receive(c) }
        }
    }

    private func sendRaw(_ d: Data) {
        let ctx = quic ? TriageFramer.context
            : NWConnection.ContentContext(identifier: "triage", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        conn?.send(content: d, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func sendPlain(_ o: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: o) { sendRaw(d) }
    }

    private func sendSealed(_ o: [String: Any]) {
        guard let key, let d = try? JSONSerialization.data(withJSONObject: o),
              let box = try? ChaChaPoly.seal(d, using: key) else { return }
        sendRaw(box.combined)
    }

    private func transcript(_ label: String) -> Data {
        Data(label.utf8) + eph.publicKey.rawRepresentation + (serverPub?.rawRepresentation ?? Data()) + nonce
    }

    private func unlock(_ secret: Data) {
        guard let serverPub, let shared = try? eph.sharedSecretFromKeyAgreement(with: serverPub) else { return }
        key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: secret + nonce,
                                             sharedInfo: Data("triage-session-v1".utf8), outputByteCount: 32)
    }

    private func handle(_ data: Data) {   // on q
        var plainJSON: [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        if let key {
            if let box = try? ChaChaPoly.SealedBox(combined: data), let plain = try? ChaChaPoly.open(box, using: key) {
                if plain.first == 0x46 || plain.first == 0x56 { RemoteFrames.shared.receive(plain); return }   // "F" JPEG or "V" video frame
                if let o = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] { handleSecure(o); return }
            }
            // A wrong pairing code (or a rejected auth) comes back in plain JSON.
            guard let o = plainJSON else { lost("Garbled message"); return }
            self.key = nil
            pendingSecret = nil
            handlePlain(o)
            return
        }
        if let o = plainJSON { handlePlain(o) }
    }

    private func handlePlain(_ o: [String: Any]) {   // on q
        guard let t = o["t"] as? String else { return }
        switch t {
        case "hello":
            guard let pubB64 = o["pub"] as? String, let pubData = Data(base64Encoded: pubB64),
                  let pub = try? P256.KeyAgreement.PublicKey(rawRepresentation: pubData),
                  let n = (o["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }) else { fail("That doesn't look like Triage"); return }
            serverPub = pub
            nonce = n
            heard = true
            macID = o["macID"] as? String ?? (o["name"] as? String)
            let name = o["name"] as? String ?? "Mac"
            let paired = o["paired"] as? Bool ?? false
            DispatchQueue.main.async { self.macName = name }
            if paired, let id = macID, let secret = Keychain.get(id) {
                let mac = HMAC<SHA256>.authenticationCode(for: transcript("auth"), using: SymmetricKey(data: secret))
                unlock(secret)
                sendPlain(["t": "auth", "mac": Data(mac).base64EncodedString()])
            } else if !paired, let id = macID, let cloud = CloudDirectory.secret(for: id),
                      let shared = try? eph.sharedSecretFromKeyAgreement(with: pub) {
                // Same iCloud account: prove it with the Mac's iCloud key and pair without a code.
                let proof = HMAC<SHA256>.authenticationCode(for: transcript("cloudpair"), using: SymmetricKey(data: cloud))
                let s = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: cloud, sharedInfo: Data("triage-pair-v1".utf8),
                                                       outputByteCount: 32).withUnsafeBytes { Data($0) }
                pendingSecret = (id, s)
                sendPlain(["t": "cloudPair", "proof": Data(proof).base64EncodedString()])
                unlock(s)
            } else {
                if let id = macID { Keychain.delete(id) }
                DispatchQueue.main.async { self.phase = .needsCode(wrong: false); self.reconnecting = false }
            }
        case "error":
            if o["retry"] as? Bool == true {
                DispatchQueue.main.async { self.phase = .needsCode(wrong: true) }
            } else {
                let why = o["error"] as? String ?? "The Mac said no"
                fail(why, forget: why.contains("isn't paired") || why.contains("removed"))
            }
        default: break
        }
    }

    /// The person typed the code shown on the Mac.
    func submit(code: String) {
        q.async {
            guard let serverPub = self.serverPub, let id = self.macID,
                  let shared = try? self.eph.sharedSecretFromKeyAgreement(with: serverPub) else { return }
            let k = SymmetricKey(data: SHA256.hash(data: Data(code.utf8)))
            let proof = HMAC<SHA256>.authenticationCode(for: self.transcript("pair"), using: k)
            let secret = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(code.utf8),
                                                        sharedInfo: Data("triage-pair-v1".utf8), outputByteCount: 32)
            let secretData = secret.withUnsafeBytes { Data($0) }
            // Unlock now: if the code is right the Mac answers sealed, if wrong it answers in plain JSON.
            self.pendingSecret = (id, secretData)
            self.sendPlain(["t": "pair", "proof": Data(proof).base64EncodedString()])
            self.unlock(secretData)
        }
    }
    private var pendingSecret: (String, Data)?

    private func handleSecure(_ o: [String: Any]) {   // on q
        let t = o["t"] as? String ?? ""
        switch t {
        case "ready":
            if let (id, s) = pendingSecret { Keychain.set(s, for: id); pendingSecret = nil }
            attempt = 0
            let body = o["body"] as? [String: Any] ?? [:]
            let info: MacInfo? = decode(body)
            let mode = body["mode"] as? String ?? "view"
            let name = target?.id
            let theme = body["theme"] as? String
            let via = label
            DispatchQueue.main.async {
                self.route = via
                if let theme { ThemeModel.shared.macThemeID = theme }
                self.info = info
                self.mode = mode
                self.phase = .ready
                self.reconnecting = false
                self.session += 1
                if case .service = self.target?.endpoint { self.rememberedMac = name }
            }
            Task { _ = try? await self.call("subscribe", ["vitals": true]) }
        case "reply":
            let id = o["id"] as? Int ?? -1
            guard let done = pending.removeValue(forKey: id) else { return }
            let r: Result<[String: Any], LinkError> = (o["ok"] as? Bool == true)
                ? .success(o["data"] as? [String: Any] ?? [:])
                : .failure(LinkError(o["error"] as? String ?? "Something went wrong"))
            DispatchQueue.main.async { done(r) }
        case "vitals":
            if let v: Vitals = decode(o["body"] ?? [:]) { DispatchQueue.main.async { self.vitals = v } }
        case "theme":
            if let id = (o["body"] as? [String: Any])?["id"] as? String {
                DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.4)) { ThemeModel.shared.macThemeID = id } }
            }
        case "clipboard":
            if let t = (o["body"] as? [String: Any])?["text"] as? String, UserDefaults.standard.object(forKey: "remote.clipAuto") as? Bool ?? true {
                DispatchQueue.main.async {
                    UIPasteboard.general.string = t
                    RemoteFrames.shared.flash("Copied from \(self.macName)")
                }
            }
        case "desktopEnded":
            DispatchQueue.main.async { RemoteFrames.shared.ended = true }
        case "bye":
            let why = (o["body"] as? [String: Any])?["reason"] as? String ?? "The Mac closed the connection"
            fail(why, forget: why.contains("removed"))
        default: break
        }
    }

    // MARK: Requests

    func call(_ op: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            q.async {
                guard self.key != nil, self.conn != nil else { cont.resume(throwing: LinkError("Not connected to your Mac")); return }
                self.seq += 1
                let id = self.seq
                self.pending[id] = { r in
                    switch r {
                    case .success(let d): cont.resume(returning: d)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
                self.sendSealed(["id": id, "n": id, "op": op, "args": args])
                self.q.asyncAfter(deadline: .now() + 25) {
                    if let done = self.pending.removeValue(forKey: id) {
                        DispatchQueue.main.async { done(.failure(LinkError("Your Mac took too long to answer"))) }
                    }
                }
            }
        }
    }

    /// Fire and forget (mouse and keys): no reply, no waiting.
    func send(_ op: String, _ args: [String: Any]) {
        q.async {
            guard self.key != nil, self.conn != nil else { return }
            self.seq += 1
            self.sendSealed(["id": self.seq, "n": self.seq, "op": op, "args": args])
        }
    }

    func setKeepAwake(_ on: Bool) async throws {
        _ = try await call("keepAwake", ["on": on])
    }

    /// Mac → phone, 4 MB at a time, into a cache folder Quick Look and Share can open.
    func download(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads/" + String(abs(path.hashValue)), isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent((path as NSString).lastPathComponent)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let h = try FileHandle(forWritingTo: out)
        defer { try? h.close() }
        var offset = 0
        while true {
            let d = try await call("fetch", ["path": path, "offset": offset])
            guard let b64 = d["data"] as? String, let data = Data(base64Encoded: b64) else { throw LinkError("The Mac sent something unreadable") }
            try h.write(contentsOf: data)
            offset += data.count
            let size = max(d["size"] as? Int ?? 1, 1)
            await MainActor.run { progress(min(Double(offset) / Double(size), 1)) }
            if (d["done"] as? Bool) == true || data.isEmpty { break }
        }
        return out
    }

    /// Phone → Mac, 4 MB at a time. Returns the path it landed at (renamed if the name was taken).
    func upload(_ data: Data, name: String, to dir: String, progress: @escaping (Double) -> Void) async throws -> String {
        let chunk = 4 << 20
        var target: String?
        var i = 0
        repeat {
            let piece = data.subdata(in: i..<min(i + chunk, data.count))
            var args: [String: Any] = ["data": piece.base64EncodedString(), "last": i + chunk >= data.count]
            if let target { args["target"] = target } else { args["dir"] = dir; args["name"] = name }
            let d = try await call("upload", args)
            target = d["target"] as? String
            i += chunk
            let done = Double(min(i, data.count)) / Double(max(data.count, 1))
            await MainActor.run { progress(done) }
        } while i < data.count
        return target ?? dir
    }
}

func decode<T: Decodable>(_ o: Any) -> T? {
    guard JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o) else { return nil }
    return try? JSONDecoder().decode(T.self, from: d)
}

enum Keychain {
    static let service = "com.alenlvovich.triage.ios.pairing"

    static func set(_ d: Data, for account: String) {
        delete(account)
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                  kSecValueData: d, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ account: String) -> Data? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                  kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(_ account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }
}
