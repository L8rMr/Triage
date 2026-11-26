import SwiftUI

// MARK: - Shared filter vocabulary (Files, Tidy, Apps)

struct FilterOption: Identifiable, Hashable {
    let id: String
    let label: String
    var symbol: String? = nil
    var count: Int = 0

    static func sizes(_ sizes: [Int64]) -> [FilterOption] {
        SizeBucket.allCases.compactMap { b in
            let n = sizes.filter { SizeBucket.of($0) == b }.count
            return n > 0 ? FilterOption(id: b.rawValue, label: b.rawValue, symbol: b.symbol, count: n) : nil
        }
    }

    static func dates(_ dates: [Date]) -> [FilterOption] {
        DateBucket.allCases.compactMap { b in
            let n = dates.filter { DateBucket.of($0) == b }.count
            return n > 0 ? FilterOption(id: b.rawValue, label: b.rawValue, symbol: b.symbol, count: n) : nil
        }
    }
}

enum SizeBucket: String, CaseIterable {
    case huge = "Over 1 GB", large = "100 MB – 1 GB", medium = "1 – 100 MB", small = "Under 1 MB"
    var symbol: String {
        switch self {
        case .huge: return "externaldrive.fill"
        case .large: return "shippingbox.fill"
        case .medium: return "doc.fill"
        case .small: return "doc"
        }
    }
    static func of(_ s: Int64) -> SizeBucket {
        s >= 1_000_000_000 ? .huge : s >= 100_000_000 ? .large : s >= 1_000_000 ? .medium : .small
    }
}

/// Non-overlapping, so ticking several makes sense.
enum DateBucket: String, CaseIterable {
    case today = "Today", week = "Earlier this week", month = "Earlier this month"
    case quarter = "Last 3 months", year = "Earlier this year", older = "Before this year"
    var symbol: String {
        switch self {
        case .today: return "sun.max"
        case .week: return "calendar"
        case .month: return "calendar"
        case .quarter: return "calendar.badge.clock"
        case .year: return "calendar.badge.clock"
        case .older: return "archivebox"
        }
    }
    static func of(_ d: Date) -> DateBucket {
        let cal = Calendar.current, now = Date()
        if d >= cal.startOfDay(for: now) { return .today }
        if d >= (cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now) { return .week }
        if d >= (cal.dateInterval(of: .month, for: now)?.start ?? now) { return .month }
        if d >= (cal.date(byAdding: .month, value: -3, to: now) ?? now) { return .quarter }
        if d >= (cal.dateInterval(of: .year, for: now)?.start ?? now) { return .year }
        return .older
    }
}

enum TextFilter {
    /// Commas mean "or": "invoice, receipt" matches either.
    static func matches(_ s: String, _ filter: String) -> Bool {
        let terms = filter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return terms.isEmpty || terms.contains { s.localizedCaseInsensitiveContains($0) }
    }
}

struct ColumnSort: Equatable {
    var key: String
    var ascending: Bool
}

// MARK: - The popover every filter opens

struct FilterPopover: View {
    let title: String
    let options: [FilterOption]
    @Binding var selection: Set<String>
    var text: Binding<String>?
    @State private var find = ""
    @State private var hovered: String?

    private var shown: [FilterOption] {
        find.isEmpty ? options : options.filter { $0.label.localizedCaseInsensitiveContains(find) }
    }
    private var active: Bool { !selection.isEmpty || !(text?.wrappedValue.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Theme.accent)
                Text(title).font(.ui(size: 13, weight: .semibold))
                Spacer()
                if active {
                    Button("Clear") { selection = []; text?.wrappedValue = "" }
                        .buttonStyle(.plain).font(.ui(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                }
            }

            if let text {
                field(placeholder: "Contains…  (use commas for “or”)", text: text)
            }

            if !options.isEmpty {
                if options.count > 8 { field(placeholder: "Find an option", text: $find) }
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(shown) { opt in
                            let on = selection.contains(opt.id)
                            Button {
                                if on { selection.remove(opt.id) } else { selection.insert(opt.id) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(on ? Theme.accent : Color.secondary)
                                    if let s = opt.symbol {
                                        Image(systemName: s).foregroundStyle(.secondary).frame(width: 16)
                                    }
                                    Text(opt.label).lineLimit(1)
                                    Spacer()
                                    if opt.count > 0 {
                                        Text("\(opt.count)").foregroundStyle(.tertiary).monospacedDigit()
                                    }
                                }
                                .font(.ui(size: 12))
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(on ? Theme.accent.opacity(0.12) : (hovered == opt.id ? Color.primary.opacity(0.05) : Color.clear),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hovered = $0 ? opt.id : (hovered == opt.id ? nil : hovered) }
                        }
                    }
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: shown.count <= 8)

                HStack {
                    Button("Select all") { selection = Set(options.map(\.id)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    Text(selection.isEmpty ? "Showing all" : "\(selection.count) selected").foregroundStyle(.tertiary)
                }
                .font(.ui(size: 11))
            }
        }
        .padding(14)
        .frame(width: 260)
        .background(Theme.bg)
    }

    private func field(placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.ui(size: 11)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(.ui(size: 12))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
    }
}

// MARK: - Column header: click the title to sort, the funnel to filter

struct ColumnHeader: View {
    let title: String
    let width: CGFloat?
    let sortKey: String?
    @Binding var sort: ColumnSort
    let options: [FilterOption]
    let selection: Binding<Set<String>>?
    let text: Binding<String>?
    var defaultAscending: Bool
    @State private var open = false
    @State private var hover = false

