import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Natural-language query understanding

struct SmartQuery {
    var terms: [String] = []
    var phrases: [String] = []
    var kinds: [(label: String, mdq: String)] = []
    var dateKey = "kMDItemFSContentChangeDate"
    var dateVerb = "edited"
    var after: Date?
    var before: Date?
    var dateLabel: String?
    var minSize: Int64?
    var maxSize: Int64?
    var sizeLabel: String?
    var scope: URL?
    var scopeLabel: String?
    /// "largest", "smallest", "newest", "oldest": sort the results instead of searching for the word
    var order: String?
    var from: String?
    var exts: [String] = []
    var math: String?

    var hasCriteria: Bool {
        !terms.isEmpty || !phrases.isEmpty || !kinds.isEmpty || after != nil || before != nil
            || minSize != nil || maxSize != nil || from != nil || !exts.isEmpty || scope != nil
    }

    /// What Triage understood, shown as chips under the search field.
    var chips: [String] {
        var c: [String] = []
        c += kinds.map(\.label)
        c += exts.map { ".\($0)" }
        if let d = dateLabel { c.append(dateVerb == "edited" ? d : "\(dateVerb) \(d)") }
        if let s = sizeLabel { c.append(s) }
        if let s = scopeLabel { c.append("in \(s)") }
        switch order {
        case "size-desc": c.append("largest first")
        case "size-asc": c.append("smallest first")
        case "date-desc": c.append("newest first")
        case "date-asc": c.append("oldest first")
        default: break
        }
        if let f = from { c.append("from \(f)") }
        c += phrases.map { "“\($0)”" }
        if !terms.isEmpty { c.append("name or text: " + terms.joined(separator: " + ")) }
        return c
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "*", with: "")
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Spotlight query-language string (the same engine Spotlight uses).
    var metadataQuery: String {
        var parts: [String] = []
        for t in (terms + phrases).map(Self.clean) where !t.isEmpty {
            parts.append("(kMDItemFSName == \"*\(t)*\"cd || kMDItemDisplayName == \"*\(t)*\"cd || kMDItemTextContent == \"\(t)*\"cdw)")
        }
        if !kinds.isEmpty { parts.append("(" + kinds.map(\.mdq).joined(separator: " || ") + ")") }
        if !exts.isEmpty {
            parts.append("(" + exts.map { "kMDItemFSName == \"*.\(Self.clean($0))\"c" }.joined(separator: " || ") + ")")
        }
        if let a = after { parts.append("\(dateKey) >= $time.iso(\(Self.iso.string(from: a)))") }
        if let b = before { parts.append("\(dateKey) < $time.iso(\(Self.iso.string(from: b)))") }
        if let m = minSize { parts.append("kMDItemFSSize > \(m)") }
        if let m = maxSize { parts.append("kMDItemFSSize < \(m)") }
        if let f = from { parts.append("kMDItemWhereFroms == \"*\(Self.clean(f))*\"cd") }
        // only a place (and maybe an order): everything in that folder
        if parts.isEmpty, scope != nil { parts.append("kMDItemFSName == \"*\"") }
        return parts.joined(separator: " && ")
    }
}

enum SmartParser {
    private static let stop: Set<String> = [
        "a", "an", "the", "my", "me", "i", "of", "for", "with", "and", "or", "file", "files", "find", "show",
        "all", "that", "which", "some", "any", "called", "named", "about", "to", "on", "at", "is", "are",
        "was", "were", "stuff", "things", "where", "get", "open", "in", "inside", "from", "during", "ago",
        "please", "what", "whats", "what's", "can", "you", "give", "list", "display", "one", "ones", "most",
    ]

