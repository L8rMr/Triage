import SwiftUI
import AppKit
import CoreAudio
import AudioToolbox

// MARK: - Core Audio helpers

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ fallback: T) -> T {
        var a = addr(sel, scope)
        var v = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let st = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        return st == noErr ? v : fallback
    }

    @discardableResult
    static func set<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: T) -> Bool {
        var a = addr(sel, scope)
        var v = value
        return withUnsafePointer(to: &v) { AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) } == noErr
    }

    static func ids(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = addr(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &out) == noErr ? out : []
    }

    static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var a = addr(sel, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        guard st == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static var defaultOutput: AudioDeviceID { CA.get(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0)) }

    static func outputDevices() -> [(id: AudioDeviceID, name: String)] {
        ids(system, kAudioHardwarePropertyDevices).compactMap { d in
            guard !ids(d, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput).isEmpty,
                  let name = string(d, kAudioObjectPropertyName) else { return nil }
            if name.hasPrefix("Triage") { return nil }
            return (d, name)
        }
    }

    static func volume(_ d: AudioDeviceID) -> Float {
        get(d, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, Float32(0.5))
    }
    static func setVolume(_ d: AudioDeviceID, _ v: Float) {
        set(d, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, Float32(max(0, min(1, v))))
    }
    static func muted(_ d: AudioDeviceID) -> Bool { get(d, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, UInt32(0)) != 0 }
    static func setMuted(_ d: AudioDeviceID, _ m: Bool) { set(d, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, UInt32(m ? 1 : 0)) }
}

// MARK: - Per-app volume through a Core Audio process tap (macOS 14.2+)

/// Silences an app's own output and replays it at our chosen volume.
@available(macOS 14.2, *)
final class AppVolumeTap {
    final class Gain { var value: Float = 1 }
    let gain = Gain()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    let objects: [AudioObjectID]

