import Foundation

/// The five theme tools, served only to theme-making sessions.
enum ThemeTools {
    static let unavailable = MCPToolResult(text: "Alloy's theme tools are not available right now.", isError: true)
    static let author = "Made in an Alloy theme session"
    static let format = "A theme file is a JSON object: {\"name\": text, \"appearance\": \"dark\"|\"light\", \"base\": optional theme id to inherit from, \"colors\": {slot: \"#RRGGBB\" or \"#RRGGBBAA\"}, \"sessionColors\": optional list of 6 to 12 hex colours, \"style\": optional {\"gutter\": 0 to 16, \"cornerRadius\": 0 to 20, \"islandOpacity\": 0.40 to 1.0, \"controlOpacity\": 0.40 to 1.0, \"controlBlur\": \"light\"|\"medium\"|\"heavy\", \"pillButtons\": true|false}}. A style key left out comes from the base theme."

    static func make(workspace: Workspace) -> [MCPTool] {
        let ref = WorkspaceRef(workspace)
        return [ThemeSlotsTool(ref: ref), ThemeReadTool(ref: ref), ThemeCheckTool(ref: ref),
                ThemePreviewTool(ref: ref), ThemeSaveTool(ref: ref)]
    }

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

    static let themeProperty: JSONValue = .object([
        "description": .string("The theme: a JSON object in the theme-file format, or a string holding that JSON.")])

    static func fail(_ text: String) -> MCPToolResult { MCPToolResult(text: text, isError: true) }

    static func reply(_ value: JSONValue) -> MCPToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return fail("Could not encode the result.") }
        return MCPToolResult(text: String(decoding: data, as: UTF8.self))
    }

    static func json(_ encodable: some Encodable) -> JSONValue {
        guard let data = try? JSONEncoder().encode(encodable), let value = JSONValue.parse(data) else { return .null }
        return value
    }

    /// The six style keys of a theme file: `{key: {value, range, purpose}}`. `range` is `[min, max]` for numbers, the
    /// allowed words for `controlBlur` and `[false, true]` for `pillButtons`.
    static func styleDescription(_ s: AppearanceStyle) -> JSONValue {
        func number(_ value: Double, _ range: ClosedRange<Double>, _ purpose: String) -> JSONValue {
            .object(["value": .number(value), "range": .array([.number(range.lowerBound), .number(range.upperBound)]),
                     "purpose": .string(purpose)])
        }
        return .object([
            "gutter": number(s.gutter, AppearanceStyle.gutterRange, "Points of window background between the islands and the window edge."),
            "cornerRadius": number(s.cornerRadius, AppearanceStyle.cornerRadiusRange, "Corner radius of the islands, in points."),
            "islandOpacity": number(s.islandOpacity, AppearanceStyle.opacityRange, "Opacity of islandFill, as a fraction: lower shows more of what is behind the window."),
            "controlOpacity": number(s.controlOpacity, AppearanceStyle.opacityRange, "Opacity of controlFill on the floating controls, as a fraction."),
            "controlBlur": .object(["value": .string(s.controlBlur.rawValue),
                                    "range": .array(ControlBlur.allCases.map { .string($0.rawValue) }),
                                    "purpose": .string("How strongly the floating controls blur what is behind them.")]),
            "pillButtons": .object(["value": .bool(s.pillButtons), "range": .array([.bool(false), .bool(true)]),
                                    "purpose": .string("Fully round buttons when true; buttons use half the island radius when false.")]),
        ])
    }

    static func hexMap(_ colors: [String: ThemeRGBA]) -> JSONValue {
        .object(colors.mapValues { .string($0.hex) })
    }

    /// The workspace and workshop, or the error to return.
    @MainActor
    static func context(_ ref: WorkspaceRef) -> (ws: Workspace, shop: any ThemeWorkshop)? {
        guard let ws = ref.workspace, let shop = ws.themeWorkshop else { return nil }
        return (ws, shop)
    }

    @MainActor
    static func notifySaved(_ ref: WorkspaceRef, _ saved: SavedTheme, _ file: ThemeFile, _ session: UUID) async {
        await context(ref)?.shop.didSave(saved, file: file, session: session)
    }

    static func missing(_ ref: WorkspaceRef) async -> MCPToolResult {
        guard ref.workspace != nil else { return NotesTools.closing }
        return unavailable
    }

    /// Parses the `theme` argument. `name` replaces the draft's name when given.
    static func parseDraft(_ arguments: JSONValue, name: String? = nil) -> Result<ThemeFile, ThemeFileError> {
        var value = arguments["theme"] ?? .null
        if case .string(let text) = value {
            if text.utf8.count > ThemeFile.maxBytes { return .failure(.tooLarge(text.utf8.count)) }
            guard let parsed = JSONValue.parse(Data(text.utf8)) else { return .failure(.notJSON) }
            value = parsed
        }
        guard case .object(var object) = value else { return .failure(.notJSON) }
        if let name { object["name"] = .string(name) }
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)) else { return .failure(.notJSON) }
        do {
            var file = try ThemeFile.parse(data)
            if file.author == nil { file.author = author }
            return .success(file)
        } catch {
            return .failure(error)
        }
    }

    struct Report {
        var theme: ResolvedTheme
        var fields: [String: JSONValue]
    }

    /// Resolves a draft against `library` and builds the check fields shared by check, preview and save.
    static func report(_ draft: ThemeFile, library: ThemeLibrary, catalog: [ThemeSlotInfo]) -> Report {
        let (theme, notes) = library.resolve(draft: draft)
        let known = Set(catalog.map(\.name))
        let ignored = draft.colors.keys.filter { !known.contains($0) }.sorted()
        let findings = ThemeContrast.findings(theme)
        return Report(theme: theme, fields: [
            "findings": json(findings),
            "ignoredSlots": .array(ignored.map(JSONValue.string)),
            "notes": .array(notes.map(JSONValue.string)),
        ])
    }
}

