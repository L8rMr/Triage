import SwiftUI
import AppKit

// MARK: - Tour steps

struct TourStep {
    let route: Route
    let symbol: String
    let title: String
    let body: String
    var tip: String? = nil
    var action: ((AppModel) -> Void)? = nil
}

enum TourKind { case quick, deep }

enum TourScript {
    static func steps(_ kind: TourKind) -> [TourStep] {
        kind == .quick ? quick : deep
    }

    static let quick: [TourStep] = [
        TourStep(route: .home, symbol: "heart.text.square.fill", title: "Welcome to VitalOS",
                 body: "An activity monitor and a file manager in one window. Your Mac gets a pulse, and your files get a smarter home.",
                 tip: "This takes about two minutes. Use the arrows or press Skip anytime."),
        TourStep(route: .heart, symbol: "waveform.path.ecg", title: "Your Mac's heartbeat",
                 body: "One heart rate built from processor, memory, heat, disk and battery. Calm Mac, slow beat. Strained Mac, fast beat and a diagnosis.",
                 tip: "Click any channel to see exactly what's behind it."),
        TourStep(route: .apps, symbol: "square.grid.2x2", title: "Apps, not processes",
                 body: "Every helper is counted under the app that owns it, so Chrome's 30 helpers show up as one Chrome.",
                 tip: "Hover a row and click × to quit that app."),
        TourStep(route: .files, symbol: "folder", title: "Files, with superpowers",
                 body: "Glass folder cards, real previews, sorting, filters and smart grouping by kind, date or size.",
                 tip: "⌘D splits into two panes. Space previews the selected file."),
        TourStep(route: .search, symbol: "sparkle.magnifyingglass", title: "Search the way you talk",
                 body: "The search field sits at the top of the sidebar (⌘K). Try \u{201C}pdfs from last week\u{201D}. It also does math, converts money (\u{201C}100 usd to eur\u{201D}) and runs VitalOS actions (\u{201C}quit chrome\u{201D}, \u{201C}wifi off\u{201D}).",
                 tip: "⌥Space opens the same search from any app.",
                 action: { $0.search.text = "pdfs from last week" }),
        TourStep(route: .clean, symbol: "externaldrive.badge.minus", title: "Free up space safely",
                 body: "Suggestions split into Safe to clear and Your call. Everything goes to the Trash first, with Undo.",
                 action: { $0.search.text = "" }),
        TourStep(route: .utilities, symbol: "square.grid.2x2", title: "Utilities",
                 body: "15 tools in one place: Clipboard, PDF Editor, Converter, Disk Map, Duplicates, App Uninstaller, Dev Servers & Ports, Health History and more.",
                 tip: "Star a tool to keep it in the sidebar. ⌘⇧2 grabs text from anywhere on screen."),
        TourStep(route: .home, symbol: "menubar.rectangle", title: "The menu bar panel",
                 body: "Click VitalOS in the menu bar: Vitals with one-tap fixes, Connectivity for Wi-Fi and Bluetooth batteries, and Sound with a volume for every app and a mic mute.",
                 tip: "The slider button in the panel picks which numbers sit in the menu bar."),
        TourStep(route: .home, symbol: "paintpalette", title: "Make it yours",
                 body: "Settings › Appearance has 10 themes, from Windows 95 and Aqua to a green CRT terminal, plus accent color, text size and a Touch layout.",
                 tip: "Press ⌘, any time. Type \u{201C}theme xp\u{201D} in search to switch instantly."),
        TourStep(route: .home, symbol: "questionmark.circle", title: "You're all set",
                 body: "Back and forward work like a browser: the arrows by the ?, your mouse's side buttons, a three-finger swipe, or ⌘[ and ⌘]. The ♥ in the menu bar shows your Mac's pulse.",
                 tip: "The ? in the corner lists everything and replays either tour."),
    ]

