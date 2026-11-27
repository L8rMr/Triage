import Foundation
import Network
import CryptoKit
import AppKit
import SwiftUI
import Combine
import IOKit.pwr_mgt

// MARK: - Triage Remote: the iPhone companion's way in
//
// Bonjour service `_triage._tcp`, WebSocket frames over TCP on the local network.
// Handshake (plain JSON):  hello ⇄ hello  →  pair (6-digit code shown on this Mac) | auth (stored secret)
// Every frame after that is ChaChaPoly-sealed with a fresh per-connection key
// (P-256 ECDH, HKDF-SHA256 salted with the long-term pairing secret), so a replayed
// or sniffed session is useless and a stolen phone can be forgotten from Settings.

enum RemoteMode: String, CaseIterable, Identifiable {
    case off, view, full
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .view: return "View only"
        case .full: return "Full control"
        }
    }
}

struct RemoteDevice: Codable, Identifiable {
    let id: String
    var name: String
    var paired: Date
    var lastSeen: Date?
}

struct RemoteEvent: Codable, Identifiable {
    var id = UUID()
    let t: Date
    let device: String
    let action: String
}

final class RemoteServer: ObservableObject {
    static let shared = RemoteServer()
    static let serviceType = "_triage._tcp"
    static let preferredPort: UInt16 = 52384

    struct PairingRequest: Identifiable, Equatable {
        let id = UUID()
        let session: UUID
        let device: String
        let code: String
    }

    @Published private(set) var listening = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var status = "Off"
    @Published private(set) var devices: [RemoteDevice] = []
    @Published private(set) var connected: [UUID: String] = [:]
    @Published private(set) var log: [RemoteEvent] = []
    @Published private(set) var pairing: PairingRequest?
    @Published private(set) var keepAwake = false

    /// Stable id the phone files this Mac's pairing secret under.
    static var macID: String {
        if let s = UserDefaults.standard.string(forKey: "remote.macID") { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: "remote.macID")
        return s
    }

    /// True while a phone is watching live vitals, so the monitor keeps its foreground pace.
    static var watching = false

