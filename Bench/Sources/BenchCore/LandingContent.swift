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

    public var heroTitle = "Fast. Native. Yours."
    public var heroLead = "The code editor for Claude Code — written in Swift, drawn on the GPU with Metal."
    public var heroMeta = "macOS 14 or later · Apple silicon · signed & notarised · updates itself · free, MIT"
    /// Shown instead of `heroMeta` while `downloadAvailable` is false (no release exists to be signed or to update itself).
    public var heroMetaSoon = "Coming soon for Apple-silicon Macs · macOS 14 or later · free, MIT"
    public var heroPoster = "hero-poster.png"
    public var heroVideo = "hero.mp4"
    public var heroAlt = "Alloy with two Claude Code sessions editing the same function, and the overlap warning that follows, in the Dracula theme."

    public var raceTitle = "Feel the difference."
    public var raceSub = "Replayed from the published benchmark. Only tests Alloy really wins are listed."

    public var notesTitle = "Stop paying to read the same file twice."
    public var notesSub = "Your sessions share what they learn."
    public var notesBenefits: [(String, String)] = [
        ("Less waiting", "Fewer file reads before a session gets going."),
        ("Less usage", "Fewer tokens counted against your plan."),
        ("More room", "Context left for the actual work."),
    ]
    public var notesPromise = "Never stale: every note is tied to the exact state of the file it describes. Once the file changes, the old text is never served."

    public var features: [Feature] = [
        Feature(title: "Many Claude sessions. One folder.",
                text: "Run several Claude Code sessions side by side, each with rich chat: plans, questions and permission requests you answer in place.",
                image: "shot-sessions.png", alt: "The session list beside a chat with a plan awaiting approval."),
        Feature(title: "Know who changed what.",
                text: "Every line is coloured by the session that wrote it. Per-session diffs; keep or revert an edit in one click.",
                image: "shot-changes.png", alt: "Code with each changed line coloured by the session that wrote it."),
        Feature(title: "Sessions that don't collide.",
                text: "Alloy warns a session before it edits lines another session (or you) is changing, so work doesn't get overwritten.",
                image: "shot-collisions.png", alt: "An overlap warning on lines two sessions are both editing."),
    ]

    public var themesTitle = "Dracula by default. Make your own."
    public var themesSub = "Built-in themes, or describe one to Claude and Alloy builds it."
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
    /// Language servers shipped in LSP phase 1 (merge d4815aa); false claims highlighting only.
    public var hasLanguageServers = true

    public var builtTitle = "Native all the way down."
    public var builtSub = "No Electron. No web view. Every pixel is drawn by Alloy's own UI framework on the GPU."
    public var stack: [(String, String)] = [("Alloy", "Swift 6"), ("MetalUI", "its own GPU UI framework"), ("Metal", "Apple's GPU API")]

    public var privacyTitle = "Your code stays yours."
    public var privacyLines = [
        "No telemetry and no account. Alloy runs the Claude Code you already have.",
        "It never changes your Claude Code settings — the optional theme skill is installed only when you click it.",
        "The update check is the only network call Alloy itself makes.",
    ]

    public var faq: [Question] = [
        Question(q: "Is it free?", a: "Yes. Alloy is open source under the MIT licence."),
        Question(q: "Do I need a Claude subscription?", a: "Yes — Alloy runs your own Claude Code, so you need Claude Code installed and logged in (a Claude subscription or API account)."),
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
