import AppKit

/// macOS only gives some permissions (Location above all) to real .app bundles.
/// When VitalOS is launched as a bare binary (from Xcode or `swift run`), it wraps itself
/// into ~/Applications/VitalOS.app, launches that, and quits. Set VITALOS_NO_BUNDLE=1 to skip.
enum AppBundler {
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Returns true when it handed off to the bundled copy and this process should exit.
    static func relaunchAsBundleIfNeeded() -> Bool {
        guard !isBundled, ProcessInfo.processInfo.environment["VITALOS_NO_BUNDLE"] == nil,
              let exe = Bundle.main.executableURL else { return false }
        let fm = FileManager.default
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = project.appendingPathComponent("Resources/Info.plist")
        let iconPNG = project.appendingPathComponent("Resources/AppIcon-1024.png")
        guard fm.fileExists(atPath: plist.path) else { return false }

        let apps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let app = apps.appendingPathComponent("VitalOS.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        do {
            try fm.createDirectory(at: macos, withIntermediateDirectories: true)
            try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let dest = macos.appendingPathComponent("VitalOS")
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: exe, to: dest)
            let destPlist = app.appendingPathComponent("Contents/Info.plist")
            if fm.fileExists(atPath: destPlist.path) { try fm.removeItem(at: destPlist) }
            try fm.copyItem(at: plist, to: destPlist)
            // theme fonts (all open-licensed) ride along in Contents/Resources/Fonts
            let fonts = project.appendingPathComponent("Resources/Fonts")
            let destFonts = app.appendingPathComponent("Contents/Resources/Fonts")
            if fm.fileExists(atPath: fonts.path) {
                if fm.fileExists(atPath: destFonts.path) { try fm.removeItem(at: destFonts) }
                try fm.copyItem(at: fonts, to: destFonts)
            }
        } catch {
            NSLog("VitalOS bundling failed: \(error)")
            return false
        }
        // A real certificate keeps permissions between builds; ad-hoc ("-") makes macOS forget them every time.
        let identity = pickSigningIdentity()
        UserDefaults.standard.set(identity, forKey: "signing.identity")
        Shell.run("/usr/bin/codesign", ["--force", "--deep", "--sign", identity, "--identifier", "com.alenlvovich.vitalos", app.path], timeout: 30)
        if let img = NSImage(contentsOf: iconPNG) { NSWorkspace.shared.setIcon(img, forFile: app.path, options: []) }

        // Quit any older copy that's still running, then open the fresh one.
        let me = ProcessInfo.processInfo.processIdentifier
        let old = NSRunningApplication.runningApplications(withBundleIdentifier: "com.alenlvovich.vitalos").filter { $0.processIdentifier != me }
        old.forEach { $0.terminate() }
        // give them a moment to quit politely, then make sure: two copies would mean two menu bar icons
        for _ in 0..<20 where old.contains(where: { !$0.isTerminated }) { Thread.sleep(forTimeInterval: 0.1) }
        old.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        Thread.sleep(forTimeInterval: 0.3)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.createsNewApplicationInstance = true
        cfg.arguments = Array(CommandLine.arguments.dropFirst())
        let done = DispatchSemaphore(value: 0)
        var ok = false
        NSWorkspace.shared.openApplication(at: app, configuration: cfg) { running, err in
            ok = running != nil && err == nil
            if let err { NSLog("VitalOS relaunch failed: \(err)") }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return ok
    }

    /// What this copy was signed with: a certificate name, or "-" for ad-hoc.
    static var signingIdentity: String { UserDefaults.standard.string(forKey: "signing.identity") ?? "-" }

    /// First Apple Development / Developer ID certificate in the keychain, else ad-hoc.
    static func pickSigningIdentity() -> String {
        let out = Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], timeout: 10)
        let names: [String] = out.split(separator: "\n").compactMap { line in
            guard let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b else { return nil }
            return String(line[line.index(after: a)..<b])
        }
        return names.first { $0.hasPrefix("Apple Development") } ?? names.first { $0.hasPrefix("Developer ID Application") } ?? names.first ?? "-"
    }

}
