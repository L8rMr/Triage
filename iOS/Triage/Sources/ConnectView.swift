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
                case .connecting: ProgressView().controlSize(.large)
                default: macList
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .animation(.snappy, value: link.phase)
    }

    /// In iCloud but not on this Wi-Fi.
    private var awayMacs: [CloudMac] { cloud.macs.filter { m in !browser.macs.contains { $0.id == m.name } } }

    private var isConnecting: Bool {
        if case .connecting = link.phase { return true }
        if case .needsCode = link.phase { return true }
        return false
    }

    private var title: String {
        switch link.phase {
        case .connecting(let n): return "Finding \(n)'s pulse"
        case .needsCode: return "Type the code on your Mac"
        case .failed: return "Lost the pulse"
        default: return browser.macs.isEmpty && awayMacs.isEmpty ? "Looking for your Mac" : "Pick your Mac"
        }
    }

    private var subtitle: String {
        switch link.phase {
        case .needsCode: return "\(link.macName) is showing six digits at the top of its screen."
        case .failed: return "Make sure your Mac is awake with Triage open and iPhone access on in Settings › iPhone."

        default:
            if !awayMacs.isEmpty { return "Your Macs, here on Wi-Fi or anywhere through iCloud." }
            return browser.macs.isEmpty
                ? "Open Triage on your Mac and turn on Settings › iPhone. Same Wi-Fi, or the same iCloud account from anywhere."
                : "Macs on this Wi-Fi running Triage."
        }
    }

    private var macList: some View {
        VStack(spacing: 12) {
            ForEach(browser.macs) { mac in
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
                Button { link.connect(anywhere: mac, lan: browser.macs) } label: {
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
            if browser.macs.isEmpty && awayMacs.isEmpty {
                ProgressView().padding(.top, 8)
                if !cloud.status.isEmpty {
                    Text(cloud.status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            if !link.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What happened").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    ForEach(link.notes, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.glass700, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 10)
            }
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
            Button("Try again") { link.disconnect() }
                .buttonStyle(.borderedProminent)
        }
    }
}