struct ThemeSlotsTool: MCPTool {
    let ref: WorkspaceRef
    let name = "theme_slots"
    let description = "List every colour slot a theme can set, what each paints, and its value in the theme Alloy shows right now, "
        + "plus the theme file format."
    let inputSchema = ThemeTools.schema([:])
    var scope: MCPToolScope { .theme }

    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        let snapshot: (catalog: [ThemeSlotInfo], shown: ResolvedTheme?)? = await MainActor.run {
            ThemeTools.context(ref).map { ($0.shop.slotCatalog, $0.shop.shownTheme) }
        }
        guard let snapshot else { return await ThemeTools.missing(ref) }
        let shown = snapshot.shown
        let slots: [JSONValue] = snapshot.catalog.map { slot in
            .object(["name": .string(slot.name), "purpose": .string(slot.purpose),
                     "value": shown?.colors[slot.name].map { .string($0.hex) } ?? .null])
        }
        return ThemeTools.reply(.object([
            "theme": shown.map { .string($0.id) } ?? .null,
            "appearance": shown.map { .string($0.appearance.rawValue) } ?? .null,
            "slots": .array(slots),
            "sessionColors": .array((shown?.sessionColors ?? []).map { .string($0.hex) }),
            "style": ThemeTools.styleDescription(shown?.style ?? .defaults),
            "format": .string(ThemeTools.format),
        ]))
    }
}

struct ThemeReadTool: MCPTool {
    let ref: WorkspaceRef
    let name = "theme_read"
    let description = "Read an existing theme's file and its fully resolved colours. Name it by id, user/<file>, or display name."
    let inputSchema = ThemeTools.schema(
        ["name": .object(["type": .string("string"),
                          "description": .string("A theme id, user/<file name>, or display name, case-insensitive.")])],
        required: ["name"])
    var scope: MCPToolScope { .theme }

    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        let wanted = arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let library: ThemeLibrary? = await MainActor.run { ThemeTools.context(ref)?.shop.library }
        guard let library else { return await ThemeTools.missing(ref) }
        let key = wanted.lowercased()
        let entry = library.all.first { $0.id.lowercased() == key }
            ?? library.all.first { $0.file.name.lowercased() == key }
        guard let entry, !wanted.isEmpty else {
            return ThemeTools.fail("No theme named \"\(wanted)\". Themes: \(library.all.map(\.id).joined(separator: ", "))")
        }
        let file = (try? entry.file.encoded()).flatMap { JSONValue.parse($0) } ?? .null
        let resolved = library.resolve(entry.id).map { ThemeTools.hexMap($0.colors) } ?? .object([:])
        return ThemeTools.reply(.object(["id": .string(entry.id), "builtIn": .bool(entry.isBuiltIn),
                                         "file": file, "resolved": resolved]))
    }
}

