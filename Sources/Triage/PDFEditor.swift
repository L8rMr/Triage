import SwiftUI
import AppKit
import PDFKit
import Vision
import CoreText

// MARK: - Tools and ribbon

enum PDFTool: String, CaseIterable, Identifiable {
    case select, editText, editArea, addText, addImage, eyedropper, crop, highlight, note, ink, rect, sign, redact
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: return "Select"
        case .editText: return "Edit Text"
        case .editArea: return "Edit Area"
        case .addText: return "Add Text"
        case .addImage: return "Add Image"
        case .eyedropper: return "Copy Style"
        case .crop: return "Crop"
        case .highlight: return "Highlight"
        case .note: return "Note"
        case .ink: return "Draw"
        case .rect: return "Box"
        case .sign: return "Sign"
        case .redact: return "Redact"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .editText: return "character.cursor.ibeam"
        case .editArea: return "rectangle.dashed"
        case .addText: return "textformat"
        case .addImage: return "photo.badge.plus"
        case .eyedropper: return "eyedropper"
        case .crop: return "crop"
        case .highlight: return "highlighter"
        case .note: return "note.text"
        case .ink: return "pencil.tip"
        case .rect: return "rectangle"
        case .sign: return "signature"
        case .redact: return "rectangle.fill"
        }
    }
    var hint: String {
        switch self {
        case .select: return "Select text or click a mark. Drag images and added text to move them; Delete removes."
        case .editText: return "Every paragraph is outlined. Click one to edit it in place — the font, size and color are matched, even on scans."
        case .editArea: return "Drag a box around exactly what you want to change. It's erased into the paper, you type the new text, and it blends in when you click away."
        case .addText: return "Click anywhere to type. Uses the style from Copy Style, or the last one you used."
        case .addImage: return "Click where the image should go, then pick a file. Drag the corner to resize."
        case .eyedropper: return "Click any text to copy its exact font, size and color for new text."
        case .crop: return "Drag the area to keep on this page."
        case .highlight: return "Drag across text to highlight it."
        case .note: return "Click to pin a sticky note."
        case .ink: return "Drag to draw freehand."
        case .rect: return "Drag to draw a box."
        case .sign: return "Click to place your signature."
        case .redact: return "Drag over anything private, then Apply Redactions to remove it for good."
        }
    }
}

enum RibbonTab: String, CaseIterable, Identifiable {
    case edit = "Edit", comment = "Comment", organize = "Organize", protect = "Protect", scan = "Scan & OCR", export = "Export"
    var id: String { rawValue }
    var tools: [PDFTool] {
        switch self {
        case .edit: return [.select, .editText, .editArea, .addText, .addImage, .eyedropper, .crop]
        case .comment: return [.select, .highlight, .note, .ink, .rect, .sign]
        case .protect: return [.select, .redact]
        default: return [.select]
        }
    }
}

struct NoteRequest: Identifiable {
    let id = UUID()
    let page: PDFPage
    let point: CGPoint
    var existing: PDFAnnotation?
    var text: String
}

// MARK: - Model

final class PDFEditorModel: ObservableObject {
    /// One editor for the whole app, so leaving the page and coming back keeps your file and edits.
    static let shared = PDFEditorModel()
    @Published var doc: PDFDocument?
    @Published var url: URL?
    @Published var tool: PDFTool = .select {
        didSet {
            if oldValue != tool { commitEditing() }   // any tool change ends the edit, so nothing stays stuck "Editing"
            view?.editLayer.refresh()
            if tool == .editText || tool == .editArea { analyzeVisible() }   // Edit Area learns the page's fonts up front
        }
    }
    @Published var ribbon: RibbonTab = .edit { didSet { if oldValue != ribbon { commitEditing() } } }
    @Published var dirty = false
    @Published var status = ""
    @Published var selected: PDFAnnotation?
    @Published var busy: String?
    @Published var findText = ""
    @Published var matches: [PDFSelection] = []
    @Published var matchIndex = 0
    @Published var inkColor: Color = .red
    @Published var inkWidth: CGFloat = 2
    @Published var showSignPad = false
    @Published var pageLabel = ""
    @Published var note: NoteRequest?
    @Published var showWatermark = false
    @Published var showHeaderFooter = false
    @Published var showPassword = false

    // text editing
    @Published var format: TextFormat?               // what's under the cursor while editing
    @Published var fontMatches: [FontMatch] = []
    @Published var look = ScanLook()
    @Published var lookAvailable = false
    @Published var defaultFormat = TextFormat.fallback  // for Add Text
    @Published var copiedFormat: TextFormat?
    @Published var analyzing: Set<ObjectIdentifier> = []

    weak var view: EditorPDFView?
    var session: EditSession?
    var sessionStarted: Date?
    private var undo: [() -> Void] = []
    private var rasters: [ObjectIdentifier: PageRaster] = [:]
    var blocks: [ObjectIdentifier: [TextBlock]] = [:]

    var editing: Bool { session != nil }

    /// Drop the big page images; they are rebuilt on demand. Text blocks and matched fonts stay.
    func releaseMemory() { rasters.removeAll() }

