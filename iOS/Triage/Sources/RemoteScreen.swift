import SwiftUI
import UIKit
import AVFoundation
import CoreMedia

// MARK: - Frames from the Mac

/// Two kinds of picture arrive: hardware video ("V", HEVC/H.264) decoded by the phone's media engine straight onto a
/// display layer, or JPEGs ("F") from older Macs. Video frames never touch the main thread.
final class RemoteFrames: ObservableObject {
    static let shared = RemoteFrames()
    @Published private(set) var image: UIImage?
    @Published private(set) var videoSize: CGSize?
    @Published var note: String?
    @Published var ended = false
    /// Fires when the decoder lost its place and needs a fresh full picture from the Mac.
    var needKeyframe: () -> Void = {}

    let layer: AVSampleBufferDisplayLayer = {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspect
        l.backgroundColor = UIColor.black.cgColor
        return l
    }()
    private let q = DispatchQueue(label: "triage.frames", qos: .userInteractive)
    private var busy = false
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var waitingForKey = true

    func receive(_ data: Data) {
        if data.first == 0x56 { q.async { self.video(data) }; return }
        lock.lock(); if busy { lock.unlock(); return }; busy = true; lock.unlock()
        q.async {
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            guard data.count > 5, let img = UIImage(data: data.subdata(in: 5..<data.count))?.preparingForDisplay() else { return }
            DispatchQueue.main.async { self.image = img; self.videoSize = nil }
        }
    }

    private func video(_ d: Data) {          // on q
        guard d.count > 4 else { return }
        let hevc = d[d.startIndex + 1] == 1, key = d[d.startIndex + 2] == 1
        var i = d.startIndex + 3
        if key {
            let n = Int(d[i]); i += 1
            var sets: [Data] = []
            for _ in 0..<n {
                guard i + 2 <= d.endIndex else { return }
                let len = Int(d[i]) << 8 | Int(d[i + 1]); i += 2
                guard i + len <= d.endIndex else { return }
                sets.append(d.subdata(in: i..<(i + len))); i += len
            }
            if let f = Self.makeFormat(sets, hevc: hevc) {
                format = f
                let dims = CMVideoFormatDescriptionGetDimensions(f)
                let size = CGSize(width: Int(dims.width), height: Int(dims.height))
                DispatchQueue.main.async { if self.videoSize != size { self.videoSize = size }; if self.image != nil { self.image = nil } }
            }
            waitingForKey = false
        }
        guard !waitingForKey, let format else { return }
        let body = d.subdata(in: i..<d.endIndex)
        guard let sb = Self.makeSample(body, format: format) else { return }
        let r = layer.sampleBufferRenderer
        if r.status == .failed {
            r.flush()
            waitingForKey = true
            needKeyframe()
            return
        }
        r.enqueue(sb)
    }

    static func makeFormat(_ sets: [Data], hevc: Bool) -> CMVideoFormatDescription? {
        guard !sets.isEmpty else { return nil }
        let ptrs = sets.map { s -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
            s.copyBytes(to: p, count: s.count)
            return p
        }
        defer { ptrs.forEach { $0.deallocate() } }
        let cptrs = ptrs.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var f: CMVideoFormatDescription?
        let st = cptrs.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { ss in
                hevc
                    ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                          parameterSetPointers: pp.baseAddress!, parameterSetSizes: ss.baseAddress!,
                                                                          nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &f)
                    : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                          parameterSetPointers: pp.baseAddress!, parameterSetSizes: ss.baseAddress!,
                                                                          nalUnitHeaderLength: 4, formatDescriptionOut: &f)
            }
        }
        return st == noErr ? f : nil
    }

    static func makeSample(_ body: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: body.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: body.count, flags: 0, blockBufferOut: &bb) == noErr, let bb else { return nil }
        body.withUnsafeBytes { raw in _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: body.count) }
        var sb: CMSampleBuffer?
        var size = body.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(att) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }

    func flash(_ s: String) {
        DispatchQueue.main.async {
            self.note = s
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if self.note == s { self.note = nil } }
        }
    }

    func reset() {
        image = nil; videoSize = nil; ended = false
        q.async { self.format = nil; self.waitingForKey = true; self.layer.sampleBufferRenderer.flush(removingDisplayedImage: true) {} }
    }
}

