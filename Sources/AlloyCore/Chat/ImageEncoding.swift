import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Why an image could not become an attachment.
public enum ImageError: Error, Equatable, Sendable {
    /// The encoded image is over the limit (`bytes` is its encoded size).
    case tooLarge(bytes: Int)
    /// The bytes are not an image ImageIO can decode.
    case unreadable

    /// The line the composer shows.
    public var message: String {
        switch self {
        case .tooLarge(let bytes):
            let mb = (Double(bytes) / (1024 * 1024) * 10).rounded() / 10
            return "Image is too large (\(mb.formatted(.number.precision(.fractionLength(0...1)))) MB, limit 5 MB)"
        case .unreadable:
            return "Couldn't read that image"
        }
    }
}

/// Turns pasted, dropped or read image bytes into an ``ImageAttachment`` the CLI accepts.
public enum ImageEncoding {
    /// The largest encoded image sent: 5 MB, measured on the bytes before base64.
    public static let maxBytes = 5 * 1024 * 1024

    private static let passThrough: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// PNG, JPEG, GIF and WebP pass through; TIFF, HEIC and anything else ImageIO decodes is re-encoded as PNG.
    /// `typeHint` is a MIME type or UTI of the source, used only when the bytes do not say.
    public static func attachment(from data: Data, typeHint: String?, limit: Int = maxBytes) throws(ImageError) -> ImageAttachment {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw .unreadable
        }
        let sourceType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
            ?? typeHint.flatMap { UTType($0) ?? UTType(mimeType: $0) }
        let size = pixelSize(of: source)
        var bytes = data
        var mediaType = sourceType?.preferredMIMEType ?? ""
        if !passThrough.contains(mediaType) {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw .unreadable }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
                throw .unreadable
            }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw .unreadable }
            bytes = out as Data
            mediaType = "image/png"
        }
        guard bytes.count <= limit else { throw .tooLarge(bytes: bytes.count) }
        return ImageAttachment(mediaType: mediaType, base64: bytes.base64EncodedString(), pixelSize: size, byteCount: bytes.count)
        #else
        throw .unreadable
        #endif
    }

    #if canImport(ImageIO)
    private static func pixelSize(of source: CGImageSource) -> (Int, Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }
    #endif

    /// File extensions a dropped file is read as an image for.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic", "heif", "bmp"]
}