    var signature: [[CGPoint]] {
        get { (UserDefaults.standard.array(forKey: "pdf.signature") as? [[[Double]]])?.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } } ?? [] }
        set { UserDefaults.standard.set(newValue.map { $0.map { [Double($0.x), Double($0.y)] } }, forKey: "pdf.signature") }
    }

    // MARK: open / save

    func open(_ u: URL) {
        commitEditing()
        guard let d = PDFDocument(url: u) else { status = "Couldn't open that PDF."; return }
        if d.isLocked {
            status = "This PDF is password-protected. Unlock it in Preview first."
        }
        doc = d; url = u; dirty = false; undo = []; selected = nil
        rasters = [:]; blocks = [:]
        status = d.isEncrypted ? "This PDF is protected; some edits may not save." : "\(d.pageCount) pages"
        if (d.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = "Looks like a scan. Edit Text works anyway: it reads the page and matches the font."
        }
        FontMatcher.warmUp()
        // start reading the first pages right away, so Edit Text is ready when you are
        for i in 0..<min(2, d.pageCount) { if let p = d.page(at: i), PageAnalyzer.isScan(p) { analyze(p) } }
    }

    var hasCustomEdits: Bool {
        guard let doc else { return false }
        for i in 0..<doc.pageCount { if doc.page(at: i)?.annotations.contains(where: PDFFlattener.isCustom) == true { return true } }
        return false
    }

    func save(as: Bool = false, options: [PDFDocumentWriteOption: Any] = [:], suffix: String? = nil) {
        commitEditing()
        guard let doc else { return }
        var dest = url
        if `as` || dest == nil || suffix != nil {
            let p = NSSavePanel()
            p.allowedContentTypes = [.pdf]
            let base = url?.deletingPathExtension().lastPathComponent ?? "Document"
            p.nameFieldStringValue = suffix.map { "\(base) (\($0)).pdf" } ?? (url?.lastPathComponent ?? "Document.pdf")
            guard p.runModal() == .OK, let u = p.url else { return }
            dest = u
        }
        guard let dest else { return }
        let keepPage = currentIndex ?? 0
        busy = "Saving…"
        let out = hasCustomEdits ? PDFFlattener.flatten(doc) : doc
        let ok = options.isEmpty ? out.write(to: dest) : out.write(to: dest, withOptions: options)
        busy = nil
        guard ok else { status = "Couldn't save."; return }
        if out !== doc && options[.userPasswordOption] == nil {
            open(dest)
            if let p = self.doc?.page(at: min(keepPage, (self.doc?.pageCount ?? 1) - 1)) { view?.go(to: p) }
        } else { url = dest; dirty = false }
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        status = "Saved \(dest.lastPathComponent) · \(Fmt.bytes(size))"
    }

    func compress() {
        var o: [PDFDocumentWriteOption: Any] = [:]
        o[.saveImagesAsJPEGOption] = true
        o[.optimizeImagesForScreenOption] = true
        save(options: o, suffix: "compressed")
    }

    func protect(open pw: String, owner: String) {
        var o: [PDFDocumentWriteOption: Any] = [:]
        if !pw.isEmpty { o[.userPasswordOption] = pw }
        o[.ownerPasswordOption] = owner.isEmpty ? (pw.isEmpty ? UUID().uuidString : pw) : owner
        save(options: o, suffix: "protected")
        status = "Saved a protected copy. Your open file is unchanged."
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf, .image]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let u = p.url else { return }
        if u.pathExtension.lowercased() == "pdf" { open(u) } else { openImage(u) }
    }

    func exportFlattened() {
        guard let doc else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.pdf]
        p.nameFieldStringValue = (url?.deletingPathExtension().lastPathComponent ?? "Document") + " (flattened).pdf"
        guard p.runModal() == .OK, let dest = p.url else { return }
        commitEditing()
        let flat = PDFFlattener.flatten(doc)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { return }
        for i in 0..<flat.pageCount {
            guard let page = flat.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            page.draw(with: .mediaBox, to: ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        _ = data.write(to: dest, atomically: true)
        status = "Exported \(dest.lastPathComponent) with every mark burned in."
    }

    func export(_ ext: String) {
        guard let doc else { return }
        commitEditing()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent((url?.deletingPathExtension().lastPathComponent ?? "Document") + ".pdf")
        _ = (hasCustomEdits ? PDFFlattener.flatten(doc) : doc).write(to: tmp)
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Export Here"
        guard p.runModal() == .OK, let dir = p.url else { return }
        busy = "Exporting…"
        DispatchQueue.global(qos: .userInitiated).async {
            let outs = (try? Converter.convert(tmp, to: ext, outDir: dir, quality: 0.9)) ?? []
            DispatchQueue.main.async {
                self.busy = nil
                self.status = outs.isEmpty ? "Export failed." : "Exported \(outs.count) file\(outs.count == 1 ? "" : "s")."
                if !outs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outs) }
            }
        }
    }

    // MARK: undo

    func pushUndo(_ f: @escaping () -> Void) { undo.append(f); dirty = true }
    func undoLast() {
        if editing { cancelEditing(); return }      // undo while typing = throw away this edit
        guard let f = undo.popLast() else { NSSound.beep(); return }
        f(); view?.needsDisplay = true; view?.editLayer.needsDisplay = true
        status = "Undone"
    }

    func add(_ a: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(a)
        pushUndo { [weak page] in page?.removeAnnotation(a) }
    }

    func remove(_ a: PDFAnnotation) {
        guard let page = a.page else { return }
        page.removeAnnotation(a)
        pushUndo { [weak page] in page?.addAnnotation(a) }
        if selected === a { selected = nil }
    }

    // MARK: markup

    func markSelection(_ type: PDFAnnotationSubtype, color: NSColor) {
        guard let sel = view?.currentSelection else { status = "Select some text first."; return }
        var made: [(PDFAnnotation, PDFPage)] = []
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let a = PDFAnnotation(bounds: line.bounds(for: page), forType: type, withProperties: nil)
                a.color = color
                page.addAnnotation(a)
                made.append((a, page))
            }
        }
        pushUndo { made.forEach { $0.1.removeAnnotation($0.0) } }
        view?.clearSelection()
    }

    func saveNote(_ r: NoteRequest, text: String) {
        if let e = r.existing {
            let old = e.contents; e.contents = text
            pushUndo { e.contents = old }
        } else {
            let a = PDFAnnotation(bounds: CGRect(x: r.point.x, y: r.point.y, width: 20, height: 20), forType: .text, withProperties: nil)
            a.contents = text
            a.color = .systemYellow
            add(a, to: r.page)
        }
    }

    func openImage(_ u: URL) {
        commitEditing()
        guard let img = NSImage(contentsOf: u), let page = PDFPage(image: img) else { return }
        let d = PDFDocument(); d.insert(page, at: 0)
        doc = d; url = nil; dirty = true; rasters = [:]; blocks = [:]
        status = "Image opened as a PDF. Edit Text reads it and matches the font."
    }

    // MARK: text editing

    func raster(for page: PDFPage) -> PageRaster? {
        let k = ObjectIdentifier(page)
        if let r = rasters[k] { return r }
        let r = PageRaster(page: page, scale: 3)
        rasters[k] = r
        return r
    }

    func analyzeVisible() {
        guard let v = view, let doc else { return }
        for p in v.visiblePages { analyze(p) }
        // read ahead one page so scrolling down is instant
        if let last = v.visiblePages.last { let i = doc.index(for: last) + 1; if i < doc.pageCount, let next = doc.page(at: i) { analyze(next) } }
    }

    /// Finds the paragraphs on a page in the background, then outlines them.
    func analyze(_ page: PDFPage) {
        let k = ObjectIdentifier(page)
        guard blocks[k] == nil, !analyzing.contains(k) else { return }
        analyzing.insert(k)
        let scan = PageAnalyzer.isScan(page)
        if scan && tool == .editText { busy = "Reading the scan…" }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = PageRaster(page: page, scale: 3)
            let found = PageAnalyzer.blocks(page, raster: r)
            DispatchQueue.main.async {
                if let r { self.rasters[k] = r }
                self.blocks[k] = found
                self.analyzing.remove(k)
                if self.analyzing.isEmpty { self.busy = nil }
                if scan && self.tool == .editText { self.status = "Scan read: \(found.count) lines. Matching fonts in the background…" }
                self.view?.editLayer.needsDisplay = true
                if scan, let r { self.prepare(found, raster: r) }
            }
        }
    }

    /// Matches font, size and color for every scanned line ahead of time, so clicking one is instant.
    private func prepare(_ blocks: [TextBlock], raster: PageRaster) {
        let todo = blocks.filter { !$0.prepared }
        guard !todo.isEmpty else { return }
        Work.heavy.addOperation {
            var done = 0
            var copies: [(TextBlock, TextBlock, TextBlock)] = []   // original, first match, untouched inputs
            for b in todo {
                guard let page = b.page else { continue }
                // work on a copy, then hand the results over on the main thread
                let c = TextBlock(page: page, lines: b.lines, textRect: b.textRect, content: b.content, isScan: true)
                let raw = TextBlock(page: page, lines: b.lines, textRect: b.textRect, content: b.content, isScan: true)
                PageAnalyzer.match(c, raster: raster)
                var area = c.lines.reduce(c.lines.first ?? c.textRect) { $0.union($1) }
                let h = c.lines.first?.height ?? 10
                area = area.insetBy(dx: -max(3, h * 0.35), dy: -max(2, h * 0.15))
                let patch = PatchMaker.clean(raster, rect: area)
                done += 1
                let n = done
                DispatchQueue.main.async {
                    guard !b.prepared, b.annotation == nil else { return }
                    b.lines = c.lines; b.textRect = c.textRect; b.content = c.content
                    b.matches = c.matches; b.look = c.look; b.sample = c.sample
                    b.patch = patch; b.prepared = true
                    if self.tool == .editText && self.session == nil {
                        self.status = n == todo.count ? "Ready: every line on this page is matched. Click any line to edit it." : "Matching fonts… \(n) of \(todo.count)"
                    }
                    self.view?.editLayer.needsDisplay = true
                }
                copies.append((b, c, raw))
            }
            // second pass: the page's main typeface wins close calls, so a date doesn't come back in a stranger font
            var votes: [String: Double] = [:]
            for (_, c, _) in copies {
                let weight = Double(min(40, c.content.string.filter { $0.isLetter }.count))
                for m in c.matches.prefix(3) { votes[m.fontName, default: 0] += m.score * weight }
            }
            guard let house = votes.max(by: { $0.value < $1.value })?.key else { return }
            let fam: (String?) -> String? = { $0.flatMap { NSFont(name: $0, size: 12)?.familyName ?? $0 } }
            for (b, c, raw) in copies where fam(c.matches.first?.fontName) != fam(house) {
                let d = raw
                PageAnalyzer.match(d, raster: raster, prefer: house)
                guard fam(d.matches.first?.fontName) == fam(house) else { continue }
                DispatchQueue.main.async {
                    guard b.annotation == nil else { return }
                    b.lines = d.lines; b.textRect = d.textRect; b.content = d.content
                    b.matches = d.matches; b.look = d.look; b.sample = d.sample
                    self.view?.editLayer.needsDisplay = true
                }
            }
        }
    }

    func block(at pt: CGPoint, on page: PDFPage) -> TextBlock? {
        (blocks[ObjectIdentifier(page)] ?? []).first { $0.annotation == nil && !covered($0, on: page) && $0.area.insetBy(dx: -2, dy: -2).contains(pt) }
    }

    /// Original text that already sits under one of your edits: never offered again, so it can't overwrite the edit.
    func covered(_ b: TextBlock, on page: PDFPage) -> Bool {
        let mid = CGPoint(x: b.area.midX, y: b.area.midY)
        return page.annotations.contains { a in
            guard let r = a as? RichTextAnnotation, r !== b.annotation else { return false }
            return (r.patch != nil && r.patchRect.contains(mid)) || r.textRect.contains(mid)
        }
    }

    func richText(at pt: CGPoint, on page: PDFPage) -> RichTextAnnotation? {
        page.annotations.compactMap { $0 as? RichTextAnnotation }.last { $0.textRect.insetBy(dx: -3, dy: -3).contains(pt) }
    }

    /// Click on original text: match it, erase it, and open an editor on top.
    func beginEditing(_ b: TextBlock, at click: CGPoint? = nil) {
        commitEditing()
        guard let page = b.page else { return }
        let raster = self.raster(for: page)
        if b.prepared {
            let a = RichTextAnnotation(textRect: b.textRect, content: b.content)
            if let p = b.patch { a.patch = p.0; a.patchRect = p.1 }
            a.look = b.look
            a.refreshBounds()
            page.addAnnotation(a)
            b.annotation = a
            startSession(a, page: page, matches: b.matches, isNew: true, scan: b.isScan, click: click)
            return
        }
        busy = b.isScan ? "Matching the font…" : nil
        let work = {
            if let raster { PageAnalyzer.match(b, raster: raster) }
            var patchArea = b.lines.reduce(b.lines.first ?? b.textRect) { $0.union($1) }
            let h = b.lines.first?.height ?? 10
            let pad = b.isScan ? max(2, h * 0.15) : 1
            patchArea = patchArea.insetBy(dx: b.isScan ? -max(3, h * 0.35) : -1, dy: -pad)
            let patch = raster.flatMap { PatchMaker.clean($0, rect: patchArea) }
            DispatchQueue.main.async {
                self.busy = nil
                let a = RichTextAnnotation(textRect: b.textRect, content: b.content)
                if let p = patch { a.patch = p.0; a.patchRect = p.1 }
                a.look = b.look
                a.refreshBounds()
                page.addAnnotation(a)
                b.annotation = a
                self.startSession(a, page: page, matches: b.matches, isNew: true, scan: b.isScan, click: click)
            }
        }
        if b.isScan { DispatchQueue.global(qos: .userInitiated).async(execute: work) } else { work() }
    }

    func beginEditing(_ a: RichTextAnnotation, page: PDFPage, at click: CGPoint? = nil) {
        commitEditing()
        let fam = a.content.length > 0 ? (a.content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName : nil
        startSession(a, page: page, matches: fam.map { [FontMatch(fontName: $0, score: 1)] } ?? [], isNew: false, scan: a.patch != nil && a.look.enabled, click: click)
    }

    /// You draw the box: read the text inside it, erase exactly that area into the paper, match the font, and edit.
    func editArea(_ rect: CGRect, on page: PDFPage) {
        commitEditing()
        guard let raster = self.raster(for: page) else { status = "Couldn't read this page."; return }
        let scan = PageAnalyzer.isScan(page)
        analyze(page)
        busy = "Reading the area…"
        DispatchQueue.global(qos: .userInitiated).async {
            // the page's own lines tell us its typeface; one line alone can fool the matcher (a sans line read as a slab serif)
            let k = ObjectIdentifier(page)
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                let ready = DispatchQueue.main.sync { () -> Bool in
                    guard let list = self.blocks[k] else { return false }
                    return list.isEmpty || list.allSatisfy { $0.prepared || $0.annotation != nil }
                }
                if ready { break }
                DispatchQueue.main.async { self.busy = "Learning this page's fonts…" }
                Thread.sleep(forTimeInterval: 0.25)
            }
            DispatchQueue.main.async { self.busy = "Reading the area…" }
            let b = PageAnalyzer.areaBlock(page, rect: rect, raster: raster)
            // lines the page analysis already matched (they saw the whole line, with context) beat a fresh guess from a box
            let known: [TextBlock] = DispatchQueue.main.sync {
                (self.blocks[k] ?? []).filter { blk in
                    guard blk.prepared, blk.annotation == nil, blk.content.length > 0 else { return false }
                    let i = blk.area.intersection(rect)
                    return !i.isNull && i.width * i.height > blk.area.width * blk.area.height * 0.25
                }
            }
            if let main = known.max(by: { $0.content.length < $1.content.length }) {
                let style = main.content.attributes(at: 0, effectiveRange: nil)
                let text = b.content.length > 0 ? b.content.string : known.map(\.content.string).joined(separator: "\n")
                b.content = NSAttributedString(string: text, attributes: style)
                b.lines = known.flatMap(\.lines) + b.lines
                b.textRect = known.map(\.textRect).reduce(main.textRect) { $0.union($1) }
                b.matches = main.matches; b.look = main.look
            } else if !b.lines.isEmpty {
                PageAnalyzer.match(b, raster: raster, prefer: self.pageFont(page, raster: raster))
            }
            if b.content.length == 0 || b.lines.isEmpty {
                // nothing readable inside: an empty box in the page's own font, sized to the area
                let size = max(6, min(rect.height * 0.7, 36)).rounded(toPlaces: 1)
                let name = self.pageFont(page, raster: raster) ?? "Helvetica"
                b.content = NSAttributedString(string: "", attributes: TextFormat(fontName: name, size: size, color: .black).attributes())
                b.textRect = rect
            }
            // the whole box you drew becomes paper, so nothing of the old text peeks out
            let wipe = b.lines.reduce(rect) { $0.union($1.insetBy(dx: -2, dy: -2)) }
            b.patch = PatchMaker.clean(raster, rect: wipe)
            b.look.enabled = true
            if !scan { b.look.softness = min(b.look.softness, 0.2); b.look.grain = 0 }   // digital page: match it without fake grain
            b.prepared = true
            DispatchQueue.main.async {
                self.busy = nil
                self.beginEditing(b)
            }
        }
    }

    /// The typeface most of this page is set in, from the lines already matched (nil before any are).
    func pageFont(_ page: PDFPage, raster: PageRaster) -> String? {
        var votes: [String: Double] = [:]
        let list = DispatchQueue.main.sync { blocks[ObjectIdentifier(page)] ?? [] }
        for b in list where b.prepared {
            let w = Double(min(40, b.content.string.filter { $0.isLetter }.count))
            for m in b.matches.prefix(3) { votes[m.fontName, default: 0] += m.score * w }
        }
        return votes.max { $0.value < $1.value }?.key
    }

    func addText(at pt: CGPoint, on page: PDFPage, text: String = "") {
        commitEditing()
        let f = copiedFormat ?? defaultFormat
        let lineH = f.font.ascender - f.font.descender + f.font.leading
        let r = CGRect(x: pt.x, y: pt.y - lineH, width: 220, height: lineH + 2)
        let a = RichTextAnnotation(textRect: r, content: NSAttributedString(string: text, attributes: f.attributes()))
        a.kind = "added"
        page.addAnnotation(a)
        if tool != .editText && tool != .addText { tool = .addText }
        startSession(a, page: page, matches: [], isNew: true, scan: false)
        session?.typing = f.attributes()
    }

    private func startSession(_ a: RichTextAnnotation, page: PDFPage, matches: [FontMatch], isNew: Bool, scan: Bool, click: CGPoint? = nil) {
        guard let layer = view?.editLayer else { return }
        let s = EditSession(annotation: a, page: page, model: self, isNew: isNew)
        session = s
        sessionStarted = Date()
        fontMatches = matches
        look = a.look
        lookAvailable = scan || a.patch != nil
        layer.attach(s, click: click)
        format = s.currentFormat
        if scan, let best = matches.first {
            status = "Matched \(best.display) at \(Int(best.score * 100))% · \(s.currentFormat.label). Type to replace; change anything on the right."
        } else {
            status = "Editing. Select letters to style just those, or change the whole box with nothing selected."
        }
        objectWillChange.send()
    }

    func commitEditing() {
        guard let s = session else { return }
        session = nil
        s.finish()
        let a = s.annotation
        func styles(_ t: NSAttributedString) -> [TextFormat] {
            var out: [TextFormat] = []
            t.enumerateAttributes(in: NSRange(location: 0, length: t.length)) { at, _, _ in out.append(TextFormat.from(at)) }
            return out
        }
        let changed = a.content.string != s.original.content.string || styles(a.content) != styles(s.original.content)
            || s.moved || a.look != s.original.look
        if s.isNew && !changed && a.kind == "edit" {
            // nothing changed: put the original back
            s.page?.removeAnnotation(a)
            if let p = s.page { blocks[ObjectIdentifier(p)]?.first { $0.annotation === a }?.annotation = nil }
        } else if s.isNew && a.kind == "added" && a.content.length == 0 {
            s.page?.removeAnnotation(a)
        } else if changed {
            dirty = true
            let page = s.page
            if s.isNew {
                pushUndo { [weak self] in
                    page?.removeAnnotation(a)
                    if let p = page { self?.blocks[ObjectIdentifier(p)]?.first { $0.annotation === a }?.annotation = nil }
                }
            } else {
                let o = s.original
                pushUndo { a.setContent(o.content); a.textRect = o.rect; a.look = o.look }
            }
        }
        status = changed ? "Edit kept. ⌘S saves it to the file." : tool.hint
        format = nil
        fontMatches = []
        lookAvailable = false
        view?.editLayer.detach()
        view?.needsDisplay = true
        objectWillChange.send()
    }

    func cancelEditing() {
        guard let s = session else { return }
        let o = s.original
        s.annotation.setContent(o.content); s.annotation.textRect = o.rect; s.annotation.look = o.look
        s.textView.textStorage?.setAttributedString(o.content)
        if s.isNew {
            session = nil; s.finish()
            s.page?.removeAnnotation(s.annotation)
            if let p = s.page { blocks[ObjectIdentifier(p)]?.first { $0.annotation === s.annotation }?.annotation = nil }
            format = nil; fontMatches = []; lookAvailable = false
            view?.editLayer.detach(); view?.needsDisplay = true
            objectWillChange.send()
        } else { commitEditing() }
        status = "Edit discarded."
    }

    /// Live formatting from the Format panel.
    func applyFormat(_ change: @escaping (inout TextFormat) -> Void) {
        if let s = session {
            s.apply(change)
            format = s.currentFormat
            dirty = true
        } else {
            var f = copiedFormat ?? defaultFormat; change(&f)
            if copiedFormat != nil { copiedFormat = f } else { defaultFormat = f }
        }
    }

    func setLook(_ l: ScanLook) {
        look = l
        session?.annotation.look = l
        session?.preview()
    }

    func eraseText(_ b: TextBlock) {
        guard let page = b.page, let r = raster(for: page) else { return }
        let area = b.lines.reduce(b.lines.first ?? b.textRect) { $0.union($1) }.insetBy(dx: -2, dy: -2)
        guard let cleaned = PatchMaker.clean(r, rect: area) else { return }
        let (img, rect) = cleaned
        let a = RichTextAnnotation(textRect: b.textRect, content: NSAttributedString())
        a.patch = img; a.patchRect = rect; a.refreshBounds()
        page.addAnnotation(a); b.annotation = a
        pushUndo { [weak page] in page?.removeAnnotation(a); b.annotation = nil }
        view?.editLayer.needsDisplay = true
        status = "Text erased. The paper behind it was filled in."
    }

    func revertEdit(_ a: RichTextAnnotation) {
        guard let page = a.page else { return }
        if session?.annotation === a { session = nil; view?.editLayer.detach() }
        page.removeAnnotation(a)
        blocks[ObjectIdentifier(page)]?.first { $0.annotation === a }?.annotation = nil
        pushUndo { [weak page] in page?.addAnnotation(a) }
        view?.editLayer.needsDisplay = true
        status = "Back to the original."
    }

    /// Eyedropper: exact style of the text under the pointer.
    func copyStyle(at pt: CGPoint, on page: PDFPage) {
        if let a = richText(at: pt, on: page), a.content.length > 0 {
            copiedFormat = TextFormat.from(a.content.attributes(at: 0, effectiveRange: nil))
        } else if let b = block(at: pt, on: page) {
            if b.isScan, let r = raster(for: page) {
                busy = "Matching the font…"
                DispatchQueue.global(qos: .userInitiated).async {
                    PageAnalyzer.match(b, raster: r)
                    let f = TextFormat.from(b.content.attributes(at: 0, effectiveRange: nil))
                    DispatchQueue.main.async { self.busy = nil; self.copiedFormat = f; self.status = "Copied style: \(f.label). Add Text uses it." }
                }
                return
            }
            copiedFormat = TextFormat.from(b.content.attributes(at: 0, effectiveRange: nil))
        } else if let sel = page.selectionForLine(at: pt), let a = sel.attributedString, a.length > 0 {
            copiedFormat = TextFormat.from(a.attributes(at: 0, effectiveRange: nil))
        } else {
            status = "No text there."; return
        }
        if let f = copiedFormat {
            status = "Copied style: \(f.label). Add Text uses it."
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(f.font.fontName, forType: .string)
        }
    }

    func applyCopiedStyle() {
        guard let f = copiedFormat else { status = "Copy a style first."; return }
        applyFormat { $0 = f }
    }

    // MARK: images, watermark, header & footer, crop

    func placeImage(at pt: CGPoint, on page: PDFPage) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url, let img = OCR.cgImage(u) else { return }
        let w = min(CGFloat(img.width) / 2, 220), h = w * CGFloat(img.height) / CGFloat(img.width)
        let a = ImageStampAnnotation(image: img, rect: CGRect(x: pt.x - w / 2, y: pt.y - h / 2, width: w, height: h))
        add(a, to: page)
        selected = a
        tool = .select
        status = "Image placed. Drag to move, drag its bottom-right corner to resize."
    }

    func addWatermark(_ text: String, size: CGFloat, color: NSColor, opacity: CGFloat, angle: CGFloat) {
        guard let doc, !text.isEmpty else { return }
        var made: [(RichTextAnnotation, PDFPage)] = []
        var f = TextFormat(fontName: "Helvetica-Bold", size: size, color: color)
        f.alignment = .center
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            let h = size * 1.3
            let r = CGRect(x: box.midX - box.width * 0.6, y: box.midY - h / 2, width: box.width * 1.2, height: h)
            let a = RichTextAnnotation(textRect: r, content: NSAttributedString(string: text, attributes: f.attributes()))
            a.kind = "watermark"; a.opacity = opacity; a.rotation = angle; a.refreshBounds()
            page.addAnnotation(a); made.append((a, page))
        }
        pushUndo { made.forEach { $0.1.removeAnnotation($0.0) } }
        status = "Watermark added to \(made.count) pages."
    }

    func addHeaderFooter(_ slots: [String], size: CGFloat, margin: CGFloat, startAt: Int) {
        guard let doc else { return }
        var made: [(RichTextAnnotation, PDFPage)] = []
        let n = doc.pageCount
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
        let file = url?.deletingPathExtension().lastPathComponent ?? "Document"
        for i in 0..<n {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            for (k, raw) in slots.enumerated() where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                let text = raw.replacingOccurrences(of: "<<page>>", with: "\(i + startAt)")
                    .replacingOccurrences(of: "<<pages>>", with: "\(n + startAt - 1)")
                    .replacingOccurrences(of: "<<date>>", with: date)
                    .replacingOccurrences(of: "<<file>>", with: file)
                var f = TextFormat(fontName: "Helvetica", size: size, color: .black)
                f.alignment = [NSTextAlignment.left, .center, .right][k % 3]
                let h = size * 1.4
                let y = k < 3 ? box.maxY - margin - h : box.minY + margin
                let r = CGRect(x: box.minX + margin, y: y, width: box.width - margin * 2, height: h)
                let a = RichTextAnnotation(textRect: r, content: NSAttributedString(string: text, attributes: f.attributes()))
                a.kind = "header"
                page.addAnnotation(a); made.append((a, page))
            }
        }
        pushUndo { made.forEach { $0.1.removeAnnotation($0.0) } }
        status = "Added header & footer to \(n) pages."
    }

    func crop(_ page: PDFPage, to r: CGRect) {
        guard r.width > 20, r.height > 20 else { return }
        let old = page.bounds(for: .cropBox)
        page.setBounds(r, for: .cropBox)
        pushUndo { page.setBounds(old, for: .cropBox) }
        view?.layoutDocumentView()
        status = "Page cropped. Undo brings it back."
    }

    func placeSignature(on page: PDFPage, at p: CGPoint) {
        let strokes = signature
        guard !strokes.isEmpty else { showSignPad = true; return }
        let size = CGSize(width: 180, height: 70)
        let origin = CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2)
        let a = PDFAnnotation(bounds: page.bounds(for: .mediaBox), forType: .ink, withProperties: nil)
        a.color = NSColor(red: 0.05, green: 0.1, blue: 0.35, alpha: 1)
        let border = PDFBorder(); border.lineWidth = 1.6; a.border = border
        for s in strokes where s.count > 1 {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: origin.x + s[0].x * size.width, y: origin.y + (1 - s[0].y) * size.height))
            for pt in s.dropFirst() { path.line(to: CGPoint(x: origin.x + pt.x * size.width, y: origin.y + (1 - pt.y) * size.height)) }
            a.add(path)
        }
        add(a, to: page)
        status = "Signature placed. Drag a Box tool around it if you want a frame."
    }

    // MARK: pages

    var currentIndex: Int? { view?.currentPage.flatMap { doc?.index(for: $0) } }

    func rotate(_ deg: Int) {
        guard let page = view?.currentPage else { return }
        page.rotation = (page.rotation + deg + 360) % 360
        pushUndo { page.rotation = (page.rotation - deg + 360) % 360 }
        view?.layoutDocumentView()
    }

    func deletePage() {
        guard let doc, doc.pageCount > 1, let i = currentIndex, let page = doc.page(at: i) else { return }
        doc.removePage(at: i)
        pushUndo { doc.insert(page, at: i) }
    }

    func insertBlank() {
        guard let doc else { return }
        let i = (currentIndex ?? -1) + 1
        let page = PDFPage()
        page.setBounds(doc.page(at: max(i - 1, 0))?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        doc.insert(page, at: i)
        pushUndo { [weak doc] in if let d = doc, let j = Optional(d.index(for: page)), j < d.pageCount { d.removePage(at: j) } }
    }

    func movePage(_ d: Int) {
        guard let doc, let i = currentIndex, i + d >= 0, i + d < doc.pageCount else { return }
        doc.exchangePage(at: i, withPageAt: i + d)
        pushUndo { doc.exchangePage(at: i, withPageAt: i + d) }
        if let p = doc.page(at: i + d) { view?.go(to: p) }
    }

    func insertFile() {
        guard let doc else { return }
        let p = NSOpenPanel(); p.allowedContentTypes = [.pdf, .image]; p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        var at = (currentIndex ?? doc.pageCount - 1) + 1
        var added: [PDFPage] = []
        for u in p.urls {
            if let other = PDFDocument(url: u) {
                for j in 0..<other.pageCount { if let pg = other.page(at: j)?.copy() as? PDFPage { doc.insert(pg, at: at); added.append(pg); at += 1 } }
            } else if let img = NSImage(contentsOf: u), let pg = PDFPage(image: img) {
                doc.insert(pg, at: at); added.append(pg); at += 1
            }
        }
        pushUndo { for pg in added { let j = doc.index(for: pg); if j < doc.pageCount { doc.removePage(at: j) } } }
        status = "Inserted \(added.count) page\(added.count == 1 ? "" : "s")"
    }

    func extractPage() {
        guard let doc, let i = currentIndex, let page = doc.page(at: i)?.copy() as? PDFPage else { return }
        let out = PDFDocument(); out.insert(page, at: 0)
        let p = NSSavePanel(); p.allowedContentTypes = [.pdf]
        p.nameFieldStringValue = (url?.deletingPathExtension().lastPathComponent ?? "Page") + " – page \(i + 1).pdf"
        if p.runModal() == .OK, let u = p.url { _ = out.write(to: u); status = "Saved page \(i + 1) as \(u.lastPathComponent)" }
    }

    // MARK: find

    func find() {
        guard let doc, !findText.isEmpty else { matches = []; view?.highlightedSelections = nil; return }
        matches = doc.findString(findText, withOptions: [.caseInsensitive, .diacriticInsensitive])
        matches.forEach { $0.color = NSColor.systemYellow.withAlphaComponent(0.5) }
        view?.highlightedSelections = matches
        matchIndex = 0
        if let f = matches.first { view?.go(to: f); view?.setCurrentSelection(f, animate: true) }
        status = matches.isEmpty ? "No matches. If this is a scan, Recognize Text first." : "\(matches.count) matches"
    }

    func nextMatch(_ d: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + d + matches.count) % matches.count
        view?.go(to: matches[matchIndex]); view?.setCurrentSelection(matches[matchIndex], animate: true)
    }

    // MARK: OCR + redaction

    static func searchablePage(_ page: PDFPage, image: CGImage) -> PDFPage? {
        let obs = OCR.observations(image)
        var box = page.bounds(for: .mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        page.draw(with: .mediaBox, to: ctx)
        ctx.setTextDrawingMode(.invisible)
        for o in obs {
            guard let c = o.topCandidates(1).first else { continue }
            let bb = o.boundingBox
            let r = CGRect(x: box.minX + bb.minX * box.width, y: box.minY + bb.minY * box.height,
                           width: bb.width * box.width, height: bb.height * box.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, max(r.height * 0.85, 1), nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: c.string, attributes: [.font: font]))
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: w > 0 ? r.width / w : 1, y: 1)
            ctx.textPosition = CGPoint(x: r.minX, y: r.minY + r.height * 0.15)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    func recognizeText(force: Bool = false) {
        guard let doc else { return }
        busy = "Recognizing text…"
        let count = doc.pageCount
        DispatchQueue.global(qos: .userInitiated).async {
            var replaced = 0
            for i in 0..<count {
                guard let page = doc.page(at: i) else { continue }
                let existing = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if existing.count > 30 && !force { continue }
                DispatchQueue.main.async { self.busy = "Recognizing text… page \(i + 1) of \(count)" }
                guard let img = OCR.render(page, scale: 3), let newPage = Self.searchablePage(page, image: img) else { continue }
                DispatchQueue.main.sync {
                    self.rasters = [:]; self.blocks = [:]
                    // carry every mark and edit over to the rebuilt page
                    for a in page.annotations { page.removeAnnotation(a); newPage.addAnnotation(a) }
                    doc.removePage(at: i)
                    doc.insert(newPage, at: i)
                }
                replaced += 1
            }
            DispatchQueue.main.async {
                self.busy = nil
                self.dirty = self.dirty || replaced > 0
                self.status = replaced == 0 ? "Every page already has real text." :
                    "Recognized text on \(replaced) page\(replaced == 1 ? "" : "s"). You can now search, select, copy and edit it."
            }
        }
    }

    func copyAllText() {
        guard let doc else { return }
        busy = "Reading text…"
        DispatchQueue.global(qos: .userInitiated).async {
            var parts: [String] = []
            for i in 0..<doc.pageCount {
                guard let p = doc.page(at: i) else { continue }
                let t = (p.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count > 30 { parts.append(t) } else if let img = OCR.render(p) { parts.append(OCR.string(img)) }
            }
            let all = parts.joined(separator: "\n\n")
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(all, forType: .string)
                ClipboardStore.shared.remember(text: all, source: "PDF Editor")
                self.busy = nil
                self.status = "Copied \(all.count) characters of text."
            }
        }
    }

    func applyRedactions() {
        guard let doc else { return }
        var pages = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), page.annotations.contains(where: { $0.userName == "vitalos-redact" }) else { continue }
            // Burn the page into pixels so the hidden text is truly gone, then re-add searchable text for the rest.
            guard let img = PDFFlattener.renderWithEdits(page, scale: 3) else { continue }
            let ns = NSImage(cgImage: img, size: page.bounds(for: .mediaBox).size)
            guard let flat = PDFPage(image: ns) else { continue }
            let finished = Self.searchablePage(flat, image: img) ?? flat
            doc.removePage(at: i)
            doc.insert(finished, at: i)
            pages += 1
        }
        dirty = true
        status = pages == 0 ? "No redaction boxes yet. Use the Redact tool first." :
            "Redacted \(pages) page\(pages == 1 ? "" : "s"). The covered text is permanently removed once you save."
    }
}