    private static let kindMap: [String: (String, String)] = {
        let pdf = ("PDFs", "kMDItemContentTypeTree == \"com.adobe.pdf\"")
        let img = ("Images", "kMDItemContentTypeTree == \"public.image\"")
        let vid = ("Videos", "kMDItemContentTypeTree == \"public.movie\"")
        let aud = ("Audio", "kMDItemContentTypeTree == \"public.audio\"")
        let doc = ("Documents", "(kMDItemContentTypeTree == \"public.composite-content\" || kMDItemContentTypeTree == \"public.text\")")
        let sheet = ("Spreadsheets", "kMDItemContentTypeTree == \"public.spreadsheet\"")
        let deck = ("Presentations", "kMDItemContentTypeTree == \"public.presentation\"")
        let app = ("Apps", "kMDItemContentTypeTree == \"com.apple.application-bundle\"")
        let folder = ("Folders", "kMDItemContentTypeTree == \"public.folder\"")
        let code = ("Code", "kMDItemContentTypeTree == \"public.source-code\"")
        let arch = ("Archives", "kMDItemContentTypeTree == \"public.archive\"")
        let inst = ("Installers", "(kMDItemContentTypeTree == \"com.apple.disk-image\" || kMDItemContentTypeTree == \"com.apple.installer-package-archive\")")
        let shot = ("Screenshots", "kMDItemIsScreenCapture == 1")
        let mail = ("Emails", "kMDItemContentTypeTree == \"com.apple.mail.emlx\"")
        let font = ("Fonts", "kMDItemContentTypeTree == \"public.font\"")
        func ext(_ label: String, _ exts: [String]) -> (String, String) {
            (label, "(" + exts.map { "kMDItemFSName == \"*.\($0)\"c" }.joined(separator: " || ") + ")")
        }
        let rom = ext("ROMs & game discs", ["iso", "gcm", "rvz", "wbfs", "ciso", "nkit.iso", "gcz", "nsp", "xci", "nds", "3ds", "cia", "gba", "gbc", "gb",
                                             "nes", "sfc", "smc", "n64", "z64", "v64", "md", "gen", "smd", "sms", "gg", "pce", "chd", "cue", "pbp", "cso", "ws", "wsc", "a26", "lnx", "32x"])
        let save = ext("Game saves", ["sav", "srm", "gci", "mcr", "mcd", "dsv", "state", "st0", "ss0"])
        let comic = ext("Comics & magazines", ["cbz", "cbr", "cb7", "cbt"])
        let book = ext("Ebooks", ["epub", "mobi", "azw", "azw3", "ibooks", "fb2", "djvu"])
        let word = ext("Word documents", ["doc", "docx", "pages", "odt", "rtf"])
        let excel = ext("Spreadsheets", ["xls", "xlsx", "xlsm", "numbers", "ods", "csv", "tsv"])
        let ppt = ext("Presentations", ["ppt", "pptx", "key", "odp"])
        let design = ext("Design files", ["psd", "ai", "sketch", "fig", "xd", "afdesign", "afphoto", "indd", "eps", "svg"])
        let raw = ext("RAW photos", ["cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2"])
        let gifs = ext("GIFs", ["gif"])
        let model3d = ext("3D models", ["stl", "obj", "fbx", "usdz", "blend", "3mf", "gltf", "glb", "step", "stp"])
        let sub = ext("Subtitles", ["srt", "vtt", "ass", "ssa", "sub"])
        let torrent = ext("Torrents", ["torrent"])
        let web = ext("Web pages", ["html", "htm", "webarchive", "mhtml"])
        let md = ext("Markdown & notes", ["md", "markdown", "txt", "rtf"])
        let dataf = ext("Data files", ["json", "csv", "xml", "yaml", "yml", "sqlite", "db", "plist"])
        let logs = ext("Logs", ["log", "crash", "ips"])
        let contact = ext("Contacts & calendars", ["vcf", "ics"])
        let exe = ext("Programs & scripts", ["sh", "command", "py", "rb", "pl", "exe", "msi", "jar", "bat", "ps1"])
        let vm = ext("Virtual machines", ["pvm", "vmwarevm", "utm", "vdi", "vmdk", "qcow2", "ova"])
        let backup = ext("Backups", ["bak", "backup", "old", "tmp"])
        let midi = ext("Music projects", ["logicx", "band", "als", "flp", "mid", "midi"])
        let video_proj = ext("Video projects", ["fcpbundle", "prproj", "aep", "drp", "imovielibrary"])
        let cert = ext("Keys & certificates", ["pem", "cer", "crt", "p12", "key", "pub", "mobileprovision"])
        return [
            "rom": rom, "roms": rom, "iso": rom, 
            "saves": save, "savefile": save,
            "comic": comic, "comics": comic, "magazine": comic, "magazines": comic, "cbz": comic, "cbr": comic,
            "ebook": book, "ebooks": book, "epub": book, "kindle": book,
            "docx": word, "pages": word, "worddoc": word,
            "xls": excel, "csv": excel, "numbers": excel, "spreadsheets": excel,
            "pptx": ppt, "slideshow": ppt,
            "photoshop": design, "psd": design, "illustrator": design, "sketch": design, "figma": design, "svg": design,
            "raw": raw, "dng": raw,
            "gif": gifs, "gifs": gifs, "meme": gifs,
            "3d": model3d, "stl": model3d, 
            "subtitle": sub, "subtitles": sub, "srt": sub, "captions": sub,
            "torrent": torrent, "torrents": torrent,
            "webpage": web, "html": web, 
            "markdown": md, "md": md, "txt": md, 
            "json": dataf, "sqlite": dataf, "xml": dataf, "yaml": dataf,
            "log": logs, "logs": logs, 
            "contact": contact, "contacts": contact, "vcard": contact, "ics": contact,
            "exe": exe, 
            "vm": vm, "vms": vm, "parallels": vm,
            
            "garageband": midi, "midi": midi, "ableton": midi,
            "premiere": video_proj, "finalcut": video_proj, "davinci": video_proj, "imovie": video_proj,
            "certificate": cert, "certificates": cert, "ssh": cert, "cert": cert,
            "pdf": pdf, "image": img, "photo": img, "picture": img, "pic": img, "img": img, "jpg": img, "png": img,
            "screenshot": shot, "screengrab": shot,
            "video": vid, "movie": vid, "clip": vid, "recording": vid,
            "audio": aud, "music": aud, "song": aud, "mp3": aud, "podcast": aud,
            "doc": doc, "document": doc, "word": doc, "note": doc,
            "spreadsheet": sheet, "excel": sheet, "sheet": sheet, "xlsx": sheet,
            "presentation": deck, "slide": deck, "deck": deck, "keynote": deck, "powerpoint": deck, "ppt": deck,
            "app": app, "application": app,
            "folder": folder, "directory": folder, "dir": folder,
            "code": code, "script": code, "source": code,
            "archive": arch, "zip": arch,
            "installer": inst, "dmg": inst, "pkg": inst,
            "email": mail, "mail": mail,
            "font": font,
        ]
    }()