/// Hosts the shared display layer.
struct VideoLayerView: UIViewRepresentable {
    final class Host: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            RemoteFrames.shared.layer.frame = bounds
            CATransaction.commit()
        }
    }
    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.backgroundColor = .black
        RemoteFrames.shared.layer.removeFromSuperlayer()
        v.layer.addSublayer(RemoteFrames.shared.layer)
        return v
    }
    func updateUIView(_ v: Host, context: Context) {
        if RemoteFrames.shared.layer.superlayer !== v.layer { v.layer.addSublayer(RemoteFrames.shared.layer) }
    }
}

// MARK: - Settings shared with the Settings screen

enum RemotePrefs {
    /// Hardware video bitrates: Fastest fits a so-so connection, Sharpest wants good Wi-Fi.
    static var stream: (fps: Int, quality: Double, maxWidth: Int, bitrate: Int) {
        switch UserDefaults.standard.string(forKey: "remote.quality") ?? "balanced" {
        case "fast": return (60, 0.4, 1600, 4_000_000)
        case "sharp": return (60, 0.72, 2940, 16_000_000)
        default: return (60, 0.55, 2200, 8_000_000)
        }
    }
}

// MARK: - The screen

struct RemoteScreen: View {
    var exit: () -> Void
    @EnvironmentObject var link: MacLink
    @ObservedObject private var frames = RemoteFrames.shared
    @Environment(\.horizontalSizeClass) private var hsc
    @AppStorage("remote.mode") private var mode = "trackpad"
    @AppStorage("remote.sensitivity") private var sensitivity = 1.6
    @AppStorage("remote.deck") private var deckTab = "both"
    @AppStorage("remote.clipAuto") private var clipAuto = true
    @AppStorage("remote.compactFull") private var compactFull = false
    @Environment(\.verticalSizeClass) private var vsc

    @State private var starting = true
    @State private var error: String?
    @State private var noInput = false
    @State private var displays: [[String: Any]] = []
    @State private var display: Int?
    @State private var mods: Set<String> = []
    @State private var locked: Set<String> = []
    @State private var typing = false
    @State private var showApps = false
    @State private var showShortcuts = false
    @State private var chrome = true
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var shareShot: [UIImage] = []
    @State private var sharing = false

    var body: some View {
        GeometryReader { proxy in
            let fold = Self.fold(proxy)
            Group {
                if let fold, fold.width > fold.height {
                    // Half folded like a laptop: the Mac on the top half, keyboard and trackpad on the bottom.
                    VStack(spacing: 0) {
                        screen.frame(height: max(fold.minY, 0))
                        Color.black.frame(height: fold.height)
                        deck(compact: true).frame(maxHeight: .infinity)
                    }
                } else if fullScreen {
                    // Fully open: the whole inner display is the Mac. Controls float and fade away.
                    ZStack(alignment: .bottom) {
                        screen
                        if chrome {
                            floatingBar.padding(.bottom, 12).transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            Button { chrome = true } label: {
                                Capsule().fill(.white.opacity(0.35)).frame(width: 64, height: 6).padding(14)
                            }
                            .accessibilityLabel("Show controls")
                        }
                    }
                } else {
                    // Closed (or a regular iPhone): screen up top, controls below.
                    VStack(spacing: 0) {
                        screen.frame(height: proxy.size.width * 0.66)
                        deck(compact: false).frame(maxHeight: .infinity)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black)
        .ignoresSafeArea(.container, edges: fullScreen ? .all : [])
        .statusBarHidden(fullScreen)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { topBar }
        .overlay { status }
        .overlay(alignment: .top) {
            if let n = frames.note {
                Text(n).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.top, 56).transition(.opacity)
            }
        }
        .animation(.snappy, value: frames.note)
        .animation(.easeInOut(duration: 0.25), value: chrome)
        .sheet(isPresented: $showApps) { AppSwitcher().environmentObject(link).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $sharing) { ShareSheet(items: shareShot) }
        .task { await start() }
        .onDisappear { stop() }
        .onChange(of: frames.ended) { _, e in if e { exit() } }
        .persistentSystemOverlays(.hidden)
    }

    /// Open Duo, a phone held sideways, or the closed phone with Full screen picked: the Mac edge to edge.
    private var fullScreen: Bool { hsc == .regular || vsc == .compact || compactFull }

    static func fold(_ proxy: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division).first?.frame
        }
        return nil
    }

    // MARK: Screen + gestures