// MARK: - Inline editing on the page

/// One text box being edited in place. The text view lives in page points and is scaled with the zoom.
final class EditSession: NSObject, NSTextViewDelegate {
    let annotation: RichTextAnnotation
    weak var page: PDFPage?
    weak var model: PDFEditorModel?
    let isNew: Bool
    let original: (content: NSAttributedString, rect: CGRect, look: ScanLook)
    let container = FlippedView()
    let textView: NSTextView
    var typing: [NSAttributedString.Key: Any]? { didSet { if let t = typing { textView.typingAttributes = t } } }
    private var fontWarned = false
    var moved = false

    init(annotation a: RichTextAnnotation, page: PDFPage, model: PDFEditorModel, isNew: Bool) {
        annotation = a; self.page = page; self.model = model; self.isNew = isNew
        original = (NSAttributedString(attributedString: a.content), a.textRect, a.look)
        let storage = NSTextStorage(attributedString: a.content)
        let lm = NSLayoutManager(); storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: CGSize(width: a.textRect.width, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        tc.widthTracksTextView = true
        lm.addTextContainer(tc)
        textView = NSTextView(frame: CGRect(origin: .zero, size: a.textRect.size), textContainer: tc)
        super.init()
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.insertionPointColor = .controlAccentColor
        textView.delegate = self
        if a.content.length > 0 { textView.typingAttributes = a.content.attributes(at: a.content.length - 1, effectiveRange: nil) }
        container.addSubview(textView)
        container.wantsLayer = true
        a.isEditing = true
    }

    var storage: NSTextStorage { textView.textStorage! }

    var currentFormat: TextFormat {
        let r = textView.selectedRange()
        let attrs: [NSAttributedString.Key: Any]
        if r.length > 0, r.location < storage.length { attrs = storage.attributes(at: r.location, effectiveRange: nil) }
        else if storage.length > 0 { attrs = storage.attributes(at: max(0, min(r.location, storage.length) - 1), effectiveRange: nil) }
        else { attrs = textView.typingAttributes }
        return TextFormat.from(attrs, fallback: model?.defaultFormat ?? .fallback)
    }

    func apply(_ change: (inout TextFormat) -> Void) {
        var r = textView.selectedRange()
        if r.length == 0 { r = NSRange(location: 0, length: storage.length) }
        if r.length > 0, textView.shouldChangeText(in: r, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttributes(in: r) { a, sub, _ in
                var f = TextFormat.from(a); change(&f)
                storage.setAttributes(f.attributes(), range: sub)
            }
            storage.endEditing()
            textView.didChangeText()
        }
        var t = TextFormat.from(textView.typingAttributes, fallback: currentFormat); change(&t)
        textView.typingAttributes = t.attributes()
        sync()
    }

    /// Copy the text view back into the annotation and grow the box to fit.
    func sync() {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        // never wrap a line you're editing: widen the box instead, like Acrobat
        let natural = storage.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        if natural + 2 > annotation.textRect.width {
            var r = annotation.textRect; r.size.width = natural + 2; annotation.textRect = r
            tc.size = CGSize(width: r.width, height: .greatestFiniteMagnitude)
            textView.setFrameSize(CGSize(width: r.width, height: textView.frame.height))
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let lineH = (textView.typingAttributes[.font] as? NSFont).map { $0.ascender - $0.descender + $0.leading } ?? 14
        let h = max(used, lineH) + 2
        var r = annotation.textRect
        if abs(r.height - h) > 0.5 { r.origin.y = r.maxY - h; r.size.height = h; annotation.textRect = r }
        annotation.setContent(NSAttributedString(attributedString: storage))
        model?.view?.editLayer.layoutSession()
    }

    func preview() { model?.view?.needsDisplay = true }

    func finish() {
        sync()
        annotation.isEditing = false
        container.removeFromSuperview()
    }

    // NSTextViewDelegate
    func textDidChange(_ n: Notification) {
        // PDFs often embed only the letters they use; swap in the installed font if a new letter is missing
        var swapped: String?
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { v, range, _ in
            guard let f = v as? NSFont else { return }
            let sub = (storage.string as NSString).substring(with: range)
            if let rep = FontMatcher.usable(f, for: sub) {
                storage.addAttribute(.font, value: rep, range: range)
                swapped = rep.displayName ?? rep.fontName
            }
        }
        if let s = swapped, !fontWarned {
            fontWarned = true
            model?.status = "This PDF only carries some letters of its font, so new letters use \(s), the closest installed match."
        }
        sync()
        model?.format = currentFormat
    }

    func textViewDidChangeSelection(_ n: Notification) {
        model?.format = currentFormat
    }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { model?.commitEditing(); return true }
        return false
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Sits over the pages: outlines editable paragraphs, hosts the inline editor, and handles move/resize.
final class EditLayer: NSView {
    weak var pdf: EditorPDFView?
    private(set) weak var session: EditSession?
    private var hover: CGRect?
    private var drag: (start: CGPoint, rect: CGRect, resize: Bool)?
    var isDragging: Bool { drag != nil }
    private var tracking: NSTrackingArea?

    var model: PDFEditorModel? { pdf?.model }

    func refresh() {
        guard let pdf, let doc = pdf.documentView else { return }
        if superview !== doc { removeFromSuperview(); doc.addSubview(self) }
        frame = doc.bounds
        autoresizingMask = [.width, .height]
        layoutSession()
        needsDisplay = true
    }

    func attach(_ s: EditSession, click: CGPoint? = nil) {
        refresh()
        session = s
        addSubview(s.container)
        layoutSession()
        window?.makeFirstResponder(s.textView)
        // caret goes where you clicked, like Acrobat (never select-all: typing would wipe the paragraph)
        var idx = s.storage.length
        if let c = click, let lm = s.textView.layoutManager, let tc = s.textView.textContainer, s.storage.length > 0 {
            lm.ensureLayout(for: tc)
            let p = CGPoint(x: c.x - s.annotation.textRect.minX, y: s.annotation.textRect.maxY - c.y)
            var frac: CGFloat = 0
            let g = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &frac)
            idx = lm.characterIndexForGlyph(at: g) + (frac > 0.5 ? 1 : 0)
        }
        s.textView.setSelectedRange(NSRange(location: min(idx, s.storage.length), length: 0))
        needsDisplay = true
    }

    func detach() { session = nil; needsDisplay = true }

    func layoutSession() {
        guard let s = session, let page = s.page else { return }
        let r = toLayer(s.annotation.textRect, page)
        s.container.frame = r
        s.container.bounds = CGRect(origin: .zero, size: s.annotation.textRect.size)
        s.textView.frame = CGRect(origin: .zero, size: s.annotation.textRect.size)
        s.textView.textContainer?.size = CGSize(width: s.annotation.textRect.width, height: .greatestFiniteMagnitude)
        needsDisplay = true
    }

    func toLayer(_ r: CGRect, _ page: PDFPage) -> CGRect {
        guard let pdf else { return r }
        return convert(pdf.convert(r, from: page), from: pdf)
    }
    func toPage(_ p: CGPoint) -> (PDFPage, CGPoint)? {
        guard let pdf else { return nil }
        let v = convert(p, to: pdf)
        guard let page = pdf.page(for: v, nearest: false) else { return nil }
        return (page, pdf.convert(v, to: page))
    }

    private var active: Bool { (model?.tool == .editText || model?.tool == .addText) || session != nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard active, !isHidden else { return nil }
        let p = convert(point, from: superview)
        if let s = session {
            if s.container.frame.contains(p) { return super.hitTest(point) }
            if s.container.frame.insetBy(dx: -9, dy: -9).contains(p) { return self }
        }
        guard model?.tool == .editText, let hit = toPage(p), let model else { return nil }
        let (page, pt) = hit
        if model.richText(at: pt, on: page) != nil || model.block(at: pt, on: page) != nil { return self }
        return nil
    }

    /// PDFKit's gesture handling often delivers clicks to the PDF view instead of this layer; it asks here first.
    func claims(_ e: NSEvent) -> Bool {
        guard let model, active else { return false }
        let p = convert(e.locationInWindow, from: nil)
        if let s = session, s.container.frame.insetBy(dx: -9, dy: -9).contains(p) { return true }
        guard model.tool == .editText, let hit = toPage(p) else { return false }
        return model.richText(at: hit.1, on: hit.0) != nil || model.block(at: hit.1, on: hit.0) != nil
    }

    func route(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let s = session, s.container.frame.contains(p) {
            window?.makeFirstResponder(s.textView)
            s.textView.mouseDown(with: e)
        } else { mouseDown(with: e) }
    }

    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
        super.updateTrackingAreas()
    }

    override func mouseMoved(with e: NSEvent) {
        guard model?.tool == .editText, let model else { if hover != nil { hover = nil; needsDisplay = true }; return }
        let p = convert(e.locationInWindow, from: nil)
        var h: CGRect?
        if let s = session, s.container.frame.insetBy(dx: -9, dy: -9).contains(p) && !s.container.frame.contains(p) {
            NSCursor.openHand.set()
        } else if let hit = toPage(p) {
            let (page, pt) = hit
            if let a = model.richText(at: pt, on: page) { h = toLayer(a.textRect, page) }
            else if let b = model.block(at: pt, on: page) { h = toLayer(b.area, page) }
            if h != nil { NSCursor.iBeam.set() }
        }
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseDown(with e: NSEvent) {
        guard let model else { return }
        let p = convert(e.locationInWindow, from: nil)
        if let s = session, let page = s.page, !s.container.frame.contains(p), s.container.frame.insetBy(dx: -9, dy: -9).contains(p) {
            let f = s.container.frame
            let corner = abs(p.x - f.maxX) < 12 && (abs(p.y - f.maxY) < 12 || abs(p.y - f.minY) < 12)
            drag = (p, s.annotation.textRect, corner)
            _ = page
            return
        }
        guard let hit = toPage(p) else { return }
        let (page, pt) = hit
        if let a = model.richText(at: pt, on: page) {
            if session?.annotation !== a { model.beginEditing(a, page: page, at: pt) }
        } else if let b = model.block(at: pt, on: page) {
            model.beginEditing(b, at: pt)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = drag, let s = session, let page = s.page, let pdf else { return }
        let p = convert(e.locationInWindow, from: nil)
        let a = pdf.convert(convert(d.start, to: pdf), to: page), b = pdf.convert(convert(p, to: pdf), to: page)
        var r = d.rect
        if d.resize { r.size.width = max(20, d.rect.width + (b.x - a.x)) }
        else { r.origin.x += b.x - a.x; r.origin.y += b.y - a.y }
        s.annotation.textRect = r
        s.moved = true
        layoutSession()
        s.sync()
        NSCursor.closedHand.set()
    }

    override func mouseUp(with e: NSEvent) { drag = nil }

    override func menu(for e: NSEvent) -> NSMenu? { pdf?.menu(for: e) }

    override func draw(_ dirty: NSRect) {
        guard let model, let pdf else { return }
        let accent = NSColor.controlAccentColor
        // your edits and placed images, drawn here so they look exactly as they'll save
        if let ctx = NSGraphicsContext.current?.cgContext {
            for page in pdf.visiblePages {
                let customs = page.annotations.filter(PDFFlattener.isCustom)
                guard !customs.isEmpty else { continue }
                let o = convert(pdf.convert(CGPoint(x: 0, y: 0), from: page), from: pdf)
                let u = convert(pdf.convert(CGPoint(x: 1, y: 1), from: page), from: pdf)
                ctx.saveGState()
                ctx.concatenate(CGAffineTransform(a: u.x - o.x, b: 0, c: 0, d: u.y - o.y, tx: o.x, ty: o.y))
                for a in customs {
                    if let t = a as? RichTextAnnotation { t.render(in: ctx, textToo: t !== session?.annotation) }
                    else if let i = a as? ImageStampAnnotation { i.render(in: ctx) }
                }
                ctx.restoreGState()
            }
        }
        guard model.tool == .editText || session != nil else { return }
        if model.tool == .editText {
            for page in pdf.visiblePages {
                let k = ObjectIdentifier(page)
                for b in model.blocks[k] ?? [] where b.annotation == nil && !model.covered(b, on: page) {
                    let r = toLayer(b.area, page).insetBy(dx: -2, dy: -2)
                    let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
                    path.lineWidth = 1
                    path.setLineDash([3, 3], count: 2, phase: 0)
                    accent.withAlphaComponent(0.45).setStroke(); path.stroke()
                }
                for a in page.annotations.compactMap({ $0 as? RichTextAnnotation }) where a !== session?.annotation && a.kind != "watermark" {
                    let r = toLayer(a.textRect, page).insetBy(dx: -2, dy: -2)
                    let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
                    path.lineWidth = 1
                    NSColor.systemGreen.withAlphaComponent(0.55).setStroke(); path.stroke()
                }
                if model.analyzing.contains(k) {
                    let pr = toLayer(page.bounds(for: pdf.displayBox), page)
                    let s = "Reading this page…" as NSString
                    s.draw(at: CGPoint(x: pr.minX + 12, y: pr.minY + 12), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: accent])
                }
            }
            if let h = hover {
                accent.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: h.insetBy(dx: -2, dy: -2), xRadius: 2, yRadius: 2).fill()
            }
        }
        if let s = session {
            let f = s.container.frame.insetBy(dx: -3, dy: -3)
            let path = NSBezierPath(rect: f); path.lineWidth = 1.5
            accent.setStroke(); path.stroke()
            for c in [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY)] {
                let h = NSBezierPath(rect: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
                NSColor.white.setFill(); h.fill(); accent.setStroke(); h.stroke()
            }
        }
    }
}

// MARK: - The canvas

final class EditorPDFView: PDFView {
    weak var model: PDFEditorModel?
    lazy var editLayer: EditLayer = { let l = EditLayer(); l.pdf = self; return l }()
    private var dragStart: CGPoint?
    private var dragPage: PDFPage?
    private var temp: PDFAnnotation?
    private var inkPath: NSBezierPath?
    private var moving: (a: PDFAnnotation, start: CGPoint, bounds: CGRect, resize: Bool, orig: CGRect)?