    private static let places: [String: String] = [
        "downloads": "Downloads", "download": "Downloads", "desktop": "Desktop", "documents": "Documents",
        "projects": "Projects", "pictures": "Pictures", "movies": "Movies", "music": "Music",
        "home": "", "applications": "/Applications",
    ]

    private static let months = ["january", "february", "march", "april", "may", "june", "july",
                                 "august", "september", "october", "november", "december"]

    private static let units: [String: Calendar.Component] = [
        "day": .day, "days": .day, "week": .weekOfYear, "weeks": .weekOfYear,
        "month": .month, "months": .month, "year": .year, "years": .year, "hour": .hour, "hours": .hour,
    ]

    private static func monthIndex(_ w: String) -> Int? {
        guard w.count >= 3 else { return nil }
        return months.firstIndex { $0.hasPrefix(w) }
    }

    private static func kind(_ w: String) -> (String, String)? {
        if let k = kindMap[w] { return k }
        if w.hasSuffix("s"), let k = kindMap[String(w.dropLast())] { return k }
        if w.hasSuffix("es"), let k = kindMap[String(w.dropLast(2))] { return k }
        return nil
    }

    private static func isTimeWord(_ w: String) -> Bool {
        ["today", "yesterday", "this", "last", "past", "recent", "recently"].contains(w)
            || monthIndex(w) != nil || (Int(w).map { $0 >= 1990 && $0 <= 2100 } ?? false)
    }

