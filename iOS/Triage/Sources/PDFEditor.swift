import SwiftUI
import PDFKit
import PencilKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - PDF Editor on the phone
//
// Opens a PDF from the Mac (or the iPhone), and edits it here with the finger or Pencil:
// draw and mark up, highlight / underline / strike text, type text boxes, sign, drop in pictures, redact for real
// (redacted pages are flattened so the hidden words are gone), fill forms, and organize pages. Saves back to the Mac
// (replacing the original, which goes to the Trash, or as a copy) or shares from the phone.

struct PDFEditorScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var pickingMac = false
    @State private var pickingPhone = false
    @State private var open: PDFSource?
    @State private var loading: String?
    @State private var error: String?
    @State private var toast: String?
    @AppStorage("pdf.recent") private var recentRaw = ""

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }

    var body: some View {
        List {
            Section {
                Button { pickingMac = true } label: { Label("Open a PDF on \(link.macName)", systemImage: "laptopcomputer") }
                Button { pickingPhone = true } label: { Label("Open a PDF on this iPhone", systemImage: "iphone") }
            } footer: {
                Text("Draw, highlight, add text, sign, insert pictures, redact, fill forms and rearrange pages. Save back to the Mac or share it.")
            }
            if !recent.isEmpty {
                Section("Recent on \(link.macName)") {
                    ForEach(recent, id: \.self) { p in
                        Button { Task { await openMac(p) } } label: { Label((p as NSString).lastPathComponent, systemImage: "doc.richtext") }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("PDF Editor")
        .helpTip("Open a PDF from the Mac or the iPhone. ✏️ draws, T adds text, ✍️ signs, 🖼 adds a picture, ■ blacks out, the eraser removes marks, ▦ rearranges pages. Select text to highlight or redact it.")
        .overlay {
            if let loading {
                VStack(spacing: 10) { ProgressView(); Text(loading).font(.footnote.weight(.semibold)) }
                    .padding(20).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .sheet(isPresented: $pickingMac) {
            MacFilePicker(title: "Open a PDF", exts: ["pdf"], multiple: false) { picked in
                if let p = picked.first { Task { await openMac(p.path) } }
            }
        }
        .fileImporter(isPresented: $pickingPhone, allowedContentTypes: [.pdf]) { r in
            guard case .success(let u) = r else { return }
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: tmp)
            do { try FileManager.default.copyItem(at: u, to: tmp); open = PDFSource(local: tmp, macPath: nil) }
            catch { self.error = error.localizedDescription }
        }
        .navigationDestination(item: $open) { src in PDFEditView(source: src) }
        .toolChrome(error: $error, toast: $toast)
    }

    private func openMac(_ path: String) async {
        loading = "Getting \((path as NSString).lastPathComponent)…"
        do {
            let u = try await link.download(path) { _ in }
            open = PDFSource(local: u, macPath: path)
            recentRaw = ([path] + recent.filter { $0 != path }).prefix(6).joined(separator: "\n")
        } catch { self.error = error.localizedDescription }
        loading = nil
    }
}

struct PDFSource: Hashable, Identifiable {
    let local: URL
    let macPath: String?
    var id: URL { local }
}

// MARK: - The editor

enum PDFMode: Equatable { case view, draw, place, erase, box }

final class ImageStamp: PDFAnnotation {
    var image: UIImage = UIImage()
    convenience init(image: UIImage, bounds: CGRect) {
        self.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.image = image
    }
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cg = image.cgImage else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(cg, in: bounds)
        context.restoreGState()
    }
}

@MainActor
final class PDFEditorModel: NSObject, ObservableObject, PDFPageOverlayViewProvider {
    let view = PDFView()
    let picker = PKToolPicker()
    @Published var mode: PDFMode = .view
    @Published var dirty = false
    @Published var hasSelection = false
    @Published var pageLabel = ""
    @Published var canUndo = false
    var placing: Placeable?
    private var canvases: [PDFPage: PKCanvasView] = [:]
    private var added: [(PDFAnnotation, PDFPage)] = []
    private var redacted: Set<PDFPage> = []
    private var boxStart: CGPoint?
    private var boxAnn: PDFAnnotation?

    enum Placeable { case text(String, UIColor), image(UIImage, CGFloat) }

    init(doc: PDFDocument) {
        super.init()
        view.pageOverlayViewProvider = self
        view.document = doc
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.pageShadowsEnabled = true
        view.isFindInteractionEnabled = true
        picker.selectedToolItemIdentifier = "com.apple.ink.pen"
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        pageChanged()
    }

    var doc: PDFDocument { view.document ?? PDFDocument() }

    @objc private func selectionChanged() { hasSelection = !(view.currentSelection?.string ?? "").isEmpty }
    @objc private func pageChanged() {
        guard let p = view.currentPage else { return }
        pageLabel = "\(doc.index(for: p) + 1) of \(doc.pageCount)"
    }

    // MARK: Drawing (PencilKit on top of each page)

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let c = canvases[page] ?? {
            let c = PKCanvasView()
            c.backgroundColor = .clear
            c.isOpaque = false
            c.drawingPolicy = .anyInput
            picker.addObserver(c)
            canvases[page] = c
            return c
        }()
        c.isUserInteractionEnabled = mode == .draw
        return c
    }

    func setMode(_ m: PDFMode) {
        if mode == .draw && m != .draw { commitDrawings() }
        mode = m
        view.isInMarkupMode = m == .draw
        for c in canvases.values { c.isUserInteractionEnabled = m == .draw }
        if m == .draw, let p = view.currentPage, let c = canvases[p] {
            picker.setVisible(true, forFirstResponder: c)
            c.becomeFirstResponder()
        } else {
            for c in canvases.values { picker.setVisible(false, forFirstResponder: c); c.resignFirstResponder() }
        }
    }

    /// Strokes become real ink annotations (they open in Preview and Acrobat as markup).
    private func commitDrawings() {
        let s = max(view.scaleFactor, 0.01)
        for (page, c) in canvases where !c.drawing.strokes.isEmpty {
            for stroke in c.drawing.strokes {
                let pts = Array(stroke.path.interpolatedPoints(by: .distance(1.5)))
                guard let first = pts.first else { continue }
                let toPage: (CGPoint) -> CGPoint = { p in self.view.convert(c.convert(p.applying(stroke.transform), to: self.view), to: page) }
                let path = UIBezierPath()
                path.move(to: toPage(first.location))
                for p in pts.dropFirst() { path.addLine(to: toPage(p.location)) }
                if pts.count == 1 { path.addLine(to: toPage(first.location).applying(.init(translationX: 0.5, y: 0.5))) }
                let width = max((pts.map(\.size.width).reduce(0, +) / CGFloat(pts.count)) / s, 0.5)
                let bounds = path.bounds.insetBy(dx: -width * 2, dy: -width * 2)
                path.apply(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
                let border = PDFBorder(); border.lineWidth = width
                a.border = border
                var color = stroke.ink.color.resolvedColor(with: .current)
                if stroke.ink.inkType == .marker { color = color.withAlphaComponent(0.35) }
                a.color = color
                a.add(path)
                add(a, to: page)
            }
            c.drawing = PKDrawing()
        }
    }

    // MARK: Text markup from a selection

    func markSelection(_ type: PDFAnnotationSubtype) {
        guard let sel = view.currentSelection else { return }
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                let a = PDFAnnotation(bounds: b, forType: type, withProperties: nil)
                a.color = type == .highlight ? UIColor.systemYellow.withAlphaComponent(0.5) : (type == .strikeOut ? .systemRed : .systemBlue)
                add(a, to: page)
            }
        }
        view.clearSelection()
    }

    func redactSelection() {
        guard let sel = view.currentSelection else { return }
        for line in sel.selectionsByLine() {
            for page in line.pages { blackBox(line.bounds(for: page).insetBy(dx: -1, dy: -1), on: page) }
        }
        view.clearSelection()
    }

    private func blackBox(_ r: CGRect, on page: PDFPage) {
        let a = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
        a.color = .black
        a.interiorColor = .black
        a.setValue("triage-redact", forAnnotationKey: .name)
        add(a, to: page)
        redacted.insert(page)
    }

    // MARK: Taps and drags on the page

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let loc = g.location(in: view)
        guard let page = view.page(for: loc, nearest: true) else { return }
        let pt = view.convert(loc, to: page)
        switch mode {
        case .place:
            guard let what = placing else { return }
            switch what {
            case .text(let s, let color):
                let font = UIFont.systemFont(ofSize: 14)
                let size = (s as NSString).boundingRect(with: CGSize(width: 320, height: 2000), options: .usesLineFragmentOrigin,
                                                        attributes: [.font: font], context: nil).size
                let a = PDFAnnotation(bounds: CGRect(x: pt.x, y: pt.y - size.height - 6, width: size.width + 10, height: size.height + 8),
                                      forType: .freeText, withProperties: nil)
                a.contents = s
                a.font = font
                a.fontColor = color
                a.color = .clear
                let b = PDFBorder(); b.lineWidth = 0; a.border = b
                add(a, to: page)
            case .image(let img, let width):
                let h = width * img.size.height / max(img.size.width, 1)
                add(ImageStamp(image: img, bounds: CGRect(x: pt.x - width / 2, y: pt.y - h / 2, width: width, height: h)), to: page)
            }
            placing = nil
            setMode(.view)
        case .erase:
            if let a = page.annotation(at: pt), a.type != "Widget" {
                if (a.value(forAnnotationKey: .name) as? String) == "triage-redact" { redacted.remove(page) }
                page.removeAnnotation(a)
                added.removeAll { $0.0 === a }
                canUndo = !added.isEmpty
                dirty = true
            }
        default: break
        }
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard mode == .box else { return }
        let loc = g.location(in: view)
        guard let page = view.page(for: loc, nearest: true) else { return }
        let pt = view.convert(loc, to: page)
        switch g.state {
        case .began:
            boxStart = pt
        case .changed:
            guard let s = boxStart else { return }
            let r = CGRect(x: min(s.x, pt.x), y: min(s.y, pt.y), width: abs(pt.x - s.x), height: abs(pt.y - s.y))
            if let b = boxAnn { b.bounds = r } else {
                let b = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
                b.color = .systemRed; b.interiorColor = UIColor.black.withAlphaComponent(0.6)
                page.addAnnotation(b); boxAnn = b
            }
        case .ended, .cancelled:
            if let b = boxAnn {
                b.page?.removeAnnotation(b)
                if b.bounds.width > 4 && b.bounds.height > 4 { blackBox(b.bounds, on: page) }
            }
            boxAnn = nil; boxStart = nil
        default: break
        }
    }

    private func add(_ a: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(a)
        added.append((a, page))
        canUndo = true
        dirty = true
    }

    func undo() {
        guard let (a, page) = added.popLast() else { return }
        page.removeAnnotation(a)
        if (a.value(forAnnotationKey: .name) as? String) == "triage-redact",
           !page.annotations.contains(where: { ($0.value(forAnnotationKey: .name) as? String) == "triage-redact" }) { redacted.remove(page) }
        canUndo = !added.isEmpty
    }

    func place(_ p: Placeable) { placing = p; setMode(.place) }

    // MARK: Pages

    func pagesChanged() { dirty = true; view.layoutDocumentView(); pageChanged() }

    // MARK: Saving

    /// Redacted pages become pictures (the words under the black boxes are gone for good); pictures and signatures
    /// are flattened into the page; everything else stays as real, editable annotations.
    func exportData() throws -> Data {
        if mode == .draw { setMode(.view) }
        let d = doc
        for page in redacted {
            let i = d.index(for: page)
            guard i != NSNotFound else { continue }
            let box = page.bounds(for: .mediaBox)
            let img = page.thumbnail(of: CGSize(width: box.width * 2.5, height: box.height * 2.5), for: .mediaBox)
            guard let flat = PDFPage(image: img) else { continue }
            d.removePage(at: i)
            d.insert(flat, at: i)
        }
        redacted = []
        let stamps = (0..<d.pageCount).contains { d.page(at: $0)?.annotations.contains { $0 is ImageStamp } ?? false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let ok = stamps ? d.write(to: url, withOptions: [.burnInAnnotationsOption: true]) : d.write(to: url)
        guard ok, let data = try? Data(contentsOf: url) else { throw LinkError("Couldn't write the PDF") }
        try? FileManager.default.removeItem(at: url)
        return data
    }
}

extension PDFEditorModel: UIGestureRecognizerDelegate {
    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(g is UIPanGestureRecognizer)
    }
    nonisolated func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated {
            if g is UIPanGestureRecognizer { return mode == .box }
            return mode == .place || mode == .erase
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let model: PDFEditorModel
    func makeUIView(context: Context) -> PDFView { model.view }
    func updateUIView(_ v: PDFView, context: Context) {}
}

struct PDFEditView: View {
    let source: PDFSource
    @EnvironmentObject var link: MacLink
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m: PDFEditorModel
    @State private var askText = false
    @State private var text = ""
    @State private var textColor = Color.black
    @State private var signing = false
    @State private var photo: PhotosPickerItem?
    @State private var showPages = false
    @State private var saving: String?
    @State private var askSave = false
    @State private var share: URL?
    @State private var error: String?
    @State private var toast: String?
    @State private var confirmLeave = false

    init(source: PDFSource) {
        self.source = source
        _m = StateObject(wrappedValue: PDFEditorModel(doc: PDFDocument(url: source.local) ?? PDFDocument()))
    }

    private var hint: String? {
        switch m.mode {
        case .place: return "Tap the page where it goes"
        case .erase: return "Tap a mark, box, picture or note to remove it"
        case .box: return "Drag over what to black out"
        case .draw: return nil
        case .view: return nil
        }
    }

    var body: some View {
        PDFKitView(model: m)
            .ignoresSafeArea(edges: .bottom)
            .background(Color.glass900)
            .overlay(alignment: .top) {
                if let hint {
                    Text(hint).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule()).padding(.top, 8)
                }
            }
            .overlay(alignment: .bottom) { if m.hasSelection && m.mode == .view { selectionBar } }
            .overlay {
                if let saving {
                    VStack(spacing: 10) { ProgressView(); Text(saving).font(.footnote.weight(.semibold)) }
                        .padding(20).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .navigationTitle(source.local.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(m.dirty)
            .toolbar { top; bottom }
            .alert("Add text", isPresented: $askText) {
                TextField("Text", text: $text)
                Button("Black") { place(.black) }
                Button("Blue") { place(.systemBlue) }
                Button("Red") { place(.systemRed) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Pick a color, then tap where it goes.") }
            .sheet(isPresented: $signing) { SignatureSheet { img in m.place(.image(img, 150)) } }
            .sheet(isPresented: $showPages) { PagesSheet(model: m) }
            .sheet(item: Binding(get: { share.map { ShareItem(url: $0) } }, set: { share = $0?.url })) { s in ShareSheet(items: [s.url]) }
            .confirmationDialog("Save to \(link.macName)", isPresented: $askSave, titleVisibility: .visible) {
                Button("Replace the original") { Task { await saveMac(replace: true) } }
                Button("Save as a copy") { Task { await saveMac(replace: false) } }
            } message: { Text("Replacing moves the original to the Trash on the Mac, so you can get it back.") }
            .confirmationDialog("Leave without saving?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { m.place(.image(img, 220)) }
                    photo = nil
                }
            }
            .toolChrome(error: $error, toast: $toast)
    }

    @ToolbarContentBuilder private var top: some ToolbarContent {
        if m.dirty {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { confirmLeave = true } }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { m.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!m.canUndo)
            Menu {
                if source.macPath != nil && link.canEdit { Button { askSave = true } label: { Label("Save to \(link.macName)", systemImage: "laptopcomputer") } }
                else if link.canEdit { Button { Task { await saveMacNew() } } label: { Label("Save to \(link.macName) (Downloads)", systemImage: "laptopcomputer") } }
                Button { exportShare() } label: { Label("Share or save to iPhone", systemImage: "square.and.arrow.up") }
                if let p = source.macPath, link.canEdit {
                    Button { Task { _ = try? await link.call("open", ["path": p]); flash($toast, "Opened on \(link.macName)") } } label: {
                        Label("Edit existing words on the Mac", systemImage: "character.cursor.ibeam")
                    }
                }
            } label: { Text("Save").fontWeight(.semibold) }
        }
    }

    @ToolbarContentBuilder private var bottom: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            tool("pencil.tip.crop.circle", .draw) { m.setMode(m.mode == .draw ? .view : .draw) }
            Spacer()
            Button { text = ""; askText = true } label: { Image(systemName: "textformat") }
            Spacer()
            Button { signing = true } label: { Image(systemName: "signature") }
            Spacer()
            PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo") }
            Spacer()
            tool("rectangle.fill", .box) { m.setMode(m.mode == .box ? .view : .box) }
            Spacer()
            tool("eraser", .erase) { m.setMode(m.mode == .erase ? .view : .erase) }
            Spacer()
            Button { m.setMode(.view); showPages = true } label: { Image(systemName: "square.grid.2x2") }
            Spacer()
            Button { m.view.findInteraction.presentFindNavigator(showingReplace: false) } label: { Image(systemName: "magnifyingglass") }
        }
    }

    private func tool(_ symbol: String, _ mode: PDFMode, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .padding(6)
                .background(m.mode == mode ? Color.phosphor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 18) {
            Button { m.markSelection(.highlight) } label: { Label("Highlight", systemImage: "highlighter") }
            Button { m.markSelection(.underline) } label: { Label("Underline", systemImage: "underline") }
            Button { m.markSelection(.strikeOut) } label: { Label("Strike", systemImage: "strikethrough") }
            Button(role: .destructive) { m.redactSelection() } label: { Label("Redact", systemImage: "rectangle.fill") }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 16)
    }

    private func place(_ color: UIColor) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        m.place(.text(t, color))
    }

    private func exportShare() {
        do {
            let data = try m.exportData()
            let u = FileManager.default.temporaryDirectory.appendingPathComponent(source.local.lastPathComponent)
            try data.write(to: u, options: .atomic)
            share = u
        } catch { self.error = error.localizedDescription }
    }

    private func saveMac(replace: Bool) async {
        guard let path = source.macPath else { return }
        saving = "Saving to \(link.macName)…"
        do {
            let data = try m.exportData()
            let dir = (path as NSString).deletingLastPathComponent
            let file = (path as NSString).lastPathComponent
            let base = (file as NSString).deletingPathExtension
            if replace { _ = try await link.call("trash", ["paths": [path]]) }
            let landed = try await link.upload(data, name: replace ? file : "\(base) (edited).pdf", to: dir) { _ in }
            m.dirty = false
            flash($toast, "Saved \((landed as NSString).lastPathComponent)")
        } catch { self.error = error.localizedDescription }
        saving = nil
    }

    private func saveMacNew() async {
        saving = "Saving to \(link.macName)…"
        do {
            let data = try m.exportData()
            let dir = (link.info?.home ?? "~") + "/Downloads"
            let landed = try await link.upload(data, name: source.local.lastPathComponent, to: dir) { _ in }
            m.dirty = false
            flash($toast, "Saved to Downloads as \((landed as NSString).lastPathComponent)")
        } catch { self.error = error.localizedDescription }
        saving = nil
    }
}