    @Published var mode: RemoteMode = RemoteMode(rawValue: UserDefaults.standard.string(forKey: "remote.mode") ?? "off") ?? .off {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "remote.mode")
            if mode != oldValue { record("This Mac", "Remote access set to \(mode.title)"); apply() }
        }
    }

    let queue = DispatchQueue(label: "triage.remote")
    private var listener: NWListener?
    private var sessions: [UUID: RemoteSession] = [:]      // touched only on `queue`
    private var assertion: IOPMAssertionID = 0
    private var vitalsSink: AnyCancellable?
    private var themeSink: AnyCancellable?
    private var retry: DispatchWorkItem?

    private init() {}

    func start() {
        load()
        apply()
        if UserDefaults.standard.bool(forKey: "remote.keepAwake") { setKeepAwake(true, by: nil) }
        CloudPresence.shared.start()            // reachable from anywhere through the user's iCloud
        vitalsSink = SystemMonitor.shared.$bpm
            .receive(on: DispatchQueue.main)        // @Published fires in willSet; hop once so we read the new values
            .sink { [weak self] _ in self?.pushVitals() }
        // the Mac's theme changed: phones that follow it repaint
        themeSink = ThemeStore.shared.$themeID
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self, self.listening else { return }
                self.queue.async { self.sessions.values.forEach { $0.push("theme", ["id": id]) } }
            }
    }

    // MARK: Listener

    private func apply() {
        if mode == .off { stop(); return }
        guard listener == nil else { status = listening ? statusLine : status; return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true                      // remote desktop: send every tiny input/frame now, not batched
        let params = NWParameters(tls: nil, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 16 << 20
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.includePeerToPeer = false
        let l: NWListener
        do {
            if let p = NWEndpoint.Port(rawValue: Self.preferredPort), let fixed = try? NWListener(using: params, on: p) { l = fixed }
            else { l = try NWListener(using: params) }
        } catch {
            status = "Couldn't start: \(error.localizedDescription)"
            return
        }
        l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: Self.serviceType)
        l.stateUpdateHandler = { [weak self, weak l] st in
            DispatchQueue.main.async { self?.listenerChanged(st, l) }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener = l
        status = "Starting…"
        l.start(queue: queue)
    }

    private var statusLine: String {
        connected.isEmpty ? "Waiting for your iPhone on port \(port)" : "\(connected.values.sorted().joined(separator: ", ")) connected"
    }

    private func listenerChanged(_ st: NWListener.State, _ l: NWListener?) {
        switch st {
        case .ready:
            listening = true
            port = l?.port?.rawValue ?? 0
            status = statusLine
        case .failed(let e):
            listening = false
            status = "Stopped: \(e.localizedDescription). Retrying…"
            listener?.cancel(); listener = nil
            retry?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.apply() }
            retry = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
        case .cancelled:
            listening = false
        default: break
        }
    }

    private func stop() {
        retry?.cancel()
        listener?.cancel(); listener = nil
        queue.async { [weak self] in
            self?.sessions.values.forEach { $0.close() }
            self?.sessions.removeAll()
        }
        listening = false
        connected = [:]
        pairing = nil
        PairingHUD.shared.hide()
        let keep = UserDefaults.standard.bool(forKey: "remote.keepAwake")
        setKeepAwake(false, by: nil)
        UserDefaults.standard.set(keep, forKey: "remote.keepAwake")
        Self.watching = false
        status = "Off"
    }

    /// A phone arriving over the internet (QUIC + length-prefixed frames instead of WebSocket).
    func acceptFramed(_ c: NWConnection) {     // on queue
        guard mode != .off else { c.cancel(); return }
        let s = RemoteSession(conn: c, server: self, framed: true)
        sessions[s.id] = s
        s.start()
    }

    private func accept(_ c: NWConnection) {   // on queue
        let s = RemoteSession(conn: c, server: self)
        sessions[s.id] = s
        s.start()
    }

    func dropped(_ s: RemoteSession) {        // on queue
        sessions[s.id] = nil
        stopWatching(s)
        if s.clipSync { clipboardWatchChanged() }
        let anyWatching = sessions.values.contains { $0.subscribed }
        DispatchQueue.main.async {
            if let name = self.connected.removeValue(forKey: s.id) { self.record(name, "Disconnected") }
            if self.pairing?.session == s.id { self.endPairing() }
            Self.watching = anyWatching
            if self.listening { self.status = self.statusLine }
        }
    }

    func authenticated(_ s: RemoteSession) {  // on queue
        DispatchQueue.main.async {
            self.connected[s.id] = s.deviceName
            if let i = self.devices.firstIndex(where: { $0.id == s.deviceID }) {
                self.devices[i].lastSeen = Date()
                self.devices[i].name = s.deviceName
                self.save()
            }
            self.record(s.deviceName, "Connected")
            self.status = self.statusLine
        }
    }

    // MARK: Pairing

    func beginPairing(_ s: RemoteSession) -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        DispatchQueue.main.async {
            let req = PairingRequest(session: s.id, device: s.deviceName, code: code)
            self.pairing = req
            PairingHUD.shared.show(req)
            NSSound(named: "Glass")?.play()
        }
        return code
    }

    func endPairing() {
        pairing = nil
        PairingHUD.shared.hide()
    }

    /// The person clicked Cancel on the Mac.
    func cancelPairing() {
        guard let p = pairing else { return }
        endPairing()
        queue.async { self.sessions[p.session]?.reject("Pairing was cancelled on the Mac") }
    }

    func storePairing(id: String, name: String, secret: Data) {
        RemoteKeychain.set(secret, for: id)
        DispatchQueue.main.async {
            self.devices.removeAll { $0.id == id }
            self.devices.append(RemoteDevice(id: id, name: name, paired: Date(), lastSeen: Date()))
            self.save()
            self.endPairing()
            self.record(name, "Paired")
        }
    }

    func secret(for id: String) -> Data? { RemoteKeychain.get(id) }

    func forget(_ d: RemoteDevice) {
        RemoteKeychain.delete(d.id)
        devices.removeAll { $0.id == d.id }
        save()
        record(d.name, "Forgotten on this Mac")
        queue.async { self.sessions.values.filter { $0.deviceID == d.id }.forEach { $0.reject("This iPhone was removed on the Mac") } }
    }

    // MARK: Remote desktop

    @Published private(set) var watcher: String?
    private var watchingSession: UUID?
    private var clipTimer: Timer?
    private var clipCount = NSPasteboard.general.changeCount

    private var displayAssertion: IOPMAssertionID = 0

    /// Wake a sleeping display and keep it on: a dark screen can't be streamed.
    private func holdDisplay(_ on: Bool) {
        if on {
            var wake: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Triage remote desktop" as CFString, kIOPMUserActiveLocal, &wake)
            if displayAssertion == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "Triage: remote desktop in use" as CFString, &displayAssertion)
            }
        } else if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }

    func startWatching(_ s: RemoteSession) {
        let id = s.id
        DispatchQueue.main.async { self.holdDisplay(true) }
        ScreenShare.shared.onFrame = { [weak self] frame in
            guard let self else { return }
            self.queue.async {
                if self.sessions[id]?.pushBinary(frame) == false && frame.first == 0x56 { ScreenShare.shared.requestKeyframe() }
            }
        }
        DispatchQueue.main.async {
            if self.watchingSession != id { self.record(s.deviceName, "Started remote desktop") }
            self.watchingSession = id
            self.watcher = s.deviceName
        }
    }

    func stopWatching(_ s: RemoteSession) {
        DispatchQueue.main.async {
            guard self.watchingSession == s.id else { return }
            ScreenShare.shared.onFrame = nil
            ScreenShare.shared.stop()
            self.holdDisplay(false)
            self.watchingSession = nil
            self.watcher = nil
            self.record(s.deviceName, "Ended remote desktop")
        }
    }

    /// The person at the Mac pulled the plug on the phone's remote session.
    func endDesktop() {
        guard let id = watchingSession else { return }
        ScreenShare.shared.onFrame = nil
        ScreenShare.shared.stop()
        holdDisplay(false)
        record(watcher ?? "iPhone", "Remote desktop stopped from the Mac")
        watchingSession = nil
        watcher = nil
        queue.async { self.sessions[id]?.push("desktopEnded", [:]) }
    }

    /// Phones that asked for it get whatever the Mac copies, as it happens.
    func clipboardWatchChanged() {
        queue.async {
            let any = self.sessions.values.contains { $0.clipSync }
            DispatchQueue.main.async {
                if any && self.clipTimer == nil {
                    self.clipCount = NSPasteboard.general.changeCount
                    let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.pollClipboard() }
                    RunLoop.main.add(t, forMode: .common)
                    self.clipTimer = t
                } else if !any {
                    self.clipTimer?.invalidate(); self.clipTimer = nil
                }
            }
        }
    }

    func noteOwnClipboardChange() {
        DispatchQueue.main.async { self.clipCount = NSPasteboard.general.changeCount }
    }

    private func pollClipboard() {
        let c = NSPasteboard.general.changeCount
        guard c != clipCount else { return }
        clipCount = c
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty, text.count < 200_000 else { return }
        queue.async { self.sessions.values.filter { $0.clipSync }.forEach { $0.push("clipboard", ["text": text]) } }
    }

    // MARK: Live vitals

    private func pushVitals() {
        guard listening, Self.watching else { return }
        let v = RemoteAPI.vitals()
        queue.async { self.sessions.values.filter { $0.subscribed }.forEach { $0.push("vitals", v) } }
    }

    func subscriptionChanged() {             // on queue
        let any = sessions.values.contains { $0.subscribed }
        DispatchQueue.main.async { Self.watching = any }
    }

    // MARK: Keep awake

    /// Survives restarts and app updates: the Mac stays awake until someone turns it off.
    func setKeepAwake(_ on: Bool, by device: String?) {
        UserDefaults.standard.set(on, forKey: "remote.keepAwake")
        guard on != keepAwake else { return }
        if on {
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Triage: kept awake from iPhone" as CFString, &assertion)
            keepAwake = r == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
            keepAwake = false
        }
        if let device { record(device, on ? "Kept the Mac awake" : "Let the Mac sleep again") }
    }

    // MARK: Activity log + storage

    func record(_ device: String, _ action: String) {
        let e = RemoteEvent(t: Date(), device: device, action: action)
        let apply = {
            self.log.insert(e, at: 0)
            if self.log.count > 300 { self.log.removeLast(self.log.count - 300) }
            self.saveLog()
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private var devicesURL: URL { Shell.supportDir.appendingPathComponent("remote-devices.json") }
    private var logURL: URL { Shell.supportDir.appendingPathComponent("remote-log.json") }

    private func load() {
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: devicesURL), let v = try? dec.decode([RemoteDevice].self, from: d) { devices = v }
        if let d = try? Data(contentsOf: logURL), let v = try? dec.decode([RemoteEvent].self, from: d) { log = v }
    }
    private func save() { try? JSONEncoder().encode(devices).write(to: devicesURL, options: .atomic) }
    private func saveLog() { try? JSONEncoder().encode(log).write(to: logURL, options: .atomic) }
}