    static func parse(_ raw: String) -> SmartQuery {
        var q = SmartQuery()
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let cal = Calendar.current
        let now = Date()

        // Calculator: "12*48", "(1200-350)/3", "15% * 80"
        if trimmed.range(of: #"^[\d\.\s\+\-\*/\(\)\^%×÷,]+$"#, options: .regularExpression) != nil,
           trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^×÷%")) != nil,
           trimmed.rangeOfCharacter(from: .decimalDigits) != nil {
            q.math = trimmed
        }

        var s = raw

        // "exact phrases"
        if let re = try? NSRegularExpression(pattern: "\"([^\"]+)\"") {
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                q.phrases.append(ns.substring(with: m.range(at: 1)))
            }
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        }

        // Sizes: "over 500mb", "<2gb", "bigger than 1 gb"
        s = s.lowercased()
        if q.math == nil,
           let re = try? NSRegularExpression(pattern: #"(>|<|over|under|above|below|bigger than|larger than|smaller than|less than|more than)?\s*(\d+(?:\.\d+)?)\s*(kb|mb|gb|tb)\b"#) {
            let ns = s as NSString
            if let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
                let cmp = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
                let num = Double(ns.substring(with: m.range(at: 2))) ?? 0
                let unit = ns.substring(with: m.range(at: 3))
                let mult: Double = ["kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12][unit] ?? 1
                let bytes = Int64(num * mult)
                if ["<", "under", "below", "smaller than", "less than"].contains(cmp) {
                    q.maxSize = bytes; q.sizeLabel = "under \(Fmt.bytes(bytes))"
                } else {
                    q.minSize = bytes; q.sizeLabel = "over \(Fmt.bytes(bytes))"
                }
                s = ns.replacingCharacters(in: m.range, with: " ")
            }
        }

        let words = s.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        var i = 0
        func word(_ k: Int) -> String? { k < words.count ? words[k] : nil }

        while i < words.count {
            let w = words[i]
            let next = word(i + 1)

            // dates
            if w == "today" {
                q.after = cal.startOfDay(for: now); q.dateLabel = "today"; i += 1; continue
            }
            if w == "yesterday" {
                let start = cal.startOfDay(for: now)
                q.after = cal.date(byAdding: .day, value: -1, to: start); q.before = start; q.dateLabel = "yesterday"; i += 1; continue
            }
            // superlatives sort rather than filter
            if ["largest", "biggest", "heaviest", "fattest"].contains(w) { q.order = "size-desc"; i += 1; continue }
            if ["smallest", "tiniest", "lightest"].contains(w) { q.order = "size-asc"; i += 1; continue }
            if ["newest", "latest"].contains(w) || (w == "most" && next == "recent") { q.order = "date-desc"; i += w == "most" ? 2 : 1; continue }
            if w == "oldest" { q.order = "date-asc"; i += 1; continue }
            if w == "recent" || w == "recently" || w == "new" {
                q.after = cal.date(byAdding: .day, value: -7, to: now); q.dateLabel = "in the last 7 days"; i += 1; continue
            }
            if ["this", "last", "past"].contains(w), let n = next, let comp = units[n] {
                if w == "this", let iv = cal.dateInterval(of: comp, for: now) {
                    q.after = iv.start; q.dateLabel = "this \(n)"
                } else if w == "last", comp != .day, comp != .hour,
                          let prev = cal.date(byAdding: comp, value: -1, to: now), let iv = cal.dateInterval(of: comp, for: prev) {
                    q.after = iv.start; q.before = iv.end; q.dateLabel = "last \(n)"
                } else {
                    q.after = cal.date(byAdding: comp, value: -1, to: now); q.dateLabel = "in the past \(n)"
                }
                i += 2; continue
            }
            if ["last", "past"].contains(w), let n = next.flatMap({ Int($0) }), let u = word(i + 2), let comp = units[u] {
                q.after = cal.date(byAdding: comp, value: -n, to: now); q.dateLabel = "in the last \(n) \(u)"
                i += 3; continue
            }
            if let n = Int(w), let u = next, let comp = units[u], word(i + 2) == "ago" {
                let d = cal.date(byAdding: comp, value: -n, to: now) ?? now
                if let iv = cal.dateInterval(of: comp == .hour ? .hour : .day, for: d) { q.after = iv.start; q.before = iv.end }
                q.dateLabel = "\(n) \(u) ago"; i += 3; continue
            }
            if let mi = monthIndex(w), w.count >= 3, (w != "may" || ["in", "from", "during"].contains(i > 0 ? words[i - 1] : "")) {
                var comps = cal.dateComponents([.year], from: now)
                comps.month = mi + 1; comps.day = 1
                if var start = cal.date(from: comps) {
                    if start > now { start = cal.date(byAdding: .year, value: -1, to: start) ?? start }
                    q.after = start; q.before = cal.date(byAdding: .month, value: 1, to: start)
                    let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; q.dateLabel = f.string(from: start)
                }
                i += 1; continue
            }
            if ["in", "from", "during"].contains(w), let n = next, let y = Int(n), y >= 1990, y <= 2100 {
                var c = DateComponents(); c.year = y; c.month = 1; c.day = 1
                q.after = cal.date(from: c); c.year = y + 1; q.before = cal.date(from: c); q.dateLabel = "in \(y)"
                i += 2; continue
            }
            if ["opened", "used", "viewed", "launched"].contains(w) {
                q.dateKey = "kMDItemLastUsedDate"; q.dateVerb = "opened"; i += 1; continue
            }
            if ["created", "made", "added"].contains(w) {
                q.dateKey = "kMDItemContentCreationDate"; q.dateVerb = "created"; i += 1; continue
            }
            if ["modified", "edited", "changed", "saved", "updated"].contains(w) { i += 1; continue }

            // size words
            if ["big", "large", "heavy"].contains(w) { q.minSize = 100_000_000; q.sizeLabel = "over 100 MB"; i += 1; continue }
            if ["huge", "giant", "massive"].contains(w) { q.minSize = 1_000_000_000; q.sizeLabel = "over 1 GB"; i += 1; continue }
            if ["small", "tiny"].contains(w) { q.maxSize = 1_000_000; q.sizeLabel = "under 1 MB"; i += 1; continue }

            // places
            if ["in", "inside", "under"].contains(w), let n = next, let p = places[n] {
                let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : (p.isEmpty ? Places.home : Places.home.appendingPathComponent(p))
                q.scope = url; q.scopeLabel = p.isEmpty ? "Home" : url.lastPathComponent
                i += 2; continue
            }

            // a bare folder name is a place too: "largest video download", "pdfs desktop"
            if q.scope == nil, let p = places[w], !p.isEmpty, !p.hasPrefix("/") {
                let url = Places.home.appendingPathComponent(p)
                q.scope = url; q.scopeLabel = url.lastPathComponent
                i += 1; continue
            }

            // provenance: "from github", "from mail.google.com", "from slack"
            if w == "from", let n = next, !isTimeWord(n), places[n] == nil {
                q.from = n; i += 2; continue
            }

            // extensions: ".swift", "ext:md"
            if w.hasPrefix("."), w.count >= 2, w.count <= 8, w.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber }) {
                q.exts.append(String(w.dropFirst())); i += 1; continue
            }
            if w.hasPrefix("ext:"), w.count > 4 { q.exts.append(String(w.dropFirst(4))); i += 1; continue }

