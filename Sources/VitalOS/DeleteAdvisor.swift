import SwiftUI
import AppKit

/// How safe it is to delete something, from "go ahead" to "macOS needs this".
enum Safety: Int, Comparable, CaseIterable {
    case safe, likelySafe, caution, keep, system

    static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .safe: return "Safe to delete"
        case .likelySafe: return "Probably safe"
        case .caution: return "Check first"
        case .keep: return "Keep"
        case .system: return "Don't touch"
        }
    }
    var color: Color {
        switch self {
        case .safe: return Theme.good
        case .likelySafe: return Theme.cpu
        case .caution: return Theme.net
        case .keep: return Theme.warn
        case .system: return Color.secondary
        }
    }
    var symbol: String {
        switch self {
        case .safe: return "checkmark.circle.fill"
        case .likelySafe: return "checkmark.circle"
        case .caution: return "exclamationmark.triangle.fill"
        case .keep: return "hand.raised.fill"
        case .system: return "lock.fill"
        }
    }
}

struct Verdict {
    let level: Safety
    let reasons: [String]
    var headline: String { level.title }
}

enum DeleteAdvisor {
    private static let installed: (names: Set<String>, ids: Set<String>) = {
        var names = Set<String>(), ids = Set<String>()
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    Places.home.appendingPathComponent("Applications").path]
        for d in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".app") {
                names.insert(String(f.dropLast(4)).lowercased())
                if let id = Bundle(path: d + "/" + f)?.bundleIdentifier { ids.insert(id.lowercased()) }
            }
        }
        return (names, ids)
    }()

    static func isInstalled(_ token: String) -> Bool {
        let t = token.lowercased()
        if installed.ids.contains(t) || installed.names.contains(t) { return true }
        if t.contains(".") { return installed.ids.contains { t.hasPrefix($0) || $0.hasPrefix(t) } }
        return installed.names.contains { $0.hasPrefix(t) || t.hasPrefix($0) }
    }

    private static func ago(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func gitRoot(_ url: URL) -> URL? {
        var dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            if dir.path == "/" || dir.path == Places.home.path { return nil }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static func assess(_ url: URL) -> Verdict {
        let u = url.standardizedFileURL
        let path = u.path
        let home = Places.home.path
        let name = u.lastPathComponent
        let ext = u.pathExtension.lowercased()

        // 1. macOS itself
        for p in ["/System/", "/usr/", "/bin/", "/sbin/", "/private/", "/Library/Apple/", "/cores", "/opt/"] where path.hasPrefix(p) {
            return Verdict(level: .system, reasons: ["Part of macOS or a system tool. Deleting it can stop your Mac or apps from working."])
        }
        let standard = ["Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music", "Applications", "Public"]
            .map { home + "/" + $0 } + [home, "/Applications", "/Library", "/Users"]
        if standard.contains(path) {
            return Verdict(level: .system, reasons: ["A standard macOS folder. Clean up what's inside it instead."])
        }

        // 2. inside an app
        if let r = path.range(of: ".app/") {
            let app = (String(path[..<r.lowerBound]) as NSString).lastPathComponent
            return Verdict(level: .keep, reasons: ["Inside \(app). Removing it would break the app."])
        }
        if ext == "app" {
            var why = ["This is an app. Use App Uninstaller to remove it with the files it leaves behind."]
            if let d = NSMetadataItem(url: u)?.value(forAttribute: "kMDItemLastUsedDate") as? Date {
                why.append("Last opened \(ago(d)).")
            }
            return Verdict(level: .caution, reasons: why)
        }

        // 3. things your tools rebuild
        let regen = ["node_modules", "DerivedData", "__pycache__", ".build", ".gradle", "Pods", ".next", ".parcel-cache", ".pytest_cache", ".mypy_cache"]
        if let hit = regen.first(where: { path.contains("/\($0)/") || name == $0 }) {
            return Verdict(level: .safe, reasons: ["\(hit) is rebuilt automatically the next time you build or install."])
        }
        if path.hasPrefix(home + "/Library/Caches") {
            return Verdict(level: .safe, reasons: ["An app cache. Apps recreate caches as needed."])
        }
        if path.hasPrefix(home + "/Library/Logs") {
            return Verdict(level: .safe, reasons: ["Log files apps write for troubleshooting."])
        }

        // 4. app data in your Library
        let appData = ["/Library/Application Support/", "/Library/Containers/", "/Library/Preferences/",
                       "/Library/Saved Application State/", "/Library/HTTPStorages/", "/Library/WebKit/"]
        if let base = appData.first(where: { path.hasPrefix(home + $0) }) {
            let rest = String(path.dropFirst((home + base).count))
            var owner = String(rest.split(separator: "/").first ?? "")
            for suffix in [".plist", ".savedState", ".binarycookies"] where owner.hasSuffix(suffix) { owner = String(owner.dropLast(suffix.count)) }
            if owner.isEmpty { return Verdict(level: .caution, reasons: ["App data folder."]) }
            if isInstalled(owner) {
                return Verdict(level: .keep, reasons: ["Settings or data for \(owner), which is installed. Deleting it resets or breaks that app."])
            }
            return Verdict(level: .likelySafe, reasons: ["Left behind by \(owner), which doesn't seem to be installed anymore."])
        }
        if path.hasPrefix(home + "/Library/") {
            return Verdict(level: .caution, reasons: ["Part of your user Library, where apps keep settings and data."])
        }

        var level: Safety = .likelySafe
        var why: [String] = []
        func atLeast(_ l: Safety) { if level < l { level = l } }
        func atMost(_ l: Safety) { if level > l { level = l } }

        let personal = ["/Documents", "/Desktop", "/Pictures", "/Movies", "/Music"].contains { path.hasPrefix(home + $0 + "/") }
        if personal { level = .caution; why.append("A personal file. Only you know whether you still need it.") }

        // 5. installers
        if ["dmg", "pkg", "mpkg", "iso", "xip"].contains(ext) {
            let token = name.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
            if token.count > 2 && isInstalled(token) {
                return Verdict(level: .safe, reasons: ["An installer for \(token.capitalized), which is already installed."])
            }
            atMost(.likelySafe); why = ["An installer. You can download it again if you need it."]
        }

        // 6. duplicates like "report (1).pdf"
        let stripped = name.replacingOccurrences(of: #" ?\(\d+\)(?=\.[^.]+$|$)"#, with: "", options: .regularExpression)
        if stripped != name {
            let original = u.deletingLastPathComponent().appendingPathComponent(stripped)
            let a = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let b = (try? original.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if let a, a == b {
                return Verdict(level: .safe, reasons: ["A copy of \(stripped) in the same folder, with the same size."])
            }
        }

        // 7. cloud
        if path.hasPrefix(Places.iCloud.path) || path.contains("/Library/CloudStorage/") {
            atLeast(.caution); why.append("Synced to the cloud. Deleting it here removes it from your other devices too.")
        }

        // 8. git
        if Shell.hasGit, let repo = gitRoot(u) {
            if repo.path == path {
                atLeast(.caution); why.append("A git project. Make sure everything is pushed before deleting it.")
            } else {
                let status = Shell.run("/usr/bin/git", ["-C", repo.path, "status", "--porcelain", "--", path], timeout: 5)
                if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    atLeast(.caution); why.append("Has changes that aren't committed to git yet.")
                } else {
                    let tracked = Shell.run("/usr/bin/git", ["-C", repo.path, "ls-files", "--", path], timeout: 5)
                    if !tracked.isEmpty { atMost(.likelySafe); why.append("Saved in git (\(repo.lastPathComponent)), so it can be restored.") }
                }
            }
        }

        // 9. how recently you used it
        let md = NSMetadataItem(url: u)
        let used = md?.value(forAttribute: "kMDItemLastUsedDate") as? Date
        let modified = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let yearAgo = Date().addingTimeInterval(-365 * 86_400)
        if let used, used > Date().addingTimeInterval(-30 * 86_400) {
            atLeast(.caution); why.append("You opened it \(ago(used)).")
        } else if let used, used < yearAgo {
            atMost(.likelySafe); why.append("Last opened \(ago(used)).")
        } else if used == nil, let m = modified, m < yearAgo {
            atMost(.likelySafe); why.append("Not opened or changed since \(ago(m)).")
        }
        if let froms = md?.value(forAttribute: "kMDItemWhereFroms") as? [String], let host = froms.compactMap({ URL(string: $0)?.host }).first {
            why.append("Downloaded from \(host), so you can likely get it again.")
            if path.hasPrefix(home + "/Downloads/") { atMost(.likelySafe) }
        }
        if why.isEmpty { why.append("Nothing suggests other files or apps depend on it.") }
        return Verdict(level: level, reasons: why)
    }
}

/// Caches verdicts so lists can show a safety column without blocking.
final class SafetyCache: ObservableObject {
    static let shared = SafetyCache()
    @Published private(set) var verdicts: [URL: Verdict] = [:]
    private var pending = Set<URL>()
    private let queue = DispatchQueue(label: "vitalos.safety", qos: .utility)

    func verdict(_ url: URL) -> Verdict? {
        if let v = verdicts[url] { return v }
        guard !pending.contains(url) else { return nil }
        pending.insert(url)
        queue.async {
            let v = DeleteAdvisor.assess(url)
            DispatchQueue.main.async {
                self.verdicts[url] = v
                self.pending.remove(url)
            }
        }
        return nil
    }

    func invalidate() { verdicts = [:] }
}

struct SafetyBadge: View {
    let url: URL
    var compact = true
    @ObservedObject private var cache = SafetyCache.shared

    var body: some View {
        if let v = cache.verdict(url) {
            HStack(spacing: 4) {
                Image(systemName: v.level.symbol).foregroundStyle(v.level.color)
                if !compact { Text(v.level.title) }
            }
            .font(.ui(size: 11))
            .help(v.reasons.joined(separator: "\n"))
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

struct VerdictCard: View {
    let verdict: Verdict
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: verdict.level.symbol).font(.ui(size: 18)).foregroundStyle(verdict.level.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Can I delete this?").font(.ui(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Text(verdict.level.title).font(.ui(size: 15, weight: .semibold)).foregroundStyle(verdict.level.color)
                }
            }
            ForEach(verdict.reasons, id: \.self) { r in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(r).font(.ui(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(verdict.level.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Right-hand inspector for the file browser.
struct FileInspector: View {
    let url: URL
    @State private var info: [InfoRow] = []
    @State private var verdict: Verdict?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Thumb(url: url, size: 200).frame(maxWidth: .infinity).frame(height: 140)
                Text(url.lastPathComponent).font(.ui(size: 14, weight: .semibold)).lineLimit(3)
                Text(Places.abbreviate(url.deletingLastPathComponent().path))
                    .font(.ui(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                if let verdict { VerdictCard(verdict: verdict) } else { ProgressView("Checking…").controlSize(.small) }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(info, id: \.k) { r in
                        HStack(alignment: .top) {
                            Text(r.k).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
                            Text(r.v).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(.ui(size: 11))
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 270)
        .background(.regularMaterial)
        .task(id: url) {
            verdict = nil
            let u = url
            async let i = Work.run { SearchPreview.details(for: u) }
            async let v = Work.run { DeleteAdvisor.assess(u) }
            info = await i
            verdict = await v
        }
    }
}
