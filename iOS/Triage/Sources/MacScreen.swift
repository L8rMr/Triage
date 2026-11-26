import SwiftUI

struct MacScreen: View {
    @EnvironmentObject var link: MacLink
    @AppStorage("heart.haptics") private var haptics = false
    @State private var askEmpty = false
    @State private var reallyEmpty = false
    @State private var error: String?
    @State private var confirmForget = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "laptopcomputer").font(.system(size: 34)).foregroundStyle(Color.phosphor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(link.macName).font(.title3.weight(.semibold))
                        Text(link.canEdit ? "Full control" : "View only").font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background((link.canEdit ? Color.phosphor : Color.amber).opacity(0.15), in: Capsule())
                            .foregroundStyle(link.canEdit ? Color.phosphor : Color.amber)
                    }
                }
                .padding(.vertical, 6)
            }
            if let i = link.info {
                Section("This Mac") {
                    if let m = i.model { LabeledContent("Model", value: m) }
                    if let c = i.chip { LabeledContent("Chip", value: c) }
                    if let o = i.os { LabeledContent("System", value: o) }
                    if let m = i.memTotal { LabeledContent("Memory", value: Fmt.bytes(m)) }
                    if let v = link.vitals { LabeledContent("Disk", value: "\(Fmt.bytes(v.diskFree)) free of \(Fmt.bytes(v.diskTotal))") }
                    if let u = link.vitals?.uptime { LabeledContent("Up for", value: Fmt.span(u)) }
                    if let s = i.setup {
                        LabeledContent("Set up", value: Date(timeIntervalSince1970: s).formatted(date: .abbreviated, time: .omitted))
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { link.vitals?.keepAwake ?? false }, set: { on in
                    Task { do { try await link.setKeepAwake(on) } catch { self.error = error.localizedDescription } }
                })) {
                    Label("Keep awake", systemImage: "cup.and.saucer.fill")
                }
                Toggle(isOn: $haptics) {
                    Label("Feel the pulse", systemImage: "hand.tap.fill")
                }
            } footer: {
                Text("Keep awake stops the Mac from sleeping while you're away, so it stays reachable. Feel the pulse taps once per heartbeat while the Heart screen is open.")
            }
            if link.canEdit {
                Section {
                    Button(role: .destructive) { askEmpty = true } label: { Label("Empty Trash on \(link.macName)", systemImage: "trash.slash") }
                }
            }
            Section {
                Button("Disconnect") { link.disconnect() }
                Button("Forget this Mac", role: .destructive) { confirmForget = true }
            } footer: {
                Text("To remove this iPhone completely, also click Forget next to it in Triage › Settings › iPhone on the Mac.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Mac")
        // two steps on purpose: emptying the Trash can't be undone
        .confirmationDialog("Empty the Trash on \(link.macName)?", isPresented: $askEmpty, titleVisibility: .visible) {
            Button("Continue", role: .destructive) { reallyEmpty = true }
        } message: { Text("Everything in it is deleted for good.") }
        .alert("This can't be undone", isPresented: $reallyEmpty) {
            Button("Empty Trash", role: .destructive) {
                Task {
                    do {
                        _ = try await link.call("emptyTrash", ["confirm": "EMPTY"])
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Files in the Trash on \(link.macName) will be permanently deleted.") }
        .confirmationDialog("Forget \(link.macName)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { link.forgetMac() }
        } message: { Text("You'll need a new code from the Mac to connect again.") }
        .alert("Couldn't do that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}