// MARK: - One phone connection

final class RemoteSession {
    let id = UUID()
    let conn: NWConnection
    unowned let server: RemoteServer

    var deviceID: String?
    var deviceName = "iPhone"
    var subscribed = false
    var clipSync = false
    private var framesInFlight = 0
    private var sentAt: [Date] = []         // when each in-flight frame left; a slot frees itself after a second regardless
    private var needKey = false             // a video frame was dropped: everything until the next keyframe is useless

    private let eph = P256.KeyAgreement.PrivateKey()
    private var clientPub: P256.KeyAgreement.PublicKey?
    private let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    private var key: SymmetricKey?
    private var code: String?
    private var attempts = 0
    private var lastSeq = 0
    private var closed = false

    let framed: Bool
    private var cloudCandidate = false

    init(conn: NWConnection, server: RemoteServer, framed: Bool = false) {
        self.conn = conn
        self.server = server
        self.framed = framed
    }

    private var context: NWConnection.ContentContext {
        framed ? TriageFramer.context
               : NWConnection.ContentContext(identifier: "triage", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
    }

    func start() {
        let framed = self.framed, peer = "\(conn.endpoint)"
        if framed { server.record("Internet", "Connection attempt from \(peer)") }
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: if framed { self?.server.record("Internet", "Secure link up with \(peer)") }
            case .failed(let e):
                if framed { self?.server.record("Internet", "Link from \(peer) failed: \(e.localizedDescription)") }
                self?.close()
            case .waiting(let e): if framed { self?.server.record("Internet", "Link from \(peer) waiting: \(e.localizedDescription)") }
            case .cancelled: self?.close()
            default: break
            }
        }
        conn.start(queue: server.queue)
        receive()
        // Anyone who hasn't finished the handshake in two minutes goes away.
        server.queue.asyncAfter(deadline: .now() + 120) { [weak self] in
            if let self, self.key == nil { self.close() }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        conn.cancel()
        server.dropped(self)
    }