    static let deep: [TourStep] = [
        TourStep(route: .home, symbol: "heart.text.square.fill", title: "The in-depth tour",
                 body: "Every feature, one page at a time, about eight minutes. Each step opens the page it's talking about so you can poke around."),
        TourStep(route: .home, symbol: "sparkles", title: "Home",
                 body: "The greeting reads your Mac's heart. Below: search, a world clock, live vitals, disk space, the busiest apps, your Downloads inbox, pinned folders and recent files.",
                 tip: "Click a widget to jump to its page."),
        TourStep(route: .home, symbol: "waveform.path.ecg.rectangle", title: "The sidebar pulse",
                 body: "The line at the top of the sidebar beats at your Mac's heart rate and changes color: green is calm, orange is busy, red is strained.",
                 tip: "Click it to open the Heart monitor."),
        TourStep(route: .heart, symbol: "waveform.path.ecg", title: "Heart: one number for everything",
                 body: "The worst vital sets most of the pace (65%); the rest nudge it. 54 bpm is resting, 180 is maxed out. Health is 100 minus stress.",
                 tip: "The diagnosis line names what's wrong in plain English."),
        TourStep(route: .heart, symbol: "stethoscope", title: "Five channels",
                 body: "HR is the processor, BP is memory pressure, TEMP is heat, SpO₂ is disk space and PWR is battery. Each has a 90-second chart and its biggest user.",
                 tip: "Click a channel for the full breakdown and how it's scored."),
        TourStep(route: .heart, symbol: "cross.case", title: "Suggestions when it's strained",
                 body: "When the heart rate climbs, VitalOS lists specific fixes: quit the hungriest app, close heavy browser tabs, restart to clear swap, let it cool, free disk space."),
        TourStep(route: .apps, symbol: "square.grid.2x2", title: "Apps",
                 body: "60 apps instead of 1,000 processes. Sort by CPU or memory, filter by name, click a row to see its processes, hover to quit.",
                 tip: "Click the CPU or Memory card for a ranked breakdown."),
        TourStep(route: .hardware, symbol: "cpu", title: "Hardware",
                 body: "Chip, memory split into app, wired and compressed, network up and down, battery cycles and health, thermal state, disk and uptime.",
                 tip: "Every card is clickable."),
        TourStep(route: .files, symbol: "folder", title: "The file browser",
                 body: "Back, forward and up, a clickable path bar, and the git branch shown automatically inside code projects.",
                 tip: "Double-click to open. Drag files onto a pane to move them."),
        TourStep(route: .files, symbol: "line.3.horizontal.decrease", title: "Filter, sort and group",
                 body: "Every column has its own filter: click the funnel next to Name, Kind, Size, Modified or Delete? and tick as many options as you like. Click a column title to sort. In grid view the same filters sit above the files as pills. Tidy Downloads, Apps and the utilities work the same way.",
                 tip: "⇧⌘. shows hidden files."),
        TourStep(route: .files, symbol: "rectangle.split.2x1", title: "Dual pane",
                 body: "Two folders side by side. Select files and press F5 to copy or F6 to move to the other pane. Name clashes are renamed automatically.",
                 tip: "⌘D toggles it. Try it now.",
                 action: { m in if m.panes.count == 1 { m.toggleSplit() } }),
        TourStep(route: .files, symbol: "eye", title: "Peek, Terminal and more",
                 body: "Space previews a file. Right-click for Reveal in Finder, Open in Terminal, Copy Path, or move to the other pane. ⌘⌫ sends to the Trash with Undo.",
                 action: { m in if m.panes.count > 1 { m.toggleSplit() } }),
        TourStep(route: .files, symbol: "plus.rectangle.on.folder", title: "Add folders and cloud drives",
                 body: "Add Folder at the bottom of the Files list pins any folder, plus iCloud Drive, Google Drive, Dropbox, OneDrive, Box, iDrive and external disks.",
                 tip: "Right-click a pinned folder to remove it."),
        TourStep(route: .files, symbol: "checkmark.shield", title: "Can I delete this?",
                 body: "Select any file and the panel on the right tells you whether it's safe to delete and why: who uses it, when you last opened it, whether it's in git or the cloud, or an app's leftovers.",
                 tip: "Risky deletes stop and show you the reasons first. List view has a Delete? column you can filter."),
        TourStep(route: .search, symbol: "sparkle.magnifyingglass", title: "Smart Search",
                 body: "Search your whole Mac in plain English. VitalOS understands kinds (pdfs, screenshots, apps), dates (today, last week, in March, in 2025), sizes (big, over 500mb) and places (in downloads).",
                 tip: "The green chips show what it understood.",
                 action: { $0.search.text = "screenshots this week" }),
        TourStep(route: .search, symbol: "link", title: "Where a file came from",
                 body: "Add \u{201C}from\u{201D} and a site to find downloads by source: \u{201C}from github\u{201D}, \u{201C}invoice from mail.google.com\u{201D}. Quotes match an exact phrase inside documents.",
                 action: { $0.search.text = "from github" }),
        TourStep(route: .search, symbol: "keyboard", title: "Search shortcuts",
                 body: "↑↓ to move, Return to open, ⌘Return to show in Finder, ⌘Y for Quick Look, ⇧⌘C to copy the path. Math works too: try 1200*12.",
                 action: { $0.search.text = "1200*12*0.0725" }),
        TourStep(route: .search, symbol: "dollarsign.arrow.circlepath", title: "Math and money",
                 body: "Type math like 1200*12*0.0725, or money like \u{201C}100 usd to eur\u{201D}, \u{201C}$50 in rubles\u{201D} or \u{201C}€20\u{201D}. About 30 currencies, live rates refreshed every 6 hours. Return copies the answer.",
                 action: { $0.search.text = "100 usd to eur" }),
        TourStep(route: .search, symbol: "bolt.circle", title: "Actions from search",
                 body: "VitalOS actions show up above your files: open any page or tool, \u{201C}quit chrome\u{201D}, \u{201C}volume 30\u{201D}, \u{201C}wifi off\u{201D}, \u{201C}mute mic\u{201D}, \u{201C}theme braun\u{201D}, quit idle apps or set a restart reminder.",
                 tip: "Press Return on an action to do it.",
                 action: { $0.search.text = "quit" }),
        TourStep(route: .search, symbol: "command", title: "⌥Space from anywhere",
                 body: "The same search floats over any app, Spotlight-style, with a live preview pane. ⌥Return opens the result right here in VitalOS.",
                 action: { $0.search.text = "" }),
        TourStep(route: .clean, symbol: "externaldrive.badge.minus", title: "Free Up Space",
                 body: "Ten suggestions: Xcode and simulator caches, npm, pip and Homebrew downloads, logs, old and huge downloads, archives and the Trash. Safe items clear in one click.",
                 tip: "Every clear can be undone from the toast."),
        TourStep(route: .tidy, symbol: "tray.and.arrow.down", title: "Tidy Downloads",
                 body: "Loose files sorted into folders by kind, biggest first, with sizes. It flags installers you already have, likely duplicates and files older than 90 days.",
                 tip: "Untick anything you want left where it is."),
        TourStep(route: .utilities, symbol: "square.grid.2x2", title: "All Utilities",
                 body: "Every tool lives on this page, grouped into Storage, Files & documents, and Apps & system. Star the ones you use most to pin them in the sidebar; the rest stay behind Show more."),
        TourStep(route: .tool(.clipboard), symbol: "doc.on.clipboard", title: "Clipboard",
                 body: "Everything you copy is kept, searchable and filterable. Press ⌘⇧2 anywhere and drag over text in a video, image, PDF or screen share to copy it. QR codes work too.",
                 tip: "⌥⇧V opens your history over any app and pastes the one you pick."),
        TourStep(route: .tool(.pdf), symbol: "doc.richtext", title: "PDF Editor",
                 body: "Acrobat-style: Edit Text outlines every paragraph. Click one to type over it in a matched font, even on scans, and restyle it live from the Format panel. Plus images, watermarks, page numbers, comments, signing, redaction, crop, passwords and compression.",
                 tip: "Recognize Text turns scans into searchable, editable text."),
        TourStep(route: .tool(.converter), symbol: "arrow.triangle.2.circlepath", title: "Converter",
                 body: "Drop images, PDFs, documents, audio, video or CSV/JSON and choose what they should become: HEIC to JPG, PDF to Word, Word to PDF, video to GIF, and more. Batch Rename sits next to it."),
        TourStep(route: .tool(.diskmap), symbol: "square.grid.3x3.square", title: "Disk Map",
                 body: "A map of what's using your disk. Bigger tiles use more space. Click a folder to zoom in; right-click to open, reveal or trash."),
        TourStep(route: .tool(.diskhealth), symbol: "stethoscope", title: "Drive Health",
                 body: "Each drive's SMART status, SSD wear, hours in use, data written, temperature and errors, plus purgeable space, Time Machine snapshots and a read-only First Aid check.",
                 tip: "Install the free sensor package from here for the full wear readout."),
        TourStep(route: .tool(.duplicates), symbol: "doc.on.doc", title: "Duplicates & Forgotten Files",
                 body: "Duplicate Finder compares file contents, not names, and always keeps one copy. Forgotten Files lists big files you haven't opened in months."),
        TourStep(route: .tool(.uninstaller), symbol: "trash.square", title: "App Uninstaller",
                 body: "Removes an app together with its settings, caches and containers. Filter by Last opened to find apps you've forgotten."),
        TourStep(route: .tool(.ports), symbol: "server.rack", title: "Dev Servers & Ports",
                 body: "Everything listening on a port, which ones your network can reach, and your Docker containers. Open, stop or restart in one click.",
                 tip: "Network by App and Startup Items live next to it."),
        TourStep(route: .tool(.history), symbol: "chart.xyaxis.line", title: "Health History",
                 body: "Your Mac's heart rate over hours or days, a report card, every spike with the app behind it, and an alert if it stays strained."),
        TourStep(route: .tool(.wifi), symbol: "wifi", title: "Wi-Fi",
                 body: "Your network, signal and speed, plus every network nearby. Tap one to join. Also in the menu bar panel's Connectivity tab, next to your Bluetooth devices.",
                 tip: "macOS needs Location access to show network names."),
        TourStep(route: .tool(.sound), symbol: "slider.vertical.3", title: "Sound Mixer",
                 body: "A volume slider for every app making sound, like Spotify or Firefox, plus the output device and master volume. Also in the menu bar panel."),
        TourStep(route: .home, symbol: "menubar.rectangle", title: "The menu bar panel",
                 body: "Vitals: the heart line, four readouts, the 3 busiest apps with a quit button, and three labeled fixes: quit idle apps (frees memory), restart tonight (resets swap) and clear caches (frees disk). Connectivity: Wi-Fi, a speed test, Copy IP, and Bluetooth devices with battery levels; click one to connect. Sound: a volume for every app plus a mic mute for all apps.",
                 tip: "Fixes that clear files move them to the Trash, so you can undo."),
        TourStep(route: .tool(.autopilot), symbol: "wand.and.stars", title: "Folder Autopilot",
                 body: "Rules that tidy folders on their own every 15 minutes, like moving old screenshots off the Desktop. Start from a template."),
        TourStep(route: .home, symbol: "arrow.left.arrow.right", title: "Back and forward",
                 body: "VitalOS remembers where you've been, pages and folders alike. Go back with the arrows by the ?, your mouse's side buttons, a three-finger swipe, or ⌘[ and ⌘]."),
        TourStep(route: .home, symbol: "menubar.rectangle", title: "Menu bar",
                 body: "The ♥ shows your Mac's heart rate. Click the slider button in the panel, or go to Settings › Menu Bar, to pick what sits up top: bpm, CPU, memory, download speed, disk, heat, battery, Wi-Fi, volume, headphone battery or mouse battery.",
                 tip: "Closing the window keeps VitalOS running up there."),
        TourStep(route: .home, symbol: "paintpalette", title: "Themes",
                 body: "Settings › Appearance: VitalOS, Apple Pro, Aqua, Windows 95, Windows XP, Windows 11, Macintosh, Linux, Braun and Phosphor. Each changes colors, type, cards, buttons and the window frame.",
                 tip: "Turn off Theme window frames to keep the usual macOS buttons.",
                 action: { _ in NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }),
        TourStep(route: .home, symbol: "slider.horizontal.3", title: "Settings",
                 body: "Accent color, Auto/Light/Dark, Compact/Comfortable/Touch, text size and Reduce motion live in Appearance. Heart & Readings sets how often VitalOS checks your Mac. Files, Menu Bar, Privacy, Shortcuts and Advanced are there too.",
                 tip: "⌘, opens Settings from anywhere in VitalOS."),
        TourStep(route: .heart, symbol: "leaf", title: "Light on your Mac",
                 body: "VitalOS slows its readings to every 5 seconds when no window is showing and stops the heart line when nobody can see it. Settings › Advanced shows how much memory VitalOS itself is using."),
        TourStep(route: .home, symbol: "questionmark.circle", title: "That's everything",
                 body: "The ? in the top-right corner lists every feature and shortcut, with a Show me button for each. You can replay either tour from there."),
    ]
}