    init?(objects: [AudioObjectID], volume: Float) {
        self.objects = objects
        gain.value = volume
        let desc = CATapDescription(stereoMixdownOfProcesses: objects)
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { return nil }

        let outDev = CA.defaultOutput
        guard let outUID = CA.string(outDev, kAudioDevicePropertyDeviceUID) else { stop(); return nil }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Triage Volume",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr else { stop(); return nil }

        let g = gain
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            let outs = UnsafeMutableAudioBufferListPointer(outData)
            let v = g.value
            // Silence everything first, then write the app's audio at the new level.
            for o in outs { if let p = o.mData { memset(p, 0, Int(o.mDataByteSize)) } }
            guard ins.count > 0, outs.count > 0 else { return }
            if ins.count == outs.count {
                for i in 0..<ins.count {
                    guard let s = ins[i].mData?.assumingMemoryBound(to: Float.self),
                          let d = outs[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let n = Int(min(ins[i].mDataByteSize, outs[i].mDataByteSize)) / 4
                    for k in 0..<n { d[k] = s[k] * v }
                }
            } else if ins.count == 1, ins[0].mNumberChannels > 1 {
                // interleaved tap → separate output channels
                guard let s = ins[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                let ch = Int(ins[0].mNumberChannels)
                let frames = Int(ins[0].mDataByteSize) / 4 / ch
                for c in 0..<min(ch, outs.count) {
                    guard let d = outs[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let n = min(frames, Int(outs[c].mDataByteSize) / 4)
                    for f in 0..<n { d[f] = s[f * ch + c] * v }
                }
            } else if outs.count == 1, outs[0].mNumberChannels > 1 {
                guard let d = outs[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                let ch = Int(outs[0].mNumberChannels)
                let frames = Int(outs[0].mDataByteSize) / 4 / ch
                for c in 0..<min(ch, ins.count) {
                    guard let s = ins[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let n = min(frames, Int(ins[c].mDataByteSize) / 4)
                    for f in 0..<n { d[f * ch + c] = s[f] * v }
                }
            }
        }
        guard status == noErr, let procID, AudioDeviceStart(aggID, procID) == noErr else { stop(); return nil }
    }

    func stop() {
        if let procID, aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        procID = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    deinit { stop() }
}

struct AppAudio: Identifiable, Equatable {
    let id: String
    let name: String
    let bundlePath: String?
    var objects: [AudioObjectID]
    var playing: Bool
}

final class MixerModel: ObservableObject {
    static let shared = MixerModel()
    @Published var apps: [AppAudio] = []
    @Published var master: Float = 0.5
    @Published var masterMuted = false
    @Published var devices: [(id: AudioDeviceID, name: String)] = []
    @Published var output: AudioDeviceID = 0
    @Published var levels: [String: Float] = (UserDefaults.standard.dictionary(forKey: "mixer.levels") as? [String: Float]) ?? [:]
    @Published var problem: String?
    private var taps: [String: AnyObject] = [:]
    private var timer: Timer?

    var supported: Bool { if #available(macOS 14.2, *) { return true } else { return false } }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        output = CA.defaultOutput
        master = CA.volume(output)
        masterMuted = CA.muted(output)
        devices = CA.outputDevices()
        guard supported else { return }
        var byApp: [String: AppAudio] = [:]
        if #available(macOS 14.2, *) {
            for obj in CA.ids(CA.system, kAudioHardwarePropertyProcessObjectList) {
                let pid = CA.get(obj, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, pid_t(-1))
                guard pid > 0, pid != getpid() else { continue }
                let running = CA.get(obj, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, UInt32(0)) != 0
                let name = appName(forPID: pid, fallback: "pid \(pid)")
                var buf = [CChar](repeating: 0, count: 4096)
                let cap = UInt32(4096)
                var bundle: String?
                if proc_pidpath(pid, &buf, cap) > 0 {
                    let path = String(cString: buf)
                    if let r = path.range(of: ".app/") { bundle = String(path[..<r.lowerBound]) + ".app" }
                }
                var a = byApp[name] ?? AppAudio(id: name, name: name, bundlePath: bundle, objects: [], playing: false)
                a.objects.append(obj)
                a.playing = a.playing || running
                byApp[name] = a
            }
        }
        let list = byApp.values
            .filter { $0.playing || levels[$0.id] != nil }
            .sorted { $0.playing != $1.playing ? $0.playing : $0.name < $1.name }
        if list != apps { apps = list }
        // keep taps attached to the app's current processes
        for a in list {
            let lv = levels[a.id] ?? 1
            if lv < 0.999 {
                if #available(macOS 14.2, *) {
                    if let t = taps[a.id] as? AppVolumeTap, Set(t.objects) == Set(a.objects) { t.gain.value = lv }
                    else { attach(a, lv) }
                }
            }
        }
    }

    func level(_ a: AppAudio) -> Float { levels[a.id] ?? 1 }

    func setLevel(_ a: AppAudio, _ v: Float) {
        levels[a.id] = v
        UserDefaults.standard.set(levels, forKey: "mixer.levels")
        guard #available(macOS 14.2, *) else { return }
        if v >= 0.999 {
            (taps[a.id] as? AppVolumeTap)?.stop()
            taps[a.id] = nil
            levels[a.id] = nil
            UserDefaults.standard.set(levels, forKey: "mixer.levels")
        } else if let t = taps[a.id] as? AppVolumeTap {
            t.gain.value = v
        } else {
            attach(a, v)
        }
    }

    @available(macOS 14.2, *)
    private func attach(_ a: AppAudio, _ v: Float) {
        (taps[a.id] as? AppVolumeTap)?.stop()
        if let t = AppVolumeTap(objects: a.objects, volume: v) {
            taps[a.id] = t
            problem = nil
        } else {
            taps[a.id] = nil
            problem = "macOS blocked per-app volume. Allow Triage under Privacy & Security → Screen & System Audio Recording, then try again."
        }
    }

    func setMaster(_ v: Float) { CA.setVolume(output, v); master = v }
    func toggleMasterMute() { CA.setMuted(output, !masterMuted); masterMuted.toggle() }

    func setOutput(_ id: AudioDeviceID) {
        CA.set(CA.system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, id)
        // taps follow the default device; rebuild them
        if #available(macOS 14.2, *) {
            for (k, t) in taps { (t as? AppVolumeTap)?.stop(); taps[k] = nil }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
    }

    func resetAll() {
        if #available(macOS 14.2, *) { for (_, t) in taps { (t as? AppVolumeTap)?.stop() } }
        taps = [:]
        levels = [:]
        UserDefaults.standard.set(levels, forKey: "mixer.levels")
        refresh()
    }
}

struct MixerPanel: View {
    @ObservedObject var mixer = MixerModel.shared
    var compact = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { mixer.toggleMasterMute() } label: {
                    Image(systemName: mixer.masterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 20)
                }
                .buttonStyle(.borderless)
                Slider(value: Binding(get: { Double(mixer.master) }, set: { mixer.setMaster(Float($0)) }), in: 0...1)
                Text("\(Int(mixer.master * 100))%").font(.ui(size: 11)).monospacedDigit().frame(width: 36, alignment: .trailing)
            }
            Picker("Output", selection: Binding(get: { mixer.output }, set: { mixer.setOutput($0) })) {
                ForEach(mixer.devices, id: \.id) { d in Text(d.name).tag(d.id) }
            }
            .font(.ui(size: 12))
            Divider()
            HStack {
                Text("APPS").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                Spacer()
                if mixer.apps.contains(where: { mixer.level($0) < 0.999 }) {
                    Button("Reset all") { mixer.resetAll() }.buttonStyle(.borderless).font(.ui(size: 10))
                }
            }
            if !mixer.supported {
                Text("Per-app volume needs macOS 14.2 or later.").font(.ui(size: 11)).foregroundStyle(.secondary)
            } else if mixer.apps.isEmpty {
                Text("Apps appear here while they're playing sound.").font(.ui(size: 11)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(mixer.apps) { a in
                        HStack(spacing: 8) {
                            Group {
                                if let p = a.bundlePath { Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable() }
                                else { Image(systemName: "app").resizable() }
                            }
                            .frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(a.name).font(.ui(size: 12)).lineLimit(1)
                                    if a.playing { Image(systemName: "waveform").font(.ui(size: 9)).foregroundStyle(Theme.accent) }
                                    Spacer()
                                    Text(mixer.level(a) == 0 ? "Muted" : "\(Int(mixer.level(a) * 100))%")
                                        .font(.ui(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                Slider(value: Binding(get: { Double(mixer.level(a)) }, set: { mixer.setLevel(a, Float($0)) }), in: 0...1)
                                    .controlSize(.small)
                            }
                            Button { mixer.setLevel(a, mixer.level(a) == 0 ? 1 : 0) } label: {
                                Image(systemName: mixer.level(a) == 0 ? "speaker.slash.fill" : "speaker.fill")
                            }
                            .buttonStyle(.borderless)
                            .help(mixer.level(a) == 0 ? "Unmute" : "Mute")
                        }
                        .contextMenu {
                            Button("Mute") { mixer.setLevel(a, 0) }
                            Button("50%") { mixer.setLevel(a, 0.5) }
                            Button("Full Volume") { mixer.setLevel(a, 1) }
                            if let p = a.bundlePath {
                                Divider()
                                Button("Bring \(a.name) to Front") { NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == p }?.activate() }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: compact ? 220 : 460)
            if let p = mixer.problem {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p).font(.ui(size: 10)).foregroundStyle(Theme.net).fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                    .controlSize(.mini)
                }
            }
        }
        .onAppear { mixer.start() }
        .onDisappear { if compact { mixer.stop() } }
    }
}

struct SoundView: View {
    var body: some View {
        ToolPage(tool: .sound, subtitle: "Turn each app up or down on its own, change the output device, and set the master volume.") {
            MixerPanel(compact: false)
                .padding(16)
                .frame(maxWidth: 560, alignment: .topLeading)
                .glass(12)
        }
    }
}