    func reject(_ why: String) {
        if key != nil { push("bye", ["reason": why]) } else { sendPlain(["t": "error", "error": why]) }
        server.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.close() }
    }

    private func receive() {
        conn.receiveMessage { [weak self] data, ctx, _, err in
            guard let self, !self.closed else { return }
            if err != nil { self.close(); return }
            if !self.framed, let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .close { self.close(); return }
            if let data, !data.isEmpty { self.handle(data) }
            if !self.closed { self.receive() }
        }
    }

    // MARK: Sending

    private func sendRaw(_ d: Data) {
        conn.send(content: d, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func sendPlain(_ o: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: o) { sendRaw(d) }
    }

    func sendSecure(_ o: [String: Any]) {
        guard let key, !closed,
              let d = try? JSONSerialization.data(withJSONObject: RemoteAPI.jsonSafe(o)),
              let box = try? ChaChaPoly.seal(d, using: key) else { return }
        sendRaw(box.combined)
    }

    func push(_ type: String, _ body: [String: Any]) { sendSecure(["t": type, "body": body]) }

    /// Screen frames: sealed raw bytes, at most two on the wire, so a slow moment drops frames instead of building lag.
    /// Returns false when the frame was dropped (link busy): video then needs a fresh keyframe.
    @discardableResult
    func pushBinary(_ payload: Data) -> Bool {       // on queue
        guard let key, !closed else { return false }
        let video = payload.first == 0x56
        let isKey = video && payload.count > 2 && payload[payload.startIndex + 2] == 1
        // Slots normally free when the send completes; on a slow internet path that can lag, so they also age out.
        let now = Date()
        sentAt.removeAll { now.timeIntervalSince($0) > 1.0 }
        framesInFlight = min(framesInFlight, sentAt.count)
        if video && needKey && !isKey { return true }            // waiting for a keyframe: don't spend the link on frames that can't show
        let limit = video ? (isKey ? 8 : 4) : 2                  // a keyframe always gets through a busy moment
        guard framesInFlight < limit, let box = try? ChaChaPoly.seal(payload, using: key) else {
            if video { needKey = true }
            return false
        }
        if isKey { needKey = false }
        framesInFlight += 1
        sentAt.append(now)
        conn.send(content: box.combined, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.server.queue.async {
                self.framesInFlight = max(0, self.framesInFlight - 1)
                if !self.sentAt.isEmpty { self.sentAt.removeFirst() }
            }
        })
        return true
    }

    // MARK: Handshake

    private var serverPubRaw: Data { eph.publicKey.rawRepresentation }

    private func transcript(_ label: String) -> Data {
        Data(label.utf8) + (clientPub?.rawRepresentation ?? Data()) + serverPubRaw + nonce
    }

    private func handle(_ data: Data) {
        if key != nil { handleSecure(data); return }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let t = o["t"] as? String else {
            reject("Unreadable message"); return
        }
        switch t {
        case "hello":
            guard server.mode != .off else { reject("Remote access is off on this Mac"); return }
            guard let id = o["id"] as? String, !id.isEmpty, id.count < 100,
                  let pubB64 = o["pub"] as? String, let pubData = Data(base64Encoded: pubB64),
                  let pub = try? P256.KeyAgreement.PublicKey(rawRepresentation: pubData) else { reject("Bad hello"); return }
            deviceID = id
            deviceName = String(((o["name"] as? String) ?? "iPhone").prefix(60))
            clientPub = pub
            let known = server.secret(for: id) != nil
            sendPlain(["t": "hello", "v": 1, "name": Host.current().localizedName ?? "Mac", "macID": RemoteServer.macID,
                       "pub": serverPubRaw.base64EncodedString(), "nonce": nonce.base64EncodedString(),
                       "paired": known, "mode": server.mode.rawValue])
            // Same iCloud account? The phone read our pairing key from the private database: no code needed.
            cloudCandidate = !known && ((o["cloud"] as? [String]) ?? []).contains(RemoteServer.macID)
            if !known && !cloudCandidate {
                // A new phone pairs with a code only on the same network: nobody on the internet can pop the code up.
                guard ToolHub.overLAN(self) else { reject("Pair on the same Wi-Fi first (or sign the phone into the same iCloud account)"); return }
                code = server.beginPairing(self)
            }

        case "auth":
            guard let id = deviceID, let secret = server.secret(for: id),
                  let macB64 = o["mac"] as? String, let mac = Data(base64Encoded: macB64),
                  HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: transcript("auth"), using: SymmetricKey(data: secret))
            else { reject("This iPhone isn't paired with this Mac any more"); return }
            unlock(with: secret)
            sendSecure(["t": "ready", "body": RemoteAPI.hello(mode: server.mode)])
            server.authenticated(self)

        case "cloudPair":
            guard cloudCandidate, let id = deviceID, let clientPub,
                  let proof = (o["proof"] as? String).flatMap({ Data(base64Encoded: $0) }) else { reject("Not pairing"); return }
            let cloud = CloudPresence.cloudSecret
            guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: transcript("cloudpair"), using: SymmetricKey(data: cloud)),
                  let shared = try? eph.sharedSecretFromKeyAgreement(with: clientPub) else {
                reject("This iPhone isn't on the same iCloud account"); return
            }
            let secretData = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: cloud, sharedInfo: Data("triage-pair-v1".utf8),
                                                            outputByteCount: 32).withUnsafeBytes { Data($0) }
            server.storePairing(id: id, name: deviceName, secret: secretData)
            server.record(deviceName, "Paired through iCloud")
            unlock(with: secretData)
            sendSecure(["t": "ready", "body": RemoteAPI.hello(mode: server.mode)])
            server.authenticated(self)

        case "pair":
            guard let code, let id = deviceID, let clientPub,
                  let proofB64 = o["proof"] as? String, let proof = Data(base64Encoded: proofB64) else { reject("Not pairing"); return }
            let k = SymmetricKey(data: SHA256.hash(data: Data(code.utf8)))
            guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: transcript("pair"), using: k) else {
                attempts += 1
                if attempts >= 3 {
                    DispatchQueue.main.async { self.server.endPairing() }
                    server.record(deviceName, "Pairing failed: wrong code three times")
                    reject("Wrong code three times. Start pairing again.")
                } else {
                    sendPlain(["t": "error", "error": "Wrong code", "retry": true])
                }
                return
            }
            guard let shared = try? eph.sharedSecretFromKeyAgreement(with: clientPub) else { reject("Key exchange failed"); return }
            let secret = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(code.utf8),
                                                        sharedInfo: Data("triage-pair-v1".utf8), outputByteCount: 32)
            let secretData = secret.withUnsafeBytes { Data($0) }
            server.storePairing(id: id, name: deviceName, secret: secretData)
            self.code = nil
            unlock(with: secretData)
            sendSecure(["t": "ready", "body": RemoteAPI.hello(mode: server.mode).merging(["secret": secretData.base64EncodedString()]) { $1 }])
            server.authenticated(self)

        default:
            reject("Say hello first")
        }
    }

    /// Fresh key for this connection: ECDH of two throwaway keys, salted with the pairing secret and this Mac's nonce.
    private func unlock(with secret: Data) {
        guard let clientPub, let shared = try? eph.sharedSecretFromKeyAgreement(with: clientPub) else { return }
        key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: secret + nonce,
                                             sharedInfo: Data("triage-session-v1".utf8), outputByteCount: 32)
    }

    // MARK: Requests

    private func handleSecure(_ data: Data) {
        guard let key, let box = try? ChaChaPoly.SealedBox(combined: data),
              let plain = try? ChaChaPoly.open(box, using: key),
              let req = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else { reject("Couldn't decrypt"); return }
        let seq = (req["n"] as? Int) ?? 0
        guard seq > lastSeq else { return }          // replayed frame
        lastSeq = seq
        let rid = req["id"] ?? seq
        let op = req["op"] as? String ?? ""
        let args = req["args"] as? [String: Any] ?? [:]

        if op == "input" {                         // the hot path: no reply, no main thread
            if server.mode == .full, let ev = args["events"] as? [[String: Any]] {
                if RemoteInput.trusted { RemoteInput.handle(ev) } else { RemoteInput.askForAccess() }
            }
            return
        }
        if op == "subscribe" {
            subscribed = (args["vitals"] as? Bool) ?? true
            server.subscriptionChanged()
            sendSecure(["t": "reply", "id": rid, "ok": true, "data": [:] as [String: Any]])
            return
        }
        RemoteAPI.perform(op, args, session: self, mode: server.mode) { [weak self] result in
            guard let self else { return }
            self.server.queue.async {
                switch result {
                case .success(let d): self.sendSecure(["t": "reply", "id": rid, "ok": true, "data": d])
                case .failure(let e): self.sendSecure(["t": "reply", "id": rid, "ok": false, "error": e.message])
                }
            }
        }
    }
}