            if let k = kind(w) {
                if !q.kinds.contains(where: { $0.label == k.0 }) { q.kinds.append((label: k.0, mdq: k.1)) }
                i += 1; continue
            }

            if stop.contains(w) { i += 1; continue }
            if q.math != nil { i += 1; continue }
            q.terms.append(w)
            i += 1
        }
        return q
    }
}

// MARK: - Calculator

enum Calc {
    static func evaluate(_ input: String) -> Double? {
        let chars = Array(input.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: "").filter { !$0.isWhitespace })
        var i = 0
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        func number() -> Double? {
            var j = i
            while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
            guard j > i, let v = Double(String(chars[i..<j])) else { return nil }
            i = j
            return v
        }
        func percent(_ v: Double) -> Double {
            if peek() == "%" { i += 1; return v / 100 }
            return v
        }
        func factor() -> Double? {
            if peek() == "-" { i += 1; return factor().map { -$0 } }
            if peek() == "(" {
                i += 1
                guard let v = expr(), peek() == ")" else { return nil }
                i += 1
                return percent(v)
            }
            return number().map(percent)
        }
        func power() -> Double? {
            guard let b = factor() else { return nil }
            if peek() == "^" {
                i += 1
                guard let e = power() else { return nil }
                return pow(b, e)
            }
            return b
        }
        func term() -> Double? {
            guard var v = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                i += 1
                guard let r = power() else { return nil }
                v = c == "*" ? v * r : v / r
            }
            return v
        }
        func expr() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }
        let v = expr()
        guard i == chars.count, let v, v.isFinite else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 8
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