private struct ShareItem: Identifiable { let url: URL; var id: URL { url } }

// MARK: - Signature

struct SignatureSheet: View {
    var done: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var canvas = PKCanvasView()
    @State private var saved: UIImage? = SignatureStore.load()
    @State private var drawingNew = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let saved, !drawingNew {
                    Image(uiImage: saved).resizable().scaledToFit().frame(maxHeight: 140).padding()
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                    Button { done(saved); dismiss() } label: { Text("Use this signature").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button("Draw a new one") { drawingNew = true }
                } else {
                    SignaturePad(canvas: canvas)
                        .frame(height: 220)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.gray.opacity(0.4)).frame(height: 1).padding(.horizontal, 24).padding(.bottom, 50) }
                    HStack {
                        Button("Clear") { canvas.drawing = PKDrawing() }
                        Spacer()
                        Button("Use") {
                            let d = canvas.drawing
                            guard !d.strokes.isEmpty else { return }
                            let img = d.image(from: d.bounds.insetBy(dx: -6, dy: -6), scale: 3)
                            SignatureStore.save(img)
                            done(img); dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Signature").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SignaturePad: UIViewRepresentable {
    let canvas: PKCanvasView
    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        return canvas
    }
    func updateUIView(_ v: PKCanvasView, context: Context) {}
}

/// Your signature stays on this iPhone only.
enum SignatureStore {
    private static var url: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("signature.png")
    }
    static func load() -> UIImage? { UIImage(contentsOfFile: url.path) }
    static func save(_ img: UIImage) {
        try? img.pngData()?.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

// MARK: - Pages

struct PagesSheet: View {
    @ObservedObject var model: PDFEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int?
    @State private var version = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14)], spacing: 14) {
                    ForEach(0..<model.doc.pageCount, id: \.self) { i in
                        if let page = model.doc.page(at: i) {
                            VStack(spacing: 4) {
                                Image(uiImage: page.thumbnail(of: CGSize(width: 200, height: 260), for: .cropBox))
                                    .resizable().scaledToFit().frame(height: 130)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected == i ? Color.phosphor : Color.stroke, lineWidth: selected == i ? 3 : 1))
                                Text("\(i + 1)").font(.caption.monospacedDigit())
                            }
                            .onTapGesture { selected = selected == i ? nil : i }
                        }
                    }
                }
                .padding()
                .id(version)
            }
            .navigationTitle("Pages").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { move(-1) } label: { Image(systemName: "arrow.left") }.disabled((selected ?? 0) == 0)
                    Spacer()
                    Button { move(1) } label: { Image(systemName: "arrow.right") }.disabled(selected == nil || selected! >= model.doc.pageCount - 1)
                    Spacer()
                    Button { rotate() } label: { Image(systemName: "rotate.right") }.disabled(selected == nil)
                    Spacer()
                    Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }.disabled(selected == nil)
                    Spacer()
                    Button { blank() } label: { Image(systemName: "doc.badge.plus") }
                    Spacer()
                    Button(role: .destructive) { delete() } label: { Image(systemName: "trash") }.disabled(selected == nil || model.doc.pageCount <= 1)
                }
            }
        }
    }

    private func changed() { version += 1; model.pagesChanged() }

    private func move(_ d: Int) {
        guard let i = selected, let p = model.doc.page(at: i) else { return }
        let j = i + d
        guard j >= 0, j < model.doc.pageCount else { return }
        model.doc.removePage(at: i)
        model.doc.insert(p, at: j)
        selected = j; changed()
    }
    private func rotate() {
        guard let i = selected, let p = model.doc.page(at: i) else { return }
        p.rotation = (p.rotation + 90) % 360; changed()
    }
    private func duplicate() {
        guard let i = selected, let p = model.doc.page(at: i)?.copy() as? PDFPage else { return }
        model.doc.insert(p, at: i + 1); selected = i + 1; changed()
    }
    private func blank() {
        let size = model.doc.page(at: 0)?.bounds(for: .mediaBox).size ?? CGSize(width: 612, height: 792)
        let img = UIGraphicsImageRenderer(size: size).image { c in UIColor.white.setFill(); c.fill(CGRect(origin: .zero, size: size)) }
        guard let p = PDFPage(image: img) else { return }
        let at = (selected ?? model.doc.pageCount - 1) + 1
        model.doc.insert(p, at: at); selected = at; changed()
    }
    private func delete() {
        guard let i = selected, model.doc.pageCount > 1 else { return }
        model.doc.removePage(at: i); selected = nil; changed()
    }
}