struct ThemeCheckTool: MCPTool {
    let ref: WorkspaceRef
    let name = "theme_check"
    let description = "Check a draft theme's text contrast and slot names without showing it. Returns the colour pairs that are hard "
        + "to read, the slots Alloy ignores, and notes."
    let inputSchema = ThemeTools.schema(["theme": ThemeTools.themeProperty], required: ["theme"])
    var scope: MCPToolScope { .theme }

    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        let draft: ThemeFile
        switch ThemeTools.parseDraft(arguments) {
        case .failure(let error): return ThemeTools.fail(error.message)
        case .success(let file): draft = file
        }
        let report: ThemeTools.Report? = await MainActor.run {
            ThemeTools.context(ref).map { ThemeTools.report(draft, library: $0.shop.library, catalog: $0.shop.slotCatalog) }
        }
        guard let report else { return await ThemeTools.missing(ref) }
        return ThemeTools.reply(.object(report.fields))
    }
}

struct ThemePreviewTool: MCPTool {
    let ref: WorkspaceRef
    let name = "theme_preview"
    let description = "Show a draft theme live across Alloy so the user can see it; the user's own theme returns when they discard it. "
        + "Returns the same check as theme_check."
    let inputSchema = ThemeTools.schema(["theme": ThemeTools.themeProperty], required: ["theme"])
    var scope: MCPToolScope { .theme }

    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        let draft: ThemeFile
        switch ThemeTools.parseDraft(arguments) {
        case .failure(let error): return ThemeTools.fail(error.message)
        case .success(let file): draft = file
        }
        let report: ThemeTools.Report? = await MainActor.run {
            guard let (_, shop) = ThemeTools.context(ref) else { return nil }
            let report = ThemeTools.report(draft, library: shop.library, catalog: shop.slotCatalog)
            shop.preview(draft, resolved: report.theme, session: caller.sessionID)
            return report
        }
        guard var report else { return await ThemeTools.missing(ref) }
        report.fields["previewing"] = .string(draft.name)
        return ThemeTools.reply(.object(report.fields))
    }
}

struct ThemeSaveTool: MCPTool {
    let ref: WorkspaceRef
    let name = "theme_save"
    let description = "Save a draft theme under a name in the user's themes folder. It never switches the theme: the user activates "
        + "it with Keep or in Settings. Returns the check plus the saved id."
    let inputSchema = ThemeTools.schema(
        ["name": .object(["type": .string("string"), "description": .string("The theme's display name; replaces any name in the draft.")]),
         "theme": ThemeTools.themeProperty],
        required: ["name", "theme"])
    var scope: MCPToolScope { .theme }

    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        guard let name = arguments["name"]?.stringValue,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ThemeTools.fail("\"name\" is required.")
        }
        let draft: ThemeFile
        switch ThemeTools.parseDraft(arguments, name: name) {
        case .failure(let error): return ThemeTools.fail(error.message)
        case .success(let file): draft = file
        }
        let prepared: (report: ThemeTools.Report, builtIns: [ThemeEntry], support: URL)? = await MainActor.run {
            guard let (ws, shop) = ThemeTools.context(ref) else { return nil }
            return (ThemeTools.report(draft, library: shop.library, catalog: shop.slotCatalog),
                    shop.library.builtIns, ws.appSupport)
        }
        guard var report = prepared?.report, let builtIns = prepared?.builtIns, let support = prepared?.support else {
            return await ThemeTools.missing(ref)
        }
        let session = caller.sessionID
        // The store takes a cross-process lock and writes files, so it runs off the main actor.
        let outcome = await Task.detached { () -> Result<SavedTheme, Error> in
            Result { try ThemeStore(appSupport: support).save(draft, name: name, session: session, builtIns: builtIns) }
        }.value
        let saved: SavedTheme
        switch outcome {
        case .failure(let error):
            if case ThemeStoreError.noFreeName(let base) = error {
                return ThemeTools.fail("Could not find a free file name for \"\(base)\". Choose a different name.")
            }
            return ThemeTools.fail("Could not save the theme: \(error.localizedDescription)")
        case .success(let value): saved = value
        }
        var file = draft
        file.name = saved.name
        await ThemeTools.notifySaved(ref, saved, file, session)
        report.fields["saved"] = .string(saved.id)
        report.fields["name"] = .string(saved.name)
        report.fields["renamed"] = .bool(saved.renamed)
        report.fields["active"] = .bool(false)
        return ThemeTools.reply(.object(report.fields))
    }
}