// MARK: - What the phone can ask for

struct RemoteError: Error { let message: String }

enum RemoteAPI {
    typealias Done = (Result<[String: Any], RemoteError>) -> Void

    static func hello(mode: RemoteMode) -> [String: Any] {
        var d = info()
        d["mode"] = mode.rawValue
        d["ops"] = allOps + (mode == .full ? Array(writeOps) : [])
        return d
    }

    static func perform(_ op: String, _ a: [String: Any], session s: RemoteSession, mode: RemoteMode, done: @escaping Done) {
        DispatchQueue.main.async {
            if writeOps.contains(op) && mode != .full {
                done(.failure(RemoteError(message: "This Mac only allows viewing. Turn on Full control in Triage › Settings › iPhone.")))
                return
            }
            switch op {
            case "vitals": done(.success(vitals()))
            case "info": done(.success(info()))
            case "apps": done(.success(["apps": SystemMonitor.shared.topByCPU.prefix(60).map(appDict)]))
            case "list": list(a, done)
            case "search":
                let scope = (a["scope"] as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                RemoteSearch.run((a["q"] as? String) ?? "", limit: min((a["limit"] as? Int) ?? 80, 300), scope: scope) { done(.success(["hits": $0])) }
            case "keepAwake":
                let on = (a["on"] as? Bool) ?? true
                RemoteServer.shared.setKeepAwake(on, by: s.deviceName)
                done(.success(["keepAwake": RemoteServer.shared.keepAwake]))
            case "quitApp": quitApp(a, s, done)
            case "trash": trash(a, s, done)
            case "emptyTrash":
                guard (a["confirm"] as? String) == "EMPTY" else { done(.failure(RemoteError(message: "Confirm on the phone first"))); return }
                FileOps.emptyTrash()
                RemoteServer.shared.record(s.deviceName, "Emptied the Trash")
                done(.success([:]))
            default:
                if !desktop(op, a, s, done) && !more(op, a, s, done) && !tools(op, a, s, done) { done(.failure(RemoteError(message: "Unknown request \(op)"))) }
            }
        }
    }

    // MARK: Readings

    static func vitals() -> [String: Any] {
        let m = SystemMonitor.shared, s = m.snap
        var d: [String: Any] = [
            "t": Date().timeIntervalSince1970, "bpm": m.bpm, "bpmHistory": m.bpmHistory,
            "cpu": s.cpu, "cpuHistory": m.cpuHistory,
            "memUsed": s.memUsed, "memTotal": s.memTotal, "memApp": s.memApp, "memWired": s.memWired,
            "memCompressed": s.memCompressed, "swap": s.swapUsed, "pressure": s.pressureLevel,
            "netIn": s.netIn, "netOut": s.netOut, "diskFree": s.diskFree, "diskTotal": s.diskTotal,
            "thermal": s.thermal.rawValue, "uptime": MacFacts.uptime,
            "keepAwake": RemoteServer.shared.keepAwake,
            "top": m.topByCPU.prefix(6).map(appDict),
        ]
        if let h = m.heart {
            d["health"] = h.health
            d["status"] = h.status
            d["factors"] = h.factors.map { ["id": $0.id, "channel": $0.channel, "label": $0.label, "stress": $0.stress,
                                            "reading": $0.reading, "cause": $0.cause ?? ""] }
        }
        if let b = s.battery {
            d["battery"] = ["percent": b.percent, "charging": b.charging, "onAC": b.onAC,
                            "minutesLeft": b.minutesLeft ?? -1, "cycles": b.cycles ?? -1, "health": b.health ?? -1]
        }
        return d
    }

    static func info() -> [String: Any] {
        var d: [String: Any] = ["name": Host.current().localizedName ?? "Mac", "model": MacFacts.model, "chip": MacFacts.chip,
                                "os": MacFacts.macOS, "boot": MacFacts.bootDate.timeIntervalSince1970,
                                "memTotal": ProcessInfo.processInfo.physicalMemory, "home": NSHomeDirectory(),
                                "user": NSFullUserName(), "theme": ThemeStore.shared.themeID]
        if let setup = MacFacts.setupDate { d["setup"] = setup.timeIntervalSince1970 }
        return d
    }

    static func appDict(_ a: AppUsage) -> [String: Any] {
        ["id": a.id, "name": a.name, "cpu": a.cpu, "memory": a.memory, "processes": a.processes.count,
         "system": a.isSystem, "bundle": a.bundlePath ?? ""]
    }

    // MARK: Files

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                                 .contentModificationDateKey, .isHiddenKey, .isPackageKey, .contentTypeKey]

