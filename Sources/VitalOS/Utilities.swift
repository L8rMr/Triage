import SwiftUI
import AppKit

// MARK: - The catalog of utilities

enum ToolID: String, CaseIterable, Identifiable, Hashable {
    case clean, tidy, clipboard, pdf, converter, rename, autopilot
    case diskmap, diskhealth, duplicates, forgotten, uninstaller
    case startup, network, ports, history, wifi, sound

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: return "Free Up Space"
        case .tidy: return "Tidy Downloads"
        case .clipboard: return "Clipboard"
        case .pdf: return "PDF Editor"
        case .converter: return "Converter"
        case .rename: return "Batch Rename"
        case .autopilot: return "Folder Autopilot"
        case .diskmap: return "Disk Map"
        case .diskhealth: return "Drive Health"
        case .duplicates: return "Duplicate Finder"
        case .forgotten: return "Forgotten Files"
        case .uninstaller: return "App Uninstaller"
        case .startup: return "Startup Items"
        case .network: return "Network by App"
        case .ports: return "Dev Servers & Ports"
        case .history: return "Health History"
        case .wifi: return "Wi-Fi"
        case .sound: return "Sound Mixer"
        }
    }

    var symbol: String {
        switch self {
        case .clean: return "externaldrive.badge.minus"
        case .tidy: return "tray.and.arrow.down"
        case .clipboard: return "doc.on.clipboard"
        case .pdf: return "doc.richtext"
        case .converter: return "arrow.triangle.2.circlepath"
        case .rename: return "character.cursor.ibeam"
        case .autopilot: return "wand.and.stars"
        case .diskmap: return "square.grid.3x3.square"
        case .diskhealth: return "stethoscope"
        case .duplicates: return "doc.on.doc"
        case .forgotten: return "clock.badge.questionmark"
        case .uninstaller: return "trash.square"
        case .startup: return "power"
        case .network: return "network"
        case .ports: return "server.rack"
        case .history: return "chart.xyaxis.line"
        case .wifi: return "wifi"
        case .sound: return "slider.vertical.3"
        }
    }

    var blurb: String {
        switch self {
        case .clean: return "Ten cleanup suggestions, safe ones in one click, all undoable."
        case .tidy: return "Sort loose downloads into folders by kind, with column filters."
        case .clipboard: return "Clipboard history, grab text from anywhere on screen, send it anywhere."
        case .pdf: return "Edit text in place with matched fonts (even scans), restyle live, add images, sign, redact, organize."
        case .converter: return "Images, PDFs, documents, audio, video and data, converted in bulk."
        case .rename: return "Rename hundreds of files with patterns, numbering and find & replace."
        case .autopilot: return "Rules that tidy folders on their own, like Hazel."
        case .diskmap: return "See what's eating your disk as a map you can click into."
        case .diskhealth: return "SMART status, SSD wear, hours in use, temperature, errors and a First Aid check."
        case .duplicates: return "Find files that are truly identical and keep just one."
        case .forgotten: return "Big files you haven't opened in a long time."
        case .uninstaller: return "Remove apps along with the files they leave behind."
        case .startup: return "Everything that launches at login or runs hidden in the background."
        case .network: return "Which apps are uploading and downloading right now."
        case .ports: return "Local servers, open ports and Docker containers, with one-click stop."
        case .history: return "Your Mac's heart rate over days, spikes, report card and alerts."
        case .wifi: return "Your current network, signal and speed. Switch networks in a tap."
        case .sound: return "A volume slider for every app playing sound, plus output device."
        }
    }

    var category: String {
        switch self {
        case .clean, .tidy, .diskmap, .diskhealth, .duplicates, .forgotten: return "Storage"
        case .clipboard, .pdf, .converter, .rename, .autopilot: return "Files & documents"
        case .uninstaller, .startup, .network, .ports, .history, .wifi, .sound: return "Apps & system"
        }
    }

    static let categories = ["Storage", "Files & documents", "Apps & system"]

    var route: Route {
        switch self {
        case .clean: return .clean
        case .tidy: return .tidy
        default: return .tool(self)
        }
    }

    @ViewBuilder var page: some View {
        switch self {
        case .clean: CleanView()
        case .tidy: TidyView()
        case .clipboard: ClipboardView()
        case .pdf: PDFEditorView()
        case .converter: ConverterView()
        case .rename: RenameView()
        case .autopilot: AutopilotView()
        case .diskmap: DiskMapView()
        case .diskhealth: DiskHealthView()
        case .duplicates: DuplicatesView()
        case .forgotten: ForgottenView()
        case .uninstaller: UninstallerView()
        case .startup: StartupView()
        case .network: NetworkView()
        case .ports: PortsView()
        case .history: HealthHistoryView()
        case .wifi: WiFiView()
        case .sound: SoundView()
        }
    }
}

