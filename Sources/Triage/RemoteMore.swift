import Foundation
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - Everything else the phone can ask for: dashboard, space, clipboard, file manager, Mac controls, theme

extension RemoteAPI {
    /// Requests that change something on the Mac. View-only phones get a polite no.
    static let writeOps: Set<String> = Set(["quitApp", "trash", "emptyTrash", "clean", "open", "reveal", "sleepDisplay", "sleepMac",
                                        "rename", "mkdir", "move", "copy", "upload", "setClipboard"]).union(toolWriteOps)

    static let allOps = ["vitals", "info", "apps", "list", "search", "keepAwake", "glance", "space", "clips", "thumb", "fetch",
                         "favorites", "setTheme"] + toolReadOps

    /// Handled here: returns false when the op isn't one of ours.
    static func more(_ op: String, _ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) -> Bool {
        switch op {
        case "glance": done(.success(glance()))
        case "space": space(done)
        case "clean": clean(a, s, done)
        case "clips": done(.success(["clips": clips()]))
        case "setClipboard":
            guard let t = a["text"] as? String, !t.isEmpty else { done(.failure(RemoteError(message: "Nothing to copy"))); break }
            ClipboardStore.shared.copyText(t)
            RemoteServer.shared.record(s.deviceName, "Put text on the Mac's clipboard")
            done(.success([:]))
        case "thumb": thumb(a, done)
        case "fetch": fetch(a, s, done)
        case "favorites": done(.success(["places": favorites()]))
        case "open", "reveal":
            guard let p = a["path"] as? String, FileManager.default.fileExists(atPath: p) else { done(.failure(RemoteError(message: "That file is gone"))); break }
            let u = URL(fileURLWithPath: p)
            if op == "open" { NSWorkspace.shared.open(u) } else { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            RemoteServer.shared.record(s.deviceName, (op == "open" ? "Opened " : "Showed in Finder: ") + tilde(p))
            done(.success([:]))
        case "sleepDisplay", "sleepMac":
            RemoteServer.shared.record(s.deviceName, op == "sleepMac" ? "Put the Mac to sleep" : "Turned the display off")
            done(.success([:]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {   // answer first, then sleep
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                p.arguments = [op == "sleepMac" ? "sleepnow" : "displaysleepnow"]
                try? p.run()
            }
        case "setTheme":
            guard let id = a["id"] as? String, AppTheme.all.contains(where: { $0.id == id }) else { done(.failure(RemoteError(message: "Unknown theme"))); break }
            ThemeStore.shared.themeID = id
            RemoteServer.shared.record(s.deviceName, "Changed the Mac's theme to \(ThemeStore.shared.current.name)")
            done(.success(["theme": id]))
        case "rename": rename(a, s, done)
        case "mkdir": mkdir(a, s, done)
        case "move", "copy": moveCopy(op, a, s, done)
        case "upload": upload(a, s, done)
        default: return false
        }
        return true
    }

    static func tilde(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    // MARK: Home dashboard

    static func glance() -> [String: Any] {
        let t = AppTime.shared
        let today = t.top(t.today, 6).map { ["id": $0.id, "name": $0.name, "secs": $0.secs] as [String: Any] }
        let todayTotal = t.today?.seconds.values.reduce(0, +) ?? 0
        let week = t.week.map { ["label": $0.label, "secs": $0.secs] as [String: Any] }

        let samples = HealthLog.shared.samples
        let dayAgo = Date().addingTimeInterval(-86_400)
        var buckets: [Int: [Double]] = [:]
        for s in samples where s.t >= dayAgo { buckets[Int(s.t.timeIntervalSince1970 / 900), default: []].append(s.bpm) }
        let heart = buckets.keys.sorted().map { k -> [String: Any] in
            let v = buckets[k]!
            return ["t": Double(k * 900), "bpm": v.reduce(0, +) / Double(v.count)]
        }
        let day = samples.filter { $0.t >= dayAgo }.map(\.bpm)

        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let wk = samples.filter { $0.t >= weekAgo }
        var counts: [String: Int] = [:]
        for s in wk { if let n = s.top { counts[n, default: 0] += 1 } }
        let total = Double(max(wk.count, 1))
        let hungry = counts.sorted { $0.value > $1.value }.prefix(6).map {
            ["name": $0.key, "share": Double($0.value) / total, "system": MacFacts.isSystem($0.key)] as [String: Any]
        }

        var d: [String: Any] = ["todayTotal": todayTotal, "today": today, "week": week, "heart": heart,
                                "heartAvg": day.isEmpty ? 0 : day.reduce(0, +) / Double(day.count), "heartPeak": day.max() ?? 0,
                                "beats": MacFacts.uptime / 60 * (day.isEmpty ? 70 : day.reduce(0, +) / Double(day.count)),
                                "hungry": hungry]
        d.merge(info()) { a, _ in a }
        return d
    }

    // MARK: Free Up Space

    static func space(_ done: @escaping Done) {
        DispatchQueue.global(qos: .userInitiated).async {
            let targets = Cleaner.targets().map(Cleaner.measure)
            let out = targets.map { t -> [String: Any] in
                ["id": t.id, "title": t.title, "detail": t.detail, "symbol": t.symbol, "safe": t.safe,
                 "size": t.size ?? 0, "count": t.count,
                 "parts": t.parts.prefix(80).map { ["path": $0.url.path, "name": $0.name, "size": $0.size] as [String: Any] }]
            }
            done(.success(["targets": out]))
        }
    }

    /// Only items a Free Up Space suggestion lists right now can be cleaned this way.
    static func clean(_ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) {
        let want = Set((a["paths"] as? [String]) ?? [])
        guard !want.isEmpty else { done(.failure(RemoteError(message: "Pick something to clear"))); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let allowed = Set(Cleaner.targets().filter { $0.id != "trash" }.flatMap { Cleaner.resolve($0.source) }.map(\.path))
            var freed: Int64 = 0, moved = 0, failed: [String] = []
            for p in want {
                guard allowed.contains(p) else { failed.append(p); continue }
                let u = URL(fileURLWithPath: p)
                let size = FS.size(of: u)
                do { try FileManager.default.trashItem(at: u, resultingItemURL: nil); freed += size; moved += 1 } catch { failed.append(p) }
            }
            RemoteServer.shared.record(s.deviceName, "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) (\(moved) items to the Trash)")
            done(.success(["freed": freed, "moved": moved, "failed": failed]))
        }
    }

    // MARK: Clipboard

    static func clips() -> [[String: Any]] {
        ClipboardStore.shared.clips.prefix(50).compactMap { c in
            guard let t = c.text ?? c.files?.joined(separator: "\n") else { return nil }
            return ["id": c.id.uuidString, "kind": c.kind, "text": String(t.prefix(4000)), "date": c.date.timeIntervalSince1970,
                    "source": c.source ?? "", "pinned": c.pinned]
        }
    }

    // MARK: File manager

    static func favorites() -> [[String: Any]] {
        let h = NSHomeDirectory()
        var out: [[String: Any]] = [["name": "Home", "path": h, "symbol": "house.fill"]]
        for (n, sym) in [("Desktop", "menubar.dock.rectangle"), ("Documents", "doc.fill"), ("Downloads", "arrow.down.circle.fill"),
                         ("Projects", "hammer.fill"), ("Pictures", "photo.fill"), ("Movies", "film.fill"), ("Music", "music.note")] {
            let p = h + "/" + n
            if FileManager.default.fileExists(atPath: p) { out.append(["name": n, "path": p, "symbol": sym]) }
        }
        let icloud = h + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: icloud) { out.append(["name": "iCloud Drive", "path": icloud, "symbol": "icloud.fill"]) }
        out.append(["name": "Applications", "path": "/Applications", "symbol": "square.grid.2x2.fill"])
        return out
    }

    /// Where the phone may create, move or copy things: inside your home folder, not in Library or hidden folders.
    static func writableDir(_ raw: String) -> Bool {
        let home = NSHomeDirectory()
        let p = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        guard p == home || p.hasPrefix(home + "/") else { return false }
        let parts = p.dropFirst(home.count).split(separator: "/").map(String.init)
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        if parts.first == "Library" && !(parts.count >= 3 && parts[1] == "Mobile Documents") { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
    }

    static func cleanName(_ n: String) -> String? {
        let t = n.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        return t.isEmpty || t.hasPrefix(".") || t.count > 255 ? nil : t
    }

    static func uniqueURL(_ u: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: u.path) else { return u }
        let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension, dir = u.deletingLastPathComponent()
        for i in 2...999 {
            let c = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            if !fm.fileExists(atPath: c.path) { return c }
        }
        return u
    }

    static func rename(_ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) {
        guard let p = a["path"] as? String, let n = (a["name"] as? String).flatMap(cleanName), trashable(p) else {
            done(.failure(RemoteError(message: "That can't be renamed from the phone"))); return
        }
        let u = URL(fileURLWithPath: p)
        let dest = u.deletingLastPathComponent().appendingPathComponent(n)
        guard !FileManager.default.fileExists(atPath: dest.path) else { done(.failure(RemoteError(message: "Something called \(n) is already there"))); return }
        do {
            try FileManager.default.moveItem(at: u, to: dest)
            RemoteServer.shared.record(s.deviceName, "Renamed \(u.lastPathComponent) to \(n)")
            done(.success(["entry": entry(dest)]))
        } catch { done(.failure(RemoteError(message: error.localizedDescription))) }
    }

    static func mkdir(_ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) {
        guard let dir = a["dir"] as? String, writableDir(dir), let n = (a["name"] as? String).flatMap(cleanName) else {
            done(.failure(RemoteError(message: "Can't make a folder there"))); return
        }
        let u = uniqueURL(URL(fileURLWithPath: dir).appendingPathComponent(n, isDirectory: true))
        do {
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
            RemoteServer.shared.record(s.deviceName, "Made folder \(tilde(u.path))")
            done(.success(["entry": entry(u)]))
        } catch { done(.failure(RemoteError(message: error.localizedDescription))) }
    }

    static func moveCopy(_ op: String, _ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) {
        let paths = (a["paths"] as? [String]) ?? []
        guard let dir = a["dir"] as? String, writableDir(dir), !paths.isEmpty, paths.count <= 500 else {
            done(.failure(RemoteError(message: "Can't put things there"))); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var ok: [String] = [], failed: [[String: String]] = []
            let fm = FileManager.default
            for p in paths {
                // moving takes it out of where it was, so it must be somewhere the phone may change; copying only reads
                if op == "move" && !trashable(p) { failed.append(["path": p, "error": "Protected location"]); continue }
                let src = URL(fileURLWithPath: p)
                if dir.hasPrefix(p + "/") || dir == p { failed.append(["path": p, "error": "Can't put a folder inside itself"]); continue }
                let dest = uniqueURL(URL(fileURLWithPath: dir).appendingPathComponent(src.lastPathComponent))
                do {
                    if op == "move" { try fm.moveItem(at: src, to: dest) } else { try fm.copyItem(at: src, to: dest) }
                    ok.append(dest.path)
                } catch { failed.append(["path": p, "error": error.localizedDescription]) }
            }
            if !ok.isEmpty { RemoteServer.shared.record(s.deviceName, "\(op == "move" ? "Moved" : "Copied") \(ok.count) item\(ok.count == 1 ? "" : "s") to \(tilde(dir))") }
            done(.success(["done": ok, "failed": failed]))
        }
    }

    /// Phone → Mac, in chunks: first chunk creates the file (uniquely named), later ones append.
    static func upload(_ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) {
        guard let b64 = a["data"] as? String, let data = Data(base64Encoded: b64) else { done(.failure(RemoteError(message: "No data"))); return }
        let fm = FileManager.default
        if let target = a["target"] as? String {          // a later chunk
            guard target.hasPrefix(NSHomeDirectory() + "/"), let h = FileHandle(forWritingAtPath: target) else {
                done(.failure(RemoteError(message: "Lost track of that upload"))); return
            }
            h.seekToEndOfFile(); h.write(data); try? h.close()
            if (a["last"] as? Bool) == true { RemoteServer.shared.record(s.deviceName, "Sent \(tilde(target)) from the iPhone") }
            done(.success(["target": target]))
            return
        }
        guard let dir = a["dir"] as? String, writableDir(dir), let n = (a["name"] as? String).flatMap(cleanName) else {
            done(.failure(RemoteError(message: "Can't save there"))); return
        }
        let u = uniqueURL(URL(fileURLWithPath: dir).appendingPathComponent(n))
        guard fm.createFile(atPath: u.path, contents: data) else { done(.failure(RemoteError(message: "Couldn't save \(n)"))); return }
        if (a["last"] as? Bool) == true { RemoteServer.shared.record(s.deviceName, "Sent \(tilde(u.path)) from the iPhone") }
        done(.success(["target": u.path]))
    }

    /// Mac → phone, 4 MB at a time, so any size works without one giant message.
    static func fetch(_ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) {
        guard let p = a["path"] as? String else { done(.failure(RemoteError(message: "Which file?"))); return }
        let offset = (a["offset"] as? Int) ?? 0
        let chunk = 4 << 20
        DispatchQueue.global(qos: .userInitiated).async {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: p), (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.intValue, let h = FileHandle(forReadingAtPath: p) else {
                done(.failure(RemoteError(message: "Can't read that file (folders and apps can't be sent)"))); return
            }
            guard size <= 2 << 30 else { done(.failure(RemoteError(message: "That file is over 2 GB"))); return }
            try? h.seek(toOffset: UInt64(offset))
            let data = h.readData(ofLength: chunk)
            try? h.close()
            if offset == 0 { RemoteServer.shared.record(s.deviceName, "Opened \(tilde(p)) on the iPhone") }
            done(.success(["size": size, "offset": offset, "data": data.base64EncodedString(), "done": offset + data.count >= size]))
        }
    }

    static func thumb(_ a: [String: Any], _ done: @escaping Done) {
        guard let p = a["path"] as? String, FileManager.default.fileExists(atPath: p) else { done(.success([:])); return }
        let px = CGFloat(min((a["size"] as? Int) ?? 160, 600))
        let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: p), size: CGSize(width: px, height: px), scale: 2,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let cg = rep?.cgImage else { done(.success([:])); return }
            let bmp = NSBitmapImageRep(cgImage: cg)
            let jpg = bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) ?? Data()
            done(.success(["jpg": jpg.base64EncodedString()]))
        }
    }
}