    static func entry(_ u: URL) -> [String: Any] {
        let v = try? u.resourceValues(forKeys: Set(keys))
        var d: [String: Any] = ["name": u.lastPathComponent, "path": u.path,
                                "dir": (v?.isDirectory ?? false) && !(v?.isPackage ?? false)]
        if let s = v?.fileSize ?? v?.totalFileAllocatedSize { d["size"] = s }
        if let m = v?.contentModificationDate { d["modified"] = m.timeIntervalSince1970 }
        if let t = v?.contentType { d["type"] = t.identifier }
        d["trashable"] = trashable(u.path)
        return d
    }

    static func list(_ a: [String: Any], _ done: @escaping Done) {
        let path = (a["path"] as? String).map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
        let hidden = (a["hidden"] as? Bool) ?? false
        DispatchQueue.global(qos: .userInitiated).async {
            let u = URL(fileURLWithPath: path)
            do {
                let items = try FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: keys,
                                                                        options: hidden ? [] : [.skipsHiddenFiles])
                let entries = items.prefix(3000).map(entry).sorted {
                    let d0 = $0["dir"] as? Bool ?? false, d1 = $1["dir"] as? Bool ?? false
                    if d0 != d1 { return d0 }
                    return ($0["name"] as? String ?? "").localizedStandardCompare($1["name"] as? String ?? "") == .orderedAscending
                }
                done(.success(["path": u.path, "parent": u.deletingLastPathComponent().path, "entries": entries]))
            } catch {
                done(.failure(RemoteError(message: "Can't open \(u.lastPathComponent): \(error.localizedDescription)")))
            }
        }
    }

    /// Only things inside your home folder, never a top-level folder itself, never Library (except caches) or dotfiles.
    static func trashable(_ raw: String) -> Bool {
        let home = NSHomeDirectory()
        let u = URL(fileURLWithPath: raw).standardizedFileURL
        let parent = u.deletingLastPathComponent().resolvingSymlinksInPath().path
        let p = parent + "/" + u.lastPathComponent
        guard p.hasPrefix(home + "/") else { return false }
        let parts = p.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard let top = parts.first else { return false }
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        if parts.count == 1 && ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures",
                                "Public", "Applications", "Projects"].contains(top) { return false }
        if top == "Library" && !(parts.count > 2 && parts[1] == "Caches") { return false }
        return true
    }

    static func trash(_ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) {
        let paths = (a["paths"] as? [String]) ?? []
        guard !paths.isEmpty, paths.count <= 500 else { done(.failure(RemoteError(message: "Pick between 1 and 500 items"))); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var trashed: [String] = [], failed: [[String: String]] = []
            for p in paths {
                guard trashable(p) else { failed.append(["path": p, "error": "Protected location"]); continue }
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
                    trashed.append(p)
                } catch {
                    failed.append(["path": p, "error": error.localizedDescription])
                }
            }
            DispatchQueue.main.async {
                for p in trashed { RemoteServer.shared.record(s.deviceName, "Moved to Trash: \(p.replacingOccurrences(of: NSHomeDirectory(), with: "~"))") }
                done(.success(["trashed": trashed, "failed": failed]))
            }
        }
    }

    static func quitApp(_ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) {
        guard let id = a["id"] as? String, let app = SystemMonitor.shared.apps.first(where: { $0.id == id }) else {
            done(.failure(RemoteError(message: "That app isn't running any more"))); return
        }
        guard !app.isSystem, app.bundlePath != Bundle.main.bundlePath else {
            done(.failure(RemoteError(message: "\(app.name) can't be quit from the phone"))); return
        }
        let force = (a["force"] as? Bool) ?? false
        if force { app.processes.forEach { kill($0.pid, SIGKILL) } } else { SystemMonitor.shared.quit(app) }
        RemoteServer.shared.record(s.deviceName, (force ? "Force quit " : "Quit ") + app.name)
        done(.success(["quit": app.name]))
    }

    /// JSONSerialization chokes on non-finite doubles; scrub them.
    static func jsonSafe(_ v: Any) -> Any {
        switch v {
        case let d as Double: return d.isFinite ? d : 0
        case let a as [Any]: return a.map(jsonSafe)
        case let m as [String: Any]: return m.mapValues(jsonSafe)
        default: return v
        }
    }
}

