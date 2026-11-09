import Foundation

/// Which project a launch opens, decided from the command line and the stored last project.
public enum ProjectChoice: Equatable, Sendable {
    case open(root: URL, file: String?)
    case askUser

    /// Resolves symlinks of an absolute path (the real file system's by default).
    public static let systemResolver: @Sendable (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }

    public static func resolve(arguments: [String], settings: AlloySettings, isDirectory: (String) -> Bool,
                               home: String, cwd: String = FileManager.default.currentDirectoryPath,
                               resolveSymlinks: (String) -> String = systemResolver,
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> ProjectChoice {
        resolveDetailed(arguments: arguments, settings: settings, isDirectory: isDirectory, home: home, cwd: cwd,
                        resolveSymlinks: resolveSymlinks, fileExists: fileExists).choice
    }

    /// `arguments` excludes the program name: `[<project-dir> [<file>]]`. Relative paths resolve against `cwd`.
    /// Symlinks are resolved before the checks, and "/" and the home directory (compared case-insensitively,
    /// as on a default macOS volume) are never a project root. A rejected argument asks the user, with a
    /// reason, rather than falling back to the last project.
    public static func resolveDetailed(arguments: [String], settings: AlloySettings, isDirectory: (String) -> Bool,
                                       home: String, cwd: String,
                                       resolveSymlinks: (String) -> String,
                                       fileExists: (String) -> Bool) -> (choice: ProjectChoice, reason: String?) {
        func absolute(_ path: String, base: String) -> String {
            let full = path.hasPrefix("/") ? path : base + "/" + path
            return URL(fileURLWithPath: full).standardizedFileURL.path
        }
        func real(_ path: String) -> String { URL(fileURLWithPath: resolveSymlinks(path)).standardizedFileURL.path }
        let forbidden = Set(["/", home, resolveSymlinks(home)].map { URL(fileURLWithPath: $0).standardizedFileURL.path.lowercased() })
        func rejection(_ root: String) -> String? {
            if forbidden.contains(root.lowercased()) { return "Pick a project folder, not your home folder or the disk root." }
            if !isDirectory(root) { return "\(root) is not a folder." }
            return nil
        }
        func ask(_ reason: String?) -> (ProjectChoice, String?) { (.askUser, reason) }

        guard let dir = arguments.first else {
            guard let last = settings.lastProjectPath, !last.isEmpty else { return ask(nil) }
            let root = real(absolute(last, base: cwd))
            // A stale or unsuitable last project is not an error worth an alert.
            return rejection(root) == nil ? (.open(root: URL(fileURLWithPath: root), file: nil), nil) : ask(nil)
        }
        let root = real(absolute(dir, base: cwd))
        if let why = rejection(root) { return ask(why) }
        guard arguments.count > 1 else { return (.open(root: URL(fileURLWithPath: root), file: nil), nil) }
        let arg = arguments[1]
        let candidates = (arg.hasPrefix("/") ? [absolute(arg, base: cwd)] : [absolute(arg, base: cwd), absolute(arg, base: root)])
            .map(real).filter { $0.hasPrefix(root + "/") }
        guard let file = candidates.first(where: fileExists) ?? candidates.first else {
            return ask("The file \(arg) is not inside the project folder.")
        }
        return (.open(root: URL(fileURLWithPath: root), file: String(file.dropFirst(root.count + 1))), nil)
    }
}