    private func locate(_ e: NSEvent) -> (PDFPage, CGPoint)? {
        let p = convert(e.locationInWindow, from: nil)
        guard let page = page(for: p, nearest: true) else { return nil }
        return (page, convert(p, to: page))
    }

    private static func isType(_ a: PDFAnnotation, _ sub: PDFAnnotationSubtype) -> Bool {
        let t = (a.type ?? "").replacingOccurrences(of: "/", with: "")
        return t == sub.rawValue.replacingOccurrences(of: "/", with: "")
    }

    override func layout() {
        super.layout()
        editLayer.refresh()
    }

    // never let the PDF view (or the editor living inside it) push the window wider
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { editLayer.needsDisplay = true } }
    }

    override func mouseDown(with e: NSEvent) {
        guard let model, let loc = locate(e) else { super.mouseDown(with: e); return }
        let (page, pt) = loc
        // the same click often arrives twice (once directly, once delayed by PDFKit's gesture handling)
        if let t = model.sessionStarted, Date().timeIntervalSince(t) < 0.4, model.editing { return }
        if let s = model.session, s.page === page, s.annotation.textRect.insetBy(dx: -6, dy: -6).contains(pt) { editLayer.route(e); return }
        if model.tool == .editText, model.richText(at: pt, on: page) != nil || model.block(at: pt, on: page) != nil { editLayer.route(e); return }
        if model.editing { model.commitEditing(); if model.tool == .editText { return } }
        switch model.tool {
        case .select:
            if let a = page.annotation(at: pt), !Self.isType(a, .widget), !Self.isType(a, .link) {
                model.selected = a
                if a is ImageStampAnnotation || (a as? RichTextAnnotation)?.kind == "added" || (a as? RichTextAnnotation)?.kind == "watermark" {
                    let corner = abs(pt.x - a.bounds.maxX) < 10 && abs(pt.y - a.bounds.minY) < 10
                    moving = (a, pt, a.bounds, corner && a is ImageStampAnnotation, (a as? RichTextAnnotation)?.textRect ?? a.bounds)
                    if e.clickCount == 2, let r = a as? RichTextAnnotation { model.beginEditing(r, page: page) }
                    return
                }
                if e.clickCount == 2 {
                    if let r = a as? RichTextAnnotation { model.tool = .editText; model.beginEditing(r, page: page) }
                    else if Self.isType(a, .text) { model.note = NoteRequest(page: page, point: pt, existing: a, text: a.contents ?? "") }
                }
                return
            }
            model.selected = nil
            super.mouseDown(with: e)
        case .editText:
            super.mouseDown(with: e)
        case .addText:
            if let a = model.richText(at: pt, on: page) { model.beginEditing(a, page: page) } else { model.addText(at: pt, on: page) }
        case .addImage:
            model.placeImage(at: pt, on: page)
        case .eyedropper:
            model.copyStyle(at: pt, on: page)
        case .note:
            model.note = NoteRequest(page: page, point: pt, existing: nil, text: "")
        case .sign:
            model.placeSignature(on: page, at: pt)
        case .highlight:
            super.mouseDown(with: e)
        case .editArea:
            if let a = model.richText(at: pt, on: page) { model.beginEditing(a, page: page); return }
            dragStart = pt; dragPage = page
        case .ink, .rect, .redact, .crop:
            dragStart = pt; dragPage = page
            if model.tool == .ink { inkPath = NSBezierPath(); inkPath?.move(to: pt) }
        }
    }

    override func mouseDragged(with e: NSEvent) {
        if editLayer.isDragging { editLayer.mouseDragged(with: e); return }
        if let m = moving, let page = m.a.page {
            let pt = convert(convert(e.locationInWindow, from: nil), to: page)
            var b = m.bounds
            if m.resize {
                let w = max(12, m.bounds.width + (pt.x - m.start.x))
                let h = m.a is ImageStampAnnotation ? w * m.bounds.height / max(m.bounds.width, 1) : m.bounds.height
                b = CGRect(x: m.bounds.minX, y: m.bounds.maxY - h, width: w, height: h)
            } else { b = m.bounds.offsetBy(dx: pt.x - m.start.x, dy: pt.y - m.start.y) }
            if let r = m.a as? RichTextAnnotation {
                r.textRect = m.orig.offsetBy(dx: pt.x - m.start.x, dy: pt.y - m.start.y)
            } else { m.a.bounds = b }
            needsDisplay = true
            return
        }
        guard let model, let start = dragStart, let page = dragPage else { super.mouseDragged(with: e); return }
        let pt = convert(convert(e.locationInWindow, from: nil), to: page)
        if let t = temp { page.removeAnnotation(t) }
        let a: PDFAnnotation
        if model.tool == .ink {
            inkPath?.line(to: pt)
            a = PDFAnnotation(bounds: page.bounds(for: .mediaBox), forType: .ink, withProperties: nil)
            if let p = inkPath { a.add(p) }
            a.color = NSColor(model.inkColor)
        } else {
            let r = CGRect(x: min(start.x, pt.x), y: min(start.y, pt.y), width: abs(pt.x - start.x), height: abs(pt.y - start.y))
            a = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
            switch model.tool {
            case .redact: a.color = .black; a.interiorColor = .black; a.userName = "vitalos-redact"
            case .crop, .editArea: a.color = .controlAccentColor; a.interiorColor = NSColor.controlAccentColor.withAlphaComponent(0.08); a.userName = "vitalos-crop"
            default: a.color = NSColor(model.inkColor)
            }
        }
        let b = PDFBorder(); b.lineWidth = model.tool == .crop || model.tool == .editArea ? 1 : model.inkWidth
        if model.tool == .crop || model.tool == .editArea { b.style = .dashed; b.dashPattern = [4, 3] }
        a.border = b
        page.addAnnotation(a)
        temp = a
    }

    override func mouseUp(with e: NSEvent) {
        if editLayer.isDragging { editLayer.mouseUp(with: e); return }
        if let m = moving {
            let a = m.a, old = m.orig
            if let r = a as? RichTextAnnotation {
                if r.textRect != old { model?.pushUndo { r.textRect = old } }
            } else if a.bounds != old { model?.pushUndo { a.bounds = old } }
            moving = nil
            return
        }
        if model?.tool == .highlight {
            super.mouseUp(with: e)
            if let s = currentSelection?.string, !s.isEmpty { model?.markSelection(.highlight, color: NSColor.systemYellow.withAlphaComponent(0.5)) }
            return
        }
        guard let model, dragStart != nil, let page = dragPage else { super.mouseUp(with: e); return }
        if model.tool == .crop, let t = temp {
            page.removeAnnotation(t)
            model.crop(page, to: t.bounds)
        } else if model.tool == .editArea, let t = temp {
            page.removeAnnotation(t)
            if t.bounds.width > 6 && t.bounds.height > 4 { model.editArea(t.bounds, on: page) }
        } else if let t = temp { model.pushUndo { [weak page] in page?.removeAnnotation(t) } }
        dragStart = nil; dragPage = nil; temp = nil; inkPath = nil
    }

    override func keyDown(with e: NSEvent) {
        if let model, let a = model.selected, !model.editing, e.keyCode == 51 || e.keyCode == 117 {
            if let r = a as? RichTextAnnotation, r.kind == "edit" { model.revertEdit(r) } else { model.remove(a) }
            return
        }
        super.keyDown(with: e)
    }

    /// Right-click: options for whatever is under the pointer.
    override func menu(for e: NSEvent) -> NSMenu? {
        guard let model, let loc = locate(e) else { return super.menu(for: e) }
        let (page, pt) = loc
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String? = nil, to m: NSMenu? = nil, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            (m ?? menu).addItem(item)
        }

        // Text you're editing right now
        if let s = model.session, s.annotation.textRect.contains(pt) || s.page === page && s.annotation.textRect.insetBy(dx: -8, dy: -8).contains(pt) {
            add("Done Editing", "checkmark") { model.commitEditing() }
            add("Discard Changes", "arrow.uturn.backward") { model.cancelEditing() }
            menu.addItem(.separator())
            let tv = s.textView
            add("Cut", "scissors") { tv.cut(nil) }
            add("Copy", "doc.on.doc") { tv.copy(nil) }
            add("Paste", "doc.on.clipboard") { tv.pasteAsPlainText(nil) }
            add("Select All") { tv.selectAll(nil) }
            menu.addItem(.separator())
            add("Bold", "bold") { model.applyFormat { $0 = $0.withTrait(.boldFontMask, on: !$0.isBold) } }
            add("Italic", "italic") { model.applyFormat { $0 = $0.withTrait(.italicFontMask, on: !$0.isItalic) } }
            add("Underline", "underline") { model.applyFormat { $0.underline.toggle() } }
            add("Bigger", "textformat.size.larger") { model.applyFormat { $0.size += 1 } }
            add("Smaller", "textformat.size.smaller") { model.applyFormat { $0.size = max(2, $0.size - 1) } }
            if !model.fontMatches.isEmpty {
                let fm = NSMenu()
                for m in model.fontMatches { add("\(m.display)  ·  \(Int(m.score * 100))%", to: fm) { model.applyFormat { $0.fontName = m.fontName } } }
                let it = NSMenuItem(title: "Matched Fonts", action: nil, keyEquivalent: ""); it.submenu = fm
                it.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
                menu.addItem(it)
            }
            if model.copiedFormat != nil { add("Apply Copied Style", "paintbrush") { model.applyCopiedStyle() } }
            add("Copy This Style", "eyedropper") { model.copiedFormat = s.currentFormat; model.status = "Copied style: \(s.currentFormat.label)" }
            return menu
        }

        // Edited text, added text, images
        if let r = model.richText(at: pt, on: page) {
            add("Edit Text", "character.cursor.ibeam") { model.tool = .editText; model.beginEditing(r, page: page) }
            add("Copy Its Style", "eyedropper") {
                if r.content.length > 0 { model.copiedFormat = TextFormat.from(r.content.attributes(at: 0, effectiveRange: nil)); model.status = "Copied style: \(model.copiedFormat!.label)" }
            }
            if r.kind == "edit" { add("Restore Original Text", "arrow.uturn.backward") { model.revertEdit(r) } }
            else { add("Delete", "trash") { model.remove(r) } }
            menu.addItem(.separator())
        } else if let a = page.annotation(at: pt), a is ImageStampAnnotation {
            model.selected = a
            add("Bring Forward", "square.2.layers.3d.top.filled") { page.removeAnnotation(a); page.addAnnotation(a) }
            add("Delete Image", "trash") { model.remove(a) }
            menu.addItem(.separator())
        } else if let b = model.block(at: pt, on: page) {
            add("Edit This Text", "character.cursor.ibeam") { model.tool = .editText; model.beginEditing(b) }
            add("Erase This Text", "eraser") { model.eraseText(b) }
            add("Copy Its Style", "eyedropper") { model.copyStyle(at: pt, on: page) }
            add("Copy Text", "doc.on.doc") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(b.content.string, forType: .string)
                ClipboardStore.shared.remember(text: b.content.string, source: "PDF Editor")
            }
            menu.addItem(.separator())
        } else if let a = page.annotation(at: pt), !Self.isType(a, .widget), !Self.isType(a, .link) {
            model.selected = a
            if Self.isType(a, .text) { add("Edit Note…", "note.text") { model.note = NoteRequest(page: page, point: pt, existing: a, text: a.contents ?? "") } }
            add("Change Color to Pen Color", "paintpalette") {
                let old = a.color; a.color = NSColor(model.inkColor)
                model.pushUndo { a.color = old }; self.needsDisplay = true
            }
            add("Delete Mark", "trash") { model.remove(a) }
            menu.addItem(.separator())
        }

        // Selected text
        if let sel = currentSelection, let s = sel.string, !s.isEmpty {
            add("Copy", "doc.on.doc") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
                ClipboardStore.shared.remember(text: s, source: "PDF Editor")
            }
            add("Highlight", "highlighter") { model.markSelection(.highlight, color: NSColor.systemYellow.withAlphaComponent(0.5)) }
            add("Underline", "underline") { model.markSelection(.underline, color: .systemBlue) }
            add("Strike Through", "strikethrough") { model.markSelection(.strikeOut, color: .systemRed) }
            add("Search the Web for “\(s.prefix(30))”", "magnifyingglass") {
                let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let u = URL(string: "https://www.google.com/search?q=\(q)") { NSWorkspace.shared.open(u) }
            }
            menu.addItem(.separator())
        }

        // Add something here
        add("Add Text Here", "textformat") { model.addText(at: pt, on: page) }
        add("Add Image Here…", "photo.badge.plus") { model.placeImage(at: pt, on: page) }
        add("Add Note Here", "note.text.badge.plus") { model.note = NoteRequest(page: page, point: pt, existing: nil, text: "") }
        add(model.signature.isEmpty ? "Set Up Signature…" : "Sign Here", "signature") { model.placeSignature(on: page, at: pt) }
        if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
            add("Paste Text Here", "doc.on.clipboard") { model.addText(at: pt, on: page, text: s) }
        }
        menu.addItem(.separator())

        // This page
        let pageMenu = NSMenu()
        add("Rotate Left", to: pageMenu) { self.go(to: page); model.rotate(-90) }
        add("Rotate Right", to: pageMenu) { self.go(to: page); model.rotate(90) }
        add("Insert Blank Page After", to: pageMenu) { self.go(to: page); model.insertBlank() }
        add("Insert File After…", to: pageMenu) { self.go(to: page); model.insertFile() }
        add("Move Up", to: pageMenu) { self.go(to: page); model.movePage(-1) }
        add("Move Down", to: pageMenu) { self.go(to: page); model.movePage(1) }
        add("Extract Page…", to: pageMenu) { self.go(to: page); model.extractPage() }
        add("Reset Crop", to: pageMenu) { page.setBounds(page.bounds(for: .mediaBox), for: .cropBox); self.layoutDocumentView() }
        pageMenu.addItem(.separator())
        add("Recognize Text in Document", to: pageMenu) { model.recognizeText() }
        add("Delete Page", to: pageMenu) { self.go(to: page); model.deletePage() }
        let pageItem = NSMenuItem(title: "Page \((document?.index(for: page) ?? 0) + 1)", action: nil, keyEquivalent: "")
        pageItem.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        pageItem.submenu = pageMenu
        menu.addItem(pageItem)

        let toolMenu = NSMenu()
        for t in PDFTool.allCases {
            let i = ClosureMenuItem(title: t.title) { model.tool = t; model.status = t.hint }
            i.state = model.tool == t ? .on : .off
            i.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)
            toolMenu.addItem(i)
        }
        let toolItem = NSMenuItem(title: "Tool", action: nil, keyEquivalent: "")
        toolItem.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)
        toolItem.submenu = toolMenu
        menu.addItem(toolItem)
        menu.addItem(.separator())
        add("Zoom In", "plus.magnifyingglass") { self.zoomIn(nil) }
        add("Zoom Out", "minus.magnifyingglass") { self.zoomOut(nil) }
        add("Fit to Window", "arrow.up.left.and.arrow.down.right") { self.autoScales = true }
        add("Undo", "arrow.uturn.backward") { model.undoLast() }
        return menu
    }
}

