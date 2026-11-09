import CoreGraphics
import Foundation

/// A rectangle in pixel coordinates, origin top-left.
public struct PixelRect: Equatable, Sendable {
    public var x, y, width, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum FrameDiff {
    /// Bounding box of pixels whose per-channel absolute difference exceeds `threshold`.
    /// Returns nil when nothing changed. Images of different sizes count as a full-frame
    /// change (the union of both sizes, anchored top-left).
    public static func changedBounds(_ a: CGImage, _ b: CGImage, in region: PixelRect?,
                                     threshold: UInt8 = 16) -> PixelRect? {
        guard a.width == b.width, a.height == b.height else {
            return PixelRect(x: 0, y: 0, width: max(a.width, b.width), height: max(a.height, b.height))
        }
        let w = a.width, h = a.height
        var x0 = 0, y0 = 0, x1 = w, y1 = h
        if let r = region {
            x0 = max(0, r.x); y0 = max(0, r.y)
            x1 = min(w, r.x + r.width); y1 = min(h, r.y + r.height)
        }
        guard x0 < x1, y0 < y1,
              let pa = render(a), let pb = render(b) else { return nil }
        let t = Int(threshold)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        pa.withUnsafeBufferPointer { ba in
            pb.withUnsafeBufferPointer { bb in
                for y in y0..<y1 {
                    let row = y * w * 4
                    // Fast path: identical rows.
                    if memcmp(ba.baseAddress! + row + x0 * 4, bb.baseAddress! + row + x0 * 4,
                              (x1 - x0) * 4) == 0 { continue }
                    for x in x0..<x1 {
                        let i = row + x * 4
                        if abs(Int(ba[i]) - Int(bb[i])) > t
                            || abs(Int(ba[i + 1]) - Int(bb[i + 1])) > t
                            || abs(Int(ba[i + 2]) - Int(bb[i + 2])) > t
                            || abs(Int(ba[i + 3]) - Int(bb[i + 3])) > t {
                            if x < minX { minX = x }
                            if x > maxX { maxX = x }
                            if y < minY { minY = y }
                            if y > maxY { maxY = y }
                        }
                    }
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// False for nil bounds or bounds no wider than `caretMaxWidth` (caret blink / cursor animation).
    public static func isContentChange(_ bounds: PixelRect?, caretMaxWidth: Int = 4) -> Bool {
        guard let bounds else { return false }
        return bounds.width > caretMaxWidth
    }

    /// True when every pixel (inside `region`, if given) is within `threshold` of the first one.
    public static func isBlank(_ image: CGImage, in region: PixelRect? = nil, threshold: UInt8 = 16) -> Bool {
        guard let p = render(image), p.count >= 4 else { return true }
        return isBlank(p, image.width, image.height, region, threshold)
    }

    private static func isBlank(_ p: [UInt8], _ w: Int, _ h: Int, _ region: PixelRect?, _ threshold: UInt8) -> Bool {
        let (x0, y0, x1, y1) = clamp(region, w, h)
        guard x0 < x1, y0 < y1 else { return true }
        let t = Int(threshold)
        let first = (y0 * w + x0) * 4
        let c0 = Int(p[first]), c1 = Int(p[first + 1]), c2 = Int(p[first + 2]), c3 = Int(p[first + 3])
        return p.withUnsafeBufferPointer { b in
            for y in y0..<y1 {
                var i = (y * w + x0) * 4
                for _ in x0..<x1 {
                    if abs(Int(b[i]) - c0) > t || abs(Int(b[i + 1]) - c1) > t
                        || abs(Int(b[i + 2]) - c2) > t || abs(Int(b[i + 3]) - c3) > t { return false }
                    i += 4
                }
            }
            return true
        }
    }

    /// Bounding box of (near-)opaque pixels: the union of an application's windows in an application-scoped
    /// capture. Everything else is transparent, and drop shadows are partly transparent so they are excluded.
    /// nil when nothing is visible.
    public static func opaqueBounds(_ image: CGImage) -> PixelRect? {
        guard let p = render(image) else { return nil }
        return opaqueBounds(p, image.width, image.height)
    }

    private static func opaqueBounds(_ p: [UInt8], _ w: Int, _ h: Int) -> PixelRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        p.withUnsafeBufferPointer { b in
            for y in 0..<h {
                var i = y * w * 4 + 3
                for x in 0..<w {
                    if b[i] >= 250 {
                        if x < minX { minX = x }; if x > maxX { maxX = x }
                        if y < minY { minY = y }; maxY = y
                    }
                    i += 4
                }
            }
        }
        return maxX < 0 ? nil : PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Fraction of rows (within `region`) that look like text: at least `minTransitions` luminance jumps
    /// larger than `contrast` between horizontally adjacent pixels. Flat fills, borders and gradients
    /// have few transitions; glyph rows have many. "Text painted" = fraction >= 0.30.
    public static func textRowFraction(_ image: CGImage, in region: PixelRect? = nil,
                                       contrast: Int = 40, minTransitions: Int = 6) -> Double {
        guard let p = render(image) else { return 0 }
        return textRowFraction(p, image.width, image.height, region, contrast, minTransitions)
    }

    private static func textRowFraction(_ p: [UInt8], _ w: Int, _ h: Int, _ region: PixelRect?,
                                        _ contrast: Int, _ minTransitions: Int) -> Double {
        let (x0, y0, x1, y1) = clamp(region, w, h)
        guard x0 < x1, y0 < y1 else { return 0 }
        var textRows = 0
        p.withUnsafeBufferPointer { b in
            for y in y0..<y1 {
                var i = (y * w + x0) * 4
                var prev = lum(b, i)
                var n = 0
                for _ in (x0 + 1)..<max(x1, x0 + 1) {
                    i += 4
                    let l = lum(b, i)
                    if abs(l - prev) > contrast { n += 1 }
                    prev = l
                }
                if n >= minTransitions { textRows += 1 }
            }
        }
        return Double(textRows) / Double(y1 - y0)
    }

    /// One-render analysis of an application-scoped frame (see `opaqueBounds`): the app's visible region,
    /// whether it is still blank, and its text-row fraction. The region is inset by `inset` px so window
    /// shadows and rounded corners do not count as content.
    public struct AppFrame: Sendable {
        public var bounds: PixelRect?
        public var blank: Bool
        public var textFraction: Double
    }

    public static func analyzeAppFrame(_ image: CGImage, inset: Int = 12) -> AppFrame {
        guard let p = render(image), let b = opaqueBounds(p, image.width, image.height) else {
            return AppFrame(bounds: nil, blank: true, textFraction: 0)
        }
        let r = PixelRect(x: b.x + inset, y: b.y + inset, width: max(0, b.width - 2 * inset), height: max(0, b.height - 2 * inset))
        return AppFrame(bounds: b, blank: isBlank(p, image.width, image.height, r, 16),
                        textFraction: textRowFraction(p, image.width, image.height, r, 40, 6))
    }

    // MARK: Cropped pixel buffers (render a region once, reuse it for blank / diff / text analysis)

    /// A tightly packed BGRA8 crop of an image. Rendering only the crop keeps per-frame cost proportional to the
    /// region and lets a baseline be rendered once and reused.
    public struct Pixels: Sendable {
        public let width, height: Int
        let data: [UInt8]
    }

    /// Renders `region` (clamped to the image) into its own buffer; nil when the clamped region is empty.
    public static func crop(_ image: CGImage, to region: PixelRect) -> Pixels? {
        let x0 = max(0, region.x), y0 = max(0, region.y)
        let x1 = min(image.width, region.x + region.width), y1 = min(image.height, region.y + region.height)
        guard x0 < x1, y0 < y1 else { return nil }
        let cw = x1 - x0, ch = y1 - y0
        var buf = [UInt8](repeating: 0, count: cw * ch * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: cw, height: ch, bitsPerComponent: 8,
                                      bytesPerRow: cw * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: -x0, y: -(image.height - y1), width: image.width, height: image.height))
            return true
        }
        return ok ? Pixels(width: cw, height: ch, data: buf) : nil
    }

    public static func isBlank(_ px: Pixels, threshold: UInt8 = 16) -> Bool {
        isBlank(px.data, px.width, px.height, nil, threshold)
    }

    /// Bounding box of pixels that differ between two crops (different sizes count as a full change).
    public static func changedBounds(_ a: Pixels, _ b: Pixels, threshold: UInt8 = 16) -> PixelRect? {
        guard a.width == b.width, a.height == b.height else {
            return PixelRect(x: 0, y: 0, width: max(a.width, b.width), height: max(a.height, b.height))
        }
        let t = Int(threshold), w = a.width
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        a.data.withUnsafeBufferPointer { ba in
            b.data.withUnsafeBufferPointer { bb in
                for y in 0..<a.height {
                    let row = y * w * 4
                    if memcmp(ba.baseAddress! + row, bb.baseAddress! + row, w * 4) == 0 { continue }
                    for x in 0..<w {
                        let i = row + x * 4
                        if abs(Int(ba[i]) - Int(bb[i])) > t || abs(Int(ba[i + 1]) - Int(bb[i + 1])) > t
                            || abs(Int(ba[i + 2]) - Int(bb[i + 2])) > t || abs(Int(ba[i + 3]) - Int(bb[i + 3])) > t {
                            if x < minX { minX = x }; if x > maxX { maxX = x }
                            if y < minY { minY = y }; maxY = y
                        }
                    }
                }
            }
        }
        return maxX < 0 ? nil : PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Per-row glyph-transition signature: (number of luminance jumps > `contrast`, hash of their x positions).
    /// Per-row transition counts and hashes of a crop; compute once for a baseline and reuse it for every frame.
    public struct RowSignatures: Sendable {
        let width, height: Int
        let rows: [(n: Int, hash: UInt64)]
    }

    public static func rowSignatures(_ px: Pixels, contrast: Int = 40) -> RowSignatures {
        var out: [(Int, UInt64)] = []
        out.reserveCapacity(px.height)
        px.data.withUnsafeBufferPointer { b in
            for y in 0..<px.height {
                var i = y * px.width * 4
                var prev = lum(b, i)
                var n = 0
                var h: UInt64 = 14695981039346656037
                for x in 1..<max(px.width, 1) {
                    i += 4
                    let l = lum(b, i)
                    if abs(l - prev) > contrast { n += 1; h = (h ^ UInt64(x)) &* 1099511628211 }
                    prev = l
                }
                out.append((n, h))
            }
        }
        return RowSignatures(width: px.width, height: px.height, rows: out)
    }

    /// Fraction of rows that look like text (>= `minTransitions` jumps) AND whose transition pattern differs from
    /// the same row of `baseline` (when given). Text that was already there in the baseline never counts.
    public static func textRowFraction(_ px: Pixels, differingFrom baseline: Pixels?,
                                       contrast: Int = 40, minTransitions: Int = 6) -> Double {
        textRowFraction(px, differingFrom: baseline.map { rowSignatures($0, contrast: contrast) },
                        contrast: contrast, minTransitions: minTransitions)
    }

    /// Same, with the baseline's row signatures precomputed (they never change, so callers cache them).
    public static func textRowFraction(_ px: Pixels, differingFrom baseline: RowSignatures?,
                                       contrast: Int = 40, minTransitions: Int = 6) -> Double {
        guard px.height > 0, px.width > 1 else { return 0 }
        let cur = rowSignatures(px, contrast: contrast).rows
        var base: [(n: Int, hash: UInt64)]?
        if let baseline, baseline.width == px.width, baseline.height == px.height { base = baseline.rows }
        var rows = 0
        for y in 0..<cur.count where cur[y].n >= minTransitions {
            if let base, base[y].n == cur[y].n, base[y].hash == cur[y].hash { continue }
            rows += 1
        }
        return Double(rows) / Double(px.height)
    }

    private static func lum(_ b: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int {
        (Int(b[i]) * 29 + Int(b[i + 1]) * 150 + Int(b[i + 2]) * 77) >> 8
    }

    private static func clamp(_ r: PixelRect?, _ w: Int, _ h: Int) -> (Int, Int, Int, Int) {
        guard let r else { return (0, 0, w, h) }
        return (max(0, r.x), max(0, r.y), min(w, r.x + r.width), min(h, r.y + r.height))
    }

    /// Renders into a tightly packed BGRA8 (premultiplied alpha) buffer.
    private static func render(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }
}