// MARK: - Smart Search for the phone (same parser as ⌘Space search, one-shot)

final class RemoteSearch: NSObject {
    private static var live = Set<RemoteSearch>()
    private let query = NSMetadataQuery()
    private var parsed = SmartQuery()
    private var limit = 80
    private var done: (([[String: Any]]) -> Void)?

    static func run(_ text: String, limit: Int, scope: URL? = nil, done: @escaping ([[String: Any]]) -> Void) {
        var p = SmartParser.parse(text)
        if let scope, p.scope == nil { p.scope = scope }
        guard p.hasCriteria || scope != nil, let pred = NSPredicate(fromMetadataQueryString: p.metadataQuery) else { done([]); return }
        let r = RemoteSearch()
        r.parsed = p; r.limit = limit; r.done = done
        r.query.predicate = pred
        r.query.searchScopes = p.scope.map { [$0] } ?? [NSMetadataQueryUserHomeScope]
        live.insert(r)
        NotificationCenter.default.addObserver(r, selector: #selector(finished), name: .NSMetadataQueryDidFinishGathering, object: r.query)
        r.query.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak r] in r?.finished() }
    }

    private static let junk = ["/Library/Caches/", "/node_modules/", "/DerivedData/", "/Library/Containers/",
                               "/Library/Group Containers/", "/.Trash/", "/Library/Developer/"]

    @objc private func finished() {
        guard let done else { return }
        self.done = nil
        query.stop()
        NotificationCenter.default.removeObserver(self)
        var out: [(hit: [String: Any], size: Int64, date: Double)] = []
        for i in 0..<min(query.resultCount, 4000) {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String,
                  !path.contains("/."), !Self.junk.contains(where: { path.contains($0) }) else { continue }
            let size = (item.value(forAttribute: "kMDItemFSSize") as? NSNumber)?.int64Value ?? 0
            let mod = (item.value(forAttribute: "kMDItemFSContentChangeDate") as? Date) ?? .distantPast
            let used = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
            var h: [String: Any] = ["name": (item.value(forAttribute: "kMDItemDisplayName") as? String) ?? (path as NSString).lastPathComponent,
                                    "path": path, "size": size, "modified": mod.timeIntervalSince1970,
                                    "trashable": RemoteAPI.trashable(path)]
            if let t = item.value(forAttribute: "kMDItemContentType") as? String { h["type"] = t }
            if let used { h["used"] = used.timeIntervalSince1970 }
            out.append((h, size, (used ?? mod).timeIntervalSince1970))
        }
        switch parsed.order {
        case "size-desc": out.sort { $0.size > $1.size }
        case "size-asc": out.sort { $0.size < $1.size }
        case "date-asc": out.sort { $0.date < $1.date }
        default: out.sort { $0.date > $1.date }
        }
        done(out.prefix(limit).map(\.hit))
        Self.live.remove(self)
    }
}

