import SwiftUI
import AppKit
import PDFKit
import Vision
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

// MARK: - OCR (shared by Converter, PDF Editor and Clipboard)

enum OCR {
    static func observations(_ image: CGImage, fast: Bool = false) -> [VNRecognizedTextObservation] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = fast ? .fast : .accurate
        req.usesLanguageCorrection = !fast
        req.automaticallyDetectsLanguage = !fast
        if fast { req.recognitionLanguages = ["en-US"] }
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        return req.results ?? []
    }

    /// Text in reading order, keeping line breaks.
    static func string(_ image: CGImage, fast: Bool = false) -> String {
        observations(image, fast: fast)
            .sorted { abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    static func barcodes(_ image: CGImage) -> [String] {
        let req = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        return (req.results ?? []).compactMap(\.payloadStringValue)
    }

    static func cgImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2.5) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}

// MARK: - Converter: any type to any type it can sensibly become

enum ConvFamily: String, CaseIterable {
    case image = "Image", pdf = "PDF", document = "Document", audio = "Audio", video = "Video", data = "Data", unknown = "Unsupported"

    static func of(_ url: URL) -> ConvFamily {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ["csv", "tsv", "json"].contains(ext) { return .data }
        if ["md", "markdown", "txt", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "wordml", "webarchive", "xml"].contains(ext) { return .document }
        guard let t = UTType(filenameExtension: ext) else { return .unknown }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .text) { return .document }
        return .unknown
    }

    var outputs: [String] {
        switch self {
        case .image: return ["png", "jpg", "heic", "tiff", "gif", "bmp", "jp2", "pdf", "txt"]
        case .pdf: return ["png", "jpg", "heic", "tiff", "txt", "rtf", "docx", "doc", "odt", "html"]
        case .document: return ["pdf", "docx", "doc", "rtf", "odt", "html", "txt"]
        case .audio: return ["m4a", "wav", "aiff", "flac", "caf", "aac"]
        case .video: return ["mp4", "mov", "m4v", "m4a", "gif", "jpg"]
        case .data: return ["csv", "tsv", "json"]
        case .unknown: return []
        }
    }
}

enum ConvertError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let s) = self { return s }; return nil }
}

enum Converter {
    static func describe(_ ext: String) -> String {
        switch ext {
        case "txt": return "Text (.txt)"
        case "jpg": return "JPEG"
        case "heic": return "HEIC"
        case "docx": return "Word (.docx)"
        case "doc": return "Word 97 (.doc)"
        case "odt": return "OpenDocument"
        case "m4a": return "AAC audio (.m4a)"
        case "gif": return "Animated GIF"
        default: return ext.uppercased()
        }
    }

    static func destination(_ src: URL, _ ext: String, in dir: URL, suffix: String = "") -> URL {
        FileOps.unique(dir.appendingPathComponent(src.deletingPathExtension().lastPathComponent + suffix).appendingPathExtension(ext))
    }

    static func convert(_ src: URL, to ext: String, outDir: URL, quality: Double) throws -> [URL] {
        switch ConvFamily.of(src) {
        case .image: return try image(src, ext, outDir, quality)
        case .pdf: return try pdf(src, ext, outDir, quality)
        case .document: return [try document(src, ext, outDir)]
        case .audio: return [try audio(src, ext, outDir)]
        case .video: return try video(src, ext, outDir, quality)
        case .data: return [try data(src, ext, outDir)]
        case .unknown: throw ConvertError.failed("Can't convert this kind of file")
        }
    }

