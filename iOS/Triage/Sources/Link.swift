import Foundation
import Network
import CryptoKit
import Security
import UIKit

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

    let deviceID: String = {
        if let s = UserDefaults.standard.string(forKey: "link.deviceID") { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: "link.deviceID")
        return s
    }()

    var deviceName: String {
        let n = UIDevice.current.name
        return n == "iPhone" || n == "iPad" ? "\(n) (\(UIDevice.current.model))" : n
    }

    // MARK: Connect / disconnect

    func connect(_ mac: FoundMac) {
        wantConnected = true
        target = mac
        open()
    }

    private func open() {
        guard let target else { return }
        q.async { self.teardown() }
        DispatchQueue.main.async {
            self.macName = target.id
            if self.phase != .ready { self.phase = .connecting(target.id) } else { self.reconnecting = true }
        }
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 16 << 20
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // Bonjour gives a service, WebSocket wants a URL-ish path; the service endpoint works as is.
        let c = NWConnection(to: target.endpoint, using: params)
        q.async {
            self.eph = P256.KeyAgreement.PrivateKey()
            self.key = nil
            self.seq = 0
            self.conn = c
            c.stateUpdateHandler = { [weak self, weak c] st in
                guard let self, let c, c === self.conn else { return }
                switch st {
                case .ready: self.sendPlain(["t": "hello", "v": 1, "id": self.deviceID, "name": self.deviceName,
                                             "pub": self.eph.publicKey.rawRepresentation.base64EncodedString()])
                case .failed(let e): self.lost("Couldn't reach \(target.id): \(e.localizedDescription)")
                case .waiting(let e): self.lost("Waiting for \(target.id): \(e.localizedDescription)")
                case .cancelled: break
                default: break
                }
            }
            c.start(queue: self.q)
            self.receive(c)
        }
    }

    /// Going to the background: hang up politely, come back on resume.
    func suspend() {
        q.async { self.teardown() }
    }

    func resume() {
        guard wantConnected, target != nil else { return }
        attempt = 0
        open()
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
                self.open()
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
            if let err { self.lost(err.localizedDescription); return }
            if let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .close { self.lost("The Mac hung up"); return }
            if let data, !data.isEmpty { self.handle(data) }
            if c === self.conn { self.receive(c) }
        }
    }

    private func sendRaw(_ d: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "triage", metadata: [meta])
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
        let plainJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let key {
            if let box = try? ChaChaPoly.SealedBox(combined: data), let plain = try? ChaChaPoly.open(box, using: key),
               let o = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] {
                handleSecure(o)
                return
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
            macID = o["macID"] as? String ?? (o["name"] as? String)
            let name = o["name"] as? String ?? "Mac"
            let paired = o["paired"] as? Bool ?? false
            DispatchQueue.main.async { self.macName = name }
            if paired, let id = macID, let secret = Keychain.get(id) {
                let mac = HMAC<SHA256>.authenticationCode(for: transcript("auth"), using: SymmetricKey(data: secret))
                unlock(secret)
                sendPlain(["t": "auth", "mac": Data(mac).base64EncodedString()])
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
            DispatchQueue.main.async {
                self.info = info
                self.mode = mode
                self.phase = .ready
                self.reconnecting = false
                self.rememberedMac = name
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

    func setKeepAwake(_ on: Bool) async throws {
        _ = try await call("keepAwake", ["on": on])
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