// MARK: - Overlay card

struct TourOverlay: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.tourActive, model.tourSteps.indices.contains(model.tourIndex) {
            let step = model.tourSteps[model.tourIndex]
            let last = model.tourIndex == model.tourSteps.count - 1
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: step.symbol)
                        .font(.ui(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                        .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(model.tourIndex + 1) of \(model.tourSteps.count)")
                            .font(.ui(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                        Text(step.title).font(.ui(size: 16, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    Button { model.endTour() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("End tour")
                }
                Text(step.body).font(.ui(size: 13)).fixedSize(horizontal: false, vertical: true)
                if let tip = step.tip {
                    Label(tip, systemImage: "lightbulb").font(.ui(size: 12)).foregroundStyle(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    ForEach(model.tourSteps.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == model.tourIndex ? Theme.accent : Color.primary.opacity(i < model.tourIndex ? 0.35 : 0.12))
                            .frame(width: i == model.tourIndex ? 16 : 6, height: 6)
                    }
                    Spacer()
                    Button("Skip") { model.endTour() }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    Button("Back") { model.tourStep(-1) }.disabled(model.tourIndex == 0)
                    Button(last ? "Done" : "Next") { last ? model.endTour() : model.tourStep(1) }
                        .buttonStyle(.borderedProminent).tint(Theme.accent.opacity(0.85))
                }
                .controlSize(.small)
            }
            .padding(18)
            .frame(width: 500)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
            .padding(.bottom, 26)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(model.tourIndex)
        }
    }
}

// MARK: - Help center (the ? button)

struct HelpItem: Identifiable {
    let section: String
    let symbol: String
    let title: String
    let detail: String
    var keys: String? = nil
    var route: Route? = nil
    var id: String { section + title }
}

enum HelpCatalog {
    static let items: [HelpItem] = [
        HelpItem(section: "Heart", symbol: "waveform.path.ecg", title: "Heart rate & health score",
                 detail: "One bpm from processor, memory, heat, disk and battery. Health is 100 minus stress.", keys: "⌘0", route: .heart),
        HelpItem(section: "Heart", symbol: "stethoscope", title: "What's behind each vital",
                 detail: "Click a channel on Heart or a card on Hardware or Apps for its breakdown and scoring.", route: .heart),
        HelpItem(section: "Heart", symbol: "cross.case", title: "Suggestions",
                 detail: "When it's working hard, VitalOS lists the fixes that would help most, with buttons.", route: .heart),
        HelpItem(section: "Heart", symbol: "waveform.path.ecg.rectangle", title: "Sidebar pulse",
                 detail: "Beats at your Mac's heart rate. Green calm, orange busy, red strained. Click it for Heart."),
        HelpItem(section: "Vitals", symbol: "square.grid.2x2", title: "Apps",
                 detail: "Helpers grouped under their app. Sort by CPU or memory, expand for processes, hover to quit.", keys: "⌘2", route: .apps),
        HelpItem(section: "Vitals", symbol: "cpu", title: "Hardware",
                 detail: "Chip, memory breakdown, network, battery cycles and health, thermal state, disk, uptime.", keys: "⌘3", route: .hardware),
        HelpItem(section: "Menu bar", symbol: "menubar.rectangle", title: "Menu bar monitor",
                 detail: "♥ and live numbers in the menu bar. Click for the panel: Vitals, Connectivity and Sound."),
        HelpItem(section: "Menu bar", symbol: "bolt.heart", title: "Quick fixes",
                 detail: "Quit idle apps (frees memory), Restart tonight (a 10 pm reminder that resets swap), Clear caches (frees disk; goes to the Trash so you can undo)."),
        HelpItem(section: "Menu bar", symbol: "xmark.circle", title: "Busiest apps",
                 detail: "The 3 apps working hardest, with CPU, memory and a quit button."),
        HelpItem(section: "Menu bar", symbol: "wifi", title: "Connectivity",
                 detail: "Wi-Fi on/off, speed test, Copy IP, other networks, and Bluetooth on/off with each device's battery (each AirPod and the case). Click a device to connect or disconnect."),
        HelpItem(section: "Menu bar", symbol: "mic.slash", title: "Sound and mic mute",
                 detail: "A volume slider for every app, the output device, and one switch that mutes the microphone for every app."),
        HelpItem(section: "Menu bar", symbol: "slider.horizontal.3", title: "Choose what shows up top",
                 detail: "The slider button in the panel or Settings › Menu Bar: bpm, CPU, memory, download speed, disk, heat, battery, Wi-Fi, volume, headphone battery, mouse battery.", keys: "⌘,"),
        HelpItem(section: "Search", symbol: "sparkle.magnifyingglass", title: "Search in the window",
                 detail: "The field at the top of the sidebar. Results appear on the Search page.", keys: "⌘K", route: .search),
        HelpItem(section: "Search", symbol: "command", title: "Search from any app",
                 detail: "A floating search over whatever you're doing, with a preview pane.", keys: "⌥Space"),
        HelpItem(section: "Search", symbol: "text.bubble", title: "Plain-English queries",
                 detail: "Kinds (pdfs, screenshots, apps), dates (today, last week, in March), sizes (big, over 500mb), places (in downloads), sources (from github), \"exact phrases\".", route: .search),
        HelpItem(section: "Search", symbol: "equal.circle", title: "Calculator",
                 detail: "Type math like 1200*12*0.0725. Return copies the answer."),
        HelpItem(section: "Search", symbol: "dollarsign.arrow.circlepath", title: "Currency converter",
                 detail: "100 usd to eur · $50 in rubles · €20 · 5000 yen. About 30 currencies with live rates, refreshed every 6 hours. Return copies the answer."),
        HelpItem(section: "Search", symbol: "bolt.circle", title: "Actions",
                 detail: "Run VitalOS from search: open any page or tool, quit chrome, force quit zoom, volume 30, wifi on/off, bluetooth on/off, mute mic, theme xp, quit idle apps, restart reminder, show hidden files."),
        HelpItem(section: "Search", symbol: "keyboard", title: "Result shortcuts",
                 detail: "Return open · ⌘Return show in Finder · ⌥Return open in VitalOS · ⌘Y Quick Look · ⇧⌘C copy path."),
        HelpItem(section: "Files", symbol: "folder", title: "Browse files",
                 detail: "Glass folder cards with item counts, real thumbnails, grid or list, git branch in code folders.", keys: "⌘4", route: .files),
        HelpItem(section: "Files", symbol: "line.3.horizontal.decrease", title: "Filter",
                 detail: "Click the funnel in any column and tick as many options as you like. Same filters in Files, Tidy Downloads and Apps.", route: .files),
        HelpItem(section: "Files", symbol: "arrow.up.arrow.down", title: "Sort and group",
                 detail: "Click column headers or use the Sort menu. Group the grid by kind, date or size.", route: .files),
        HelpItem(section: "Files", symbol: "rectangle.split.2x1", title: "Dual pane",
                 detail: "Two folders side by side. F5 copies, F6 moves to the other pane.", keys: "⌘D", route: .files),
        HelpItem(section: "Files", symbol: "plus.rectangle.on.folder", title: "Add folders & cloud drives",
                 detail: "Add Folder in the sidebar pins any folder, plus iCloud Drive, Google Drive, Dropbox, OneDrive, Box, iDrive and external disks."),
        HelpItem(section: "Files", symbol: "eye", title: "Peek", detail: "Preview the selected file.", keys: "Space", route: .files),
        HelpItem(section: "Files", symbol: "terminal", title: "Open in Terminal", detail: "Opens the current folder in Terminal.", keys: "⌥⇧⌘T"),
        HelpItem(section: "Files", symbol: "eye.slash", title: "Hidden files", detail: "Show or hide dotfiles.", keys: "⇧⌘."),
        HelpItem(section: "Files", symbol: "trash", title: "Trash with Undo", detail: "Every move to the Trash shows an Undo toast.", keys: "⌘⌫"),
        HelpItem(section: "Utilities", symbol: "externaldrive.badge.minus", title: "Free Up Space",
                 detail: "Ten cleanup suggestions, split into Safe to clear and Your call. Everything can be undone.", keys: "⌘5", route: .clean),
        HelpItem(section: "Utilities", symbol: "tray.and.arrow.down", title: "Tidy Downloads",
                 detail: "Sorts loose downloads by kind with sizes. Flags installers you already have, duplicates and old files.", keys: "⌘6", route: .tidy),
        HelpItem(section: "Files", symbol: "checkmark.shield", title: "Can I delete this?",
                 detail: "The info panel and the Delete? column say whether something is safe to delete and why. Risky deletes ask first.", keys: "⌥⌘I", route: .files),
        HelpItem(section: "Utilities", symbol: "square.grid.2x2", title: "All Utilities",
                 detail: "Every tool on one page. Star tools to pin them in the sidebar.", keys: "⌘5", route: .utilities),
    ] + ToolID.allCases.filter { $0 != .clean && $0 != .tidy }.map { t in
        HelpItem(section: "Utilities", symbol: t.symbol, title: t.title, detail: t.blurb,
                 keys: t == .clipboard ? "⌘⇧2 · ⌥⇧V" : nil, route: t.route)
    } + [
        HelpItem(section: "Appearance", symbol: "paintpalette", title: "Themes",
                 detail: "10 looks in Settings › Appearance: VitalOS, Apple Pro, Aqua, Windows 95, Windows XP, Windows 11, Macintosh, Linux, Braun and Phosphor.", keys: "⌘,"),
        HelpItem(section: "Appearance", symbol: "circle.lefthalf.filled", title: "Mode and accent color",
                 detail: "Auto, Light or Dark for themes that support both, and an accent color that overrides the theme's own."),
        HelpItem(section: "Appearance", symbol: "hand.tap", title: "Density and text size",
                 detail: "Compact, Comfortable or Touch (bigger controls), and text from 85% to 130%."),
        HelpItem(section: "Appearance", symbol: "macwindow", title: "Theme window frames",
                 detail: "Retro and Windows themes draw their own title bar and window buttons. Turn it off to keep the macOS ones."),
        HelpItem(section: "Appearance", symbol: "figure.walk.motion", title: "Reduce motion",
                 detail: "Stops the moving heart line and the CRT glow."),
        HelpItem(section: "Settings", symbol: "gearshape", title: "All settings",
                 detail: "Appearance, General (open at login), Menu Bar, Heart & Readings, Files, Privacy & Permissions, Shortcuts and Advanced.", keys: "⌘,"),
        HelpItem(section: "Settings", symbol: "speedometer", title: "How often VitalOS checks",
                 detail: "Settings › Heart & Readings: every 1, 1.5 or 3 seconds with a window open, and 5, 15 or 60 seconds in the background."),
        HelpItem(section: "Settings", symbol: "leaf", title: "VitalOS's own usage",
                 detail: "Settings › Advanced shows VitalOS's memory use. The usage log writes its CPU and memory to a file once a minute."),
        HelpItem(section: "Getting around", symbol: "arrow.left.arrow.right", title: "Back and forward",
                 detail: "Like a browser: the arrows by the ?, mouse side buttons, three-finger swipe.", keys: "⌘[  ⌘]"),
        HelpItem(section: "Getting around", symbol: "sidebar.left", title: "Sidebar",
                 detail: "Search at the top, then Vitals, Files with your added folders, and your starred Utilities."),
        HelpItem(section: "Getting around", symbol: "questionmark.circle", title: "This help and the tours",
                 detail: "The ? in the top-right corner, or the Help menu.", keys: "⇧⌘/"),
    ]
}

struct HelpCenter: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [HelpItem] {
        query.isEmpty ? HelpCatalog.items : HelpCatalog.items.filter {
            ($0.title + " " + $0.detail + " " + $0.section + " " + ($0.keys ?? "")).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Everything VitalOS can do").font(.ui(size: 22, weight: .bold, design: .rounded))
                    Text("Take a tour, or find a feature and jump straight to it.").font(.ui(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.ui(size: 18)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 12) {
                tourButton(.quick, "Quick tour", "\(TourScript.quick.count) stops · about two minutes", "hare")
                tourButton(.deep, "In-depth tour", "\(TourScript.deep.count) stops · about eight minutes", "tortoise")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a feature or shortcut", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    let sections = ["Heart", "Vitals", "Menu bar", "Search", "Files", "Utilities", "Appearance", "Settings", "Getting around"]
                    ForEach(sections, id: \.self) { sec in
                        let items = filtered.filter { $0.section == sec }
                        if !items.isEmpty {
                            Text(sec.uppercased()).font(.ui(size: 10, weight: .semibold)).kerning(0.8)
                                .foregroundStyle(.secondary).padding(.top, 10)
                            ForEach(items) { item in row(item) }
                        }
                    }
                    if filtered.isEmpty {
                        Text("Nothing matches \u{201C}\(query)\u{201D}.").font(.ui(size: 12)).foregroundStyle(.secondary).padding(.top, 20)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 680, height: 640)
        .background(Theme.bg)
    }

    private func tourButton(_ kind: TourKind, _ title: String, _ sub: String, _ symbol: String) -> some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.startTour(kind) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.ui(size: 22)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(size: 14, weight: .semibold))
                    Text(sub).font(.ui(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "play.circle.fill").font(.ui(size: 20)).foregroundStyle(Theme.accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .glass(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ item: HelpItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol).font(.ui(size: 15)).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.ui(size: 13, weight: .semibold))
                Text(item.detail).font(.ui(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let k = item.keys {
                Text(k).font(.ui(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }
            if let r = item.route {
                Button("Show me") { model.route = r; dismiss() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .glass(10)
    }
}

struct HelpButton: View {
    @EnvironmentObject var model: AppModel
    @State private var hover = false

    var body: some View {
        Button { model.showHelp = true } label: {
            Image(systemName: "questionmark")
                .font(.ui(size: 12, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(hover ? Theme.accent.opacity(0.25) : Color.primary.opacity(0.08)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                .foregroundStyle(hover ? Theme.accent : Color.secondary)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("How to use VitalOS (⌘?)")
    }
}
