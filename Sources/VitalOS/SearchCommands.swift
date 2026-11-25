import Foundation
import AppKit
import CoreAudio

// MARK: - VitalOS actions you can run from search

struct SearchCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: [String]
    let run: () -> Void
}

extension Notification.Name { static let vitalOSGo = Notification.Name("VitalOSGo") }

enum SearchCommands {
    /// Opens the main window on a page: "home", "heart", "apps", "hardware", "files", "utilities", or a ToolID raw value.
    static func go(_ page: String) {
        UserDefaults.standard.set(page, forKey: "pending.route")
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) { w.makeKeyAndOrderFront(nil) }
        NotificationCenter.default.post(name: .vitalOSGo, object: page)
    }

    private static func say(_ s: String) { DispatchQueue.main.async { UndoCenter.shared.show(s) } }

    static func all() -> [SearchCommand] {
        var c: [SearchCommand] = [
            .init(id: "home", title: "Home", subtitle: "Open VitalOS", symbol: "house.fill", keywords: ["home", "vitalos", "open"]) { go("home") },
            .init(id: "heart", title: "Heart", subtitle: "What's slowing your Mac down", symbol: "heart.fill", keywords: ["heart", "slow", "why", "performance", "cpu", "memory", "ram", "activity"]) { go("heart") },
            .init(id: "apps", title: "Apps", subtitle: "Everything running, with quit buttons", symbol: "square.grid.2x2.fill", keywords: ["apps", "running", "processes", "task", "manager"]) { go("apps") },
            .init(id: "hardware", title: "Hardware", subtitle: "Battery, disk, temperature", symbol: "cpu", keywords: ["hardware", "battery", "temperature", "heat", "disk"]) { go("hardware") },
            .init(id: "files", title: "Files", subtitle: "The file manager", symbol: "folder.fill", keywords: ["files", "finder", "folder", "browse"]) { go("files") },
            .init(id: "settings", title: "Settings", subtitle: "Themes, menu bar, readings", symbol: "gearshape.fill", keywords: ["settings", "preferences", "options", "customize"]) {
                NSApp.activate(ignoringOtherApps: true); NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
            .init(id: "restart", title: "Remind me to restart tonight", subtitle: "Clears swap at 10 pm", symbol: "arrow.clockwise.circle.fill", keywords: ["restart", "reboot", "swap", "remind"]) { QuickFix.remindRestartTonight() },
            .init(id: "idle", title: "Quit idle apps", subtitle: "Apps with no windows open give their memory back", symbol: "moon.zzz.fill", keywords: ["quit", "idle", "free", "memory", "ram"]) {
                let idle = QuickFix.idleApps(SystemMonitor.shared.apps)
                idle.forEach { $0.0.terminate() }
                say(idle.isEmpty ? "No idle apps right now" : "Quit \(idle.count) idle app\(idle.count == 1 ? "" : "s")")
            },
            .init(id: "hidden", title: "Show or hide hidden files", subtitle: "Files that start with a dot", symbol: "eye.fill", keywords: ["hidden", "dot", "files", "show"]) {
                let d = UserDefaults.standard; d.set(!d.bool(forKey: "files.hidden"), forKey: "files.hidden"); go("files")
            },
            .init(id: "wifi-on", title: "Turn Wi-Fi on", subtitle: "", symbol: "wifi", keywords: ["wifi", "wi-fi", "on", "internet"]) { WiFiModel.shared.setPower(true); say("Wi-Fi on") },
            .init(id: "wifi-off", title: "Turn Wi-Fi off", subtitle: "", symbol: "wifi.slash", keywords: ["wifi", "wi-fi", "off"]) { WiFiModel.shared.setPower(false); say("Wi-Fi off") },
            .init(id: "bt-on", title: "Turn Bluetooth on", subtitle: "", symbol: "wave.3.right", keywords: ["bluetooth", "on", "airpods"]) { BluetoothModel.shared.setPower(true) },
            .init(id: "bt-off", title: "Turn Bluetooth off", subtitle: "", symbol: "wave.3.right", keywords: ["bluetooth", "off"]) { BluetoothModel.shared.setPower(false) },
            .init(id: "mic", title: "Mute or unmute the microphone", subtitle: "For every app", symbol: "mic.slash.fill", keywords: ["mute", "mic", "microphone", "unmute"]) {
                Mic.setMuted(!Mic.muted); say(Mic.muted ? "Microphone muted" : "Microphone on")
            },
        ]
        for t in ToolID.allCases {
            c.append(.init(id: "tool-" + t.rawValue, title: t.title, subtitle: "VitalOS tool", symbol: "wrench.and.screwdriver.fill",
                           keywords: t.title.lowercased().split(separator: " ").map(String.init) + [t.rawValue]) { go(t.rawValue) })
        }
        for th in AppTheme.all {
            c.append(.init(id: "theme-" + th.id, title: "Switch theme to \(th.name)", subtitle: th.era, symbol: "paintpalette.fill",
                           keywords: ["theme", "look", "appearance", "skin"] + th.name.lowercased().split(separator: " ").map(String.init) + [th.id]) {
                ThemeStore.shared.themeID = th.id
            })
        }
        return c
    }

    /// Commands whose words cover what was typed. "quit chrome" and "volume 30" are built on the fly.
    static func match(_ raw: String) -> [SearchCommand] {
        let q = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let words = q.split(separator: " ").map(String.init)
        var out: [SearchCommand] = []

        // quit <app>
        if let verb = words.first, ["quit", "close", "kill", "force"].contains(verb), words.count >= 2 {
            let name = words.dropFirst().filter { $0 != "quit" }.joined(separator: " ")
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                guard let n = app.localizedName, n.lowercased().contains(name), app.bundleIdentifier != "com.alenlvovich.vitalos" else { continue }
                let force = verb == "force" || verb == "kill"
                out.append(.init(id: "quit-\(app.processIdentifier)", title: "\(force ? "Force quit" : "Quit") \(n)", subtitle: "Running now", symbol: "xmark.circle.fill", keywords: []) {
                    if force { app.forceTerminate() } else { app.terminate() }
                    say("\(force ? "Force quit" : "Quit") \(n)")
                })
            }
        }
        // volume 30
        if words.first == "volume" || words.first == "vol", words.count == 2, let v = Int(words[1]), (0...100).contains(v) {
            out.append(.init(id: "vol", title: "Set volume to \(v)%", subtitle: "Main output", symbol: "speaker.wave.2.fill", keywords: []) {
                CA.setVolume(CA.defaultOutput, Float(v) / 100); say("Volume \(v)%")
            })
        }
        let scored: [(SearchCommand, Int)] = all().compactMap { c in
            let hay = ([c.title.lowercased()] + c.keywords).joined(separator: " ")
            guard words.allSatisfy({ w in hay.split(separator: " ").contains { $0.hasPrefix(w) } }) else { return nil }
            let lead = c.title.lowercased().hasPrefix(q) ? 2 : c.keywords.contains(where: { $0.hasPrefix(words[0]) }) ? 1 : 0
            return (c, lead)
        }
        out += scored.sorted { $0.1 > $1.1 }.map(\.0)
        return Array(out.prefix(5))
    }
}