    init(_ title: String, width: CGFloat? = nil, sortKey: String? = nil, sort: Binding<ColumnSort>,
         options: [FilterOption] = [], selection: Binding<Set<String>>? = nil, text: Binding<String>? = nil,
         defaultAscending: Bool = true) {
        self.title = title
        self.width = width
        self.sortKey = sortKey
        self._sort = sort
        self.options = options
        self.selection = selection
        self.text = text
        self.defaultAscending = defaultAscending
    }

    private var sorted: Bool { sortKey != nil && sort.key == sortKey }
    private var filterable: Bool { selection != nil || text != nil }
    private var count: Int { (selection?.wrappedValue.count ?? 0) + ((text?.wrappedValue.isEmpty ?? true) ? 0 : 1) }

    var body: some View {
        HStack(spacing: 5) {
            Button {
                guard let k = sortKey else { return }
                if sort.key == k { sort.ascending.toggle() } else { sort = ColumnSort(key: k, ascending: defaultAscending) }
            } label: {
                HStack(spacing: 3) {
                    Text(title.uppercased()).kerning(0.6)
                    if sorted {
                        Image(systemName: sort.ascending ? "chevron.up" : "chevron.down").font(.ui(size: 8, weight: .bold))
                    }
                }
                .foregroundStyle(sorted ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(sortKey == nil)

            if filterable {
                Button { open.toggle() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        if count > 0 { Text("\(count)").font(.ui(size: 9, weight: .bold)) }
                    }
                    .foregroundStyle(count > 0 ? Theme.accent : Color.secondary.opacity(hover || open ? 1 : 0.55))
                }
                .buttonStyle(.plain)
                .help("Filter \(title.lowercased())")
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    FilterPopover(title: title, options: options,
                                  selection: selection ?? .constant([]), text: text)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.ui(size: 10, weight: .semibold))
        .frame(minWidth: width ?? 140, maxWidth: width ?? .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Pill version for places without columns (grid view)

struct FilterPill: View {
    let title: String
    let options: [FilterOption]
    let selection: Binding<Set<String>>?
    let text: Binding<String>?
    @State private var open = false

    init(_ title: String, options: [FilterOption] = [], selection: Binding<Set<String>>? = nil, text: Binding<String>? = nil) {
        self.title = title
        self.options = options
        self.selection = selection
        self.text = text
    }

    private var summary: String? {
        if let t = text?.wrappedValue, !t.isEmpty { return "“\(t)”" }
        guard let s = selection?.wrappedValue, !s.isEmpty else { return nil }
        return s.count == 1 ? (options.first { s.contains($0.id) }?.label ?? s.first) : "\(s.count)"
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Text(summary.map { "\(title): \($0)" } ?? title).lineLimit(1)
                Image(systemName: "chevron.down").font(.ui(size: 8, weight: .bold))
            }
            .font(.ui(size: 11, weight: .medium))
            .foregroundStyle(summary != nil ? Theme.accent : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(summary != nil ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(summary != nil ? Theme.accent.opacity(0.6) : Theme.stroke))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            FilterPopover(title: title, options: options, selection: selection ?? .constant([]), text: text)
        }
    }
}

/// "12 of 340 · 2.1 GB · Clear" — the same line under every filtered list.
struct FilterSummary: View {
    let shown: Int
    let total: Int
    let bytes: Int64?
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Theme.accent)
            Text("Showing \(shown) of \(total)" + (bytes.map { " · \(Fmt.bytes($0))" } ?? ""))
            Spacer()
            Button("Clear filters", action: clear).buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
        .font(.ui(size: 11))
        .foregroundStyle(.secondary)
    }
}
