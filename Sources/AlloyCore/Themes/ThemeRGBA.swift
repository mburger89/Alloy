import Foundation

/// A plain RGBA colour (components 0...1) read from a theme file. AlloyCore never imports MetalUI,
/// so later layers map these values onto the UI framework's colour type.
public struct ThemeRGBA: Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Accepts exactly `#RRGGBB` and `#RRGGBBAA`, case-insensitive.
    public init?(hex: String) {
        let utf8 = Array(hex.utf8)
        guard utf8.first == UInt8(ascii: "#"), utf8.count == 7 || utf8.count == 9 else { return nil }
        var bytes: [Double] = []
        var index = 1
        while index < utf8.count {
            guard let hi = Self.nibble(utf8[index]), let lo = Self.nibble(utf8[index + 1]) else { return nil }
            bytes.append(Double(hi * 16 + lo) / 255)
            index += 2
        }
        self.r = bytes[0]
        self.g = bytes[1]
        self.b = bytes[2]
        self.a = bytes.count == 4 ? bytes[3] : 1
    }

    /// Uppercase `#RRGGBB`, or `#RRGGBBAA` when the alpha is below 1.
    public var hex: String {
        func byte(_ v: Double) -> String {
            let n = Int((min(max(v, 0), 1) * 255).rounded())
            return String(format: "%02X", n)
        }
        return "#" + byte(r) + byte(g) + byte(b) + (a < 1 ? byte(a) : "")
    }

    private static func nibble(_ c: UInt8) -> Int? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(c) - Int(UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(c) - Int(UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(c) - Int(UInt8(ascii: "A")) + 10
        default: return nil
        }
    }
}
