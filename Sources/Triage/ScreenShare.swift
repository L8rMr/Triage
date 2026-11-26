import Foundation
import AppKit
import ScreenCaptureKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import ApplicationServices

// MARK: - Remote desktop: the screen out, the mouse and keyboard in
//
// Frames: ScreenCaptureKit only hands over a frame when something on screen changed, so an idle desktop costs
// nothing and a moving one streams at up to the phone's chosen fps. Each frame is JPEG'd and sent as a sealed
// binary message ("F" + width + height + jpeg), never JSON/base64, and a viewer never has more than two frames in
// flight: if Wi-Fi hiccups we drop stale frames instead of queueing lag.

final class ScreenShare: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = ScreenShare()
    private let q = DispatchQueue(label: "triage.screen", qos: .userInteractive)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private(set) var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var quality: CGFloat = 0.55
    /// Hands a finished frame (already JPEG) to whoever is watching.
    var onFrame: ((Data) -> Void)?
    private(set) var running = false

    static var displays: [[String: Any]] {
        NSScreen.screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(n.uint32Value)
            let b = CGDisplayBounds(id)
            return ["id": Int(id), "name": s.localizedName, "w": b.width, "h": b.height, "main": CGDisplayIsMain(id) != 0]
        }
    }

    func start(display: CGDirectDisplayID?, fps: Int, maxWidth: Int, quality: CGFloat) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw RemoteError(message: "Allow Triage under Screen Recording on the Mac (System Settings › Privacy & Security), then try again.")
        }
        await stopAsync()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let want = display ?? CGMainDisplayID()
        guard let d = content.displays.first(where: { $0.displayID == want }) ?? content.displays.first else {
            throw RemoteError(message: "Couldn't find that display")
        }
        displayID = d.displayID
        self.quality = min(max(quality, 0.2), 0.9)
        let scale = min(1, CGFloat(maxWidth) / CGFloat(d.width * 2))
        let cfg = SCStreamConfiguration()
        cfg.width = max(320, Int(CGFloat(d.width * 2) * scale))
        cfg.height = max(200, Int(CGFloat(d.height * 2) * scale))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(min(max(fps, 5), 60)))
        cfg.showsCursor = true
        cfg.queueDepth = 3
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.capturesAudio = false
        let filter = SCContentFilter(display: d, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        try await s.startCapture()
        stream = s
        running = true
    }

    func stop() { Task { await stopAsync() } }

    private func stopAsync() async {
        guard let s = stream else { return }
        stream = nil
        running = false
        try? await s.stopCapture()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        running = false
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sb.imageBuffer,
              let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, raw == SCFrameStatus.complete.rawValue else { return }
        let img = CIImage(cvPixelBuffer: pb)
        guard let cg = ci.createCGImage(img, from: img.extent) else { return }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        var header = Data([0x46])                       // "F"
        var w = UInt16(cg.width).bigEndian, h = UInt16(cg.height).bigEndian
        header.append(Data(bytes: &w, count: 2)); header.append(Data(bytes: &h, count: 2))
        onFrame?(header + (out as Data))
    }

    func screenshot() async throws -> Data {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw RemoteError(message: "Allow Triage under Screen Recording on the Mac first.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let d = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { throw RemoteError(message: "No display") }
        let cfg = SCStreamConfiguration()
        cfg.width = d.width * 2; cfg.height = d.height * 2; cfg.showsCursor = false
        let cg = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg)
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

// MARK: - Mouse and keyboard from the phone

enum RemoteInput {
    private static let q = DispatchQueue(label: "triage.input", qos: .userInteractive)
    private static var leftDown = false
    private static var rightDown = false
    private static var lastClick = Date.distantPast
    private static var clickCount: Int64 = 1

    static var trusted: Bool { AXIsProcessTrusted() }

    static func askForAccess() {
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opt)
    }

    static func handle(_ events: [[String: Any]]) {
        q.async { events.forEach(one) }
    }

    private static var display: CGRect { CGDisplayBounds(ScreenShare.shared.displayID) }

    private static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private static func clamp(_ p: CGPoint) -> CGPoint {
        // keep the pointer on any connected screen, not just the one being shown
        var all = CGRect.null
        var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &n)
        for i in 0..<Int(n) { all = all.union(CGDisplayBounds(ids[i])) }
        if all.isNull { all = display }
        return CGPoint(x: min(max(p.x, all.minX), all.maxX - 1), y: min(max(p.y, all.minY), all.maxY - 1))
    }

    private static func flags(_ e: [String: Any]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in (e["mods"] as? [String]) ?? [] {
            switch m {
            case "cmd": f.insert(.maskCommand)
            case "opt": f.insert(.maskAlternate)
            case "ctrl": f.insert(.maskControl)
            case "shift": f.insert(.maskShift)
            case "fn": f.insert(.maskSecondaryFn)
            default: break
            }
        }
        return f
    }

    private static func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1, flags f: CGEventFlags = []) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: clicks)
        if !f.isEmpty { ev.flags = f }
        ev.post(tap: .cghidEventTap)
    }

    private static func moveTo(_ p: CGPoint) {
        let p = clamp(p)
        post(leftDown ? .leftMouseDragged : rightDown ? .rightMouseDragged : .mouseMoved, at: p, button: rightDown ? .right : .left)
    }

    private static func one(_ e: [String: Any]) {
        let k = e["k"] as? String ?? ""
        switch k {
        case "move":       // absolute, 0…1 across the shown display
            let x = e["x"] as? Double ?? 0, y = e["y"] as? Double ?? 0
            let d = display
            moveTo(CGPoint(x: d.minX + d.width * x, y: d.minY + d.height * y))
        case "moveBy":     // relative, in points (trackpad)
            let c = cursor
            moveTo(CGPoint(x: c.x + (e["dx"] as? Double ?? 0), y: c.y + (e["dy"] as? Double ?? 0)))
        case "down", "up":
            let right = (e["b"] as? String) == "right"
            if k == "down" {
                let now = Date()
                clickCount = now.timeIntervalSince(lastClick) < NSEvent.doubleClickInterval ? min(clickCount + 1, 3) : 1
                lastClick = now
                if right { rightDown = true } else { leftDown = true }
            } else {
                if right { rightDown = false } else { leftDown = false }
            }
            let type: CGEventType = right ? (k == "down" ? .rightMouseDown : .rightMouseUp) : (k == "down" ? .leftMouseDown : .leftMouseUp)
            post(type, at: cursor, button: right ? .right : .left, clicks: right ? 1 : clickCount, flags: flags(e))
        case "click":
            let right = (e["b"] as? String) == "right"
            one(["k": "down", "b": right ? "right" : "left", "mods": e["mods"] ?? []])
            one(["k": "up", "b": right ? "right" : "left", "mods": e["mods"] ?? []])
        case "scroll":
            let dy = Int32((e["dy"] as? Double ?? 0).rounded()), dx = Int32((e["dx"] as? Double ?? 0).rounded())
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
        case "key":
            guard let name = e["key"] as? String, let code = keyCodes[name.lowercased()] else { return }
            let f = flags(e)
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
                ev.flags = f
                ev.post(tap: .cghidEventTap)
            }
        case "media":      // the Mac's F-row specials, like pressing them on a MacBook
            media(e["key"] as? String ?? "")
        case "text":
            for ch in (e["s"] as? String) ?? "" {
                if ch == "\n" { one(["k": "key", "key": "return"]); continue }
                let u = Array(String(ch).utf16)
                for down in [true, false] {
                    guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                    ev.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                    ev.post(tap: .cghidEventTap)
                }
            }
        default: break
        }
    }

    /// NX_KEYTYPE_* system keys (volume, brightness, playback) go out as "system defined" events, the way a real keyboard sends them.
    private static func systemKey(_ code: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((code << 16) | ((down ? 0xa : 0xb) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func rawKey(_ code: CGKeyCode) {
        for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap) }
    }

    private static func media(_ key: String) {
        switch key {
        case "f1": systemKey(3)              // brightness down
        case "f2": systemKey(2)              // brightness up
        case "f3": DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app")) }
        case "f4": one(["k": "key", "key": "space", "mods": ["cmd"]])      // Spotlight
        case "f5": rawKey(176)               // Dictation key
        case "f6": rawKey(178)               // Do Not Disturb key
        case "f7": systemKey(18)             // previous track
        case "f8": systemKey(16)             // play / pause
        case "f9": systemKey(17)             // next track
        case "f10": systemKey(7)             // mute
        case "f11": systemKey(1)             // volume down
        case "f12": systemKey(0)             // volume up
        default: break
        }
    }

    /// US keyboard layout virtual key codes.
    static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
            "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39,
            "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
            "delete": 51, "escape": 53, "esc": 53, "volumeup": 72, "volumedown": 73, "mute": 74,
            "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let f: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, c) in f.enumerated() { m["f\(i + 1)"] = c }
        return m
    }()
}

