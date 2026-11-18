import Foundation

/// The one ordered list of editors the harness knows, for results, reports and the site.
public enum EditorCatalog {
    public static let all: [(id: String, name: String)] = [
        ("zed", "Zed"), ("delta", "Delta"), ("vscode", "VS Code"), ("cursor", "Cursor"),
        ("sublime", "Sublime Text"), ("idea", "IntelliJ IDEA"), ("alloy", "Alloy"),
    ]

    /// Ids that are always listed, so results that only know the original three render exactly as before.
    private static let always: Set<String> = ["zed", "delta", "alloy"]

    /// Zed, Delta and Alloy always, plus any other editor that appears in `r.apps` or `r.outcomes`, in catalogue order.
    public static func present(in r: RunResult) -> [(id: String, name: String)] {
        all.filter { always.contains($0.id) || r.apps[$0.id] != nil || r.outcomes[$0.id] != nil }
    }

    /// Display name of a known id (the id itself otherwise).
    public static func name(of id: String) -> String { all.first { $0.id == id }?.name ?? id }
}
