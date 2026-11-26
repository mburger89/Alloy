import Foundation

/// The landing page's copy and fixed facts. Numbers about speed and memory are NOT here: they come from the published
/// benchmark JSON when the page is rendered. Titles follow docs/superpowers/specs/2026-11-12-alloy-launch-site-design.md, Part 3.
public struct LandingContent: Sendable {
    public struct Theme: Sendable {
        public var name: String, dark: Bool
        /// Window background, surface, text, accent and three syntax colours, from the theme's JSON in Sources/AlloyCore/Themes/BuiltIn.
        public var background: String, surface: String, text: String, keyword: String, string: String, comment: String, function: String
    }
    public struct Feature: Sendable {
        public var title: String, text: String
        /// File name under `assets/`; the page shows a plain panel when the file is not there.
        public var image: String, alt: String
    }
    public struct Question: Sendable { public var q: String, a: String }

    /// The one switch for every download link. False until the first release exists: each Download button and the
    /// Releases links render as an inactive "Coming soon" instead. Set it to true at release time.
    public var downloadAvailable = false
    public var downloadURL = "https://github.com/mburger89/Alloy/releases/latest/download/Alloy.dmg"
    public var repoURL = "https://github.com/mburger89/Alloy"
    public var releasesURL = "https://github.com/mburger89/Alloy/releases"
    public var issuesURL = "https://github.com/mburger89/Alloy/issues"

    public var heroTitle = "Fast. Native. Yours."
    public var heroLead = "The native code editor for any AI coding agent, written in Swift, drawn on the GPU."
    public var heroMeta = "macOS 14 or later · Apple silicon · signed & notarised · updates itself · free, MIT"
    /// Shown instead of `heroMeta` while `downloadAvailable` is false (no release exists to be signed or to update itself).
    public var heroMetaSoon = "Coming soon for Apple-silicon Macs · macOS 14 or later · free, MIT"
    public var heroPoster = "hero-poster.png"
    public var heroVideo = "hero.mp4"
    public var heroAlt = "Alloy with a Claude Code session and an OpenCode session in the same folder: the Claude Code edit overlaps a line the OpenCode session changed, and the overlap warning follows. The theme is one an agent built."

    public var raceTitle = "Feel the difference."
    public var raceSub = "Replayed from the published benchmark. Only tests Alloy really wins are listed."

    public var agentsTitle = "Bring your agent. Bring your model."
    public var agentsSub = "Alloy is the editor around your agent, not another model."
    public var agentsPoints: [(String, String)] = [
        ("Five agents built in", "Claude Code, Codex, Gemini CLI, OpenCode and Goose. Add any Agent Client Protocol agent in Settings: its command, arguments and environment variables."),
        ("Any model, even local", "Alloy never talks to a model itself. Use whatever your agent uses, such as OpenCode or Goose running a model on your Mac through Ollama."),
        ("Keys stay in the Keychain", "Secrets are typed into a secure field and stored only in your macOS Keychain, never in a file."),
    ]
    public var agentsImages: [Feature] = [
        Feature(title: "Chat with a local model.", text: "OpenCode running qwen2.5-coder:7b through Ollama, inside an Alloy session.",
                image: "shot-agents.png", alt: "An Alloy session with OpenCode answering from a local model."),
        Feature(title: "Add any agent.", text: "Settings › Agents lists the built-in agents, and Add agent… adds your own. Secret values never show.",
                image: "shot-agents-settings.png", alt: "Settings, Agents: the built-in agents and the Add agent form."),
    ]

    public var notesTitle = "Stop paying to read the same file twice."
    public var notesSub = "Your sessions share what they learn."
    public var notesBenefits: [(String, String)] = [
        ("Less waiting", "Fewer file reads before a session gets going."),
        ("Less usage", "Fewer tokens counted against your plan."),
        ("More room", "Context left for the actual work."),
    ]
    public var notesPromise = "Never stale: every note is tied to the exact state of the file it describes. Once the file changes, the old text is never served."

    public var features: [Feature] = [
        Feature(title: "Many agent sessions. One folder.",
                text: "Run Claude Code, Codex, Gemini CLI, OpenCode, Goose — or any ACP agent — side by side. Plans, questions and permission requests are answered in place.",
                image: "shot-sessions.png", alt: "The session list beside a chat with a plan awaiting approval."),
        Feature(title: "Know who changed what.",
                text: "Every line is coloured by the session that wrote it, whichever agent that is. Per-session diffs; keep or revert an edit in one click.",
                image: "shot-changes.png", alt: "Code with each changed line coloured by the session that wrote it."),
        Feature(title: "Sessions that don't collide.",
                text: "Alloy warns a session before it edits lines another session (or you) is changing, whichever agents they are, so work doesn't get overwritten.",
                image: "shot-collisions.png", alt: "An overlap warning on lines two sessions are both editing."),
        Feature(title: "A real code editor, too.",
                text: "Code mode puts a full editor beside your sessions: language servers, split panes, Git and a built-in terminal, all drawn on the GPU.",
                image: "shot-code.png", alt: "Alloy's Code mode: the file tree, a Swift file with Git change bars, a second file in a split pane and the terminal below."),
        Feature(title: "Plugins.",
                text: "Add themes, language servers, commands, panels and tools for your agents. Install from a folder or git, keep them updated, and run them in the macOS sandbox.",
                image: "shot-plugins.png", alt: "Settings, Plugins: installed plugins with their permissions."),
        Feature(title: "CSV as a table.",
                text: "CSV and TSV files open as a table. Edit cells in place, sort, and keep or revert each change.",
                image: "shot-csv.png", alt: "A CSV file in Table view with edited cells tinted."),
    ]

