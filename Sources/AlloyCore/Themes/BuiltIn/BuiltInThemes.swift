import Foundation

/// Themes compiled into the app as JSON string literals (no bundle resources). Tasks that add a
/// theme append a literal to `sources`.
public enum BuiltInThemes {
    /// `(id, JSON)` pairs in registry order.
    static let sources: [(id: String, json: String)] = [
        (id: "dracula", json: draculaJSON),
        (id: "alloy-dark", json: alloyDarkJSON),
        (id: "alloy-light", json: alloyLightJSON),
        (id: "solarized-dark", json: solarizedDarkJSON),
        (id: "solarized-light", json: solarizedLightJSON),
        (id: "one-dark", json: oneDarkJSON),
    ]

    public static var all: [ThemeEntry] { parsed }

    private static let parsed: [ThemeEntry] = sources.compactMap { source in
        do throws(ThemeFileError) {
            let file = try ThemeFile.parse(Data(source.json.utf8))
            return ThemeEntry(id: source.id, file: file, isBuiltIn: true, url: nil)
        } catch {
            #if DEBUG
            fatalError("Built-in theme \(source.id) failed to parse: \(error.message)")
            #else
            return nil
            #endif
        }
    }
}