    private var screen: some View {
        GeometryReader { g in
            let img = frames.image
            let fitted = Self.fit(frames.videoSize ?? img?.size ?? CGSize(width: 16, height: 10), in: g.size)
            ZStack {
                Color.black
                if frames.videoSize != nil {
                    VideoLayerView()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .scaleEffect(zoom, anchor: .center)
                        .offset(pan)
                } else if let img {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .scaleEffect(zoom, anchor: .center)
                        .offset(pan)
                }
                InputSurfaceView(mode: mode == "touch" ? .touch : .trackpad, sensitivity: sensitivity,
                                 mods: { takeMods() }, send: send,
                                 normalize: { p in
                                     // undo zoom and pan, then map into the picture
                                     let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
                                     let q = CGPoint(x: (p.x - pan.width - c.x) / zoom + c.x, y: (p.y - pan.height - c.y) / zoom + c.y)
                                     guard fitted.contains(q) else { return nil }
                                     return CGPoint(x: (q.x - fitted.minX) / fitted.width, y: (q.y - fitted.minY) / fitted.height)
                                 },
                                 pinch: { scale, translation, ended in
                                     zoom = min(max(zoom * scale, 1), 5)
                                     pan = zoom <= 1.01 ? .zero : CGSize(width: pan.width + translation.x, height: pan.height + translation.y)
                                 },
                                 tapChrome: { if fullScreen { chrome.toggle() } },
                                 displaySwipe: { step in nextDisplay(step) })
            }
            .clipped()
        }
    }