// MARK: - Ops

extension RemoteAPI {
    static let desktopOps: Set<String> = ["screenStart", "screenStop", "displays", "screenshot", "runningApps", "activate",
                                          "launchables", "launch", "clipSync", "pasteOnMac"]

    static func desktop(_ op: String, _ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) -> Bool {
        guard desktopOps.contains(op) else { return false }
        guard RemoteServer.shared.mode == .full else {
            done(.failure(RemoteError(message: "Remote desktop needs Full control. Turn it on in Triage › Settings › iPhone on the Mac.")))
            return true
        }
        switch op {
        case "displays": done(.success(["displays": ScreenShare.displays, "current": Int(ScreenShare.shared.displayID)]))
        case "screenStart":
            if !RemoteInput.trusted { RemoteInput.askForAccess() }
            let id = (a["display"] as? Int).map { CGDirectDisplayID($0) }
            Task {
                do {
                    try await ScreenShare.shared.start(display: id, fps: a["fps"] as? Int ?? 30, maxWidth: a["maxWidth"] as? Int ?? 1600,
                                                       quality: CGFloat(a["quality"] as? Double ?? 0.55))
                    RemoteServer.shared.startWatching(s)
                    let b = CGDisplayBounds(ScreenShare.shared.displayID)
                    done(.success(["display": Int(ScreenShare.shared.displayID), "w": b.width, "h": b.height,
                                   "input": RemoteInput.trusted]))
                } catch {
                    done(.failure((error as? RemoteError) ?? RemoteError(message: error.localizedDescription)))
                }
            }
        case "screenStop":
            RemoteServer.shared.stopWatching(s)
            done(.success([:]))
        case "screenshot":
            Task {
                do { done(.success(["png": try await ScreenShare.shared.screenshot().base64EncodedString()])) }
                catch { done(.failure((error as? RemoteError) ?? RemoteError(message: error.localizedDescription))) }
            }
        case "runningApps":
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
                ["name": $0.localizedName ?? "App", "bundle": $0.bundleIdentifier ?? "", "active": $0.isActive, "pid": Int($0.processIdentifier)] as [String: Any]
            }
            done(.success(["apps": apps]))
        case "activate":
            if let pid = a["pid"] as? Int, let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                app.activate()
                done(.success([:]))
            } else { done(.failure(RemoteError(message: "That app quit"))) }
        case "launchables":
            DispatchQueue.global(qos: .userInitiated).async {
                var out: [[String: Any]] = []
                let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
                for d in dirs {
                    for n in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where n.hasSuffix(".app") {
                        out.append(["name": String(n.dropLast(4)), "path": d + "/" + n])
                    }
                }
                done(.success(["apps": out.sorted { ($0["name"] as! String).localizedCaseInsensitiveCompare($1["name"] as! String) == .orderedAscending }]))
            }
        case "launch":
            guard let p = a["path"] as? String, p.hasSuffix(".app") else { done(.failure(RemoteError(message: "Not an app"))); return true }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: p), configuration: NSWorkspace.OpenConfiguration()) { _, err in
                if let err { done(.failure(RemoteError(message: err.localizedDescription))) } else { done(.success([:])) }
            }
            RemoteServer.shared.record(s.deviceName, "Opened \((p as NSString).lastPathComponent)")
        case "clipSync":
            s.clipSync = (a["on"] as? Bool) ?? true
            RemoteServer.shared.clipboardWatchChanged()
            done(.success(["text": NSPasteboard.general.string(forType: .string) ?? ""]))
        case "pasteOnMac":
            guard let t = a["text"] as? String, !t.isEmpty else { done(.failure(RemoteError(message: "Nothing to paste"))); return true }
            ClipboardStore.shared.copyText(t)
            RemoteServer.shared.noteOwnClipboardChange()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { RemoteInput.handle([["k": "key", "key": "v", "mods": ["cmd"]]]) }
            done(.success([:]))
        default: return false
        }
        return true
    }
}