// MARK: - Currency conversion ("100 usd to eur", "$50 in rubles", "€20")

enum Currency {
    private static let names: [String: String] = [
        "$": "USD", "usd": "USD", "dollar": "USD", "dollars": "USD", "bucks": "USD", "us$": "USD",
        "€": "EUR", "eur": "EUR", "euro": "EUR", "euros": "EUR",
        "£": "GBP", "gbp": "GBP", "pound": "GBP", "pounds": "GBP", "quid": "GBP",
        "¥": "JPY", "jpy": "JPY", "yen": "JPY",
        "₽": "RUB", "rub": "RUB", "ruble": "RUB", "rubles": "RUB", "roubles": "RUB", "рубль": "RUB", "рублей": "RUB", "руб": "RUB",
        "cad": "CAD", "aud": "AUD", "chf": "CHF", "franc": "CHF", "francs": "CHF", "cny": "CNY", "yuan": "CNY", "rmb": "CNY",
        "inr": "INR", "rupee": "INR", "rupees": "INR", "mxn": "MXN", "peso": "MXN", "pesos": "MXN", "ils": "ILS", "shekel": "ILS", "shekels": "ILS",
        "uah": "UAH", "hryvnia": "UAH", "krw": "KRW", "won": "KRW", "brl": "BRL", "real": "BRL", "try": "TRY", "lira": "TRY",
        "sek": "SEK", "nok": "NOK", "dkk": "DKK", "pln": "PLN", "zloty": "PLN", "hkd": "HKD", "sgd": "SGD", "nzd": "NZD", "kzt": "KZT", "gel": "GEL", "aed": "AED",
    ]
    private static let d = UserDefaults.standard
    private static var fetching = false

    struct Request { let amount: Double; let from: String; let to: String }

    static func parse(_ raw: String) -> Request? {
        let s = raw.lowercased().replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let pattern = #"^([$€£¥₽]|us\$)?\s*(\d+(?:\.\d+)?)\s*([a-zа-я$€£¥₽]+)?\s*(?:to|in|into|as|=|->|→|в)?\s*([a-zа-я$€£¥₽]+)?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func g(_ i: Int) -> String? { Range(m.range(at: i), in: s).map { String(s[$0]) } }
        guard let amount = g(2).flatMap(Double.init) else { return nil }
        let from = g(1).flatMap { names[$0] } ?? g(3).flatMap { names[$0] }
        guard let from else { return nil }
        let toWord = g(1) != nil ? (g(4) ?? g(3)) : g(4)
        let to = toWord.flatMap { names[$0] } ?? (from == "USD" ? "EUR" : "USD")
        guard to != from else { return nil }
        return Request(amount: amount, from: from, to: to)
    }

    private static var rates: [String: Double]? { d.dictionary(forKey: "fx.rates") as? [String: Double] }
    private static var age: TimeInterval { Date().timeIntervalSince1970 - d.double(forKey: "fx.time") }

    /// Result text and a caption, or nil when rates aren't here yet (then `then` runs once they arrive).
    static func convert(_ r: Request, then: @escaping () -> Void) -> (text: String, caption: String)? {
        if rates == nil || age > 6 * 3600 { refresh(then) }
        guard let rates, let a = rates[r.from], let b = rates[r.to], a > 0 else { return nil }
        let rate = b / a, value = r.amount * rate
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = r.to
        f.maximumFractionDigits = value < 1 ? 4 : 2
        let text = f.string(from: NSNumber(value: value)) ?? String(format: "%.2f %@", value, r.to)
        let mins = Int(age / 60)
        let when = mins < 2 ? "just now" : mins < 120 ? "\(mins) min ago" : "\(mins / 60) h ago"
        return (text, String(format: "%@ %@ → %@ · 1 %@ = %.4f %@ · rates %@", Calc.format(r.amount), r.from, r.to, r.from, rate, r.to, when))
    }

    private static func refresh(_ then: @escaping () -> Void) {
        guard !fetching, let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return }
        fetching = true
        URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { fetching = false }
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r = j["rates"] as? [String: Double] else { return }
            d.set(r, forKey: "fx.rates"); d.set(Date().timeIntervalSince1970, forKey: "fx.time")
            DispatchQueue.main.async(execute: then)
        }.resume()
    }
}
