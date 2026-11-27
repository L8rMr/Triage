import SwiftUI

/// Before there's a Mac: a flat line looking for a pulse.
struct ConnectView: View {
    @ObservedObject var browser: MacBrowser
    @ObservedObject private var cloud = CloudDirectory.shared
    @EnvironmentObject var link: MacLink
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    ECGView(bpm: isConnecting ? 72 : 0, color: .phosphor, flat: !isConnecting)
                        .frame(height: 120)
                        .padding(.horizontal, -20)
                    Text(title).font(.title2.weight(.bold))
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.top, 30)

                switch link.phase {
                case .needsCode(let wrong): codeEntry(wrong: wrong)
                case .failed(let why): failed(why)
                case .connecting: connecting
                default: macList
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            Text("Triage \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")")
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).padding(.bottom, 4)
        }
        .scrollDismissesKeyboard(.interactively)
        .animation(.snappy, value: link.phase)
    }

    /// Bonjour can remember a Mac after you've left the Wi-Fi: only list it while actually on Wi-Fi.
    private var lanMacs: [FoundMac] { PathWatch.shared.onWiFi ? browser.macs : [] }

    /// In iCloud but not on this Wi-Fi.
    private var awayMacs: [CloudMac] { cloud.macs.filter { m in !lanMacs.contains { $0.id == m.name } } }

    private var isConnecting: Bool {
        if case .connecting = link.phase { return true }
        if case .needsCode = link.phase { return true }
        return false
    }

    private var title: String {
        switch link.phase {
        case .connecting(let n): return "Connecting to \(n)"
        case .needsCode: return "Type the code on your Mac"
        case .failed: return "Lost the pulse"
        default: return lanMacs.isEmpty && awayMacs.isEmpty ? "Looking for your Mac" : "Pick your Mac"
        }
    }

    private var subtitle: String {
        switch link.phase {
        case .needsCode: return "\(link.macName) is showing six digits at the top of its screen."
        case .failed: return "Make sure your Mac is awake with Triage open and iPhone access on in Settings › iPhone."

        default:
            if !awayMacs.isEmpty { return "Your Macs, here on Wi-Fi or anywhere through iCloud." }
            return lanMacs.isEmpty
                ? "Open Triage on your Mac and turn on Settings › iPhone. Same Wi-Fi, or the same iCloud account from anywhere."
                : "Macs on this Wi-Fi running Triage."
        }
    }

    private var macList: some View {
        VStack(spacing: 12) {
            ForEach(lanMacs) { mac in
                Button { link.connect(mac) } label: {
                    Card {
                        HStack(spacing: 14) {
                            Image(systemName: "laptopcomputer").font(.title2).foregroundStyle(Color.phosphor)
                                .frame(width: 44, height: 44)
                                .background(Color.phosphor.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mac.id).font(.headline)
                                Text(mac.id == link.rememberedMac ? "Paired" : "Tap to pair").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(awayMacs) { mac in
                Button { link.connect(anywhere: mac, lan: lanMacs) } label: {
                    Card {
                        HStack(spacing: 14) {
                            Image(systemName: "icloud").font(.title2).foregroundStyle(Color.phosphor)
                                .frame(width: 44, height: 44)
                                .background(Color.phosphor.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mac.name).font(.headline)
                                Text("Through iCloud · no code · seen \(mac.seen.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if lanMacs.isEmpty && awayMacs.isEmpty {
                ProgressView().padding(.top, 8)
                Text(cloud.status.isEmpty ? (PathWatch.shared.onWiFi ? "Looking on this Wi-Fi and asking iCloud where your Mac is…" : "Asking iCloud where your Mac is…") : cloud.status)
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !PathWatch.shared.onWiFi {
                    Text("On cellular? Check Settings › Cellular › Triage is switched on.")
                        .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
            }
            if !link.notes.isEmpty { notesCard.padding(.top, 10) }
            if case .failed = link.phase, awayMacs.isEmpty, !cloud.status.isEmpty {
                Text(cloud.status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func codeEntry(wrong: Bool) -> some View {
        VStack(spacing: 16) {
            ZStack {
                // the real field, invisible; the boxes just draw what's in it
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($codeFocused)
                    .opacity(0.01)
                    .onChange(of: code) { _, v in
                        let digits = String(v.filter(\.isNumber).prefix(6))
                        if digits != v { code = digits }
                        if digits.count == 6 {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            link.submit(code: digits)
                        }
                    }
                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { i in
                        let ch = i < code.count ? String(code[code.index(code.startIndex, offsetBy: i)]) : ""
                        Text(ch)
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.phosphor)
                            .frame(width: 44, height: 58)
                            .background(Color.glass700, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(i == code.count ? Color.phosphor : Color.white.opacity(0.08), lineWidth: i == code.count ? 2 : 1))
                        if i == 2 { Spacer().frame(width: 6) }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { codeFocused = true }
            }
            if wrong {
                Label("That code didn't match. Try again.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Color.coral)
            }
            Button("Cancel") { link.disconnect(); code = "" }.foregroundStyle(.secondary)
        }
        .onAppear { code = ""; codeFocused = true }
        .onChange(of: wrong) { _, w in
            if w { code = ""; UINotificationFeedbackGenerator().notificationOccurred(.error) }
        }
    }

    private func failed(_ why: String) -> some View {
        VStack(spacing: 14) {
            Text(why).font(.callout).foregroundStyle(Color.amber).multilineTextAlignment(.center)
            if PathWatch.shared.vpn {
                Label("A VPN is on and carries all of this iPhone's traffic, so it can't reach your Mac. Turn the VPN off, then try again.", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .padding(12).background(Color.glass700, in: RoundedRectangle(cornerRadius: 12))
            }
            Button("Try again") { link.disconnect() }
                .buttonStyle(.borderedProminent)
            if !link.notes.isEmpty { notesCard }
        }
    }

    /// Live: what the phone is trying right now, how long it's been, and each way in that didn't work.
    private var connecting: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                Text(link.step.isEmpty ? "Starting" : link.step).font(.callout.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .contentTransition(.opacity)
                    .animation(.snappy, value: link.step)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let t = Int(ctx.date.timeIntervalSince(link.startedAt))
                let left = max(Int(MacLink.giveUpAfter) - t, 0)
                VStack(spacing: 6) {
                    ProgressView(value: min(Double(t) / MacLink.giveUpAfter, 1)).tint(.phosphor).frame(maxWidth: 240)
                    Text("\(t) s · gives up in \(left) s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !link.notes.isEmpty { notesCard }
            Button("Cancel") { link.disconnect() }.buttonStyle(.bordered)
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What happened").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            ForEach(Array(link.notes.enumerated()), id: \.offset) { _, n in Text("• " + n).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.glass700, in: RoundedRectangle(cornerRadius: 12))
    }
}