// MARK: - Search engine

final class SmartSearch: ObservableObject {
    enum Category: String, CaseIterable {
        case recent = "Jump back in"
        case actions = "Triage"
        case top = "Top hit"
        case apps = "Applications"
        case folders = "Folders"
        case documents = "Documents"
        case media = "Images, video & audio"
        case code = "Code"
        case other = "Other"
    }

    struct Hit: Identifiable {
        let url: URL
        let name: String
        let category: Category
        let lastUsed: Date?
        let modified: Date?
        let size: Int64?
        let contentOnly: Bool
        let score: Double
        var index = 0
        var command: SearchCommand? = nil
        var id: String { command.map { "cmd:" + $0.id } ?? url.path }
    }

    struct Section: Identifiable {
        let id: Category
        let hits: [Hit]
    }

    @Published var text = "" { didSet { if text != oldValue { schedule() } } }
    @Published private(set) var parsed = SmartQuery()
    @Published private(set) var sections: [Section] = []
    @Published private(set) var flat: [Hit] = []
    @Published private(set) var total = 0
    @Published private(set) var searching = false
    @Published private(set) var mathResult: String?
    @Published private(set) var mathCaption: String?
    @Published private(set) var commands: [SearchCommand] = []
    @Published var selected = 0
    @Published var focusToken = 0
    @Published private(set) var history: [String] = UserDefaults.standard.stringArray(forKey: "vitalos.searchHistory") ?? []

    var onClose: (() -> Void)?
    var onOpenInTriage: ((URL) -> Void)?

    private let query = NSMetadataQuery()
    private var work: DispatchWorkItem?
    private var recentsMode = false

    var current: Hit? { flat.indices.contains(selected) ? flat[selected] : nil }