    static func fit(_ img: CGSize, in box: CGSize) -> CGRect {
        let s = min(box.width / max(img.width, 1), box.height / max(img.height, 1))
        let w = img.width * s, h = img.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    // MARK: Controls

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { exit() } label: { Image(systemName: "xmark").font(.headline).frame(width: 36, height: 36) }
                .background(.ultraThinMaterial, in: Circle())
            Spacer()
            if hsc != .regular && vsc != .compact {
                Button { withAnimation(.snappy) { compactFull.toggle(); chrome = true } } label: {
                    Image(systemName: compactFull ? "keyboard" : "arrow.up.left.and.arrow.down.right")
                        .font(.headline).frame(width: 36, height: 36)
                }
                .background(.ultraThinMaterial, in: Circle())
                .accessibilityLabel(compactFull ? "Keyboard and trackpad" : "Full screen")
            }
            Menu {
                Picker("Pointer", selection: $mode) {
                    Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left").tag("trackpad")
                    Label("Touch", systemImage: "hand.point.up").tag("touch")
                }
                if displays.count > 1 {
                    Picker("Display", selection: Binding(get: { display ?? 0 }, set: { switchDisplay($0) })) {
                        ForEach(displays.indices, id: \.self) { i in
                            Text(displays[i]["name"] as? String ?? "Display").tag(displays[i]["id"] as? Int ?? 0)
                        }
                    }
                }
                Button { zoom = 1; pan = .zero } label: { Label("Reset Zoom", systemImage: "arrow.down.right.and.arrow.up.left") }
                Button { screenshot() } label: { Label("Screenshot to iPhone", systemImage: "camera.viewfinder") }
                Toggle(isOn: $clipAuto) { Label("Copy from Mac to iPhone automatically", systemImage: "doc.on.clipboard") }
            } label: { Image(systemName: "slider.horizontal.3").font(.headline).frame(width: 36, height: 36) }
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, fullScreen ? 14 : 6)
        .opacity(chrome || !fullScreen ? 1 : 0)
    }

    /// Fully open: a slim dock you can hide by tapping the screen with three fingers… or the eye.
    private var floatingBar: some View {
        VStack(spacing: 10) {
            if deckTab == "keys" {
                MacKeyboard(mods: $mods, locked: $locked, showFRow: true) { k, m in sendKey(k, m) }
                    .frame(maxWidth: 620).frame(height: hsc == .regular ? 250 : 210)
            }
            HStack(spacing: 8) {
                barButton("keyboard", deckTab == "keys" ? "Hide keys" : "Keyboard") { deckTab = deckTab == "keys" ? "both" : "keys" }
                barButton("character.cursor.ibeam", typing ? "Done" : "Type") { typing.toggle() }
                barButton("cursorarrow.click", "Click") { send([["k": "click", "b": "left", "mods": takeMods()]]) }
                barButton("cursorarrow.click.2", "Right") { send([["k": "click", "b": "right", "mods": takeMods()]]) }
                barButton("square.grid.2x2", "Apps") { showApps = true }
                PasteButton(payloadType: String.self) { s in pasteOnMac(s.first ?? "") }
                    .labelStyle(.iconOnly).buttonBorderShape(.circle).tint(.white.opacity(0.2))
                barButton("chevron.down", "Hide") { chrome = false }
            }
            KeyCapture(active: $typing, send: send, mods: { takeMods() }).frame(width: 1, height: 1).opacity(0.01)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func barButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(label).font(.caption2)
            }
            .frame(width: 62, height: 46)
        }
        .foregroundStyle(.white)
    }

    /// The bottom half, MacBook-style: keyboard over trackpad, or either one on its own.
    private func deck(compact: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $deckTab) {
                    Image(systemName: "laptopcomputer").tag("both")
                    Image(systemName: "rectangle.and.hand.point.up.left").tag("trackpad")
                    Image(systemName: "keyboard").tag("keys")
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Spacer()
                Button { showShortcuts = true } label: { Image(systemName: "bolt.fill").frame(width: 30, height: 30) }
                    .popover(isPresented: $showShortcuts) {
                        shortcutGrid
                            .padding(12)
                            .frame(width: 340)
                            .background(Color(white: 0.1))
                            .environment(\.colorScheme, .dark)
                            .presentationCompactAdaptation(.popover)
                    }
                Button { typing.toggle() } label: { Image(systemName: typing ? "keyboard.chevron.compact.down" : "character.cursor.ibeam").frame(width: 30, height: 30) }
                Button { showApps = true } label: { Image(systemName: "square.grid.2x2").frame(width: 30, height: 30) }
                PasteButton(payloadType: String.self) { s in pasteOnMac(s.first ?? "") }
                    .labelStyle(.iconOnly).buttonBorderShape(.capsule)
            }
            .tint(.white)
            switch deckTab {
            case "keys":
                MacKeyboard(mods: $mods, locked: $locked, showFRow: true) { k, m in sendKey(k, m) }
            case "trackpad":
                trackpad
                HStack(spacing: 8) { clickButton("Click", "left"); clickButton("Right-click", "right") }.frame(height: 44)
            default:
                GeometryReader { g in
                    VStack(spacing: 8) {
                        MacKeyboard(mods: $mods, locked: $locked, showFRow: true) { k, m in sendKey(k, m) }
                            .frame(height: g.size.height * 0.62)
                        trackpad.padding(.horizontal, g.size.width * 0.18)    // centered, like a MacBook's
                    }
                }
            }
            KeyCapture(active: $typing, send: send, mods: { takeMods() }).frame(width: 1, height: 1).opacity(0.01)
        }
        .padding(10)
        .background(Color(white: 0.07))
        .environment(\.colorScheme, .dark)
    }

    /// Drag to move · tap to click · two-finger tap = right-click · two-finger drag = scroll · hold then drag = drag ·
    /// pinch = zoom · three-finger swipe up = Mission Control, down = App Exposé, sideways = switch Spaces ·
    /// three-finger tap = Look Up · four-finger swipe down = show desktop
    private var trackpad: some View {
        InputSurfaceView(mode: .trackpad, sensitivity: sensitivity, mods: { takeMods() }, send: send,
                         normalize: { _ in nil }, pinch: nil, tapChrome: { send([["k": "key", "key": "d", "mods": ["ctrl", "cmd"]]]) })
            .background(
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.12)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.1)))
    }

    private func clickButton(_ title: String, _ b: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            send([["k": "click", "b": b, "mods": takeMods()]])
        } label: {
            Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(.white)
    }

    private var modRow: some View {
        HStack(spacing: 6) {
            ForEach([("cmd", "⌘"), ("opt", "⌥"), ("ctrl", "⌃"), ("shift", "⇧")], id: \.0) { m in
                Button { if mods.contains(m.0) { mods.remove(m.0) } else { mods.insert(m.0) } } label: {
                    Text(m.1).font(.system(size: 18, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 36)
                }
                .background(mods.contains(m.0) ? Color.phosphor.opacity(0.85) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .foregroundStyle(mods.contains(m.0) ? .black : .white)
            }
        }
    }

    private var keyRow: some View {
        HStack(spacing: 6) {
            ForEach([("escape", "esc"), ("tab", "⇥"), ("left", "←"), ("up", "↑"), ("down", "↓"), ("right", "→"), ("delete", "⌫"), ("return", "⏎")], id: \.0) { k in
                Button { key(k.0) } label: {
                    Text(k.1).font(.system(size: 15, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity, minHeight: 36)
                }
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .foregroundStyle(.white)
            }
        }
    }

    private struct Shortcut: Identifiable { let id: String; let symbol: String; let key: String; let mods: [String] }
    private let shortcuts: [Shortcut] = [
        Shortcut(id: "Copy", symbol: "doc.on.doc", key: "c", mods: ["cmd"]),
        Shortcut(id: "Paste", symbol: "doc.on.clipboard", key: "v", mods: ["cmd"]),
        Shortcut(id: "Undo", symbol: "arrow.uturn.backward", key: "z", mods: ["cmd"]),
        Shortcut(id: "Spotlight", symbol: "magnifyingglass", key: "space", mods: ["cmd"]),
        Shortcut(id: "Switch", symbol: "rectangle.2.swap", key: "tab", mods: ["cmd"]),
        Shortcut(id: "Mission", symbol: "rectangle.3.group", key: "up", mods: ["ctrl"]),
        Shortcut(id: "Desktop", symbol: "menubar.dock.rectangle", key: "f11", mods: []),
        Shortcut(id: "Close", symbol: "xmark.square", key: "w", mods: ["cmd"]),
        Shortcut(id: "Quit", symbol: "power", key: "q", mods: ["cmd"]),
        Shortcut(id: "Snip", symbol: "camera.viewfinder", key: "4", mods: ["cmd", "shift"]),
        Shortcut(id: "Select all", symbol: "selection.pin.in.out", key: "a", mods: ["cmd"]),
        Shortcut(id: "Lock", symbol: "lock.fill", key: "q", mods: ["ctrl", "cmd"]),
    ]

    private var shortcutGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(shortcuts) { s in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    send([["k": "key", "key": s.key, "mods": s.mods]])
                    showShortcuts = false
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: s.symbol).font(.system(size: 15, weight: .semibold))
                        Text(s.id).font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let error {
            VStack(spacing: 12) {
                Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle)
                Text(error).multilineTextAlignment(.center)
                HStack {
                    Button("Try again") { Task { await start() } }.buttonStyle(.borderedProminent)
                    Button("Close") { exit() }.buttonStyle(.bordered)
                }
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(30)
        } else if starting && frames.image == nil && frames.videoSize == nil {
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Connecting to \(link.macName)'s screen…").font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
        } else if noInput {
            Text("Viewing only: allow Triage under Accessibility on the Mac to control it.")
                .font(.caption.weight(.semibold)).padding(10)
                .background(.ultraThinMaterial, in: Capsule())
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 90)
        }
    }

    // MARK: Talking to the Mac

    private func takeMods() -> [String] {
        let m = Array(mods.union(locked))
        if !mods.isEmpty { DispatchQueue.main.async { mods = [] } }
        return m
    }

    private func send(_ events: [[String: Any]]) { link.send("input", ["events": events]) }

    /// F1–F12 do what the icons say (brightness, Mission Control, volume…) unless fn is held, like a MacBook.
    private func sendKey(_ k: String, _ m: [String]) {
        let isF = k.count <= 3 && k.hasPrefix("f") && Int(k.dropFirst()) != nil
        if isF && !m.contains("fn") {
            send([["k": "media", "key": k]])
        } else {
            send([["k": "key", "key": k, "mods": m.filter { $0 != "fn" }]])
        }
    }

    private func key(_ k: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        send([["k": "key", "key": k, "mods": takeMods()]])
    }

    private func start() async {
        error = nil
        starting = true
        frames.reset()
        let p = RemotePrefs.stream
        frames.needKeyframe = { [link] in link.send("keyframe", [:]) }
        var args: [String: Any] = ["fps": p.fps, "quality": p.quality, "maxWidth": p.maxWidth, "codec": "hevc", "bitrate": p.bitrate]
        if let display { args["display"] = display }
        do {
            let d = try await link.call("screenStart", args)
            display = d["display"] as? Int
            noInput = (d["input"] as? Bool) == false
            if let ds = try? await link.call("displays") { displays = ds["displays"] as? [[String: Any]] ?? [] }
            _ = try? await link.call("clipSync", ["on": true])
        } catch {
            self.error = error.localizedDescription
        }
        starting = false
    }

    private func stop() {
        Task {
            _ = try? await link.call("screenStop")
            _ = try? await link.call("clipSync", ["on": false])
        }
    }

    /// Four-finger swipe on the picture: next or previous screen, with its name flashed so you know where you are.
    private func nextDisplay(_ step: Int) {
        let ids = displays.compactMap { $0["id"] as? Int }
        guard ids.count > 1 else { frames.flash("Only one display"); return }
        let i = ids.firstIndex(of: display ?? ids[0]) ?? 0
        let next = ids[(i + step + ids.count) % ids.count]
        frames.flash(displays.first { $0["id"] as? Int == next }?["name"] as? String ?? "Display")
        switchDisplay(next)
    }

    private func switchDisplay(_ id: Int) {
        display = id
        Task { await start() }
    }

    private func pasteOnMac(_ s: String) {
        guard !s.isEmpty else { return }
        Task {
            do { _ = try await link.call("pasteOnMac", ["text": s]); frames.flash("Pasted on \(link.macName)") }
            catch { frames.flash(error.localizedDescription) }
        }
    }

    private func screenshot() {
        Task {
            do {
                let d = try await link.call("screenshot")
                if let b = (d["png"] as? String).flatMap({ Data(base64Encoded: $0) }), let img = UIImage(data: b) {
                    shareShot = [img]; sharing = true
                }
            } catch { frames.flash(error.localizedDescription) }
        }
    }
}

