import SwiftUI

/// A little ⓘ-style question mark that explains whatever it sits next to, in a sentence or two.
struct HelpTip: View {
    let text: String
    @State private var shown = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "questionmark.circle").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Help")
        .popover(isPresented: $shown) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(idealWidth: 300, maxWidth: 340)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// How to use Triage, in as few words as possible.
struct HowToScreen: View {
    private let topics: [(String, String, [String])] = [
        ("Connect", "link", [
            "At home, Triage finds your Mac on Wi-Fi by itself.",
            "Away, it finds it through your iCloud and connects straight to it. Same Apple ID, no code.",
            "First time on a new phone without iCloud: pair on the same Wi-Fi with the 6-digit code the Mac shows.",
            "On the Mac: Settings › iPhone chooses Off, View only or Full control.",
        ]),
        ("Home", "house", [
            "Your Mac's heart rate, memory, storage and battery at a glance. Tap a tile for more.",
            "An amber “last reading” badge means you're not connected and the numbers are old.",
        ]),
        ("Remote", "display", [
            "Trackpad: one finger moves, tap clicks, two-finger tap right-clicks, two fingers scroll.",
            "Three-finger swipes (or four, in Settings) do Mission Control, App Exposé and Spaces.",
            "Keyboard: the Mac keyboard has the F-row and modifiers. Tap a modifier once for the next key, twice to lock.",
            "Type opens the iPhone keyboard: swipe-typing and autocorrect work, and it appears on the Mac as you go.",
            "⚡ holds shortcuts. Apps opens and switches Mac apps. The paste button pastes your iPhone clipboard on the Mac.",
            "iPhone Duo: half-fold it like a laptop for screen above, keyboard and trackpad below.",
        ]),
        ("Files", "folder", [
            "Browse the Mac's folders. Tap a file to open it; long-press for Share, Open on Mac, Move, Rename, Info and more.",
            "Ask in plain words: “pdfs from last month”, “largest videos”.",
            "Send files and photos to the Mac from the ••• menu.",
        ]),
        ("Tools", "wrench.and.screwdriver", [
            "Everyday: PDF Editor, Converter, Batch Rename, Clipboard, Tidy Downloads, Autopilot, Wi-Fi, Sound.",
            "Make room: Free Up Space, Disk Map, Duplicates, Forgotten Files, App Uninstaller.",
            "Fix a slow Mac: Heart monitor, Apps, Health History, Startup Items, Network, Ports, Drive Health.",
            "Anything that deletes goes to the Mac's Trash first, so it can be undone.",
        ]),
        ("Widgets", "square.grid.2x2", [
            "Long-press the Home Screen › + › Triage. Long-press a widget › Edit to choose what it shows.",
            "Live while Triage is open. When it's closed, iOS refreshes them every 15 minutes or so; tap one to refresh now.",
        ]),
        ("Settings", "gearshape", [
            "Theme: match the Mac or pick your own. Widgets follow it.",
            "Remote: picture quality, pointer speed, gestures and key clicks.",
        ]),
    ]

    var body: some View {
        List {
            ForEach(topics, id: \.0) { t in
                Section {
                    ForEach(t.2, id: \.self) { line in
                        Text(line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                } header: { Label(t.0, systemImage: t.1) }
            }
            Section { Text("Tap any ⓘ-style question mark in the app for a quick explanation of what's next to it.").font(.footnote).foregroundStyle(.secondary) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.glass900)
        .navigationTitle("How to")
    }
}

extension View {
    /// A question mark in the top bar that explains this screen.
    func helpTip(_ text: String) -> some View {
        toolbar { ToolbarItem(placement: .topBarTrailing) { HelpTip(text) } }
    }
}
