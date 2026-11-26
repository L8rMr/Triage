import SwiftUI
import AppKit
import Carbon.HIToolbox

/// System-wide hotkey (⌥Space) through Carbon: works in every app, no Accessibility permission needed.
final class HotKey {
    static let shared = HotKey()
    var action: (() -> Void)? { didSet { actions[1] = action } }
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    /// ⌥Space by default (id 1). Other ids register extra shortcuts.
    func register(id: UInt32 = 1, keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey),
                  action: (() -> Void)? = nil) {
        if let action { actions[id] = action }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { HotKey.shared.fire(id) }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        if let old = refs[id] { UnregisterEventHotKey(old) }
        var ref: EventHotKeyRef?
        let hkid = EventHotKeyID(signature: OSType(0x5654_4F53), id: id)
        RegisterEventHotKey(keyCode, modifiers, hkid, GetApplicationEventTarget(), 0, &ref)
        if let ref { refs[id] = ref }
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }
}

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The floating search window, shown over whatever app you're in.
final class GlobalSearch: NSObject, NSWindowDelegate {
    static let shared = GlobalSearch()
    let engine = SmartSearch()
    private var panel: SearchPanel?
    private var monitor: Any?
    /// The app you were in, so closing the panel hands the keyboard straight back to it.
    private var previous: NSRunningApplication?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        if panel == nil { build() }
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2,
                                         y: f.maxY - f.height * 0.18 - panel.frame.height))
        }
        engine.refresh()
        // Typing only reaches us if VitalOS is the active app: a panel can be key while keystrokes still go to
        // whatever app was in front. Activate, show the panel, then put the cursor in the field ourselves.
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous = front }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        engine.focusToken += 1
        DispatchQueue.main.async { [weak self] in self?.focusField() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let p = self.panel, p.isVisible else { return }
            // a floating panel normally takes the keyboard without activating VitalOS (so your main window stays put);
            // if macOS didn't give it the keyboard, activate as a fallback
            if !p.isKeyWindow { NSApp.activate(ignoringOtherApps: true); p.makeKeyAndOrderFront(nil) }
            self.focusField()
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let p = self.panel, p.isVisible, e.window === p || p.isKeyWindow else { return e }
                return self.engine.handleKey(e) ? nil : e
            }
        }
    }

    func hide() {
        guard panel?.isVisible == true || monitor != nil else { return }
        panel?.orderOut(nil)
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        // back to where you were, unless you went on to a VitalOS window
        let ourWindowKey = NSApp.windows.contains { $0.isKeyWindow && !($0 is SearchPanel) && $0.isVisible }
        if !ourWindowKey, let p = previous, !p.isTerminated { p.activate() }
        previous = nil
    }

    private func focusField() {
        guard let panel, panel.isVisible else { return }
        if !panel.isKeyWindow { panel.makeKey() }
        if let r = panel.firstResponder as? NSText, r.isEditable { return }   // already typing in it
        if let field = Self.firstEditable(in: panel.contentView) { panel.makeFirstResponder(field) }
    }

    private static func firstEditable(in v: NSView?) -> NSView? {
        guard let v else { return nil }
        if let f = v as? NSTextField, f.isEditable { return f }
        if let t = v as? NSTextView, t.isEditable { return t }
        for s in v.subviews { if let f = firstEditable(in: s) { return f } }
        return nil
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func build() {
        let p = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 520),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.delegate = self
        engine.onClose = { [weak self] in self?.hide() }
        p.contentView = NSHostingView(rootView: SmartSearchView(engine: engine))
        panel = p
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The floating ⌥Space panel: its own field on top of the shared results body.
struct SmartSearchView: View {
    @ObservedObject var engine: SmartSearch
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.ui(size: 22)).foregroundStyle(Theme.accent)
                TextField("Search your whole Mac, the way you'd say it", text: $engine.text)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 22))
                    .focused($focused)
                    .modifier(SearchKeys(engine: engine))
                SearchStatus(engine: engine)
            }
            .padding(.horizontal, 18).padding(.vertical, 15)
            SearchResultsBody(engine: engine, inline: false)
        }
        .frame(width: 800, height: 520)
        .background(VisualEffect(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear { focused = true }
        .onChange(of: engine.focusToken) { _, _ in focused = true }
    }
}