// MARK: - Keychain for pairing secrets

enum RemoteKeychain {
    static let service = "com.alenlvovich.triage.remote"

    static func set(_ d: Data, for account: String) {
        delete(account)
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                  kSecValueData: d, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                  kSecAttrLabel: "Triage iPhone pairing"]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ account: String) -> Data? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                  kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(_ account: String) {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - The code on the Mac's screen, Apple TV style

final class PairingHUD {
    static let shared = PairingHUD()
    private var panel: NSPanel?

    func show(_ req: RemoteServer.PairingRequest) {
        hide()
        let host = NSHostingView(rootView: PairingCard(req: req))
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 40))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        panel = p
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }
}

private struct PairingCard: View {
    let req: RemoteServer.PairingRequest
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(hex6: 0x2BF59A))
                Text("\(req.device) wants to connect").font(.system(size: 14, weight: .semibold))
            }
            Text(req.code.prefix(3) + " " + req.code.suffix(3))
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .kerning(4)
                .foregroundStyle(Color(hex6: 0x2BF59A))
                .shadow(color: Color(hex6: 0x2BF59A).opacity(0.6), radius: 10)
            Text("Type this code on your iPhone to pair it with Triage.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Not now") { RemoteServer.shared.cancelPairing() }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 28).padding(.vertical, 20)
        .frame(width: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(Color(hex6: 0x0E1513).opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(hex6: 0x2BF59A).opacity(0.35), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}