struct PDFCanvas: NSViewRepresentable {
    @ObservedObject var model: PDFEditorModel

    func makeNSView(context: Context) -> EditorPDFView {
        let v = EditorPDFView()
        v.model = model
        for o in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            v.setContentCompressionResistancePriority(.defaultLow, for: o)
            v.setContentHuggingPriority(.defaultLow, for: o)
        }
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = .underPageBackgroundColor
        model.view = v
        let nc = NotificationCenter.default
        nc.addObserver(forName: .PDFViewPageChanged, object: v, queue: .main) { [weak model, weak v] _ in
            guard let model, let v, let p = v.currentPage, let d = v.document else { return }
            model.pageLabel = "Page \(d.index(for: p) + 1) of \(d.pageCount)"
        }
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewDocumentChanged, .PDFViewDisplayModeChanged] {
            nc.addObserver(forName: name, object: v, queue: .main) { [weak v] _ in
                DispatchQueue.main.async { v?.editLayer.refresh() }
            }
        }
        nc.addObserver(forName: .PDFViewVisiblePagesChanged, object: v, queue: .main) { [weak model] _ in
            if model?.tool == .editText { model?.analyzeVisible() }
        }
        return v
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorPDFView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }

    func updateNSView(_ v: EditorPDFView, context: Context) {
        if v.document !== model.doc { v.document = model.doc; v.editLayer.refresh() }
        if model.view !== v { model.view = v }
    }
}