struct SearchStatus: View {
    @ObservedObject var engine: SmartSearch
    var body: some View {
        HStack(spacing: 8) {
            if engine.searching { ProgressView().controlSize(.small) }
            if engine.total > 0 && !engine.text.isEmpty {
                Text("\(engine.total) found").font(.ui(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// A search field that lives right where you type (Home, sidebar). No second box pops up.
struct InlineSearchField: View {
    @ObservedObject var engine: SmartSearch
    var placeholder = "Search your whole Mac, the way you'd say it"
    var size: CGFloat = 15
    var focusToken = 0
    var onType: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(engine.text.isEmpty ? Color.secondary : Theme.accent)
            TextField(placeholder, text: $engine.text)
                .textFieldStyle(.plain)
                .font(.ui(size: size))
                .focused($focused)
                .modifier(SearchKeys(engine: engine))
                .onChange(of: engine.text) { _, t in if !t.isEmpty { onType?() } }
            if engine.text.isEmpty {
                Text("⌘K").font(.ui(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            } else {
                SearchStatus(engine: engine)
                Button { engine.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .onChange(of: focusToken) { _, _ in focused = true }
    }
}

/// Chips, results, preview and key hints. Shared by the panel and the in-window search.
struct SearchResultsBody: View {
    @ObservedObject var engine: SmartSearch
    let inline: Bool
    @State private var monitor: Any?

    private let examples = [
        "pdfs from last week", "screenshots today", "big videos in downloads",
        "swift files edited this week", "invoice from mail.google.com", "apps opened yesterday",
        "presentations in 2025", "1200 * 12 * 0.0725", "100 usd to eur", "quit chrome", "theme xp",
    ]

    var body: some View {
        VStack(spacing: 0) {
            if !engine.parsed.chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Understood").font(.ui(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        ForEach(engine.parsed.chips, id: \.self) { c in
                            Text(c).font(.ui(size: 11, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.accent.opacity(0.14), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .padding(.vertical, 8)
            }

            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)

            HStack(spacing: 0) {
                results.frame(width: inline ? 460 : 430)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            HStack(spacing: 16) {
                hint("↑↓", "Move"); hint("↩", "Open"); hint("⌘↩", "Show in Finder")
                if !inline { hint("⌥↩", "Open in VitalOS") }
                hint("⌘Y", "Quick Look"); hint("⇧⌘C", "Copy path")
                Spacer()
                hint("⌥Space", "from any app")
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .onAppear {
            guard inline, monitor == nil else { return }
            let e = engine
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
                if NSApp.keyWindow is SearchPanel || GlobalSearch.shared.isVisible { return ev }   // the floating panel owns the keys
                return e.handleKey(ev) ? nil : ev
            }
        }
        .onDisappear {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.ui(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.ui(size: 10))
        }
        .foregroundStyle(.secondary)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let m = engine.mathResult {
                        HStack(spacing: 10) {
                            Image(systemName: "equal.circle.fill").font(.ui(size: 20)).foregroundStyle(Theme.accent)
                            Text(m).font(.ui(size: 18, weight: .semibold, design: .rounded)).textSelection(.enabled)
                            Spacer()
                            Text("↩ copy").font(.ui(size: 10)).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(engine.selected == -1 ? Theme.accent.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .id(-1)
                        .onTapGesture { engine.selected = -1 }
                    }

                    if engine.text.trimmingCharacters(in: .whitespaces).isEmpty && !engine.history.isEmpty {
                        header("Recent searches")
                        ForEach(engine.history.prefix(4), id: \.self) { h in
                            Button { engine.text = h } label: {
                                Label(h, systemImage: "clock.arrow.circlepath").font(.ui(size: 12))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(engine.sections) { sec in
                        header(sec.id.rawValue)
                        ForEach(sec.hits) { hit in
                            HitRow(hit: hit, selected: hit.index == engine.selected)
                                .id(hit.index)
                                .onTapGesture(count: 2) { engine.selected = hit.index; engine.activate() }
                                .onTapGesture { engine.selected = hit.index }
                                .draggable(hit.url)
                                .contextMenu {
                                    if hit.command != nil { Button("Do it") { engine.selected = hit.index; engine.activate() } } else {
                                    Button("Open") { engine.selected = hit.index; engine.activate() }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
                                    Button("Open in VitalOS") { engine.onOpenInVitalOS?(hit.url) }
                                    Button("Copy Path") { engine.selected = hit.index; engine.copyPath() }
                                    }
                                }
                        }
                    }

                    if !engine.searching && engine.sections.isEmpty && engine.mathResult == nil
                        && !engine.text.trimmingCharacters(in: .whitespaces).isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Nothing matched.").font(.ui(size: 13, weight: .semibold))
                            Text("Try fewer words, or drop a filter like a date or size.")
                                .font(.ui(size: 12)).foregroundStyle(.secondary)
                        }
                        .padding(14)
                    }
                }
                .padding(8)
            }
            .onChange(of: engine.selected) { _, s in
                // scroll only as far as needed to keep the selection in view (centering every step made the list jump)
                proxy.scrollTo(s)
            }
        }
    }

    private func header(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.ui(size: 10, weight: .semibold)).kerning(0.7)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 3)
    }

    @ViewBuilder private var preview: some View {
        if engine.selected == -1, let m = engine.mathResult {
            VStack(spacing: 10) {
                Text(engine.text).font(.ui(size: 14, design: .monospaced)).foregroundStyle(.secondary)
                Text("= \(m)").font(.ui(size: 34, weight: .semibold, design: .rounded)).textSelection(.enabled)
                if let cap = engine.mathCaption { Text(cap).font(.ui(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                Text("Return copies the result").font(.ui(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(20)
        } else if let hit = engine.current, let c = hit.command {
            VStack(spacing: 12) {
                Image(systemName: c.symbol).font(.system(size: 34)).foregroundStyle(.white)
                    .frame(width: 72, height: 72).background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(c.title).font(.ui(size: 18, weight: .semibold)).multilineTextAlignment(.center)
                if !c.subtitle.isEmpty { Text(c.subtitle).font(.ui(size: 12)).foregroundStyle(.secondary) }
                Text("Press Return to do it").font(.ui(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let hit = engine.current {
            SearchPreview(hit: hit)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ask for files the way you'd say it").font(.ui(size: 15, weight: .semibold))
                Text("VitalOS understands kinds, dates, sizes, places, where a file was downloaded from, and math.")
                    .font(.ui(size: 12)).foregroundStyle(.secondary)
                ForEach(examples, id: \.self) { ex in
                    Button { engine.text = ex } label: {
                        Text(ex).font(.ui(size: 12, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Full-window search page, driven by the sidebar field.
struct SearchPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: "Search", subtitle: "Your whole Mac. Type in the sidebar, use ↑↓ and Return.")
            SearchResultsBody(engine: model.search, inline: true)
                .glass()
        }
        .padding(28)
        .padding(.top, 8)
    }
}

struct HitRow: View {
    let hit: SmartSearch.Hit
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let c = hit.command {
                Image(systemName: c.symbol).font(.system(size: 13)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(Theme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: hit.url.path)).resizable().frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.name).font(.ui(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(hit.command.map { $0.subtitle.isEmpty ? "VitalOS action · ↩ to do it" : $0.subtitle } ?? Places.abbreviate(hit.url.deletingLastPathComponent().path))
                    .font(.ui(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            if hit.contentOnly {
                Text("text").font(.ui(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.accent.opacity(0.15), in: Capsule()).foregroundStyle(Theme.accent)
            }
            if let d = hit.lastUsed ?? hit.modified {
                Text(d, format: .relative(presentation: .named)).font(.ui(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Theme.accent.opacity(0.28) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

struct InfoRow: Hashable {
    let k: String
    let v: String
}

struct SearchPreview: View {
    let hit: SmartSearch.Hit
    @State private var info: [InfoRow] = []

    var body: some View {
        VStack(spacing: 10) {
            Thumb(url: hit.url, size: 240).frame(width: 220, height: 160)
            Text(hit.name).font(.ui(size: 14, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
            Text(Places.abbreviate(hit.url.deletingLastPathComponent().path))
                .font(.ui(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                .multilineTextAlignment(.center)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(info, id: \.k) { r in
                    HStack(alignment: .top, spacing: 8) {
                        Text(r.k).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                        Text(r.v).lineLimit(2).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .font(.ui(size: 11))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .task(id: hit.id) {
            let url = hit.url
            info = await Work.run { SearchPreview.details(for: url) }
        }
    }

    nonisolated static func details(for url: URL) -> [InfoRow] {
        var rows: [InfoRow] = []
        guard let md = NSMetadataItem(url: url) else { return rows }
        func v(_ k: String) -> Any? { md.value(forAttribute: k) }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        if let kind = v("kMDItemKind") as? String { rows.append(InfoRow(k: "Kind", v: kind)) }
        if let s = v("kMDItemFSSize") as? NSNumber, s.int64Value > 0 { rows.append(InfoRow(k: "Size", v: Fmt.bytes(s.int64Value))) }
        if let w = v("kMDItemPixelWidth") as? NSNumber, let h = v("kMDItemPixelHeight") as? NSNumber {
            rows.append(InfoRow(k: "Dimensions", v: "\(w.intValue) × \(h.intValue)"))
        }
        if let d = v("kMDItemDurationSeconds") as? NSNumber {
            let t = Int(d.doubleValue)
            rows.append(InfoRow(k: "Duration", v: t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                                                           : String(format: "%d:%02d", t / 60, t % 60)))
        }
        if let p = v("kMDItemNumberOfPages") as? NSNumber { rows.append(InfoRow(k: "Pages", v: "\(p.intValue)")) }
        if let d = v("kMDItemLastUsedDate") as? Date { rows.append(InfoRow(k: "Last opened", v: df.string(from: d))) }
        if let d = v("kMDItemFSContentChangeDate") as? Date { rows.append(InfoRow(k: "Modified", v: df.string(from: d))) }
        if let d = v("kMDItemContentCreationDate") as? Date { rows.append(InfoRow(k: "Created", v: df.string(from: d))) }
        if let f = v("kMDItemWhereFroms") as? [String], let first = f.first {
            rows.append(InfoRow(k: "Downloaded from", v: URL(string: first)?.host ?? first))
        }
        if let a = v("kMDItemAuthors") as? [String], !a.isEmpty { rows.append(InfoRow(k: "Author", v: a.joined(separator: ", "))) }
        if let ver = v("kMDItemVersion") as? String { rows.append(InfoRow(k: "Version", v: ver)) }
        return rows
    }
}


/// Up, down, return and escape belong to the results list, not the text field: otherwise the arrows
/// just jump the text cursor to the start or end of what you typed and the highlight never moves.
struct SearchKeys: ViewModifier {
    let engine: SmartSearch
    func body(content: Content) -> some View {
        content.onKeyPress(keys: [.upArrow, .downArrow, .return, .escape], phases: [.down, .repeat]) { press in
            switch press.key {
            case .upArrow: engine.move(-1)
            case .downArrow: engine.move(1)
            case .return: engine.activate(reveal: press.modifiers.contains(.command), inVitalOS: press.modifiers.contains(.option))
            default: if engine.text.isEmpty { engine.onClose?() } else { engine.text = "" }
            }
            return .handled
        }
    }
}
