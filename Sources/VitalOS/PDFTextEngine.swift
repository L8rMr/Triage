import AppKit
import PDFKit
import Vision
import CoreText

// MARK: - Text formatting (one run of text)

struct TextFormat: Equatable {
    var fontName: String
    var size: CGFloat
    var color: NSColor
    var underline = false
    var strike = false
    var alignment: NSTextAlignment = .left
    var lineHeight: CGFloat = 0      // points between baselines, 0 = automatic
    var tracking: CGFloat = 0        // extra space between letters, points
    var baseline: CGFloat = 0        // raise/lower, points
    var hScale: CGFloat = 1          // horizontal stretch

    static let fallback = TextFormat(fontName: "Helvetica", size: 12, color: .black)

    var font: NSFont { NSFont(name: fontName, size: size) ?? .systemFont(ofSize: size) }
    var family: String { font.familyName ?? fontName }
    var styleName: String {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return (members.first { ($0.first as? String) == fontName }?[1] as? String) ?? "Regular"
    }
    var isBold: Bool { NSFontManager.shared.traits(of: font).contains(.boldFontMask) }
    var isItalic: Bool { NSFontManager.shared.traits(of: font).contains(.italicFontMask) }
    var label: String { "\(font.displayName ?? fontName) · \(Fmt1.n(size)) pt" }

