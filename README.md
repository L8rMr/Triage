# Triage

An activity monitor and a file manager in one native SwiftUI Mac app. Your Mac gets a heartbeat: one heart rate built from processor, memory, heat, disk and battery that speeds up as your Mac works harder, drawn as a real bedside ECG.

## Build & run

```bash
./build.sh            # swift build → build/Triage.app → opens it
```

Needs macOS 14+ and Xcode or the Command Line Tools (Swift 5.9+). Prefer Xcode? `open Package.swift`, pick the Triage scheme, ⌘R. Run from Xcode, Triage copies itself into `~/Applications/Triage.app` so macOS can grant it permissions like Location and Bluetooth.

## What's in it

| Area | What it does |
|---|---|
| **Heart** | One bpm for your whole Mac, drawn like a bedside monitor: the sweep speed stays steady and the spikes grow with strain. Click a channel to see what's behind it, with fixes. |
| **Apps** | Every process grouped under the app that owns it, with CPU, memory, a sparkline and a quit button. |
| **Hardware** | Chip, memory breakdown, swap, network, battery health and cycles, thermal state, disk, uptime. |
| **Files** | Grid or list, real thumbnails, dual pane (⌘D), filters, sort and group, Peek, git branch in code folders, "Can I delete this?" verdicts, Trash with Undo. |
| **Smart Search** (⌘K, ⌥Space anywhere) | Plain-English file search on top of Spotlight ("pdfs from last week", "big videos in downloads"), a calculator, currency conversion ("100 usd to eur", live rates) and Triage actions ("quit chrome", "volume 30", "wifi off", "theme xp"). |
| **Menu bar** | Pick the numbers you want up top (bpm, CPU, memory, network, disk, heat, battery, Wi-Fi, volume, headphone and mouse battery). The panel has three tabs: **Vitals** (heart, busiest apps with quit, quick fixes), **Connectivity** (Wi-Fi, speed test, Bluetooth devices with battery levels) and **Sound** (volume for each app, mic mute for every app). |
| **PDF Editor** | Edit text in scanned PDFs. Fonts are matched to the scan, and the original ink is erased under your edit. Sign, redact, flatten and export. |
| **Utilities** | Free Up Space, Tidy Downloads, Clipboard history, Converter, Disk Map, Drive Health, Duplicates & Forgotten Files, App Uninstaller, Startup Items, Network, Dev Servers & Ports, Health History, Wi-Fi, Sound Mixer, Folder Autopilot. |
| **Themes** | 10 looks in Settings › Appearance: Triage, Apple Pro, Aqua, Windows 95, Windows XP, Windows 11, Macintosh (System 7), Linux (GNOME), Braun and Phosphor (CRT). Each changes colors, type, cards, buttons and the window frame. Also accent color, Light/Dark, Compact/Comfortable/Touch density and text size. |

Every destructive action goes to the Trash first and shows an **Undo** toast. Nothing leaves your Mac, except the currency rates lookup (open.er-api.com).

## Light on your Mac

Readings slow to every 5 seconds when no window is showing, and the heart line stops drawing when nobody can see it. Settings › Advanced shows how much memory Triage itself is using, and an optional usage log writes its CPU and memory once a minute.

## Shortcuts

⌘K search · ⌥Space search from any app · ⌘1 Home · ⌘0 Heart · ⌘2 Apps · ⌘3 Hardware · ⌘4 Files · ⌘D dual pane · F5/F6 copy/move to the other pane · Space Peek · ⌘⌫ Trash · ⇧⌘N new folder · ⌥⇧⌘T Terminal here · ⇧⌘. hidden files · ⌘, Settings · ⇧⌘/ Help

## Notes

- Without root, macOS hides CPU and memory for root-owned processes (kernel_task, WindowServer). Everything you run is counted.
- macOS asks once for Desktop, Documents and Downloads access, and for Location (to show Wi-Fi names) and Bluetooth.
- Closing the window keeps Triage in the menu bar. Quit from the menu bar panel.

## Fonts

The theme fonts in `Resources/Fonts` are open-licensed and ship with their licenses: VT323, Space Grotesk and Silkscreen under the SIL Open Font License 1.1, and Ubuntu under the Ubuntu Font Licence 1.0.