struct PDFThumbs: NSViewRepresentable {
    @ObservedObject var model: PDFEditorModel
    func makeNSView(context: Context) -> PDFThumbnailView {
        let t = PDFThumbnailView()
        t.thumbnailSize = CGSize(width: 110, height: 140)
        t.backgroundColor = .clear
        t.allowsDragging = true
        return t
    }
    func updateNSView(_ t: PDFThumbnailView, context: Context) {
        if t.pdfView !== model.view { t.pdfView = model.view }
    }
}

// MARK: - The page

struct PDFEditorView: View {
    @ObservedObject private var m = PDFEditorModel.shared
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            ribbon
            Rectangle().fill(Theme.stroke).frame(height: 0.5)
            if m.doc == nil {
                ToolPage(tool: .pdf) {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.richtext").font(.ui(size: 40)).foregroundStyle(Theme.accent)
                        Text("Drop a PDF or a scanned image here").font(.ui(size: 15, weight: .semibold))
                        Button("Open…") { m.openPanel() }.buttonStyle(.borderedProminent)
                        Text("Edit any paragraph in place, even on scans: the font, size, color and paper are matched so the change is invisible · restyle text live · add text, images, watermarks, headers and page numbers · highlight, notes, drawing · sign · real redaction · crop, rotate, reorder, insert and extract pages · OCR · password-protect · compress · export to Word, text or images")
                            .font(.ui(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .background(RoundedRectangle(cornerRadius: 14).strokeBorder(dropping ? Theme.accent : Theme.stroke, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                }
            } else {
                HStack(spacing: 0) {
                    PDFThumbs(model: m).frame(width: 140).background(.regularMaterial)
                    PDFCanvas(model: m).frame(minWidth: 200, maxWidth: .infinity)
                    Group {
                        if m.editing || m.tool == .addText || m.tool == .eyedropper { FormatPanel(m: m) } else { sidePanel }
                    }
                    .frame(width: 270).background(.regularMaterial)
                }
            }
            statusBar
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            if u.pathExtension.lowercased() == "pdf" { m.open(u) } else { m.openImage(u) }
            return true
        } isTargeted: { dropping = $0 }
        .onDisappear { m.commitEditing(); m.releaseMemory() }
        .sheet(item: $m.note) { r in NoteSheet(request: r, model: m) }
        .sheet(isPresented: $m.showSignPad) { SignaturePad(model: m) }
        .sheet(isPresented: $m.showWatermark) { WatermarkSheet(model: m) }
        .sheet(isPresented: $m.showHeaderFooter) { HeaderFooterSheet(model: m) }
        .sheet(isPresented: $m.showPassword) { PasswordSheet(model: m) }
    }

    // MARK: ribbon

    private var ribbon: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { m.commitEditing(); m.openPanel() } label: { Image(systemName: "folder") }.help("Open")
                Button { m.save() } label: { Image(systemName: "square.and.arrow.down") }.help("Save (⌘S)")
                    .keyboardShortcut("s", modifiers: .command).disabled(m.doc == nil)
                Button { m.undoLast() } label: { Image(systemName: "arrow.uturn.backward") }.help("Undo (⌘Z)")
                    .keyboardShortcut(m.editing ? nil : KeyboardShortcut("z", modifiers: .command))   // while typing, ⌘Z belongs to the text
                    .disabled(m.doc == nil)
                Divider().frame(height: 16)
                ForEach(RibbonTab.allCases) { t in
                    Button { m.ribbon = t; if !t.tools.contains(m.tool) { m.tool = .select } } label: {
                        Text(t.rawValue).font(.ui(size: 12, weight: m.ribbon == t ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(m.ribbon == t ? Theme.accent.opacity(0.15) : Color.clear, in: Capsule())
                            .foregroundStyle(m.ribbon == t ? Theme.accent : Color.primary)
                    }
                    .buttonStyle(.plain).disabled(m.doc == nil)
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in PDF", text: $m.findText).textFieldStyle(.plain).frame(width: 130).onSubmit { m.find() }
                    if !m.matches.isEmpty {
                        Text("\(m.matchIndex + 1)/\(m.matches.count)").font(.ui(size: 10)).foregroundStyle(.secondary)
                        Button { m.nextMatch(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        Button { m.nextMatch(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .disabled(m.doc == nil)
            }
            HStack(spacing: 6) {
                ForEach(m.ribbon.tools) { t in toolButton(t) }
                if !m.ribbon.tools.isEmpty { Divider().frame(height: 30).padding(.horizontal, 4) }
                ribbonActions
                Spacer()
            }
            .disabled(m.doc == nil)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.top, 44).padding(.bottom, 8)
    }

    private func toolButton(_ t: PDFTool) -> some View {
        Button { m.tool = t; m.status = t.hint } label: {
            VStack(spacing: 2) {
                Image(systemName: t.symbol).font(.ui(size: 13))
                Text(t.title).font(.ui(size: 9))
            }
            .frame(width: 58, height: 36)
            .background(m.tool == t ? Theme.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(m.tool == t ? Theme.accent : Color.primary)
        }
        .buttonStyle(.plain)
        .help(t.hint)
    }

    private func action(_ title: String, _ symbol: String, _ f: @escaping () -> Void) -> some View {
        Button { m.commitEditing(); f() } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.ui(size: 13))
                Text(title).font(.ui(size: 9)).lineLimit(1)
            }
            .frame(minWidth: 58).frame(height: 36)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var ribbonActions: some View {
        switch m.ribbon {
        case .edit:
            action("Watermark", "drop.halffull") { m.showWatermark = true }
            action("Header & Footer", "rectangle.topthird.inset.filled") { m.showHeaderFooter = true }
        case .comment:
            action("Underline", "underline") { m.markSelection(.underline, color: .systemBlue) }
            action("Strike", "strikethrough") { m.markSelection(.strikeOut, color: .systemRed) }
            action("Signature…", "signature") { m.showSignPad = true }
        case .organize:
            action("Rotate Left", "rotate.left") { m.rotate(-90) }
            action("Rotate Right", "rotate.right") { m.rotate(90) }
            action("Move Up", "arrow.up") { m.movePage(-1) }
            action("Move Down", "arrow.down") { m.movePage(1) }
            action("Blank Page", "doc.badge.plus") { m.insertBlank() }
            action("Insert / Combine", "doc.on.doc") { m.insertFile() }
            action("Extract", "doc.badge.arrow.up") { m.extractPage() }
            action("Delete", "trash") { m.deletePage() }
        case .protect:
            action("Apply Redactions", "checkmark.shield") { m.applyRedactions() }
            action("Password…", "lock") { m.showPassword = true }
        case .scan:
            action("Recognize Text", "text.viewfinder") { m.recognizeText() }
            action("Redo OCR", "arrow.clockwise") { m.recognizeText(force: true) }
            action("Copy All Text", "doc.on.clipboard") { m.copyAllText() }
        case .export:
            action("Save As", "square.and.arrow.down.on.square") { m.save(as: true) }
            action("Compress", "arrow.down.right.and.arrow.up.left") { m.compress() }
            action("Flattened", "square.3.layers.3d.down.right") { m.exportFlattened() }
            action("Word", "doc.text") { m.export("docx") }
            action("Text", "text.alignleft") { m.export("txt") }
            action("PNG", "photo") { m.export("png") }
            action("JPEG", "photo.on.rectangle") { m.export("jpg") }
        }
    }

    // MARK: side panel (when not editing text)

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Tool") {
                    Label(m.tool.title, systemImage: m.tool.symbol).font(.ui(size: 13, weight: .semibold))
                    Text(m.tool.hint).font(.ui(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if m.tool == .editText {
                        Text("Dashed boxes are original text. Green boxes are text you've changed.").font(.ui(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if [.ink, .rect, .highlight].contains(m.tool) || m.ribbon == .comment {
                    section("Pen") {
                        ColorPicker("Color", selection: $m.inkColor).font(.ui(size: 12))
                        HStack { Text("Width").font(.ui(size: 12)); Slider(value: $m.inkWidth, in: 1...8) }
                        Button("Set up signature…") { m.showSignPad = true }
                    }
                }
                if let a = m.selected {
                    section("Selected") {
                        Text(a is ImageStampAnnotation ? "Image" : (a is RichTextAnnotation ? "Text box" : (a.type ?? "Mark"))).font(.ui(size: 12))
                        if let img = a as? ImageStampAnnotation {
                            HStack { Text("Opacity").font(.ui(size: 12))
                                Slider(value: Binding(get: { img.opacity }, set: { img.opacity = $0; m.view?.needsDisplay = true }), in: 0.1...1) }
                        }
                        Button("Delete", role: .destructive) { m.remove(a) }
                    }
                }
                section("Pages") {
                    Text(m.pageLabel).font(.ui(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button { m.rotate(-90) } label: { Image(systemName: "rotate.left") }.help("Rotate left")
                        Button { m.rotate(90) } label: { Image(systemName: "rotate.right") }.help("Rotate right")
                        Button { m.movePage(-1) } label: { Image(systemName: "arrow.up") }.help("Move page up")
                        Button { m.movePage(1) } label: { Image(systemName: "arrow.down") }.help("Move page down")
                        Button { m.deletePage() } label: { Image(systemName: "trash") }.help("Delete page")
                    }
                }
                section("Scans") {
                    Text("Edit Text works on scans directly. Recognize Text also makes the whole file searchable.")
                        .font(.ui(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Recognize Text") { m.recognizeText() }
                }
            }
            .controlSize(.small)
            .padding(14)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            c()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let b = m.busy { ProgressView().controlSize(.small); Text(b).lineLimit(1).truncationMode(.tail) }
            else { Text(m.status).lineLimit(1).truncationMode(.tail) }
            Spacer()
            if m.dirty { Text("Edited").foregroundStyle(Theme.net) }
            if let u = m.url { Text(u.lastPathComponent).foregroundStyle(.secondary) }
        }
        .font(.ui(size: 11))
        .frame(minWidth: 0, maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.regularMaterial)
    }
}

// MARK: - Format panel (live)

struct FormatPanel: View {
    @ObservedObject var m: PDFEditorModel
    @State private var familyFilter = ""
    private static let families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }

    private var f: TextFormat { m.format ?? m.copiedFormat ?? m.defaultFormat }

    private func bind<V>(_ kp: WritableKeyPath<TextFormat, V>) -> Binding<V> {
        Binding(get: { f[keyPath: kp] }, set: { v in m.applyFormat { $0[keyPath: kp] = v } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(m.editing ? "Format" : "Style for new text").font(.ui(size: 14, weight: .bold))
                    Spacer()
                    if m.editing {
                        Button("Done") { m.commitEditing() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    }
                }
                Text(m.editing ? "Changes apply to selected letters, or the whole box when nothing is selected." : "Used by Add Text. Copy Style fills it from any text in the PDF.")
                    .font(.ui(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                // preview
                Text("Aa Bb 123 — The quick brown fox")
                    .font(Font(f.font.withSize(min(max(f.size, 10), 22)) as CTFont))
                    .foregroundStyle(Color(nsColor: f.color))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))

                if !m.fontMatches.isEmpty {
                    group("Matched from the page") {
                        ForEach(m.fontMatches.prefix(6)) { match in
                            Button { m.applyFormat { $0.fontName = match.fontName } } label: {
                                HStack {
                                    Text(match.display).font(Font(NSFont(name: match.fontName, size: 13) ?? .systemFont(ofSize: 13)))
                                    Spacer()
                                    Text("\(Int(match.score * 100))%").font(.ui(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                                    if match.fontName == f.fontName { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                group("Font") {
                    Picker("Family", selection: Binding(get: { f.family }, set: { fam in m.applyFormat { $0 = $0.withFamily(fam) } })) {
                        if !Self.families.contains(f.family) { Text(f.family).tag(f.family) }
                        ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Style", selection: Binding(get: { f.fontName }, set: { n in m.applyFormat { $0.fontName = n } })) {
                        let members = NSFontManager.shared.availableMembers(ofFontFamily: f.family) ?? []
                        if !members.contains(where: { ($0.first as? String) == f.fontName }) { Text(f.styleName).tag(f.fontName) }
                        ForEach(members.indices, id: \.self) { i in
                            if let n = members[i].first as? String { Text((members[i].count > 1 ? members[i][1] as? String : nil) ?? n).tag(n) }
                        }
                    }
                    HStack {
                        Text("Size").frame(width: 46, alignment: .leading)
                        TextField("", value: Binding(get: { Double(f.size) }, set: { v in m.applyFormat { $0.size = CGFloat(max(1, v)) } }), format: .number.precision(.fractionLength(0...1))).frame(width: 52)
                        Stepper("", value: bind(\.size), in: 2...400, step: 0.5).labelsHidden()
                        Spacer()
                        ColorPicker("", selection: Binding(get: { Color(nsColor: f.color) }, set: { c in m.applyFormat { $0.color = NSColor(c) } })).labelsHidden()
                        Button { NSColorSampler().show { c in if let c { m.applyFormat { $0.color = c } } } } label: { Image(systemName: "eyedropper") }
                            .help("Pick a color from anywhere on screen, like the ink in the scan")
                    }
                    HStack(spacing: 4) {
                        toggle("bold", f.isBold) { m.applyFormat { $0 = $0.withTrait(.boldFontMask, on: !$0.isBold) } }
                        toggle("italic", f.isItalic) { m.applyFormat { $0 = $0.withTrait(.italicFontMask, on: !$0.isItalic) } }
                        toggle("underline", f.underline) { m.applyFormat { $0.underline.toggle() } }
                        toggle("strikethrough", f.strike) { m.applyFormat { $0.strike.toggle() } }
                        Spacer()
                        ForEach([(NSTextAlignment.left, "text.alignleft"), (.center, "text.aligncenter"), (.right, "text.alignright"), (.justified, "text.justify")], id: \.1) { a in
                            toggle(a.1, f.alignment == a.0) { m.applyFormat { $0.alignment = a.0 } }
                        }
                    }
                }

                group("Spacing") {
                    slider("Letters", bind(\.tracking), -3...12, unit: "pt")
                    slider("Width", Binding(get: { f.hScale * 100 }, set: { v in m.applyFormat { $0.hScale = v / 100 } }), 50...200, unit: "%")
                    slider("Baseline", bind(\.baseline), -20...20, unit: "pt")
                    HStack {
                        Text("Line height").frame(width: 70, alignment: .leading)
                        Text(f.lineHeight == 0 ? "Auto" : "\(Fmt1.n(f.lineHeight)) pt").monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Stepper("", onIncrement: { m.applyFormat { $0.lineHeight = ($0.lineHeight == 0 ? ($0.size * 1.2).rounded() : $0.lineHeight) + 0.5 } },
                                onDecrement: { m.applyFormat { $0.lineHeight = max(0, ($0.lineHeight == 0 ? ($0.size * 1.2).rounded() : $0.lineHeight) - 0.5) } }).labelsHidden()
                        Button("Auto") { m.applyFormat { $0.lineHeight = 0 } }.controlSize(.mini)
                    }
                }

                if m.editing && m.lookAvailable || m.look.enabled {
                    group("Scan look") {
                        Toggle("Blend with the scan", isOn: Binding(get: { m.look.enabled }, set: { var l = m.look; l.enabled = $0; m.setLook(l) }))
                        slider("Softness", Binding(get: { m.look.softness * 100 }, set: { v in var l = m.look; l.softness = v / 100; m.setLook(l) }), 0...150, unit: "")
                            .disabled(!m.look.enabled)
                        slider("Grain", Binding(get: { m.look.grain * 100 }, set: { v in var l = m.look; l.grain = v / 100; m.setLook(l) }), 0...100, unit: "")
                            .disabled(!m.look.enabled)
                        slider("Ink weight", Binding(get: { m.look.weight * 10 }, set: { v in var l = m.look; l.weight = v / 10; m.setLook(l) }), 0...60, unit: "")
                            .disabled(!m.look.enabled)
                        Text("Softness and speckle are measured from the scan. You'll see them when you click outside the box.")
                            .font(.ui(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                group("Style") {
                    HStack {
                        Button("Copy Style") {
                            m.copiedFormat = f
                            m.status = "Copied style: \(f.label)"
                        }
                        Button("Paste Style") { m.applyCopiedStyle() }.disabled(m.copiedFormat == nil)
                        Button("Copy Font Name") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(f.fontName, forType: .string)
                            m.status = "Copied “\(f.fontName)”"
                        }
                    }
                    if let c = m.copiedFormat { Text("Copied: \(c.label)").font(.ui(size: 10)).foregroundStyle(.secondary) }
                }

                if m.editing {
                    HStack {
                        Button("Discard Changes", role: .destructive) { m.cancelEditing() }
                        Spacer()
                        Button("Done") { m.commitEditing() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .font(.ui(size: 12))
            .controlSize(.small)
            .padding(14)
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            c()
        }
    }

    private func toggle(_ symbol: String, _ on: Bool, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: symbol).frame(width: 22, height: 20)
                .background(on ? Theme.accent.opacity(0.2) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(on ? Theme.accent : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func slider(_ title: String, _ v: Binding<CGFloat>, _ range: ClosedRange<CGFloat>, unit: String) -> some View {
        HStack {
            Text(title).frame(width: 60, alignment: .leading)
            Slider(value: v, in: range)
            Text("\(Fmt1.n(v.wrappedValue.rounded(toPlaces: 1)))\(unit)").font(.ui(size: 10)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Sheets

struct NoteSheet: View {
    let request: NoteRequest
    let model: PDFEditorModel
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Note").font(.ui(size: 16, weight: .bold))
            TextEditor(text: $text).font(.ui(size: 13)).frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { model.saveNote(request, text: text); dismiss() }.buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { text = request.text }
    }
}

struct WatermarkSheet: View {
    let model: PDFEditorModel
    @State private var text = "CONFIDENTIAL"
    @State private var size: CGFloat = 64
    @State private var color: Color = .red
    @State private var opacity: CGFloat = 0.18
    @State private var angle: CGFloat = 45
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Watermark").font(.ui(size: 16, weight: .bold))
            TextField("Text", text: $text)
            HStack { Text("Size"); Slider(value: $size, in: 18...160); Text("\(Int(size))").monospacedDigit().frame(width: 30) }
            HStack { Text("Opacity"); Slider(value: $opacity, in: 0.05...1); Text("\(Int(opacity * 100))%").monospacedDigit().frame(width: 36) }
            HStack { Text("Angle"); Slider(value: $angle, in: -90...90); Text("\(Int(angle))°").monospacedDigit().frame(width: 36) }
            ColorPicker("Color", selection: $color)
            Text("Goes on every page. Undo removes it.").font(.ui(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Watermark") { model.addWatermark(text, size: size, color: NSColor(color), opacity: opacity, angle: angle); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(text.isEmpty)
            }
        }
        .padding(20).frame(width: 400)
    }
}

struct HeaderFooterSheet: View {
    let model: PDFEditorModel
    @State private var slots = ["", "", "", "", "Page <<page>> of <<pages>>", ""]
    @State private var size: CGFloat = 9
    @State private var margin: CGFloat = 28
    @State private var start = 1
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Header & Footer").font(.ui(size: 16, weight: .bold))
            Text("Use <<page>>, <<pages>>, <<date>> and <<file>>. For Bates numbering, type a prefix like ABC-<<page>> and set the start number.")
                .font(.ui(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("HEADER").font(.ui(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            HStack { TextField("Left", text: $slots[0]); TextField("Center", text: $slots[1]); TextField("Right", text: $slots[2]) }
            Text("FOOTER").font(.ui(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            HStack { TextField("Left", text: $slots[3]); TextField("Center", text: $slots[4]); TextField("Right", text: $slots[5]) }
            HStack {
                Text("Size"); Stepper("\(Int(size)) pt", value: $size, in: 6...24)
                Text("Margin"); Stepper("\(Int(margin)) pt", value: $margin, in: 6...90, step: 2)
                Text("Start at"); Stepper("\(start)", value: $start, in: 1...999_999)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { model.addHeaderFooter(slots, size: size, margin: margin, startAt: start); dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 560)
    }
}

struct PasswordSheet: View {
    let model: PDFEditorModel
    @State private var openPW = ""
    @State private var ownerPW = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Protect with a password").font(.ui(size: 16, weight: .bold))
            SecureField("Password to open (optional)", text: $openPW)
            SecureField("Password to change or print (optional)", text: $ownerPW)
            Text("Saves a protected copy. Without an open password, anyone can read it but not edit it.")
                .font(.ui(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Protected Copy…") { dismiss(); DispatchQueue.main.async { model.protect(open: openPW, owner: ownerPW) } }
                    .buttonStyle(.borderedProminent).disabled(openPW.isEmpty && ownerPW.isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }
}

struct SignaturePad: View {
    let model: PDFEditorModel
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @Environment(\.dismiss) private var dismiss
    private let size = CGSize(width: 420, height: 160)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your signature").font(.ui(size: 16, weight: .bold))
            Text("Sign with your trackpad or mouse. It's saved on this Mac for next time.").font(.ui(size: 12)).foregroundStyle(.secondary)
            Canvas { ctx, _ in
                for s in strokes + [current] where s.count > 1 {
                    var p = Path()
                    p.move(to: CGPoint(x: s[0].x * size.width, y: s[0].y * size.height))
                    for pt in s.dropFirst() { p.addLine(to: CGPoint(x: pt.x * size.width, y: pt.y * size.height)) }
                    ctx.stroke(p, with: .color(Color(red: 0.05, green: 0.1, blue: 0.35)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: size.width, height: size.height)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.gray.opacity(0.4)).frame(height: 1).padding(.horizontal, 30).padding(.bottom, 34) }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in current.append(CGPoint(x: v.location.x / size.width, y: v.location.y / size.height)) }
                .onEnded { _ in strokes.append(current); current = [] })
            HStack {
                Button("Clear") { strokes = []; current = [] }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Signature") { model.signature = strokes; model.tool = .sign; model.status = PDFTool.sign.hint; dismiss() }
                    .buttonStyle(.borderedProminent).disabled(strokes.isEmpty)
            }
        }
        .padding(20)
        .onAppear { strokes = model.signature }
    }
}


/// NSMenuItem that runs a closure, for building right-click menus in AppKit views.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}