// MARK: - Hub page

struct UtilitiesView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("utilities.pinned") private var pinnedRaw = "clean,tidy,clipboard,pdf"
    @State private var query = ""

    private var pinned: [String] { pinnedRaw.split(separator: ",").map(String.init) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    PageTitle(title: "Utilities", subtitle: "\(ToolID.allCases.count) tools that work with your files and your Mac's health. Star the ones you want in the sidebar.")
                    Spacer()
                    FilterPill("Find a tool", text: $query)
                }
                ForEach(ToolID.categories, id: \.self) { cat in
                    let tools = ToolID.allCases.filter {
                        $0.category == cat && (query.isEmpty || TextFilter.matches($0.title + " " + $0.blurb, query))
                    }
                    if !tools.isEmpty {
                        Text(cat.uppercased()).font(.ui(size: 11, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                            ForEach(tools) { t in card(t) }
                        }
                    }
                }
            }
            .padding(28)
            .padding(.top, 8)
        }
    }

    private func card(_ t: ToolID) -> some View {
        let isPinned = pinned.contains(t.rawValue)
        return Button { model.route = t.route } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: t.symbol)
                        .font(.ui(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Spacer()
                    Button {
                        var p = pinned
                        if isPinned { p.removeAll { $0 == t.rawValue } } else { p.append(t.rawValue) }
                        pinnedRaw = p.joined(separator: ",")
                    } label: {
                        Image(systemName: isPinned ? "star.fill" : "star").foregroundStyle(isPinned ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isPinned ? "Remove from sidebar" : "Show in sidebar")
                }
                Text(t.title).font(.ui(size: 14, weight: .semibold))
                Text(t.blurb).font(.ui(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .glass(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Common page frame for every utility.
struct ToolPage<Content: View, Trailing: View>: View {
    let tool: ToolID
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 12) {
                Image(systemName: tool.symbol)
                    .font(.ui(size: 22, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                PageTitle(title: tool.title, subtitle: subtitle ?? tool.blurb)
                Spacer()
                trailing
            }
            content
        }
        .padding(28)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension ToolPage where Trailing == EmptyView {
    init(tool: ToolID, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.tool = tool
        self.subtitle = subtitle
        self.trailing = EmptyView()
        self.content = content()
    }
}

// MARK: - Background work

/// Where slow work runs. Quick jobs (listing a folder, reading a plist) never wait behind
/// whole-disk scans, and big scans are limited to a few at a time so the Mac stays responsive.
enum Work {
    static let quick = DispatchQueue(label: "vitalos.quick", qos: .userInitiated, attributes: .concurrent)
    static let heavy: OperationQueue = {
        let q = OperationQueue()
        q.name = "vitalos.heavy"
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()

    /// Run blocking work off the Swift-concurrency pool and await the result.
    static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { c in quick.async { c.resume(returning: work()) } }
    }
    static func runHeavy<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { c in heavy.addOperation { c.resume(returning: work()) } }
    }
}

// MARK: - Shell helper

enum Shell {
    /// Runs a tool with arguments and returns stdout. Never goes through a shell, so no quoting issues.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        let handle = out.fileHandleForReading
        // A dedicated thread, never the shared pool: if the pool is busy, a pooled reader would never start
        // and every caller would hang until the timeout.
        let reader = Thread {
            data = handle.readDataToEndOfFile()
            done.signal()
        }
        reader.stackSize = 256 * 1024
        reader.start()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func which(_ names: [String]) -> String? {
        names.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var hasGit: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
            || FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
    }

    static var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VitalOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// A table header row + rows, sharing the app's column look. Used by several utilities.
struct TableBox<Header: View, Rows: View>: View {
    let header: Header
    let rows: Rows
    let footer: String?

    init(footer: String? = nil, @ViewBuilder header: () -> Header, @ViewBuilder rows: () -> Rows) {
        self.footer = footer
        self.header = header()
        self.rows = rows()
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 16).padding(.vertical, 8)
            Rectangle().fill(Theme.stroke).frame(height: 0.5)
            ScrollView { LazyVStack(spacing: 0) { rows }.padding(.vertical, 4) }
            if let footer {
                Rectangle().fill(Theme.stroke).frame(height: 0.5)
                Text(footer).font(.ui(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .glass(12)
    }
}