    public var editorTitle = "Everything you need when you take the wheel."
    public var editorSub = "When you want to write the code yourself, Alloy is a complete editor."
    public var editorCapabilities: [(String, String)] = [
        ("Code mode", "File tree, tabs and split panes. Switch between chat and code in one click."),
        ("Language servers", "Completion with snippets, hover, go to definition and references, rename, quick fixes and formatting, with errors and linter warnings as you type."),
        ("Editing", "Multiple cursors, folding, find, and search and replace across the project. Command palette, Quick Open and your own shortcuts."),
        ("Git", "Change bars in the gutter, blame with author and age, compare with the last commit, stage, commit and switch branches."),
        ("Terminal", "A built-in terminal with clickable links, find, and a check before multi-line pastes."),
        ("Open from the terminal", "alloy <file> opens the file in its enclosing git repository, or else its folder."),
    ]

    public var themesTitle = "Dracula by default. Make your own."
    public var themesSub = "Built-in themes, themes from plugins, or describe one to your agent and Alloy builds it."
    /// The built-in themes, in registry order (Sources/AlloyCore/Themes/BuiltIn/BuiltInThemes.swift).
    public var themes: [Theme] = [
        Theme(name: "Dracula", dark: true, background: "#20222B", surface: "#282A36", text: "#F8F8F2", keyword: "#FF79C6", string: "#F1FA8C", comment: "#97A2C3", function: "#50FA7B"),
        Theme(name: "Alloy Dark", dark: true, background: "#0B1020", surface: "#161C2E", text: "#E9EDF5", keyword: "#FF8F88", string: "#A5D6FF", comment: "#A8B0BA", function: "#D2A8FF"),
        Theme(name: "Alloy Light", dark: false, background: "#F5F5F7", surface: "#FFFFFF", text: "#14181F", keyword: "#BF1D29", string: "#0A3069", comment: "#59636E", function: "#6F3FC9"),
        Theme(name: "Solarized Dark", dark: true, background: "#002B36", surface: "#002B36", text: "#9EAAAA", keyword: "#859900", string: "#2AA198", comment: "#839496", function: "#3194DA"),
        Theme(name: "Solarized Light", dark: false, background: "#FDF6E3", surface: "#FDF6E3", text: "#3E494D", keyword: "#627000", string: "#1F756F", comment: "#5E6C6C", function: "#1E6EA7"),
        Theme(name: "One Dark", dark: true, background: "#20232A", surface: "#282C34", text: "#BCC2CC", keyword: "#CC85E0", string: "#98C379", comment: "#9198A5", function: "#61AFEF"),
    ]

    public var languagesTitle = "Your languages, out of the box."
    /// The grammars in Sources/AlloyHighlight/Languages.swift.
    public var languages = ["Swift", "Python", "JavaScript", "TypeScript", "TSX", "JSON", "Markdown", "Bash", "Rust", "Go", "C", "C++", "YAML", "HTML", "CSS"]
    /// False claims highlighting only.
    public var hasLanguageServers = true

    public var builtTitle = "Native all the way down."
    public var builtSub = "No Electron. No web view. Every pixel is drawn by Alloy's own UI framework on the GPU."
    public var stack: [(String, String)] = [("Alloy", "Swift 6"), ("MetalUI", "its own GPU UI framework"), ("Metal", "Apple's GPU API")]

    public var privacyTitle = "Your code stays yours."
    public var privacyLines = [
        "No telemetry and no account. Alloy runs the agents you already have installed.",
        "It never changes your agents' settings — the optional theme skill is installed only when you click it.",
        "API keys are kept only in your macOS Keychain.",
        "The only requests Alloy itself makes are update checks. Agents and language servers you run make their own connections.",
    ]

    public var faq: [Question] = [
        Question(q: "Is it free?", a: "Yes. Alloy is open source under the MIT licence."),
        Question(q: "Which agents and models can I use?", a: "Claude Code, Codex, Gemini CLI, OpenCode and Goose are built in, and Settings › Agents adds any other agent that speaks the Agent Client Protocol. Alloy never talks to a model itself: the model is whatever your agent uses."),
        Question(q: "Can I use a local model?", a: "Yes, through an agent that supports one. OpenCode or Goose can run a local model with Ollama, and Alloy works with them like any other agent."),
        Question(q: "What do I need to run it?", a: "A Mac with Apple silicon on macOS 14 or later, and at least one coding agent installed and signed in."),
        Question(q: "Does it run on Intel Macs?", a: "Not yet: Apple silicon only."),
        Question(q: "How do updates work?", a: "Alloy checks for updates once a day in the background. It installs when you quit or when you choose Restart to update — never mid-session."),
        Question(q: "How is it so fast?", a: "It's native Swift drawn straight to the GPU with Metal, and it only does work for what's on screen."),
    ]

    public var closingTitle = "Try it in a minute."
    public var closingSub = "Download, open a folder, start a session."
    /// Shown instead of the closing title and sub while `downloadAvailable` is false.
    public var closingTitleSoon = "Coming soon."
    public var closingSubSoon = "Alloy is coming soon for Apple-silicon Macs. Star the repository on GitHub to hear when it ships."

    /// File names present in `Bench/site/assets`; decides which screenshots and the video are rendered.
    public var assets: Set<String> = []

    public init() {}

}