    func attributes() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        if lineHeight > 0 { p.minimumLineHeight = lineHeight; p.maximumLineHeight = lineHeight }
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        if tracking != 0 { a[.kern] = tracking }
        if baseline != 0 { a[.baselineOffset] = baseline }
        if abs(hScale - 1) > 0.001 { a[.expansion] = log(hScale) }
        if underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }

    static func from(_ a: [NSAttributedString.Key: Any], fallback: TextFormat = .fallback) -> TextFormat {
        var f = fallback
        if let font = a[.font] as? NSFont { f.fontName = font.fontName; f.size = font.pointSize }
        if let c = a[.foregroundColor] as? NSColor { f.color = c }
        if let p = a[.paragraphStyle] as? NSParagraphStyle {
            f.alignment = p.alignment
            f.lineHeight = p.maximumLineHeight > 0 && p.maximumLineHeight == p.minimumLineHeight ? p.maximumLineHeight : 0
        } else { f.alignment = .left; f.lineHeight = 0 }
        f.tracking = (a[.kern] as? CGFloat) ?? (a[.kern] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        f.baseline = (a[.baselineOffset] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        f.hScale = (a[.expansion] as? NSNumber).map { CGFloat(exp($0.doubleValue)) } ?? 1
        f.underline = ((a[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0
        f.strike = ((a[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0
        return f
    }

    /// Same look, different family. Keeps bold/italic when the family has them.
    func withFamily(_ fam: String) -> TextFormat {
        var f = self
        let converted = NSFontManager.shared.convert(font, toFamily: fam)
        if converted.familyName == fam { f.fontName = converted.fontName }
        else if let any = NSFontManager.shared.availableMembers(ofFontFamily: fam)?.first?.first as? String { f.fontName = any }
        return f
    }
    func withTrait(_ t: NSFontTraitMask, on: Bool) -> TextFormat {
        var f = self
        let fm = NSFontManager.shared
        f.fontName = (on ? fm.convert(font, toHaveTrait: t) : fm.convert(font, toNotHaveTrait: t)).fontName
        return f
    }
}

enum Fmt1 { static func n(_ v: CGFloat) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v) } }

/// The "made on a scanner" look for replacement text.
struct ScanLook: Equatable {
    var enabled = false
    var softness: CGFloat = 0.35   // blur, in points
    var grain: CGFloat = 0.25      // 0…1 speckle in the ink
}

struct FontMatch: Identifiable, Hashable {
    var id: String { fontName }
    let fontName: String
    let score: Double
    var display: String { NSFont(name: fontName, size: 12)?.displayName ?? fontName }
}

// MARK: - The page as pixels

final class PageRaster {
    let width: Int, height: Int
    let scale: CGFloat
    let box: CGRect
    var px: [UInt8]

    init?(page: PDFPage, scale: CGFloat = 3) {
        box = page.bounds(for: .mediaBox)
        self.scale = scale
        width = Int(box.width * scale); height = Int(box.height * scale)
        guard width > 0, height > 0, width * height < 60_000_000 else { return nil }
        px = [UInt8](repeating: 255, count: width * height * 4)
        let w = width, h = height, b = box
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -b.minX, y: -b.minY)
            page.draw(with: .mediaBox, to: ctx)
            return true
        }
        if !ok { return nil }
    }

    var cgImage: CGImage? {
        let data = Data(px)
        guard let prov = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Page rect → integral pixel rect (origin top-left), clipped.
    func pxRect(_ r: CGRect) -> (x: Int, y: Int, w: Int, h: Int) {
        let x0 = max(0, Int(((r.minX - box.minX) * scale).rounded(.down)))
        let x1 = min(width, Int(((r.maxX - box.minX) * scale).rounded(.up)))
        let y0 = max(0, Int(((box.maxY - r.maxY) * scale).rounded(.down)))
        let y1 = min(height, Int(((box.maxY - r.minY) * scale).rounded(.up)))
        return (x0, y0, max(0, x1 - x0), max(0, y1 - y0))
    }
    func pageRect(x: Int, y: Int, w: Int, h: Int) -> CGRect {
        CGRect(x: box.minX + CGFloat(x) / scale, y: box.maxY - CGFloat(y + h) / scale, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
    }
    @inline(__always) func lum(_ x: Int, _ y: Int) -> Int {
        let i = (y * width + x) * 4
        return (Int(px[i]) * 299 + Int(px[i + 1]) * 587 + Int(px[i + 2]) * 114) / 1000
    }

    /// Otsu threshold for a region: the split between ink and paper.
    func threshold(x: Int, y: Int, w: Int, h: Int) -> (t: Int, bg: Int, ink: Int) {
        var hist = [Int](repeating: 0, count: 256)
        for yy in y..<(y + h) { for xx in x..<(x + w) { hist[lum(xx, yy)] += 1 } }
        let total = w * h
        guard total > 0 else { return (128, 255, 0) }
        var sum = 0.0; for i in 0..<256 { sum += Double(i * hist[i]) }
        var sumB = 0.0, wB = 0, best = 0.0, t = 128
        for i in 0..<256 {
            wB += hist[i]; if wB == 0 { continue }
            let wF = total - wB; if wF == 0 { break }
            sumB += Double(i * hist[i])
            let mB = sumB / Double(wB), mF = (sum - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; t = i }
        }
        // medians on each side
        func median(_ range: ClosedRange<Int>) -> Int {
            let n = range.reduce(0) { $0 + hist[$1] }; var acc = 0
            for i in range { acc += hist[i]; if acc * 2 >= n { return i } }
            return range.upperBound
        }
        return (t, median(min(t + 1, 255)...255), median(0...t))
    }
}

// MARK: - Erasing text while keeping the paper

enum PatchMaker {
    /// Copies the area, then paints over ink with nearby paper pixels so grain and tint survive.
    static func clean(_ r: PageRaster, rect: CGRect) -> (CGImage, CGRect)? {
        let (x, y, w, h) = r.pxRect(rect)
        guard w > 2, h > 2 else { return nil }
        let (t, bg, _) = r.threshold(x: x, y: y, w: w, h: h)
        // paper noise: anything darker than the paper's own speckle counts as ink, including the soft grey halo
        var paper: [Int] = []
        for yy in stride(from: 0, to: h, by: 2) { for xx in stride(from: 0, to: w, by: 2) {
            let l = r.lum(x + xx, y + yy); if l > t + (bg - t) / 2 { paper.append(l) }
        } }
        let mean = paper.isEmpty ? Double(bg) : Double(paper.reduce(0, +)) / Double(paper.count)
        let sd = paper.isEmpty ? 4 : sqrt(paper.map { pow(Double($0) - mean, 2) }.reduce(0, +) / Double(paper.count))
        let cut = bg - max(10, Int(sd * 2.5))
        var mask = [Bool](repeating: false, count: w * h)
        if bg - t > 18 {
            for yy in 0..<h { for xx in 0..<w where r.lum(x + xx, y + yy) < cut { mask[yy * w + xx] = true } }
        }
        // grow the mask about half a point so nothing of the old letters survives
        let grow = max(2, Int(r.scale * 0.6 + 0.5))
        var grown = mask
        for yy in 0..<h { for xx in 0..<w where mask[yy * w + xx] {
            for dy in -grow...grow { for dx in -grow...grow {
                let nx = xx + dx, ny = yy + dy
                if nx >= 0, ny >= 0, nx < w, ny < h { grown[ny * w + nx] = true }
            } }
        } }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        var rows = [[Int]](repeating: [], count: h)
        for yy in 0..<h {
            for xx in 0..<w {
                let si = ((y + yy) * r.width + (x + xx)) * 4, di = (yy * w + xx) * 4
                out[di] = r.px[si]; out[di + 1] = r.px[si + 1]; out[di + 2] = r.px[si + 2]; out[di + 3] = 255
                if !grown[yy * w + xx] { rows[yy].append(xx) }
            }
        }
        var rng = SystemRandomNumberGenerator()
        let bgByte = UInt8(clamping: bg)
        for yy in 0..<h {
            for xx in 0..<w where grown[yy * w + xx] {
                var src: (Int, Int)?
                for d in 0..<max(h, 1) {
                    for ry in [yy - d, yy + d] where ry >= 0 && ry < h && !rows[ry].isEmpty {
                        src = (rows[ry].randomElement(using: &rng)!, ry); break
                    }
                    if src != nil { break }
                }
                let di = (yy * w + xx) * 4
                if let (sx, sy) = src {
                    let si = (sy * w + sx) * 4
                    out[di] = out[si]; out[di + 1] = out[si + 1]; out[di + 2] = out[si + 2]
                } else { out[di] = bgByte; out[di + 1] = bgByte; out[di + 2] = bgByte }
            }
        }
        guard let prov = CGDataProvider(data: Data(out) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return (img, r.pageRect(x: x, y: y, w: w, h: h))
    }
}

// MARK: - Font matching for scans

enum FontMatcher {
    static let families = ["Helvetica", "Helvetica Neue", "Arial", "Arial Narrow", "Verdana", "Tahoma", "Trebuchet MS", "Gill Sans",
                           "Futura", "Avenir", "Avenir Next", "Optima", "Lucida Grande", "Century Gothic", "Franklin Gothic Medium",
                           "Segoe UI", "Calibri", "Seravek", "PT Sans", "Times New Roman", "Times", "Georgia", "Palatino", "Baskerville",
                           "Hoefler Text", "Didot", "Bodoni 72", "Book Antiqua", "Garamond", "EB Garamond", "Cochin", "Charter",
                           "Iowan Old Style", "Cambria", "Big Caslon", "PT Serif", "Rockwell", "Courier", "Courier New", "Menlo",
                           "American Typewriter", "Copperplate", "Arial Black", "Impact"]

    static let candidates: [String] = {
        let have = Set(NSFontManager.shared.availableFontFamilies)
        var out: [String] = []
        for fam in families where have.contains(fam) {
            let members = NSFontManager.shared.availableMembers(ofFontFamily: fam) ?? []
            var picked = Set<String>()
            for m in members {
                guard let name = m.first as? String, let traits = (m.count > 3 ? m[3] as? NSNumber : nil)?.uintValue,
                      let weight = (m.count > 2 ? m[2] as? NSNumber : nil)?.intValue else { continue }
                let bold = traits & NSFontTraitMask.boldFontMask.rawValue != 0
                let italic = traits & NSFontTraitMask.italicFontMask.rawValue != 0
                let key = "\(bold)\(italic)"
                if !picked.contains(key), (bold || (weight >= 4 && weight <= 6)) { picked.insert(key); out.append(name) }
            }
        }
        return out
    }()

    /// Coverage grid of the ink inside a region, gridW columns wide.
    static func grid(_ cov: (Int, Int) -> Float, x: Int, y: Int, w: Int, h: Int, gridW: Int, rows: Int) -> [Float] {
        var g = [Float](repeating: 0, count: gridW * rows)
        let cell = Float(w) / Float(gridW)
        for gy in 0..<rows {
            let y0 = Int(Float(gy) * cell), y1 = min(h, Int(Float(gy + 1) * cell))
            if y0 >= h { break }
            for gx in 0..<gridW {
                let x0 = Int(Float(gx) * cell), x1 = min(w, Int(Float(gx + 1) * cell))
                var s: Float = 0, n: Float = 0
                var yy = y0; while yy < max(y1, y0 + 1) && yy < h {
                    var xx = x0; while xx < max(x1, x0 + 1) && xx < w { s += cov(x + xx, y + yy); n += 1; xx += 1 }
                    yy += 1
                }
                g[gy * gridW + gx] = n > 0 ? s / n : 0
            }
        }
        return g
    }

    struct Result { var matches: [FontMatch]; var size: CGFloat; var color: NSColor; var look: ScanLook; var ink: CGRect; var baseline: CGFloat = 0; var body: CGFloat = 0 }

    /// Finds the font, size and ink color of one line of scanned text.
    static func analyze(_ r: PageRaster, line rect: CGRect, text: String, fonts: Bool = true) -> Result? {
        let (x, y, w, h) = r.pxRect(rect.insetBy(dx: -1, dy: -1))
        guard w > 4, h > 4 else { return nil }
        let (t, bg, _) = r.threshold(x: x, y: y, w: w, h: h)
        guard bg - t > 12 else { return nil }
        // tight ink box + ink color + softness
        var minX = w, maxX = -1, minY = h, maxY = -1
        var rs = 0, gs = 0, bs = 0, n = 0, mid = 0, solid = 0
        let core = t - (t / 3)
        for yy in 0..<h { for xx in 0..<w {
            let l = r.lum(x + xx, y + yy)
            if l <= t {
                solid += 1
                if xx < minX { minX = xx }; if xx > maxX { maxX = xx }; if yy < minY { minY = yy }; if yy > maxY { maxY = yy }
                if l <= core { let i = ((y + yy) * r.width + x + xx) * 4; rs += Int(r.px[i]); gs += Int(r.px[i + 1]); bs += Int(r.px[i + 2]); n += 1 }
            } else if l < bg - (bg - t) / 4 { mid += 1 }
        } }
        guard maxX > minX, maxY > minY else { return nil }
        let color = n > 0 ? NSColor(srgbRed: CGFloat(rs / n) / 255, green: CGFloat(gs / n) / 255, blue: CGFloat(bs / n) / 255, alpha: 1)
                          : NSColor(white: CGFloat(t) / 510, alpha: 1)
        let inkW = maxX - minX + 1, inkH = maxY - minY + 1
        let softness = min(1.2, Double(mid) / Double(max(solid, 1)) * 0.9 / Double(r.scale) * 3)
        // paper noise for grain
        var bgVals: [Int] = []; bgVals.reserveCapacity(400)
        let step = max(1, (w * h) / 400)
        var k = 0
        while k < w * h { let l = r.lum(x + k % w, y + k / w); if l > t + (bg - t) / 2 { bgVals.append(l) }; k += step }
        let mean = bgVals.isEmpty ? 0 : Double(bgVals.reduce(0, +)) / Double(bgVals.count)
        let sd = bgVals.isEmpty ? 0 : sqrt(bgVals.map { pow(Double($0) - mean, 2) }.reduce(0, +) / Double(bgVals.count))
        let look = ScanLook(enabled: softness > 0.12 || sd > 4, softness: CGFloat(max(0.15, softness)), grain: CGFloat(min(0.8, sd / 18)))

        let ink = r.pageRect(x: x + minX, y: y + minY, w: inkW, h: inkH)
        // baseline = lowest row most letters sit on; body = letter height above it (ignores descenders and accents)
        var rowInk = [Int](repeating: 0, count: inkH)
        for yy in 0..<inkH { for xx in 0..<inkW where r.lum(x + minX + xx, y + minY + yy) <= t { rowInk[yy] += 1 } }
        let peak = rowInk.max() ?? 1
        let topRow = rowInk.firstIndex { $0 * 100 >= peak * 18 } ?? 0
        let baseRow = rowInk.lastIndex { $0 * 100 >= peak * 35 } ?? (inkH - 1)
        let baselineY = r.box.maxY - CGFloat(y + minY + baseRow + 1) / r.scale
        let body = CGFloat(baseRow - topRow + 1) / r.scale
        let sample = String(text.trimmingCharacters(in: .whitespaces).prefix(60))
        guard !sample.isEmpty, fonts else { return Result(matches: [], size: ink.height / 0.72, color: color, look: look, ink: ink, baseline: baselineY, body: body) }

        // Three measures, each robust to scanner blur:
        //  shape   – both texts squeezed into the same small grid (spacing drift doesn't matter much)
        //  aspect  – overall width ÷ height of the line (wide vs narrow families)
        //  density – ink per area (regular vs bold; blur moves ink around but keeps its total)
        let rows = 12
        let cols = max(6, min(240, Int((Double(rows) * Double(inkW) / Double(inkH)).rounded())))
        // True ink darkness = darkest few percent (blurred thin strokes never reach it, so a median would lie).
        var hist = [Int](repeating: 0, count: 256)
        for yy in 0..<inkH { for xx in 0..<inkW { hist[r.lum(x + minX + xx, y + minY + yy)] += 1 } }
        var acc = 0, darkest = 0
        for i in 0..<256 { acc += hist[i]; if acc * 100 >= inkW * inkH * 3 { darkest = i; break } }
        let cut = (bg + darkest) / 2
        // true ink color: the darkest pixels (we add the scanner's softness back ourselves)
        var tr = 0, tg = 0, tb = 0, tn = 0
        for yy in 0..<inkH { for xx in 0..<inkW where r.lum(x + minX + xx, y + minY + yy) <= darkest + 14 {
            let i = ((y + minY + yy) * r.width + x + minX + xx) * 4
            tr += Int(r.px[i]); tg += Int(r.px[i + 1]); tb += Int(r.px[i + 2]); tn += 1
        } }
        let trueInk = tn > 0 ? NSColor(srgbRed: CGFloat(tr / tn) / 255, green: CGFloat(tg / tn) / 255, blue: CGFloat(tb / tn) / 255, alpha: 1) : color
        // the scan's letters as a clean outline: half-way between paper and ink
        let tCov: (Int, Int) -> Float = { xx, yy in r.lum(xx, yy) < cut ? 1 : 0 }
        func stretched(_ cov: (Int, Int) -> Float, x: Int, y: Int, w: Int, h: Int) -> [Float] {
            var g = [Float](repeating: 0, count: rows * cols)
            for gy in 0..<rows {
                let y0 = y + gy * h / rows, y1 = max(y0 + 1, y + (gy + 1) * h / rows)
                for gx in 0..<cols {
                    let x0 = x + gx * w / cols, x1 = max(x0 + 1, x + (gx + 1) * w / cols)
                    var s: Float = 0, n: Float = 0
                    var yy = y0; while yy < y1 { var xx = x0; while xx < x1 { s += cov(xx, yy); n += 1; xx += 1 }; yy += 1 }
                    g[gy * cols + gx] = s / max(n, 1)
                }
            }
            return g
        }
        func centered(_ v: [Float]) -> [Float] { let m = v.reduce(0, +) / Float(max(v.count, 1)); return v.map { $0 - m } }
        let target = centered(stretched(tCov, x: x + minX, y: y + minY, w: inkW, h: inkH))
        var tMass: Float = 0
        for yy in 0..<inkH { for xx in 0..<inkW { tMass += tCov(x + minX + xx, y + minY + yy) } }
        let tDensity = Double(tMass) / Double(inkW * inkH)
        let tAspect = Double(inkW) / Double(inkH)

        let names = candidates
        var slots = [(String, Double, CGFloat)?](repeating: nil, count: names.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: names.count) { i in
            let name = names[i]
            // render once to learn the proportions, then again at the scan's exact pixel size
            guard let probe = render(sample, font: name, size: 48), probe.6 > 2 else { return }
            let px = max(8, 48 * CGFloat(inkH) / CGFloat(probe.6))
            guard let res = render(sample, font: name, size: px) else { return }
            let (cov0, rw, rh, bx, by, bw, bh) = res
            guard bw > 2, bh > 2 else { return }
            let aspect = Double(bw) / Double(bh)
            let aspectScore = exp(-abs(log(aspect / tAspect)) * 7)
            // put the candidate through the same scanner blur, then trace it exactly like the scan
            var score = -1.0
            for radius in [0, 1, 2] {
                let cov = radius == 0 ? cov0 : blurred(cov0, rw, rh, radius)
                var hist = [Int](repeating: 0, count: 101)
                for yy in by..<(by + bh) { for xx in bx..<(bx + bw) { hist[Int(cov[yy * rw + xx] * 100)] += 1 } }
                var acc = 0, top = 100
                for i in stride(from: 100, through: 0, by: -1) { acc += hist[i]; if acc * 100 >= bw * bh * 3 { top = i; break } }
                let half = Float(top) / 200
                let rc: (Int, Int) -> Float = { xx, yy in cov[yy * rw + xx] >= half ? 1 : 0 }
                let g = centered(stretched(rc, x: bx, y: by, w: bw, h: bh))
                var dot: Float = 0, na: Float = 0, nb: Float = 0
                for k in 0..<g.count { dot += g[k] * target[k]; na += g[k] * g[k]; nb += target[k] * target[k] }
                let shape = Double(dot / max(sqrt(na * nb), 1e-6))
                var mass: Float = 0
                for yy in by..<(by + bh) { for xx in bx..<(bx + bw) { mass += rc(xx, yy) } }
                let density = Double(mass) / Double(bw * bh)
                let densityScore = exp(-abs(log(max(density, 0.001) / max(tDensity, 0.001))) * 4)
                score = max(score, max(0, shape) * 0.5 + aspectScore * 0.3 + densityScore * 0.2)
            }
            let size = (CGFloat(inkW) / r.scale) / (CGFloat(bw) / px)
            lock.lock(); slots[i] = (name, score, size); lock.unlock()
        }
        var scored = slots.compactMap { $0 }
        // italics only when they clearly beat the best upright font (blurry scans fool slant)
        func isItalic(_ n: String) -> Bool { NSFontManager.shared.traits(of: NSFont(name: n, size: 12) ?? .systemFont(ofSize: 12)).contains(.italicFontMask) }
        let bestUpright = scored.filter { !isItalic($0.0) }.map(\.1).max() ?? 0
        scored = scored.map { isItalic($0.0) && $0.1 < bestUpright + 0.06 ? ($0.0, $0.1 - 0.1, $0.2) : $0 }
        scored.sort { $0.1 > $1.1 }
        let best = scored.first
        return Result(matches: scored.prefix(8).map { FontMatch(fontName: $0.0, score: $0.1) },
                      size: best?.2 ?? ink.height / 0.72, color: trueInk, look: look, ink: ink, baseline: baselineY, body: body)
    }

    /// The whole run of ink on a text line. OCR boxes often miss the first or last characters.
    static func inkRun(_ r: PageRaster, around rect: CGRect) -> CGRect {
        let h = rect.height
        // only the middle of this line's own height, so lines above and below can't bridge the gaps
        let wide = CGRect(x: rect.minX - h * 4, y: rect.minY + h * 0.2, width: rect.width + h * 8, height: h * 0.6)
        let (x, y, w, hh) = r.pxRect(wide)
        guard w > 4, hh > 4 else { return rect }
        let (t, bg, _) = r.threshold(x: x, y: y, w: w, h: hh)
        guard bg - t > 12 else { return rect }
        var col = [Bool](repeating: false, count: w)
        var rowsHit = [Int](repeating: 0, count: hh)
        for xx in 0..<w { for yy in 0..<hh where r.lum(x + xx, y + yy) <= t { col[xx] = true; rowsHit[yy] += 1 } }
        let (ix, _, iw, _) = r.pxRect(rect)
        var left = max(0, ix - x), right = min(w - 1, ix - x + iw - 1)
        let maxGap = Int(h * r.scale * 0.7)
        var gap = 0, k = left - 1
        while k >= 0 { if col[k] { left = k; gap = 0 } else { gap += 1; if gap > maxGap { break } }; k -= 1 }
        gap = 0; k = right + 1
        while k < w { if col[k] { right = k; gap = 0 } else { gap += 1; if gap > maxGap { break } }; k += 1 }
        while left < right && !col[left] { left += 1 }
        while right > left && !col[right] { right -= 1 }
        _ = rowsHit
        let run = r.pageRect(x: x + left, y: y, w: right - left + 1, h: hh)
        let grown = CGRect(x: run.minX, y: rect.minY, width: run.width, height: rect.height)
        // a missed letter or two at the ends, never a neighbouring column
        guard grown.width >= rect.width * 0.5, grown.width <= rect.width + h * 3 else { return rect }
        return grown.union(rect)
    }

    static func blurred(_ a: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        var t = a, o = a
        let d = Float(2 * r + 1)
        for y in 0..<h { for x in 0..<w { var s: Float = 0; for k in -r...r { s += a[y * w + min(max(x + k, 0), w - 1)] }; t[y * w + x] = s / d } }
        for y in 0..<h { for x in 0..<w { var s: Float = 0; for k in -r...r { s += t[min(max(y + k, 0), h - 1) * w + x] }; o[y * w + x] = s / d } }
        return o
    }

    /// Renders text black-on-white; returns coverage + tight ink box.
    /// Loading a font file is the slow part, so each candidate is loaded once and resized from then on.
    private static let fontLock = NSLock()
    private static var baseFonts: [String: CTFont] = [:]
    static func font(_ name: String, _ size: CGFloat) -> CTFont {
        fontLock.lock(); defer { fontLock.unlock() }
        if let b = baseFonts[name] { return CTFontCreateCopyWithAttributes(b, size, nil, nil) }
        let b = CTFontCreateWithName(name as CFString, 12, nil)
        baseFonts[name] = b
        return CTFontCreateCopyWithAttributes(b, size, nil, nil)
    }
    /// Loads every candidate in the background so the first click is fast too.
    static func warmUp() {
        Work.heavy.addOperation { for n in candidates { _ = font(n, 12) } }
    }

    static func render(_ s: String, font name: String, size: CGFloat) -> ([Float], Int, Int, Int, Int, Int, Int)? {
        let font = Self.font(name, size)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        let width = Int(CTLineGetTypographicBounds(line, nil, nil, nil)) + 16
        let height = Int(size * 1.8)
        guard width > 0, width < 8000 else { return nil }
        var buf = [UInt8](repeating: 255, count: width * height)
        let ok = buf.withUnsafeMutableBytes { b -> Bool in
            guard let ctx = CGContext(data: b.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.textPosition = CGPoint(x: 8, y: size * 0.45)
            CTLineDraw(line, ctx)
            return true
        }
        guard ok else { return nil }
        var cov = [Float](repeating: 0, count: width * height)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for yy in 0..<height { for xx in 0..<width {
            let c = Float(255 - Int(buf[yy * width + xx])) / 255
            cov[yy * width + xx] = c
            if c > 0.45 { if xx < minX { minX = xx }; if xx > maxX { maxX = xx }; if yy < minY { minY = yy }; if yy > maxY { maxY = yy } }
        } }
        guard maxX > minX, maxY > minY else { return nil }
        return (cov, width, height, minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    /// Fonts embedded in PDFs are often trimmed to the letters used. Swap in the installed font when a new letter is missing.
    static func usable(_ font: NSFont, for text: String) -> NSFont? {
        let chars = Array(text.utf16)
        guard !chars.isEmpty else { return nil }
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        if CTFontGetGlyphsForCharacters(font as CTFont, chars, &glyphs, chars.count) { return nil }
        var base = font.fontName
        if let plus = base.firstIndex(of: "+") { base = String(base[base.index(after: plus)...]) }
        if let f = NSFont(name: base, size: font.pointSize), f.fontName != font.fontName { return f }
        let fam = (font.familyName ?? base).components(separatedBy: "+").last ?? base
        if let f = NSFontManager.shared.font(withFamily: fam, traits: NSFontManager.shared.traits(of: font), weight: 5, size: font.pointSize) { return f }
        return NSFont(name: "Helvetica", size: font.pointSize)
    }
}

// MARK: - What's on a page that can be edited

final class TextBlock: Identifiable {
    let id = UUID()
    weak var page: PDFPage?
    var lines: [CGRect]        // where the original text sits
    var textRect: CGRect       // where the editable text goes
    var content: NSAttributedString
    var isScan: Bool
    var matches: [FontMatch] = []
    var look = ScanLook()
    var sample: (rect: CGRect, word: String)?   // one clean word to match the font on
    var prepared = false                       // font/size/color already matched in the background
    var patch: (CGImage, CGRect)?              // pre-cleaned paper for this line
    weak var annotation: RichTextAnnotation?

    init(page: PDFPage, lines: [CGRect], textRect: CGRect, content: NSAttributedString, isScan: Bool) {
        self.page = page; self.lines = lines; self.textRect = textRect; self.content = content; self.isScan = isScan
    }
    var area: CGRect { lines.reduce(textRect) { $0.union($1) } }
}

enum PageAnalyzer {
    /// True for scans, including scans that already have an invisible OCR text layer.
    private static var scanCache = NSMapTable<PDFPage, NSNumber>.weakToStrongObjects()
    private static let cacheLock = NSLock()
    static func isScan(_ page: PDFPage) -> Bool {
        cacheLock.lock(); let hit = scanCache.object(forKey: page); cacheLock.unlock()
        if let hit { return hit.boolValue }
        let s = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let v = s.isEmpty || hasInvisibleText(page)
        cacheLock.lock(); scanCache.setObject(NSNumber(value: v), forKey: page); cacheLock.unlock()
        return v
    }

    /// Accurate OCR of just one paragraph, run when you click it (the page scan uses the fast pass).
    static func refineText(_ b: TextBlock, raster: PageRaster) {
        guard let full = raster.cgImage else { return }
        let area = b.lines.reduce(b.lines.first ?? b.textRect) { $0.union($1) }.insetBy(dx: -3, dy: -3)
        let (x, y, w, h) = raster.pxRect(area)
        guard w > 4, h > 4, let crop = full.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { return }
        let obs = OCR.observations(crop).filter { $0.topCandidates(1).first != nil && abs($0.boundingBox.midY - 0.5) < 0.3 }
        guard !obs.isEmpty else { return }
        // group pieces into lines by vertical overlap, then read each line left to right
        var rows: [[VNRecognizedTextObservation]] = []
        for o in obs.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            if let i = rows.firstIndex(where: { row in
                let r = row[0].boundingBox
                return abs(r.midY - o.boundingBox.midY) < max(r.height, o.boundingBox.height) * 0.5
            }) { rows[i].append(o) } else { rows.append([o]) }
        }
        var lines = rows.map { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
               .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
        // a block is one line on scans; never invent extra lines
        if b.lines.count == 1 { lines = [lines.joined(separator: " ")] }
        // the longest plain word, with its exact box: punctuation and spacing can't confuse the font match there
        let pr = raster.pageRect(x: x, y: y, w: w, h: h)
        var best: (CGRect, String)?
        for o in obs {
            guard let c = o.topCandidates(1).first else { continue }
            let str = c.string
            var idx = str.startIndex
            for word in str.split(separator: " ") {
                guard let r = str.range(of: word, range: idx..<str.endIndex) else { continue }
                idx = r.upperBound
                let clean = word.trimmingCharacters(in: .punctuationCharacters)
                guard clean.count >= 3, clean.allSatisfy({ $0.isLetter || $0.isNumber }), clean.count > (best?.1.count ?? 0),
                      let cr = str.range(of: clean, range: r),
                      let box = try? c.boundingBox(for: cr)?.boundingBox else { continue }
                best = (CGRect(x: pr.minX + box.minX * pr.width, y: pr.minY + box.minY * pr.height,
                               width: box.width * pr.width, height: box.height * pr.height), clean)
            }
        }
        if let bw = best { b.sample = (bw.0, bw.1) }
        guard !lines.isEmpty else { return }
        let attrs = b.content.length > 0 ? b.content.attributes(at: 0, effectiveRange: nil) : [:]
        b.content = NSAttributedString(string: lines.joined(separator: "\n"), attributes: attrs)
    }

    static func hasInvisibleText(_ page: PDFPage) -> Bool {
        guard let cg = page.pageRef else { return false }
        final class Flag { var hit = false }
        let flag = Flag()
        guard let table = CGPDFOperatorTableCreate() else { return false }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode), mode == 3, let info {
                Unmanaged<Flag>.fromOpaque(info).takeUnretainedValue().hit = true
            }
        }
        let stream = CGPDFContentStreamCreateWithPage(cg)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(flag).toOpaque())
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return flag.hit
    }

    /// Finds paragraphs of text. Fast; font matching for scans happens later, per block.
    static func blocks(_ page: PDFPage, raster: PageRaster?) -> [TextBlock] {
        if isScan(page) { return scanBlocks(page, raster: raster) }
        return vectorBlocks(page)
    }

    private struct Line { var rect: CGRect; var text: NSAttributedString; var size: CGFloat }

    private static func group(_ lines: [Line]) -> [[Line]] {
        let sorted = lines.sorted { $0.rect.maxY > $1.rect.maxY }
        var out: [[Line]] = []
        for l in sorted {
            if var last = out.last, let prev = last.last {
                let gap = prev.rect.minY - l.rect.maxY
                let sameSize = abs(prev.size - l.size) < max(prev.size, l.size) * 0.2
                let aligned = abs(prev.rect.minX - l.rect.minX) < prev.size * 2.5 || abs(prev.rect.midX - l.rect.midX) < prev.size * 2
                let overlapX = min(prev.rect.maxX, l.rect.maxX) - max(prev.rect.minX, l.rect.minX) > -prev.size
                if gap < prev.size * 0.9, gap > -prev.size * 0.5, sameSize, aligned, overlapX {
                    last.append(l); out[out.count - 1] = last; continue
                }
            }
            out.append([l])
        }
        return out
    }

    private static func vectorBlocks(_ page: PDFPage) -> [TextBlock] {
        guard let all = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        var lines: [Line] = []
        for sel in all.selectionsByLine() {
            guard let a = sel.attributedString, a.string.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else { continue }
            let trimmed = NSMutableAttributedString(attributedString: a)
            while trimmed.string.hasSuffix("\n") || trimmed.string.hasSuffix("\r") { trimmed.deleteCharacters(in: NSRange(location: trimmed.length - 1, length: 1)) }
            let size = (a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? sel.bounds(for: page).height
            lines.append(Line(rect: sel.bounds(for: page), text: trimmed, size: size))
        }
        return group(lines).map { para in
            let text = NSMutableAttributedString()
            var pitch: CGFloat = 0
            if para.count > 1 {
                pitch = (para.first!.rect.minY - para.last!.rect.minY) / CGFloat(para.count - 1)
            }
            for (i, l) in para.enumerated() {
                if i > 0 { text.append(NSAttributedString(string: "\n", attributes: l.text.attributes(at: 0, effectiveRange: nil))) }
                text.append(l.text)
            }
            // normalise each run into our attribute set, keeping the PDF's own font
            let full = NSRange(location: 0, length: text.length)
            text.enumerateAttributes(in: full) { attrs, range, _ in
                var f = TextFormat.from(attrs)
                f.lineHeight = pitch > 0 ? pitch.rounded() : 0
                text.setAttributes(f.attributes(), range: range)
            }
            let union = para.map(\.rect).reduce(para[0].rect) { $0.union($1) }
            var tr = union
            tr.size.width = union.width + 4
            return TextBlock(page: page, lines: para.map(\.rect), textRect: tr, content: text, isScan: false)
        }
    }

    private static func scanBlocks(_ page: PDFPage, raster: PageRaster?) -> [TextBlock] {
        guard let raster, let img = raster.cgImage else { return [] }
        let obs = OCR.observations(img, fast: true)
        let box = raster.box
        var lines: [Line] = []
        for o in obs {
            guard let c = o.topCandidates(1).first else { continue }
            let bb = o.boundingBox
            let r = CGRect(x: box.minX + bb.minX * box.width, y: box.minY + bb.minY * box.height,
                           width: bb.width * box.width, height: bb.height * box.height)
            lines.append(Line(rect: r, text: NSAttributedString(string: c.string), size: r.height * 0.9))
        }
        // the fast reader sometimes splits one printed line into pieces; put them back together
        var merged: [Line] = []
        for l in lines.sorted(by: { abs($0.rect.midY - $1.rect.midY) > min($0.rect.height, $1.rect.height) * 0.5 ? $0.rect.midY > $1.rect.midY : $0.rect.minX < $1.rect.minX }) {
            if let i = merged.lastIndex(where: { m in
                let h = max(m.rect.height, l.rect.height)
                let sameRow = abs(m.rect.midY - l.rect.midY) < h * 0.5
                let gap = l.rect.minX - m.rect.maxX
                return sameRow && gap < h * 0.6 && gap > -m.rect.width
            }) {
                var m = merged[i]
                let left = m.rect.minX <= l.rect.minX
                m.text = NSAttributedString(string: left ? m.text.string + " " + l.text.string : l.text.string + " " + m.text.string)
                m.rect = m.rect.union(l.rect)
                merged[i] = m
            } else { merged.append(l) }
        }
        return merged.map { [$0] }.map { para in
            let text = NSMutableAttributedString(string: para.map(\.text.string).joined(separator: "\n"),
                                                 attributes: TextFormat(fontName: "Helvetica", size: max(6, para[0].size * 0.8), color: .black).attributes())
            let union = para.map(\.rect).reduce(para[0].rect) { $0.union($1) }
            return TextBlock(page: page, lines: para.map(\.rect), textRect: union, content: text, isScan: true)
        }
    }

    /// Matches font, size, color and the scanner's softness for a scanned paragraph, and positions text on the original baselines.
    static func match(_ b: TextBlock, raster: PageRaster) {
        guard b.isScan else { matchVector(b); return }
        b.lines = b.lines.map { FontMatcher.inkRun(raster, around: $0) }
        refineText(b, raster: raster)
        let strings = b.content.string.components(separatedBy: "\n")
        var results: [(FontMatcher.Result, String)] = []
        let order = Array(zip(b.lines, strings)).sorted { $0.1.count > $1.1.count }
        if let sw = b.sample, let r = FontMatcher.analyze(raster, line: sw.rect.insetBy(dx: -1, dy: -sw.rect.height * 0.1), text: sw.word) {
            results.append((r, sw.word))
        }
        if results.isEmpty {
            for (rect, s) in order.prefix(order.first.map { $0.1.count < 12 } == true ? 2 : 1) {
                if let r = FontMatcher.analyze(raster, line: rect, text: s) { results.append((r, s)) }
            }
        }
        guard let main = results.first?.0 else { return }
        // combine scores across sampled lines
        var total: [String: Double] = [:]
        for (r, _) in results { for m in r.matches { total[m.fontName, default: 0] += m.score } }
        let ranked = total.sorted { $0.value > $1.value }.map { FontMatch(fontName: $0.key, score: $0.value / Double(results.count)) }
        b.matches = Array(ranked.prefix(8))
        let fontName = ranked.first?.fontName ?? "Helvetica"
        // size: from letter height (cap height for caps/digits, x-height for lowercase), cross-checked with width
        var hSizes: [CGFloat] = [], wSizes: [CGFloat] = []
        var inks: [CGRect] = [], baselines: [CGFloat] = []
        let probe = NSFont(name: fontName, size: 100) ?? .systemFont(ofSize: 100)
        for (rect, s) in zip(b.lines, strings) {
            guard let r = FontMatcher.analyze(raster, line: rect, text: s, fonts: false) else { continue }
            inks.append(r.ink); baselines.append(r.baseline)
            let letters = s.filter { $0.isLetter || $0.isNumber }
            let tall = letters.filter { $0.isUppercase || $0.isNumber || "bdfhklt".contains($0) }.count
            let ratio = (tall * 2 >= letters.count ? probe.capHeight : probe.xHeight) / 100
            if ratio > 0, r.body > 0 { hSizes.append(r.body / ratio) }
            if let res = FontMatcher.render(String(s.trimmingCharacters(in: .whitespaces).prefix(60)), font: fontName, size: 48), res.5 > 0 {
                wSizes.append(r.ink.width / (CGFloat(res.5) / 48))
            }
        }
        func median(_ a: [CGFloat]) -> CGFloat? { a.isEmpty ? nil : a.sorted()[a.count / 2] }
        // width fit is exact once the line is read correctly; letter height is the fallback
        var size = median(wSizes) ?? median(hSizes) ?? main.size
        if let h = median(hSizes), abs(size - h) / h > 0.3 { size = h }
        size = size.rounded(toPlaces: 1)
        var f = TextFormat(fontName: fontName, size: size, color: main.color)
        let font = f.font
        if baselines.count > 1 {
            f.lineHeight = ((baselines.first! - baselines.last!) / CGFloat(baselines.count - 1)).rounded(toPlaces: 1)
        }
        let first = baselines.first ?? (b.lines.first?.minY ?? 0)
        let lineH = f.lineHeight > 0 ? f.lineHeight : (font.ascender - font.descender + font.leading)
        let top = f.lineHeight > 0 ? first + lineH + font.descender : first + font.ascender + font.leading
        let left = inks.map(\.minX).min() ?? b.textRect.minX
        let width = (inks.map(\.maxX).max() ?? b.textRect.maxX) - left
        let n = CGFloat(max(strings.count, 1))
        b.textRect = CGRect(x: left, y: top - lineH * n, width: width + size * 0.5, height: lineH * n)
        b.content = NSAttributedString(string: b.content.string, attributes: f.attributes())
        b.look = main.look
    }

    private static func matchVector(_ b: TextBlock) {
        guard b.content.length > 0, let font = b.content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return }
        var list = [FontMatch(fontName: font.fontName, score: 1)]
        var base = font.fontName
        if let plus = base.firstIndex(of: "+") { base = String(base[base.index(after: plus)...]) }
        if base != font.fontName, NSFont(name: base, size: 12) != nil { list.append(FontMatch(fontName: base, score: 0.99)) }
        b.matches = list
    }
}

extension CGFloat { func rounded(toPlaces p: Int) -> CGFloat { let m = pow(10, CGFloat(p)); return (self * m).rounded() / m } }

// MARK: - The edited text, drawn on the page

final class RichTextAnnotation: PDFAnnotation {
    var patch: CGImage?
    var patchRect: CGRect = .zero
    var content = NSAttributedString()
    var textRect: CGRect = .zero { didSet { refreshBounds() } }
    var look = ScanLook() { didSet { cache = nil } }
    var rotation: CGFloat = 0
    var opacity: CGFloat = 1
    var isEditing = false
    var kind = "edit"     // edit · added · watermark · header
    private var cache: (key: Int, img: CGImage)?

    convenience init(textRect: CGRect, content: NSAttributedString) {
        self.init(bounds: textRect, forType: .stamp, withProperties: nil)
        self.textRect = textRect
        self.content = content
        userName = "vitalos-richtext"
        // PDFKit draws annotations at their color's opacity; an unset stamp color comes out faded
        color = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        border = nil
        refreshBounds()
    }

    func refreshBounds() {
        var b = textRect
        if patch != nil { b = b.union(patchRect) }
        if rotation != 0 { b = b.insetBy(dx: -b.height, dy: -b.width / 2) }
        bounds = b.insetBy(dx: -2, dy: -2)
        cache = nil
    }

    func setContent(_ c: NSAttributedString) { content = c; cache = nil }

    /// PDFKit fades custom annotations, so it never draws these: the edit layer draws them on screen,
    /// and the flattener draws them into the saved file.
    override func draw(with box: PDFDisplayBox, in ctx: CGContext) {}

    func render(in ctx: CGContext, textToo: Bool = true) {
        ctx.saveGState()
        ctx.setAlpha(1); ctx.setBlendMode(.normal); ctx.setTextDrawingMode(.fill); ctx.setShouldAntialias(true)
        if let patch { ctx.interpolationQuality = .high; ctx.draw(patch, in: patchRect) }
        if textToo && !isEditing && content.length > 0 {
            ctx.setAlpha(opacity)
            if rotation != 0 {
                ctx.translateBy(x: textRect.midX, y: textRect.midY)
                ctx.rotate(by: rotation * .pi / 180)
                ctx.translateBy(x: -textRect.midX, y: -textRect.midY)
            }
            if look.enabled, let img = scanImage() {
                ctx.draw(img, in: textRect)
            } else {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                content.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        ctx.restoreGState()
    }

    /// Text rendered like it went through a scanner: slightly soft, with speckled ink.
    private func scanImage() -> CGImage? {
        var hasher = Hasher()
        hasher.combine(content); hasher.combine(textRect.width); hasher.combine(textRect.height)
        hasher.combine(look.softness); hasher.combine(look.grain)
        let key = hasher.finalize()
        if let c = cache, c.key == key { return c.img }
        let s: CGFloat = 4
        let w = Int(textRect.width * s), h = Int(textRect.height * s)
        guard w > 0, h > 0, w * h < 40_000_000 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let content = self.content, rect = textRect
        let ok = px.withUnsafeMutableBytes { b -> Bool in
            guard let c = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.scaleBy(x: s, y: s)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
            content.draw(with: CGRect(origin: .zero, size: rect.size), options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        guard ok else { return nil }
        // blur (box blur twice ≈ gaussian)
        let radius = Int((look.softness * s * 0.5).rounded())
        if radius > 0 { Self.boxBlur(&px, w, h, radius) }
        // grain: knock random bits out of the ink, darken others
        if look.grain > 0 {
            var g = SystemRandomNumberGenerator()
            for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 {
                let r = Double(UInt8.random(in: 0...255, using: &g)) / 255
                let f = 1 - Double(look.grain) * 0.22 * r
                for k in 0..<4 { px[i + k] = UInt8(Double(px[i + k]) * f) }
            }
        }
        guard let prov = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        cache = (key, img)
        return img
    }

    private static func boxBlur(_ px: inout [UInt8], _ w: Int, _ h: Int, _ r: Int) {
        var tmp = px
        let d = r * 2 + 1
        for y in 0..<h {
            var acc = [Int](repeating: 0, count: 4)
            for x in -r...r { let xx = min(max(x, 0), w - 1); for k in 0..<4 { acc[k] += Int(px[(y * w + xx) * 4 + k]) } }
            for x in 0..<w {
                for k in 0..<4 { tmp[(y * w + x) * 4 + k] = UInt8(acc[k] / d) }
                let out = min(max(x - r, 0), w - 1), inn = min(max(x + r + 1, 0), w - 1)
                for k in 0..<4 { acc[k] += Int(px[(y * w + inn) * 4 + k]) - Int(px[(y * w + out) * 4 + k]) }
            }
        }
        for x in 0..<w {
            var acc = [Int](repeating: 0, count: 4)
            for y in -r...r { let yy = min(max(y, 0), h - 1); for k in 0..<4 { acc[k] += Int(tmp[(yy * w + x) * 4 + k]) } }
            for y in 0..<h {
                for k in 0..<4 { px[(y * w + x) * 4 + k] = UInt8(acc[k] / d) }
                let out = min(max(y - r, 0), h - 1), inn = min(max(y + r + 1, 0), h - 1)
                for k in 0..<4 { acc[k] += Int(tmp[(inn * w + x) * 4 + k]) - Int(tmp[(out * w + x) * 4 + k]) }
            }
        }
    }
}

/// A placed picture (logo, photo, stamp).
final class ImageStampAnnotation: PDFAnnotation {
    var image: CGImage?
    var opacity: CGFloat = 1
    convenience init(image: CGImage, rect: CGRect) {
        self.init(bounds: rect, forType: .stamp, withProperties: nil)
        self.image = image
        userName = "vitalos-image"
        color = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        border = nil
    }
    override func draw(with box: PDFDisplayBox, in ctx: CGContext) {}

    func render(in ctx: CGContext) {
        guard let image else { return }
        ctx.saveGState(); ctx.setAlpha(opacity); ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)
        ctx.restoreGState()
    }
}

// MARK: - Saving: burn edits into the page

enum PDFFlattener {
    static func isCustom(_ a: PDFAnnotation) -> Bool { a is RichTextAnnotation || a is ImageStampAnnotation }

    /// The page as pixels, including your edited text and placed images.
    static func renderWithEdits(_ page: PDFPage, scale: CGFloat = 3) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        for a in page.annotations {
            if let t = a as? RichTextAnnotation { t.render(in: ctx) } else if let i = a as? ImageStampAnnotation { i.render(in: ctx) }
        }
        return ctx.makeImage()
    }

    /// New document where edited text and images are real page content (vector text, re-editable next time).
    static func flatten(_ doc: PDFDocument) -> PDFDocument {
        let out = PDFDocument()
        out.documentAttributes = doc.documentAttributes
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let customs = page.annotations.filter(isCustom)
            if customs.isEmpty {
                if let c = page.copy() as? PDFPage { out.insert(c, at: out.pageCount) }
                continue
            }
            let scan = PageAnalyzer.isScan(page)
            let others = page.annotations.filter { !isCustom($0) }
            others.forEach { $0.shouldDisplay = false }
            customs.forEach { $0.shouldDisplay = false }
            let rot = page.rotation
            page.rotation = 0
            var box = page.bounds(for: .mediaBox)
            let data = NSMutableData()
            var newPage: PDFPage?
            if let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) {
                ctx.beginPDFPage(nil)
                page.draw(with: .mediaBox, to: ctx)
                ctx.saveGState()
                ctx.translateBy(x: -box.minX, y: -box.minY)
                for a in customs {
                    if let t = a as? RichTextAnnotation { t.render(in: ctx) }
                    else if let i = a as? ImageStampAnnotation { i.render(in: ctx) }
                }
                ctx.restoreGState()
                ctx.endPDFPage(); ctx.closePDF()
                newPage = PDFDocument(data: data as Data)?.page(at: 0)
            }
            if scan, let np = newPage, let img = OCR.render(np, scale: 3) {
                // scans: rebuild the hidden text layer so search finds the new words, not the old ones
                let ns = NSImage(cgImage: img, size: box.size)
                if let flat = PDFPage(image: ns) { newPage = PDFEditorModel.searchablePage(flat, image: img) ?? flat }
            }
            page.rotation = rot
            others.forEach { $0.shouldDisplay = true }
            customs.forEach { $0.shouldDisplay = true }
            guard let np = newPage else { if let c = page.copy() as? PDFPage { out.insert(c, at: out.pageCount) }; continue }
            np.setBounds(page.bounds(for: .cropBox), for: .cropBox)
            np.rotation = rot
            for a in others { if let c = a.copy() as? PDFAnnotation { np.addAnnotation(c) } }
            out.insert(np, at: out.pageCount)
        }
        return out
    }
}