    // images
    static func writeImage(_ cg: CGImage, to dest: URL, quality: Double) throws {
        guard let type = UTType(filenameExtension: dest.pathExtension),
              let d = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError.failed("Can't write \(dest.pathExtension.uppercased())")
        }
        CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw ConvertError.failed("Writing failed") }
    }

    private static func image(_ src: URL, _ ext: String, _ dir: URL, _ q: Double) throws -> [URL] {
        guard let cg = OCR.cgImage(src) else { throw ConvertError.failed("Can't read image") }
        let dest = destination(src, ext, in: dir)
        switch ext {
        case "pdf":
            let doc = PDFDocument()
            guard let page = PDFPage(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))) else { throw ConvertError.failed("PDF failed") }
            doc.insert(page, at: 0)
            guard doc.write(to: dest) else { throw ConvertError.failed("PDF failed") }
        case "txt":
            try OCR.string(cg).write(to: dest, atomically: true, encoding: .utf8)
        default:
            try writeImage(cg, to: dest, quality: q)
        }
        return [dest]
    }

    // PDFs
    private static func pdf(_ src: URL, _ ext: String, _ dir: URL, _ q: Double) throws -> [URL] {
        guard let doc = PDFDocument(url: src) else { throw ConvertError.failed("Can't open PDF") }
        if ["png", "jpg", "heic", "tiff"].contains(ext) {
            var out: [URL] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i), let cg = OCR.render(page, scale: 2) else { continue }
                let dest = destination(src, ext, in: dir, suffix: doc.pageCount > 1 ? " – page \(i + 1)" : "")
                try writeImage(cg, to: dest, quality: q)
                out.append(dest)
            }
            return out
        }
        let dest = destination(src, ext, in: dir)
        let text = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            if let a = page.attributedString, a.string.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 {
                text.append(a)
            } else if let cg = OCR.render(page) {
                text.append(NSAttributedString(string: OCR.string(cg), attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            }
            if i < doc.pageCount - 1 { text.append(NSAttributedString(string: "\n\u{0C}\n")) }
        }
        try writeAttributed(text, to: dest)
        return [dest]
    }

    // documents
    static func readAttributed(_ src: URL) throws -> NSAttributedString {
        let ext = src.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            let raw = try String(contentsOf: src, encoding: .utf8)
            let a = try AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return NSAttributedString(a)
        }
        return try NSAttributedString(url: src, options: [:], documentAttributes: nil)
    }

    static func writeAttributed(_ a: NSAttributedString, to dest: URL) throws {
        let range = NSRange(location: 0, length: a.length)
        let type: NSAttributedString.DocumentType
        switch dest.pathExtension.lowercased() {
        case "txt":
            try a.string.write(to: dest, atomically: true, encoding: .utf8); return
        case "pdf":
            try printToPDF(a, dest); return
        case "rtf": type = .rtf
        case "html": type = .html
        case "doc": type = .docFormat
        case "docx": type = .officeOpenXML
        case "odt": type = .openDocument
        default: throw ConvertError.failed("Unsupported output")
        }
        let data = try a.data(from: range, documentAttributes: [.documentType: type])
        try data.write(to: dest)
    }

    private static func printToPDF(_ a: NSAttributedString, _ dest: URL) throws {
        var thrown: Error?
        let work = {
            let page = NSSize(width: 612, height: 792), margin: CGFloat = 54
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: page.width - margin * 2, height: page.height))
            tv.textStorage?.setAttributedString(a)
            tv.isVerticallyResizable = true
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
            let used = tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? page.height
            tv.frame.size.height = max(used + 20, page.height - margin * 2)
            let info = NSPrintInfo()
            info.paperSize = page
            info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
            info.jobDisposition = .save
            info.dictionary().setObject(dest, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)
            let op = NSPrintOperation(view: tv, printInfo: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            if !op.run() { thrown = ConvertError.failed("PDF export failed") }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        if let thrown { throw thrown }
    }

    private static func document(_ src: URL, _ ext: String, _ dir: URL) throws -> URL {
        let dest = destination(src, ext, in: dir)
        try writeAttributed(try readAttributed(src), to: dest)
        return dest
    }

    // audio via afconvert
    private static func audio(_ src: URL, _ ext: String, _ dir: URL) throws -> URL {
        let dest = destination(src, ext, in: dir)
        let fmt: [String]
        switch ext {
        case "m4a": fmt = ["-f", "m4af", "-d", "aac", "-b", "256000"]
        case "aac": fmt = ["-f", "adts", "-d", "aac", "-b", "256000"]
        case "wav": fmt = ["-f", "WAVE", "-d", "LEI16"]
        case "aiff": fmt = ["-f", "AIFF", "-d", "BEI16"]
        case "flac": fmt = ["-f", "flac", "-d", "flac"]
        default: fmt = ["-f", "caff", "-d", "aac"]
        }
        Shell.run("/usr/bin/afconvert", fmt + [src.path, dest.path], timeout: 900)
        guard FileManager.default.fileExists(atPath: dest.path) else { throw ConvertError.failed("Audio conversion failed") }
        return dest
    }

    // video via AVFoundation
    private static func video(_ src: URL, _ ext: String, _ dir: URL, _ q: Double) throws -> [URL] {
        let asset = AVURLAsset(url: src)
        let dest = destination(src, ext, in: dir)
        switch ext {
        case "gif": try gif(asset, dest); return [dest]
        case "jpg":
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            let cg = try gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
            try writeImage(cg, to: dest, quality: q)
            return [dest]
        default:
            let preset = ext == "m4a" ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
            guard let s = AVAssetExportSession(asset: asset, presetName: preset) else { throw ConvertError.failed("Can't export video") }
            s.outputURL = dest
            s.outputFileType = ext == "m4a" ? .m4a : ext == "mov" ? .mov : ext == "m4v" ? .m4v : .mp4
            let done = DispatchSemaphore(value: 0)
            s.exportAsynchronously { done.signal() }
            done.wait()
            guard s.status == .completed else { throw ConvertError.failed(s.error?.localizedDescription ?? "Export failed") }
            return [dest]
        }
    }

    private static func gif(_ asset: AVURLAsset, _ dest: URL) throws {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        final class Box { var seconds = 15.0 }
        let box = Box()
        let loaded = DispatchSemaphore(value: 0)
        Task.detached {
            if let d = try? await asset.load(.duration) { box.seconds = min(CMTimeGetSeconds(d), 15) }
            loaded.signal()
        }
        loaded.wait()
        let seconds = box.seconds
        let fps = 10.0
        let frames = max(Int(seconds * fps), 1)
        guard let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw ConvertError.failed("GIF failed")
        }
        CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 1 / fps]] as CFDictionary
        for i in 0..<frames {
            if let cg = try? gen.copyCGImage(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600), actualTime: nil) {
                CGImageDestinationAddImage(d, cg, frameProps)
            }
        }
        guard CGImageDestinationFinalize(d) else { throw ConvertError.failed("GIF failed") }
    }

    // data: csv / tsv / json
    private static func parseDelimited(_ text: String, _ sep: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == sep { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else if c != "\r" { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    private static func data(_ src: URL, _ ext: String, _ dir: URL) throws -> URL {
        let dest = destination(src, ext, in: dir)
        let text = try String(contentsOf: src, encoding: .utf8)
        var table: [[String]]
        switch src.pathExtension.lowercased() {
        case "json":
            guard let arr = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else {
                throw ConvertError.failed("JSON must be a list of objects")
            }
            var keys: [String] = []
            for o in arr { for k in o.keys.sorted() where !keys.contains(k) { keys.append(k) } }
            table = [keys] + arr.map { o in keys.map { k in o[k].map { "\($0)" } ?? "" } }
        case "tsv": table = parseDelimited(text, "\t")
        default: table = parseDelimited(text, ",")
        }
        switch ext {
        case "json":
            guard let head = table.first else { throw ConvertError.failed("Empty file") }
            let objs = table.dropFirst().map { r in
                Dictionary(head.enumerated().map { ($0.element, $0.offset < r.count ? r[$0.offset] : "") }, uniquingKeysWith: { a, _ in a })
            }
            try JSONSerialization.data(withJSONObject: objs, options: [.prettyPrinted, .sortedKeys]).write(to: dest)
        default:
            let sep = ext == "tsv" ? "\t" : ","
            let esc: (String) -> String = { f in
                f.contains(sep) || f.contains("\"") || f.contains("\n") ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
            }
            try table.map { $0.map(esc).joined(separator: sep) }.joined(separator: "\n").write(to: dest, atomically: true, encoding: .utf8)
        }
        return dest
    }
}

struct ConvJob: Identifiable {
    let url: URL
    var status = "Ready"
    var outputs: [URL] = []
    var failed = false
    var id: URL { url }
    var family: ConvFamily { ConvFamily.of(url) }
}

struct ConverterView: View {
    @EnvironmentObject var model: AppModel
    @State private var jobs: [ConvJob] = []
    @State private var target = ""
    @State private var quality = 0.85
    @State private var outDir: URL?
    @State private var running = false
    @State private var dropping = false

    private var families: Set<ConvFamily> { Set(jobs.map(\.family)).subtracting([.unknown]) }
    private var targets: [String] {
        guard let first = families.first else { return [] }
        return first.outputs.filter { t in families.allSatisfy { $0.outputs.contains(t) } }
    }

    var body: some View {
        ToolPage(tool: .converter, subtitle: "Drop files of any kind. Pick what to turn them into. Images, PDFs, documents, audio, video and data.", trailing: {
            HStack {
                Button("Use Files selection") { add(Array(model.active.selection)) }.disabled(model.active.selection.isEmpty)
                Button("Add Files…") { pick() }
            }
        }) {
            if jobs.isEmpty {
                dropZone
            } else {
                HStack(spacing: 12) {
                    Picker("Convert to", selection: $target) {
                        ForEach(targets, id: \.self) { Text(Converter.describe($0)).tag($0) }
                    }
                    .frame(width: 260)
                    if ["jpg", "heic"].contains(target) {
                        Text("Quality").font(.ui(size: 12)).foregroundStyle(.secondary)
                        Slider(value: $quality, in: 0.3...1).frame(width: 120)
                    }
                    Menu(outDir.map { "Save to \($0.lastPathComponent)" } ?? "Save next to originals") {
                        Button("Next to originals") { outDir = nil }
                        Button("Choose folder…") {
                            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                            if p.runModal() == .OK { outDir = p.url }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Clear") { jobs = [] }.disabled(running)
                    Button(running ? "Converting…" : "Convert \(jobs.count) file\(jobs.count == 1 ? "" : "s")") { run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || target.isEmpty)
                }
                if targets.isEmpty {
                    Text("These files have no format in common. Convert one kind at a time.").font(.ui(size: 12)).foregroundStyle(Theme.net)
                }
                TableBox(footer: "Images → any image, PDF or text (OCR) · PDFs → images, text or Word · Documents → PDF, Word, RTF, HTML · Audio → M4A, WAV, AIFF, FLAC · Video → MP4, MOV, M4A, GIF · CSV ↔ TSV ↔ JSON") {
                    HStack(spacing: 0) {
                        Text("FILE").frame(maxWidth: .infinity, alignment: .leading)
                        Text("KIND").frame(width: 100, alignment: .leading)
                        Text("STATUS").frame(width: 200, alignment: .leading)
                    }
                    .font(.ui(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                } rows: {
                    ForEach(jobs) { j in
                        HStack(spacing: 0) {
                            HStack(spacing: 6) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: j.url.path)).resizable().frame(width: 16, height: 16)
                                Text(j.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(j.family.rawValue).foregroundStyle(j.family == .unknown ? Theme.warn : .secondary).frame(width: 100, alignment: .leading)
                            HStack {
                                Text(j.status).foregroundStyle(j.failed ? Theme.warn : (j.outputs.isEmpty ? .secondary : Theme.good)).lineLimit(1)
                                if let o = j.outputs.first {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting(j.outputs) } label: { Image(systemName: "arrow.up.forward.square") }
                                        .buttonStyle(.borderless).help(o.lastPathComponent)
                                }
                            }
                            .frame(width: 200, alignment: .leading)
                        }
                        .font(.ui(size: 12))
                        .padding(.horizontal, 16).padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Open Original") { NSWorkspace.shared.open(j.url) }
                            Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([j.url]) }
                            if !j.outputs.isEmpty {
                                Divider()
                                Button("Open Converted File") { j.outputs.forEach { NSWorkspace.shared.open($0) } }
                                Button("Show Converted File in Finder") { NSWorkspace.shared.activateFileViewerSelecting(j.outputs) }
                            }
                            Divider()
                            Button("Remove from List") { jobs.removeAll { $0.url == j.url } }.disabled(running)
                        }
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in add(urls); return true }
            }
        }
        .onChange(of: targets) { _, t in if !t.contains(target) { target = t.first ?? "" } }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc").font(.ui(size: 36)).foregroundStyle(Theme.accent)
            Text("Drop files here").font(.ui(size: 15, weight: .semibold))
            Text("Or use Add Files, or select files in the browser and press Use Files selection.").font(.ui(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(dropping ? Theme.accent : Theme.stroke, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { dropping = $0 }
    }

    private func pick() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        if p.runModal() == .OK { add(p.urls) }
    }

    private func add(_ urls: [URL]) {
        let new = urls.filter { u in !FS.isFolder(u) && !jobs.contains { $0.url == u } }.map { ConvJob(url: $0) }
        jobs += new
        if target.isEmpty || !targets.contains(target) { target = targets.first ?? "" }
    }

    private func run() {
        running = true
        let t = target, q = quality, list = jobs
        DispatchQueue.global(qos: .userInitiated).async {
            for j in list {
                DispatchQueue.main.async { if let i = jobs.firstIndex(where: { $0.url == j.url }) { jobs[i].status = "Converting…" } }
                do {
                    let outs = try Converter.convert(j.url, to: t, outDir: outDir ?? j.url.deletingLastPathComponent(), quality: q)
                    DispatchQueue.main.async {
                        if let i = jobs.firstIndex(where: { $0.url == j.url }) {
                            jobs[i].outputs = outs
                            jobs[i].status = outs.count > 1 ? "Done · \(outs.count) files" : "Done · \(outs.first?.lastPathComponent ?? "")"
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        if let i = jobs.firstIndex(where: { $0.url == j.url }) { jobs[i].status = error.localizedDescription; jobs[i].failed = true }
                    }
                }
            }
            DispatchQueue.main.async {
                running = false
                model.reloadAll()
                UndoCenter.shared.show("Converted \(list.count) file\(list.count == 1 ? "" : "s") to \(t.uppercased())")
            }
        }
    }
}

// MARK: - Batch Rename

struct RenameView: View {
    @EnvironmentObject var model: AppModel
    @State private var files: [URL] = []
    @State private var pattern = "{name}"
    @State private var find = ""
    @State private var replace = ""
    @State private var useRegex = false
    @State private var caseMode = "keep"
    @State private var start = 1
    @State private var pad = 2

    private func newName(_ u: URL, _ i: Int) -> String {
        let base = u.deletingPathExtension().lastPathComponent
        let ext = u.pathExtension
        let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var n = pattern
            .replacingOccurrences(of: "{name}", with: base)
            .replacingOccurrences(of: "{n}", with: String(format: "%0\(pad)d", start + i))
            .replacingOccurrences(of: "{date}", with: df.string(from: v?.contentModificationDate ?? Date()))
            .replacingOccurrences(of: "{created}", with: df.string(from: v?.creationDate ?? Date()))
            .replacingOccurrences(of: "{folder}", with: u.deletingLastPathComponent().lastPathComponent)
        if !find.isEmpty {
            n = useRegex ? n.replacingOccurrences(of: find, with: replace, options: .regularExpression)
                         : n.replacingOccurrences(of: find, with: replace)
        }
        switch caseMode {
        case "lower": n = n.lowercased()
        case "upper": n = n.uppercased()
        case "title": n = n.capitalized
        case "kebab": n = n.lowercased().replacingOccurrences(of: " ", with: "-")
        default: break
        }
        n = n.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return ext.isEmpty ? n : "\(n).\(ext)"
    }

    private var preview: [(URL, String, Bool)] {
        var seen = Set<String>()
        return files.enumerated().map { i, u in
            let n = newName(u, i)
            let clash = !seen.insert(u.deletingLastPathComponent().path + "/" + n.lowercased()).inserted
                || (n != u.lastPathComponent && FileManager.default.fileExists(atPath: u.deletingLastPathComponent().appendingPathComponent(n).path))
            return (u, n, clash)
        }
    }

    var body: some View {
        ToolPage(tool: .rename, trailing: {
            HStack {
                Button("Use Files selection") {
                    files = model.active.visible.map(\.url).filter { model.active.selection.contains($0) }
                }
                .disabled(model.active.selection.isEmpty)
                Button("Add Files…") {
                    let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = true
                    if p.runModal() == .OK { files += p.urls }
                }
            }
        }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("New name").frame(width: 90, alignment: .leading)
                    TextField("{name}", text: $pattern).textFieldStyle(.roundedBorder)
                    Menu("Insert") {
                        Button("Original name  {name}") { pattern += "{name}" }
                        Button("Number  {n}") { pattern += "{n}" }
                        Button("Modified date  {date}") { pattern += "{date}" }
                        Button("Created date  {created}") { pattern += "{created}" }
                        Button("Folder name  {folder}") { pattern += "{folder}" }
                    }
                    .fixedSize()
                }
                HStack {
                    Text("Find").frame(width: 90, alignment: .leading)
                    TextField("text to find", text: $find).textFieldStyle(.roundedBorder)
                    Text("Replace with")
                    TextField("replacement", text: $replace).textFieldStyle(.roundedBorder)
                    Toggle("Regex", isOn: $useRegex).toggleStyle(.checkbox)
                }
                HStack(spacing: 16) {
                    Picker("Case", selection: $caseMode) {
                        Text("Keep").tag("keep"); Text("lowercase").tag("lower"); Text("UPPERCASE").tag("upper")
                        Text("Title Case").tag("title"); Text("kebab-case").tag("kebab")
                    }
                    .frame(width: 200)
                    Stepper("Start at \(start)", value: $start, in: 0...9999)
                    Stepper("Digits \(pad)", value: $pad, in: 1...6)
                    Spacer()
                    Button("Rename \(files.count) item\(files.count == 1 ? "" : "s")") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(files.isEmpty || preview.contains { $0.2 })
                }
            }
            .font(.ui(size: 12))
            .padding(14).glass(12)

            TableBox(footer: preview.contains { $0.2 } ? "Some new names clash. Change the pattern or add {n}." : "Renames can be undone.") {
                HStack(spacing: 0) {
                    Text("NOW").frame(maxWidth: .infinity, alignment: .leading)
                    Text("BECOMES").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.ui(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            } rows: {
                ForEach(Array(preview.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        Text(row.0.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.1).foregroundStyle(row.2 ? Theme.warn : (row.1 == row.0.lastPathComponent ? .secondary : Color.primary))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.ui(size: 12))
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.0]) }
                        Button("Copy New Name") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.1, forType: .string)
                        }
                        Divider()
                        Button("Remove from List") { files.removeAll { $0 == row.0 } }
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in files += urls; return true }
        }
    }

    private func apply() {
        var moved: [Moved] = []
        for (u, n, _) in preview where n != u.lastPathComponent {
            let dest = u.deletingLastPathComponent().appendingPathComponent(n)
            if (try? FileManager.default.moveItem(at: u, to: dest)) != nil { moved.append(Moved(from: u, to: dest)) }
        }
        files = files.map { u in moved.first { $0.from == u }?.to ?? u }
        model.reloadAll()
        UndoCenter.shared.show("Renamed \(moved.count) item\(moved.count == 1 ? "" : "s")") {
            for m in moved { try? FileManager.default.moveItem(at: m.to, to: m.from) }
            files = files.map { u in moved.first { $0.to == u }?.from ?? u }
            model.reloadAll()
        }
    }
}

// MARK: - Folder Autopilot

struct AutoRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New rule"
    var enabled = true
    var folder = Places.downloads.path
    var kinds: [String] = []
    var nameContains = ""
    var olderThanDays = 0
    var minSizeMB = 0
    var action = "move"            // move, copy, trash
    var destination = ""
    var lastRun: Date?
    var lastCount = 0

    var sentence: String {
        var s = "In \(Places.name(URL(fileURLWithPath: folder))), "
        s += kinds.isEmpty ? "any file" : kinds.joined(separator: " or ").lowercased()
        if !nameContains.isEmpty { s += " named like “\(nameContains)”" }
        if olderThanDays > 0 { s += " older than \(olderThanDays) day\(olderThanDays == 1 ? "" : "s")" }
        if minSizeMB > 0 { s += " over \(minSizeMB) MB" }
        switch action {
        case "trash": s += " → move to the Trash"
        case "copy": s += " → copy to \(URL(fileURLWithPath: destination).lastPathComponent)"
        default: s += " → move to \(URL(fileURLWithPath: destination).lastPathComponent)"
        }
        return s
    }
}

final class RuleStore: ObservableObject {
    static let shared = RuleStore()
    @Published var rules: [AutoRule] = [] { didSet { save() } }
    private let file = Shell.supportDir.appendingPathComponent("autopilot.json")
    private var timer: Timer?

    init() {
        if let d = try? Data(contentsOf: file), let r = try? JSONDecoder().decode([AutoRule].self, from: d) { rules = r }
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.runAll(auto: true) }
    }

    private func save() { if let d = try? JSONEncoder().encode(rules) { try? d.write(to: file, options: .atomic) } }

    func matches(_ r: AutoRule) -> [URL] {
        let cutoff = Date().addingTimeInterval(-Double(r.olderThanDays) * 86_400)
        return FS.list(URL(fileURLWithPath: r.folder), showHidden: false).filter { f in
            if f.isDir { return false }
            let ext = f.url.pathExtension.lowercased()
            if ["crdownload", "download", "part"].contains(ext) { return false }
            if !r.kinds.isEmpty && !r.kinds.contains(FileKind.of(ext).rawValue) { return false }
            if !TextFilter.matches(f.name, r.nameContains) { return false }
            if r.olderThanDays > 0 && f.added > cutoff { return false }
            if r.minSizeMB > 0 && f.size < Int64(r.minSizeMB) * 1_000_000 { return false }
            return true
        }.map(\.url)
    }

    @discardableResult
    func run(_ r: AutoRule) -> [Moved] {
        let urls = matches(r)
        var moved: [Moved] = []
        if r.action == "trash" {
            moved = FileOps.trash(urls)
        } else {
            let dest = URL(fileURLWithPath: r.destination)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            moved = FileOps.transfer(urls, to: dest, move: r.action == "move").done
        }
        if let i = rules.firstIndex(where: { $0.id == r.id }) { rules[i].lastRun = Date(); rules[i].lastCount = moved.count }
        return moved
    }

    func runAll(auto: Bool) {
        var all: [Moved] = []
        for r in rules where r.enabled && (r.action == "trash" || !r.destination.isEmpty) { all += run(r) }
        if !all.isEmpty {
            UndoCenter.shared.show("Autopilot tidied \(all.count) file\(all.count == 1 ? "" : "s")") { FileOps.moveBack(all) }
        } else if !auto {
            UndoCenter.shared.show("Autopilot: nothing to do right now")
        }
    }

    static let templates: [AutoRule] = [
        AutoRule(name: "Old screenshots", folder: Places.home.appendingPathComponent("Desktop").path, kinds: ["Images"],
                 nameContains: "Screenshot, Screen Shot", olderThanDays: 7, action: "move",
                 destination: Places.home.appendingPathComponent("Pictures/Screenshots").path),
        AutoRule(name: "Used installers", folder: Places.downloads.path, kinds: ["Installers"], olderThanDays: 3, action: "trash"),
        AutoRule(name: "PDFs to Documents", folder: Places.downloads.path, kinds: ["Documents"], nameContains: ".pdf", olderThanDays: 1,
                 action: "move", destination: Places.home.appendingPathComponent("Documents/From Downloads").path),
        AutoRule(name: "Archive old downloads", folder: Places.downloads.path, olderThanDays: 60, action: "move",
                 destination: Places.downloads.appendingPathComponent("Archive").path),
    ]
}