    init() {
        query.notificationBatchingInterval = 0.15
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            self?.collect(); self?.searching = false
        }
        nc.addObserver(forName: .NSMetadataQueryGatheringProgress, object: query, queue: .main) { [weak self] _ in
            self?.collect()
        }
        nc.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
            self?.collect()
        }
        run()
    }

    private func schedule() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.run() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: w)
    }

    func refresh() { run() }

    private func run() {
        query.stop()
        let q = SmartParser.parse(text)
        parsed = q
        mathResult = q.math.flatMap(Calc.evaluate).map(Calc.format)
        mathCaption = nil
        if mathResult == nil, let fx = Currency.parse(text), let r = Currency.convert(fx, then: { [weak self] in self?.run() }) {
            mathResult = r.text; mathCaption = r.caption
        }
        commands = SearchCommands.match(text)
        selected = mathResult != nil ? -1 : 0

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // A money conversion is the answer; files that merely contain "usd" are noise.
        if mathCaption != nil {
            recentsMode = false; total = 0; searching = false
            publish([])
            return
        }
        if trimmed.isEmpty {
            recentsMode = true
            query.predicate = NSPredicate(fromMetadataQueryString: "kMDItemLastUsedDate >= $time.today(-3) && kMDItemContentTypeTree != \"com.apple.application-bundle\"")
            query.searchScopes = [NSMetadataQueryUserHomeScope]
        } else {
            recentsMode = false
            guard q.hasCriteria, let p = NSPredicate(fromMetadataQueryString: q.metadataQuery) else {
                total = 0; searching = false
                publish([])
                return
            }
            query.predicate = p
            query.searchScopes = q.scope.map { [$0] } ?? [NSMetadataQueryLocalComputerScope]
        }
        searching = true
        query.start()
    }

    private static func isJunk(_ path: String) -> Bool {
        if path.contains("/.") { return true }
        let bad = ["/Library/Caches/", "/node_modules/", "/DerivedData/", "/Library/Containers/", "/Library/Group Containers/",
                   "/private/var/", "/Library/Application Support/Google/", "/.Trash/", "/Library/Developer/CoreSimulator/"]
        return bad.contains { path.contains($0) }
    }

    private static func category(_ type: String?) -> Category {
        guard let t = type.flatMap({ UTType($0) }) else { return .other }
        if t.conforms(to: .applicationBundle) || t.conforms(to: .application) { return .apps }
        if t.conforms(to: .folder) { return .folders }
        if t.conforms(to: .image) || t.conforms(to: .audiovisualContent) || t.conforms(to: .audio) { return .media }
        if t.conforms(to: .sourceCode) || t.conforms(to: .script) || t.conforms(to: .json) || t.conforms(to: .propertyList) { return .code }
        if t.conforms(to: .pdf) || t.conforms(to: .text) || t.conforms(to: .spreadsheet)
            || t.conforms(to: .presentation) || t.conforms(to: .compositeContent) { return .documents }
        if t.conforms(to: .directory) { return .folders }
        return .other
    }

    private static func score(name: String, fsName: String, terms: [String], cat: Category,
                              used: Date?, mod: Date?, path: String) -> Double {
        var s = 0.0
        if terms.isEmpty { s += 20 }
        for t in terms {
            if name == t || fsName == t { s += 120 }
            else if name.hasPrefix(t) || fsName.hasPrefix(t) { s += 70 }
            else if [" ", "-", "_", "."].contains(where: { name.contains($0 + t) || fsName.contains($0 + t) }) { s += 50 }
            else if name.contains(t) || fsName.contains(t) { s += 35 }
            else { s += 8 }   // matched inside the document only
        }
        switch cat {
        case .apps: s += 40
        case .folders: s += 12
        default: break
        }
        if let d = used ?? mod {
            let age = -d.timeIntervalSinceNow / 86_400
            s += age < 1 ? 30 : age < 7 ? 20 : age < 30 ? 10 : age < 365 ? 3 : 0
        }
        if used != nil { s += 6 }
        if path.contains("/Library/") { s -= 35 }
        if path.hasPrefix("/System/") && cat != .apps { s -= 30 }
        s -= Double(max(0, path.split(separator: "/").count - 5)) * 1.5
        return s
    }

    private func collect() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        let n = min(query.resultCount, 3000)
        let terms = (parsed.terms + parsed.phrases).map { $0.lowercased() }
        var seen = Set<String>()
        var out: [Hit] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String,
                  !Self.isJunk(path), seen.insert(path).inserted else { continue }
            let fsName = (path as NSString).lastPathComponent
            let name = (item.value(forAttribute: "kMDItemDisplayName") as? String) ?? fsName
            let used = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
            let mod = item.value(forAttribute: "kMDItemFSContentChangeDate") as? Date
            let size = (item.value(forAttribute: "kMDItemFSSize") as? NSNumber)?.int64Value
            let cat = Self.category(item.value(forAttribute: "kMDItemContentType") as? String)
            let ln = name.lowercased(), lf = fsName.lowercased()
            let contentOnly = !terms.isEmpty && !terms.allSatisfy { ln.contains($0) || lf.contains($0) }
            let sc = recentsMode
                ? (used?.timeIntervalSince1970 ?? 0)
                : Self.score(name: ln, fsName: lf, terms: terms, cat: cat, used: used, mod: mod, path: path)
            out.append(Hit(url: URL(fileURLWithPath: path), name: name, category: cat, lastUsed: used,
                           modified: mod, size: size, contentOnly: contentOnly, score: sc))
        }
        total = out.count
        let sorted: [Hit]
        switch parsed.order {
        case "size-desc": sorted = out.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        case "size-asc": sorted = out.sorted { ($0.size ?? .max) < ($1.size ?? .max) }
        case "date-desc": sorted = out.sorted { ($0.lastUsed ?? $0.modified ?? .distantPast) > ($1.lastUsed ?? $1.modified ?? .distantPast) }
        case "date-asc": sorted = out.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
        default: sorted = out.sorted { $0.score > $1.score }
        }

        var secs: [Section] = []
        if recentsMode {
            secs.append(Section(id: .recent, hits: Array(sorted.prefix(12))))
        } else if let top = sorted.first {
            secs.append(Section(id: .top, hits: [top]))
            let rest = sorted.dropFirst()
            for cat in Category.allCases where cat != .top && cat != .recent && cat != .actions {
                let limit = cat == .apps ? 5 : (cat == .folders ? 6 : 8)
                let group = Array(rest.filter { $0.category == cat }.prefix(limit))
                if !group.isEmpty { secs.append(Section(id: cat, hits: group)) }
            }
        }
        publish(secs)
    }

    /// Puts Triage actions first, numbers every row for keyboard moves, keeps the selection.
    private func publish(_ fileSections: [Section]) {
        var secs = fileSections
        if !recentsMode, !commands.isEmpty {
            let hits = commands.map { c in
                Hit(url: URL(fileURLWithPath: "/"), name: c.title, category: .actions, lastUsed: nil, modified: nil, size: nil,
                    contentOnly: false, score: 0, command: c)
            }
            secs.insert(Section(id: .actions, hits: hits), at: 0)
        }
        var idx = 0
        var flatOut: [Hit] = []
        secs = secs.map { sec in
            Section(id: sec.id, hits: sec.hits.map { h in
                var h = h
                h.index = idx
                idx += 1
                flatOut.append(h)
                return h
            })
        }
        let keepPath = current?.id
        sections = secs
        flat = flatOut
        if let keepPath, let i = flatOut.firstIndex(where: { $0.id == keepPath }) { selected = i }
        else if selected >= flatOut.count { selected = mathResult != nil ? -1 : 0 }
    }

    // MARK: actions

    func move(_ d: Int) {
        let lower = mathResult != nil ? -1 : 0
        guard !flat.isEmpty || lower == -1 else { return }
        selected = min(max(selected + d, lower), max(flat.count - 1, lower))
    }

    private func remember() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return }
        var h = history.filter { $0.lowercased() != t.lowercased() }
        h.insert(t, at: 0)
        history = Array(h.prefix(8))
        UserDefaults.standard.set(history, forKey: "vitalos.searchHistory")
    }

    func activate(reveal: Bool = false, inTriage: Bool = false) {
        if selected == -1, let m = mathResult {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(m.replacingOccurrences(of: ",", with: ""), forType: .string)
            onClose?()
            return
        }
        guard let hit = current else { return }
        if let c = hit.command { onClose?(); c.run(); return }
        remember()
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
        else if inTriage { onOpenInTriage?(hit.url) }
        else { NSWorkspace.shared.open(hit.url) }
        onClose?()
    }

    func copyPath() {
        guard let hit = current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.url.path, forType: .string)
        remember()
    }

    func quickLook() {
        guard let hit = current else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", hit.url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Keys handled while the search panel is key. Returns true when consumed.
    func handleKey(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags
        switch e.keyCode {
        case 125: move(1); return true                    // ↓
        case 126: move(-1); return true                   // ↑
        case 36, 76:                                      // ↩
            activate(reveal: f.contains(.command), inTriage: f.contains(.option)); return true
        case 53:                                          // esc
            if text.isEmpty { onClose?() } else { text = "" }
            return true
        default: break
        }
        if f.contains(.command), let ch = e.charactersIgnoringModifiers?.lowercased() {
            if ch == "y" { quickLook(); return true }
            if ch == "c" && f.contains(.shift) { copyPath(); return true }
            if ch == "o" { activate(); return true }
            if ch == "r" { activate(reveal: true); return true }
        }
        return false
    }
}