// MARK: - App switcher + launcher

private struct AppSwitcher: View {
    @EnvironmentObject var link: MacLink
    @Environment(\.dismiss) private var dismiss
    @State private var running: [[String: Any]] = []
    @State private var all: [[String: Any]] = []
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section("Open on \(link.macName)") {
                        ForEach(running.indices, id: \.self) { i in
                            let a = running[i]
                            Button {
                                Task { _ = try? await link.call("activate", ["pid": a["pid"] as? Int ?? 0]); dismiss() }
                            } label: {
                                HStack {
                                    Text(a["name"] as? String ?? "App")
                                    Spacer()
                                    if a["active"] as? Bool == true { Text("In front").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                Section(query.isEmpty ? "All apps" : "Matches") {
                    ForEach(all.indices.filter { query.isEmpty || (all[$0]["name"] as? String ?? "").localizedCaseInsensitiveContains(query) }, id: \.self) { i in
                        Button {
                            Task { _ = try? await link.call("launch", ["path": all[i]["path"] as? String ?? ""]); dismiss() }
                        } label: { Text(all[i]["name"] as? String ?? "") }
                    }
                }
            }
            .searchable(text: $query, prompt: "Open an app on the Mac")
            .navigationTitle("Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                if let d = try? await link.call("runningApps") { running = d["apps"] as? [[String: Any]] ?? [] }
                if let d = try? await link.call("launchables") { all = d["apps"] as? [[String: Any]] ?? [] }
            }
        }
    }
}

// MARK: - Multi-touch input surface (UIKit for precise, immediate gestures)

struct InputSurfaceView: UIViewRepresentable {
    enum Mode { case trackpad, touch }
    let mode: Mode
    let sensitivity: Double
    let mods: () -> [String]
    let send: ([[String: Any]]) -> Void
    let normalize: (CGPoint) -> CGPoint?
    let pinch: ((CGFloat, CGPoint, Bool) -> Void)?
    let tapChrome: () -> Void
    var displaySwipe: ((Int) -> Void)? = nil

    func makeUIView(context: Context) -> InputSurface { InputSurface() }
    func updateUIView(_ v: InputSurface, context: Context) {
        v.mode = mode
        v.sensitivity = CGFloat(sensitivity)
        v.mods = mods
        v.send = send
        v.normalize = normalize
        v.onPinch = pinch
        v.onThreeTap = tapChrome
        v.onDisplaySwipe = displaySwipe
    }
}

final class InputSurface: UIView, UIGestureRecognizerDelegate {
    var mode: InputSurfaceView.Mode = .trackpad
    var sensitivity: CGFloat = 1.6
    var mods: () -> [String] = { [] }
    var send: ([[String: Any]]) -> Void = { _ in }
    var normalize: (CGPoint) -> CGPoint? = { _ in nil }
    var onPinch: ((CGFloat, CGPoint, Bool) -> Void)?
    var onThreeTap: () -> Void = {}

    private let tick = UIImpactFeedbackGenerator(style: .light)
    private let thunk = UIImpactFeedbackGenerator(style: .medium)
    private var holdLast: CGPoint = .zero
    private var pinchLast: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let pan1 = UIPanGestureRecognizer(target: self, action: #selector(pan1(_:)))
        pan1.maximumNumberOfTouches = 1
        let pan2 = UIPanGestureRecognizer(target: self, action: #selector(pan2(_:)))
        pan2.minimumNumberOfTouches = 2; pan2.maximumNumberOfTouches = 2
        let tap1 = UITapGestureRecognizer(target: self, action: #selector(tap1(_:)))
        let tap2 = UITapGestureRecognizer(target: self, action: #selector(tap2(_:)))
        tap2.numberOfTouchesRequired = 2
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
        hold.minimumPressDuration = 0.28
        hold.allowableMovement = 12
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        pan1.require(toFail: hold)
        tap1.require(toFail: tap2)
        var swipes: [UIGestureRecognizer] = []
        for (fingers, dirs) in [(3, [UISwipeGestureRecognizer.Direction.up, .down, .left, .right]), (4, [.down, .up, .left, .right])] {
            for d in dirs {
                let sw = UISwipeGestureRecognizer(target: self, action: #selector(swipe(_:)))
                sw.numberOfTouchesRequired = fingers
                sw.direction = d
                swipes.append(sw)
            }
        }
        for g in [pan1, pan2, tap1, tap2, hold, pinch] + swipes { g.delegate = self; addGestureRecognizer(g) }
        tick.prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (other is UIPinchGestureRecognizer && g is UIPanGestureRecognizer)
    }

    private func absMove(_ p: CGPoint) -> [String: Any]? {
        guard let n = normalize(p) else { return nil }
        return ["k": "move", "x": Double(n.x), "y": Double(n.y)]
    }

    /// Trackpad acceleration: slow moves are precise, fast flicks cross the screen.
    private func accel(_ v: CGPoint) -> CGFloat {
        let speed = hypot(v.x, v.y)
        return sensitivity * (0.6 + min(speed / 700, 2.4))
    }

    @objc private func pan1(_ g: UIPanGestureRecognizer) {
        switch mode {
        case .trackpad:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            let a = accel(g.velocity(in: self))
            if t != .zero { send([["k": "moveBy", "dx": Double(t.x * a), "dy": Double(t.y * a)]]) }
        case .touch:
            let p = g.location(in: self)
            switch g.state {
            case .began:
                if let m = absMove(p) { send([m, ["k": "down", "b": "left", "mods": mods()]]) }
            case .changed:
                if let m = absMove(p) { send([m]) }
            default:
                send([["k": "up", "b": "left"]])
            }
        }
    }

    @objc private func pan2(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if t != .zero { send([["k": "scroll", "dx": Double(t.x * 2), "dy": Double(t.y * 2)]]) }
    }

    @objc private func tap1(_ g: UITapGestureRecognizer) {
        tick.impactOccurred()
        var ev: [[String: Any]] = []
        if mode == .touch, let m = absMove(g.location(in: self)) { ev.append(m) }
        ev.append(["k": "click", "b": "left", "mods": mods()])
        send(ev)
    }

    @objc private func tap2(_ g: UITapGestureRecognizer) {
        thunk.impactOccurred()
        var ev: [[String: Any]] = []
        if mode == .touch, let m = absMove(g.location(in: self)) { ev.append(m) }
        ev.append(["k": "click", "b": "right", "mods": mods()])
        send(ev)
    }


    /// macOS trackpad gestures, sent as the shortcuts macOS maps them to.
    var onDisplaySwipe: ((Int) -> Void)?

    /// 3 = like a Mac trackpad. 4 = for phones with iOS Zoom on, which keeps three-finger gestures for itself.
    private var fingers: Int { UserDefaults.standard.object(forKey: "remote.fingers") as? Int ?? 3 }

    @objc private func swipe(_ g: UISwipeGestureRecognizer) {
        let n = g.numberOfTouchesRequired, sideways = g.direction == .left || g.direction == .right
        // the "other" count: with 3-finger gestures, four fingers sideways switches displays / down shows desktop
        if n != fingers {
            guard n == 4, fingers == 3 else { return }
            thunk.impactOccurred()
            if sideways { onDisplaySwipe?(g.direction == .left ? 1 : -1) }
            else if g.direction == .down { send([["k": "key", "key": "f11", "mods": []]]) }
            return
        }
        guard mode == .trackpad else { return }
        thunk.impactOccurred()
        let key: (String, [String])
        switch g.direction {
        case .up: key = ("up", ["ctrl"])                 // Mission Control
        case .down: key = ("down", ["ctrl"])             // App Exposé
        case .left: key = ("right", ["ctrl"])            // next Space
        default: key = ("left", ["ctrl"])                // previous Space
        }
        send([["k": "key", "key": key.0, "mods": key.1]])
    }

    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }   // no iOS undo HUD on 3-finger swipes
    private var zoomAcc: CGFloat = 1

    @objc private func hold(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            thunk.impactOccurred()
            holdLast = p
            if mode == .touch {
                // long press in touch mode = right click where you are
                var ev: [[String: Any]] = []
                if let m = absMove(p) { ev.append(m) }
                ev.append(["k": "click", "b": "right", "mods": mods()])
                send(ev)
            } else {
                send([["k": "down", "b": "left", "mods": mods()]])      // hold, then drag
            }
        case .changed:
            guard mode == .trackpad else { return }
            let d = CGPoint(x: p.x - holdLast.x, y: p.y - holdLast.y)
            holdLast = p
            send([["k": "moveBy", "dx": Double(d.x * sensitivity * 1.2), "dy": Double(d.y * sensitivity * 1.2)]])
        default:
            if mode == .trackpad { send([["k": "up", "b": "left"]]) }
        }
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        guard let onPinch else {
            // on the trackpad: pinch zooms the Mac's front window (⌘+ / ⌘−), one step per 25% of pinch
            zoomAcc *= g.scale
            g.scale = 1
            if zoomAcc > 1.25 { send([["k": "key", "key": "=", "mods": ["cmd"]]]); zoomAcc = 1; tick.impactOccurred() }
            if zoomAcc < 0.8 { send([["k": "key", "key": "-", "mods": ["cmd"]]]); zoomAcc = 1; tick.impactOccurred() }
            if g.state == .ended { zoomAcc = 1 }
            return
        }
        guard g.numberOfTouches >= 2 || g.state == .ended else { return }
        let p = g.location(in: self)
        if g.state == .began { pinchLast = p }
        let t = CGPoint(x: p.x - pinchLast.x, y: p.y - pinchLast.y)
        pinchLast = p
        onPinch(g.scale, t, g.state == .ended)
        g.scale = 1
    }
}

// MARK: - Keyboard: the iPhone keyboard (and any hardware keyboard) typing straight into the Mac

struct KeyCapture: UIViewRepresentable {
    @Binding var active: Bool
    let send: ([[String: Any]]) -> Void
    let mods: () -> [String]

    func makeUIView(context: Context) -> KeyCaptureView {
        let v = KeyCaptureView()
        v.onResign = { DispatchQueue.main.async { active = false } }
        return v
    }

    func updateUIView(_ v: KeyCaptureView, context: Context) {
        v.send = send
        v.mods = mods
        if active && !v.isFirstResponder { DispatchQueue.main.async { v.becomeFirstResponder() } }
        if !active && v.isFirstResponder { DispatchQueue.main.async { v.resignFirstResponder() } }
    }
}

final class KeyCaptureView: UIView, UIKeyInput {
    var send: ([[String: Any]]) -> Void = { _ in }
    var mods: () -> [String] = { [] }
    var onResign: () -> Void = {}

    override var canBecomeFirstResponder: Bool { true }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    var hasText: Bool { true }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default

    func insertText(_ text: String) {
        let m = mods()
        if !m.isEmpty, text.count == 1, text != "\n" {
            // a modifier is armed: ⌘ + "c" is a shortcut, not the letter c
            send([["k": "key", "key": text.lowercased(), "mods": m]])
        } else if text == "\n" {
            send([["k": "key", "key": "return", "mods": m]])
        } else {
            send([["k": "text", "s": text]])
        }
    }

    func deleteBackward() { send([["k": "key", "key": "delete", "mods": mods()]]) }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        onResign()
        return r
    }

    /// Hardware keyboards (Magic Keyboard, Duo keyboard case): arrows, escape and ⌘-shortcuts go straight through.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            guard let k = p.key else { continue }
            var m: [String] = []
            if k.modifierFlags.contains(.command) { m.append("cmd") }
            if k.modifierFlags.contains(.alternate) { m.append("opt") }
            if k.modifierFlags.contains(.control) { m.append("ctrl") }
            if k.modifierFlags.contains(.shift) { m.append("shift") }
            let special: [UIKeyboardHIDUsage: String] = [
                .keyboardLeftArrow: "left", .keyboardRightArrow: "right", .keyboardUpArrow: "up", .keyboardDownArrow: "down",
                .keyboardEscape: "escape", .keyboardTab: "tab", .keyboardDeleteForward: "forwarddelete",
                .keyboardHome: "home", .keyboardEnd: "end", .keyboardPageUp: "pageup", .keyboardPageDown: "pagedown",
            ]
            if let name = special[k.keyCode] {
                send([["k": "key", "key": name, "mods": m]]); handled = true
            } else if m.contains("cmd") || m.contains("ctrl") || m.contains("opt") {
                let c = k.charactersIgnoringModifiers.lowercased()
                if !c.isEmpty { send([["k": "key", "key": c == " " ? "space" : c, "mods": m]]); handled = true }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
}
