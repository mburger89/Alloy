import AlloyCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite struct ImageEncodingTests {
    static func encode(width: Int, height: Int, type: UTType, noise: Bool) -> Data {
        var pixels = [UInt8](repeating: 200, count: width * height * 4)
        if noise { for i in pixels.indices { pixels[i] = UInt8.random(in: 0...255) } }
        let ctx = pixels.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func tiffBecomesPNG() throws {
        let tiff = Self.encode(width: 8, height: 6, type: .tiff, noise: false)
        let a = try ImageEncoding.attachment(from: tiff, typeHint: "public.tiff")
        #expect(a.mediaType == "image/png")
        let bytes = try #require(Data(base64Encoded: a.base64))
        #expect(bytes.prefix(4) == Data([0x89, 0x50, 0x4e, 0x47]))
        #expect(a.byteCount == bytes.count)
        #expect(a.pixelSize?.0 == 8 && a.pixelSize?.1 == 6)
    }

    @Test func pngPassesThrough() throws {
        let png = Self.encode(width: 4, height: 4, type: .png, noise: false)
        let a = try ImageEncoding.attachment(from: png, typeHint: nil)
        #expect(a.mediaType == "image/png")
        #expect(Data(base64Encoded: a.base64) == png)
    }

    @Test func jpegPassesThrough() throws {
        let jpeg = Self.encode(width: 4, height: 4, type: .jpeg, noise: false)
        let a = try ImageEncoding.attachment(from: jpeg, typeHint: nil)
        #expect(a.mediaType == "image/jpeg")
        #expect(Data(base64Encoded: a.base64) == jpeg)
    }

    @Test func oversizeRefused() {
        let big = Self.encode(width: 200, height: 200, type: .png, noise: true)
        #expect(big.count > 100_000)
        do {
            _ = try ImageEncoding.attachment(from: big, typeHint: nil, limit: 100_000)
            Issue.record("expected tooLarge")
        } catch {
            #expect(error == .tooLarge(bytes: big.count))
            #expect(ImageEncoding.maxBytes == 5 * 1024 * 1024)
            #expect(error.message.hasPrefix("Image is too large ("))
            #expect(error.message.hasSuffix("MB, limit 5 MB)"))
        }
    }

    @Test func garbageRefused() {
        do {
            _ = try ImageEncoding.attachment(from: Data("not an image".utf8), typeHint: "public.png")
            Issue.record("expected unreadable")
        } catch {
            #expect(error == .unreadable)
            #expect(error.message == "Couldn't read that image")
        }
    }
}
