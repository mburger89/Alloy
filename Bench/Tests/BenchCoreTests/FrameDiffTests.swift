import CoreGraphics
import Foundation
import Testing
@testable import BenchCore

private func makeImage(width: Int = 200, height: Int = 100,
                       base: (UInt8, UInt8, UInt8) = (255, 255, 255),
                       paint: [(PixelRect, (UInt8, UInt8, UInt8))] = []) -> CGImage {
    var data = [UInt8](repeating: 255, count: width * height * 4)
    func set(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
        let i = (y * width + x) * 4
        data[i] = c.0; data[i + 1] = c.1; data[i + 2] = c.2; data[i + 3] = 255
    }
    for y in 0..<height { for x in 0..<width { set(x, y, base) } }
    for (r, c) in paint {
        for y in r.y..<(r.y + r.height) { for x in r.x..<(r.x + r.width) { set(x, y, c) } }
    }
    let provider = CGDataProvider(data: Data(data) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

@Suite struct FrameDiffTests {
    @Test func identicalIsNil() {
        #expect(FrameDiff.changedBounds(makeImage(), makeImage(), in: nil) == nil)
    }

    @Test func singleGlyphChangeIsContent() {
        let r = PixelRect(x: 40, y: 30, width: 8, height: 12)
        let b = makeImage(paint: [(r, (0, 0, 0))])
        let bounds = FrameDiff.changedBounds(makeImage(), b, in: nil)
        #expect(bounds == r)
        #expect(FrameDiff.isContentChange(bounds))
    }

    @Test func caretBlinkIsNotContent() {
        let r = PixelRect(x: 60, y: 20, width: 2, height: 16)
        let bounds = FrameDiff.changedBounds(makeImage(), makeImage(paint: [(r, (0, 0, 0))]), in: nil)
        #expect(bounds == r)
        #expect(!FrameDiff.isContentChange(bounds))
        #expect(!FrameDiff.isContentChange(nil))
    }

    @Test func regionLimitsSearch() {
        let r = PixelRect(x: 150, y: 60, width: 8, height: 12)
        let b = makeImage(paint: [(r, (0, 0, 0))])
        let region = PixelRect(x: 0, y: 0, width: 100, height: 50)
        #expect(FrameDiff.changedBounds(makeImage(), b, in: region) == nil)
        #expect(FrameDiff.changedBounds(makeImage(), b, in: PixelRect(x: 100, y: 50, width: 100, height: 50)) == r)
    }

    @Test func belowThresholdIgnored() {
        let r = PixelRect(x: 10, y: 10, width: 20, height: 20)
        let b = makeImage(paint: [(r, (245, 245, 245))])
        #expect(FrameDiff.changedBounds(makeImage(), b, in: nil) == nil)
    }

    @Test func blankDetection() {
        #expect(FrameDiff.isBlank(makeImage()))
        let px = PixelRect(x: 199, y: 99, width: 1, height: 1)
        #expect(!FrameDiff.isBlank(makeImage(paint: [(px, (0, 0, 0))])))
    }

    @Test func sizeMismatchIsFullFrameChange() {
        let bounds = FrameDiff.changedBounds(makeImage(), makeImage(width: 220, height: 90), in: nil)
        #expect(bounds == PixelRect(x: 0, y: 0, width: 220, height: 100))
        #expect(FrameDiff.isContentChange(bounds))
    }
}

@Suite struct TextPaintedTests {
    private func stripes(rows: Int) -> [(PixelRect, (UInt8, UInt8, UInt8))] {
        stride(from: 0, to: 200, by: 4).map { (PixelRect(x: $0, y: 0, width: 1, height: rows), (0, 0, 0)) }
    }

    @Test func blankImageIsNotText() {
        #expect(FrameDiff.textRowFraction(makeImage()) == 0)
    }

    @Test func fortyPercentStripedRowsIsText() {
        let f = FrameDiff.textRowFraction(makeImage(paint: stripes(rows: 40)))
        #expect(abs(f - 0.4) < 0.01)
        #expect(f >= 0.3)
    }

    @Test func twentyPercentIsBelowThreshold() {
        #expect(FrameDiff.textRowFraction(makeImage(paint: stripes(rows: 20))) < 0.3)
    }

    @Test func flatBarAndBorderAreNotText() {
        let bar = makeImage(paint: [(PixelRect(x: 0, y: 0, width: 200, height: 60), (0, 0, 0))])
        #expect(FrameDiff.textRowFraction(bar) == 0)
    }

    @Test func regionLimitsTheFraction() {
        let img = makeImage(paint: stripes(rows: 40))
        #expect(FrameDiff.textRowFraction(img, in: PixelRect(x: 0, y: 0, width: 200, height: 40)) == 1)
        #expect(FrameDiff.textRowFraction(img, in: PixelRect(x: 0, y: 50, width: 200, height: 50)) == 0)
    }

    @Test func blankInRegion() {
        let img = makeImage(paint: [(PixelRect(x: 0, y: 0, width: 50, height: 50), (0, 0, 0))])
        #expect(!FrameDiff.isBlank(img))
        #expect(FrameDiff.isBlank(img, in: PixelRect(x: 100, y: 0, width: 100, height: 100)))
    }
}