struct AutopilotView: View {
    @ObservedObject private var store = RuleStore.shared
    @State private var editing: AutoRule?

    var body: some View {
        ToolPage(tool: .autopilot, subtitle: "Rules check their folders every 15 minutes while VitalOS is open. Every run can be undone.", trailing: {
            HStack {
                Menu("Add from template") {
                    ForEach(RuleStore.templates) { t in Button(t.name) { var n = t; n.id = UUID(); store.rules.append(n) } }
                }
                .fixedSize()
                Button("New Rule") { editing = AutoRule() }
                Button("Run All Now") { store.runAll(auto: false) }.buttonStyle(.borderedProminent)
            }
        }) {
            if store.rules.isEmpty {
                empty("No rules yet. Start from a template, like moving old screenshots off the Desktop.")
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.rules) { r in
                        let n = store.matches(r).count
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("", isOn: Binding(get: { r.enabled }, set: { v in if let i = store.rules.firstIndex(of: r) { store.rules[i].enabled = v } }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.name).font(.ui(size: 13, weight: .semibold))
                                Text(r.sentence).font(.ui(size: 12)).foregroundStyle(.secondary)
                                Text(r.lastRun.map { "Last ran \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())), handled \(r.lastCount)" } ?? "Hasn't run yet")
                                    .font(.ui(size: 11)).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text("\(n) match\(n == 1 ? "" : "es") now").font(.ui(size: 11)).foregroundStyle(n > 0 ? Theme.accent : .secondary)
                            Button("Run") {
                                let moved = store.run(r)
                                UndoCenter.shared.show("\(r.name): handled \(moved.count) file\(moved.count == 1 ? "" : "s")") { FileOps.moveBack(moved) }
                            }
                            .disabled(n == 0 || (r.action != "trash" && r.destination.isEmpty))
                            Button("Edit") { editing = r }
                            Button { store.rules.removeAll { $0.id == r.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        .controlSize(.small)
                        .padding(14).glass(12)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Run Now") {
                                let moved = store.run(r)
                                UndoCenter.shared.show("\(r.name): handled \(moved.count) file\(moved.count == 1 ? "" : "s")") { FileOps.moveBack(moved) }
                            }
                            Button("Edit…") { editing = r }
                            Button(r.enabled ? "Turn Off" : "Turn On") {
                                if let i = store.rules.firstIndex(of: r) { store.rules[i].enabled.toggle() }
                            }
                            Button("Duplicate") { var c = r; c.id = UUID(); c.name += " copy"; c.lastRun = nil; store.rules.append(c) }
                            Divider()
                            Button("Show Watched Folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.folder)]) }
                            if !r.destination.isEmpty {
                                Button("Show Destination") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.destination)]) }
                            }
                            Divider()
                            Button("Delete Rule", role: .destructive) { store.rules.removeAll { $0.id == r.id } }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { r in
            RuleEditor(rule: r) { saved in
                if let i = store.rules.firstIndex(where: { $0.id == saved.id }) { store.rules[i] = saved } else { store.rules.append(saved) }
                editing = nil
            } cancel: { editing = nil }
        }
    }
}

struct RuleEditor: View {
    @State var rule: AutoRule
    let save: (AutoRule) -> Void
    let cancel: () -> Void

