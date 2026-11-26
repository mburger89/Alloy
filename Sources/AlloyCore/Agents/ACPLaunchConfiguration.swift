import Foundation

public enum ACPResumeMode: Sendable, Equatable { case new, resume, load }

/// The shared-notes MCP server offered to the agent in `session/new`, `session/load` and `session/resume`.
public struct ACPMCPDescriptor: Sendable, Equatable {
    public var name: String
    public var url: String
    public var token: String
    public init(name: String, url: String, token: String) { self.name = name; self.url = url; self.token = token }
}

/// Reads and writes project files for an agent's `fs/*` requests (implemented with the file service).
public protocol ACPFileHandling: Sendable {
    func readTextFile(path: String, line: Int?, limit: Int?) async throws -> String
    func writeTextFile(path: String, content: String) async throws
}

public struct ACPLaunchConfiguration: Sendable {
    public var agent: AgentDefinition
    public var executable: URL
    public var arguments: [String]
    public var projectDirectory: URL
    public var sessionID: UUID
    public var acpSessionID: String?
    public var resume: ACPResumeMode
    /// Plain variables plus secrets read from the Keychain; never logged.
    public var env: [String: String]
    public var loginPATH: String?
    public var mcp: ACPMCPDescriptor?
    public var systemPrompt: String?
    public var fileService: (any ACPFileHandling)?
    /// Alloy's history file of this session; the transport appends the translated lines to it.
    public var history: ACPHistory?
    /// Auto-select the allow option for permission requests on Alloy's own tools (`askBeforeSharedNotes` off).
    public var autoAllowAlloyTools = false
    /// Also auto-select the allow option for Alloy's theme tools (a theme session with `askBeforeSharedNotes` off).
    public var autoAllowThemeTools = false
    /// A theme session's prompt for an agent that cannot use Alloy's tools: write the theme file into the themes folder.
    public var promptWithoutTools: String?
    /// The one notice the transcript gets when `promptWithoutTools` replaces the tools.
    public var toolsUnavailableNotice: String?
    /// Notices (overlap and the like) that lead the next prompt; asked for each time a prompt is actually sent.
    public var leadingContext: (@Sendable () async -> String?)?

    public init(agent: AgentDefinition, executable: URL, arguments: [String]? = nil, projectDirectory: URL,
                sessionID: UUID, acpSessionID: String? = nil, resume: ACPResumeMode = .new,
                env: [String: String] = [:], loginPATH: String? = nil, mcp: ACPMCPDescriptor? = nil,
                systemPrompt: String? = nil, fileService: (any ACPFileHandling)? = nil,
                history: ACPHistory? = nil, autoAllowAlloyTools: Bool = false,
                leadingContext: (@Sendable () async -> String?)? = nil) {
        self.agent = agent; self.executable = executable; self.arguments = arguments ?? agent.args
        self.projectDirectory = projectDirectory; self.sessionID = sessionID; self.acpSessionID = acpSessionID
        self.resume = resume; self.env = env; self.loginPATH = loginPATH; self.mcp = mcp
        self.systemPrompt = systemPrompt; self.fileService = fileService
        self.history = history; self.autoAllowAlloyTools = autoAllowAlloyTools; self.leadingContext = leadingContext
    }
}

public typealias ACPTransportFactory = @Sendable (ACPLaunchConfiguration) -> any SessionTransport