    private func chooseFolder(_ set: @escaping (String) -> Void) {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { set(u.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rule").font(.ui(size: 18, weight: .bold))
            Form {
                TextField("Name", text: $rule.name)
                HStack {
                    Text("Watch folder")
                    Spacer()
                    Button(Places.name(URL(fileURLWithPath: rule.folder))) { chooseFolder { rule.folder = $0 } }
                }
                HStack {
                    Text("Kinds")
                    Spacer()
                    FilterPill("Kinds", options: FileKind.allCases.map { FilterOption(id: $0.rawValue, label: $0.rawValue, symbol: $0.symbol) },
                               selection: Binding(get: { Set(rule.kinds) }, set: { rule.kinds = Array($0).sorted() }))
                }
                TextField("Name contains (commas = or)", text: $rule.nameContains)
                Stepper("Older than \(rule.olderThanDays) days", value: $rule.olderThanDays, in: 0...365)
                Stepper("Bigger than \(rule.minSizeMB) MB", value: $rule.minSizeMB, in: 0...10_000, step: 10)
                Picker("Then", selection: $rule.action) {
                    Text("Move to folder").tag("move"); Text("Copy to folder").tag("copy"); Text("Move to Trash").tag("trash")
                }
                if rule.action != "trash" {
                    HStack {
                        Text("Destination")
                        Spacer()
                        Button(rule.destination.isEmpty ? "Choose…" : URL(fileURLWithPath: rule.destination).lastPathComponent) {
                            chooseFolder { rule.destination = $0 }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Text("Right now this matches \(RuleStore.shared.matches(rule).count) file(s).").font(.ui(size: 12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save") { save(rule) }.buttonStyle(.borderedProminent)
                    .disabled(rule.action != "trash" && rule.destination.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
