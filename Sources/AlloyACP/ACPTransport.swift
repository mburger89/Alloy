import AlloyCore
import Foundation

/// Runs one ACP agent as a `SessionTransport`: it owns the agent process, performs the handshake, and translates
/// between ACP and Alloy's existing wire model so everything above the transport stays as it is for Claude.
public actor ACPTransport: SessionTransport {
    /// Seconds of silence after which a running prompt counts as stuck.
    public static let defaultWatchdog: Double = 600
    private static let deltaInterval: Duration = .milliseconds(16)

    private struct PendingPermission { var rpcID: JSONValue; var options: [ACPPermissionOption] }

    private let configuration: ACPLaunchConfiguration
    private let clock: any AutosaveClock
    private let watchdogSeconds: Double
    private let stream: AsyncStream<ProcessEvent>
    private let events: AsyncStream<ProcessEvent>.Continuation

    private var process: ACPProcess?
    private var connection: ACPConnection?
    private var translator: ACPTranslator
    private var capabilities: ACPAgentCapabilities?
    private var acpSessionID = ""
    private var configOptions: [ACPConfigOption] = []
    private var modesState: ACPModes?
    private var ready: Task<Void, Error>?
    private var incomingTask: Task<Void, Never>?
    private var consumed = 0
    private var incomingEnded = false
    private var started = false
    private var finished = false

    private var turn = 0
    private var turnActive = false
    private var cancelRequested = false
    private var promptTask: Task<Void, Never>?
    private var promptRequestID: Int?
    private var lastActivity = 0.0
    private var watchdog: Task<Void, Never>?
    private var pending: [String: PendingPermission] = [:]
    private var permissionCounter = 0

    private var deltaBuffer = ""
    private var deltaIsThinking = false
    private var deltaFlush: Task<Void, Never>?

    private struct QueuedPrompt { var content: [UserContent]; var uuid: UUID }
    /// Messages that wait for the running turn: ACP takes one prompt at a time. Each is echoed when it is sent.
    private var queue: [QueuedPrompt] = []
    private var pumpTask: Task<Void, Never>?
    /// Guidance for an agent that takes no `systemPrompt`: it leads the first prompt, once.
    private var prefacePending: String?
    /// While `session/load` replays history: its updates are Alloy's already, so they are not applied.
    private var loading = false
    private var authCounter = 0
    private var authWaiter: (rid: String, methods: [ACPAuthMethod], continuation: CheckedContinuation<ACPAuthMethod?, Never>)?
    private var authMethods: [ACPAuthMethod] = []
    /// What the history file still waits for: the text or thinking that streams into one block.
    private var histBuffer = ""
    private var histThinking = false

    public init(configuration: ACPLaunchConfiguration, clock: any AutosaveClock = SystemAutosaveClock(),
                watchdog: Double = ACPTransport.defaultWatchdog,
                readFile: @escaping @Sendable (String) -> String? = ACPTranslator.readFromDisk) {
        self.configuration = configuration
        self.clock = clock
        self.watchdogSeconds = watchdog
        self.translator = ACPTranslator(projectRoot: configuration.projectDirectory, readFile: readFile)
        (stream, events) = AsyncStream<ProcessEvent>.makeStream()
    }

    // MARK: SessionTransport

    public func start() async throws -> AsyncStream<ProcessEvent> {
        guard !started else { return stream }
        started = true
        let proc = try ACPProcess(command: configuration.executable.path, arguments: configuration.arguments,
                                  environment: configuration.env, currentDirectory: configuration.projectDirectory,
                                  loginPATH: configuration.loginPATH)
        process = proc
        let conn = ACPConnection(input: proc.stdout, output: { data in try? await proc.send(data) })
        connection = conn
        incomingTask = Task { await self.runIncoming(conn, proc) }
        Task { await self.watchExit(proc) }
        let handshake = Task<Void, Error> { try await self.handshake(conn) }
        ready = handshake
        Task {
            if case .failure(let error) = await handshake.result { await self.handshakeFailed(error) }
        }
        return stream
    }

    public func send(_ message: OutboundMessage) async throws {
        switch message {
        case .user(let content, let uuid, let priority): try await sendPrompt(content, uuid: uuid, priority: priority)
        case .allow(let rid, let input, let updated):
            if rid.hasPrefix("acp-auth-") { answerAuth(rid, input: input) }
            else { await answerPermission(rid, allow: true, updated: updated) }
        case .deny(let rid, _):
            if rid.hasPrefix("acp-auth-") { answerAuth(rid, input: nil) }
            else { await answerPermission(rid, allow: false, updated: nil) }
        case .control(_, let subtype): try await control(subtype)
        case .controlError: break
        }
    }

    public func terminate() async {
        await stop(timeout: .seconds(3))
    }

    public func stopAndWait(timeout: Duration) async {
        await stop(timeout: timeout)
    }

    private func stop(timeout: Duration) async {
        watchdog?.cancel()
        deltaFlush?.cancel()
        guard let process else { finishStream(); return }
        await process.stopAndWait(timeout: timeout)
    }

    // MARK: handshake

    private func handshake(_ conn: ACPConnection) async throws {
        let info = ACPInitializeParams.ClientInfo(name: "alloy", title: "Alloy",
                                                  version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
        let initResult = try await conn.request("initialize", ACPInitializeParams(clientInfo: info), as: ACPInitializeResult.self)
        capabilities = initResult.agentCapabilities
        authMethods = initResult.authMethods
        while true {
            do {
                try await openSession(conn)
                return
            } catch let e as ACPError where e.isAuthRequired {
                switch await login(conn) {
                case .signedIn: continue
                case .handedOff: return
                case .cancelled: throw e
                }
            }
        }
    }

    /// `session/resume` when the agent offers it, else `session/load` (its replay discarded), else `session/new` with a
    /// notice: the order a restored session, a settings relaunch and a Restart all follow.
    private func openSession(_ conn: ACPConnection) async throws {
        var servers: [ACPMCPServer] = []
        var guidance = configuration.systemPrompt
        if let mcp = configuration.mcp {
            if capabilities?.acceptsHTTPMCP == true {
                servers.append(.http(name: mcp.name, url: mcp.url,
                                     headers: [ACPNameValue(name: "Authorization", value: "Bearer \(mcp.token)")]))
            } else {
                emit([.notice(kind: .commandOutput,
                              text: "Shared notes are unavailable: \(configuration.agent.name) does not take HTTP MCP servers.")])
            }
        }
        if servers.isEmpty { guidance = nil }
        var systemPrompt: ACPSystemPrompt?
        if let guidance, !guidance.isEmpty {
            if capabilities?.acceptsSystemPrompt == true { systemPrompt = ACPSystemPrompt(text: guidance) }
            else { prefacePending = guidance }
        }
        let cwd = configuration.projectDirectory.path
        if let saved = configuration.acpSessionID, !saved.isEmpty, configuration.resume != .new {
            let params = ACPSessionLoadParams(sessionId: saved, cwd: cwd, mcpServers: servers, systemPrompt: systemPrompt)
            var state: ACPSessionStateResult?
            do {
                if capabilities?.canResume == true {
                    state = try await conn.request("session/resume", params, as: ACPSessionStateResult.self)
                } else if capabilities?.canLoad == true {
                    loading = true
                    translator.isReplaying = true
                    do { state = try await conn.request("session/load", params, as: ACPSessionStateResult.self) }
                    catch { await endLoad(); throw error }
                    await endLoad()
                }
            } catch let e as ACPError where e.isAuthRequired {
                throw e
            } catch let e as ACPError where e == .connectionClosed {
                throw e
            } catch {
                state = nil   // the agent no longer knows it: a new session, with the notice
            }
            if let state {
                acpSessionID = saved
                configOptions = state.configOptions ?? []
                modesState = state.modes
                emit([.systemInit(SystemInit(model: "", permissionMode: "", sessionID: saved, tools: [], slashCommands: []))])
                emit(translator.state(modes: state.modes, models: state.models, options: state.configOptions))
                return
            }
            emit([.notice(kind: .commandOutput, text: "This agent doesn't remember the earlier conversation")])
        }
        let new = try await conn.request("session/new",
                                         ACPSessionNewParams(cwd: cwd, mcpServers: servers, systemPrompt: systemPrompt),
                                         as: ACPSessionNewResult.self)
        acpSessionID = new.sessionId
        configOptions = new.configOptions ?? []
        modesState = new.modes
        let state = translator.state(modes: new.modes, models: new.models, options: new.configOptions)
        emit([.systemInit(SystemInit(model: translator.currentModelID ?? "", permissionMode: translator.currentModeID ?? "",
                                     sessionID: new.sessionId, tools: [], slashCommands: []))])
        emit(state)
    }

    /// The replay is over once every update that arrived before the response has been looked at.
    private func endLoad() async {
        if let conn = connection {
            let target = await conn.incomingCount()
            var waited = 0
            while consumed < target, !incomingEnded, waited < 2000 { try? await Task.sleep(for: .milliseconds(1)); waited += 1 }
        }
        loading = false
        translator.isReplaying = false
        translator.resetTurn()
    }

    private func handshakeFailed(_ error: Error) async {
        let text: String
        if let e = error as? ACPError, e.isAuthRequired {
            text = "\(configuration.agent.name) needs you to sign in."
        } else if let e = error as? ACPError, e == .connectionClosed {
            return   // the exit notice says it
        } else {
            text = "\(configuration.agent.name) could not start a session: \(error)"
        }
        emit([.notice(kind: .error, text: text)])
        await process?.stopAndWait(timeout: .seconds(3))
    }

    // MARK: login

    private enum LoginOutcome { case signedIn, handedOff, cancelled }

    /// Shows the sign-in card (one button per method) and carries out the choice: `authenticate` for an agent method;
    /// for a terminal method the workspace opens a terminal tab, and re-initializes the agent when the user returns.
    private func login(_ conn: ACPConnection) async -> LoginOutcome {
        guard !authMethods.isEmpty else { return .cancelled }
        guard let method = await askAuth(authMethods) else {
            emit([.notice(kind: .warning, text: "Sign-in cancelled.")])
            return .cancelled
        }
        if method.type == "terminal" {
            var env: [String: JSONValue] = [:]
            if case .object(let o)? = method.env { env = o }
            else if let list = method.env?.arrayValue {
                for item in list { if let n = item["name"]?.stringValue, let v = item["value"] { env[n] = v } }
            }
            let command = ([configuration.executable.path] + configuration.arguments + (method.args ?? []))
            emit([.controlRequest(ControlRequest(requestID: "acp-auth-terminal-\(authCounter)", kind: .other(
                subtype: "acp_auth_terminal",
                body: .object(["command": .array(command.map { .string($0) }), "env": .object(env),
                               "method": .string(method.id), "agent": .string(configuration.agent.name)]))))])
            emit([.notice(kind: .commandOutput, text: "Sign in to \(configuration.agent.name) in the terminal, then continue here.")])
            let again = await askAuth([ACPAuthMethod(id: method.id, name: "I've signed in", description: "Restart \(configuration.agent.name) and continue", type: nil, args: nil, env: nil)])
            guard again != nil else { return .cancelled }
            emit([.controlRequest(ControlRequest(requestID: "acp-reinit-\(authCounter)", kind: .other(
                subtype: "acp_reinitialize", body: .object([:]))))])
            return .handedOff
        }
        do {
            _ = try await conn.request("authenticate", ACPAuthenticateParams(methodId: method.id), as: JSONValue.self)
            return .signedIn
        } catch {
            emit([.notice(kind: .error, text: "\(configuration.agent.name) sign-in failed: \((error as? ACPError)?.message ?? "\(error)")")])
            return .cancelled
        }
    }

    private func askAuth(_ methods: [ACPAuthMethod]) async -> ACPAuthMethod? {
        authCounter += 1
        let rid = "acp-auth-\(authCounter)"
        let question = "\(configuration.agent.name) needs you to sign in."
        let options: [JSONValue] = methods.map {
            .object(["label": .string($0.name ?? $0.id), "description": .string($0.description ?? "")])
        }
        let input: JSONValue = .object(["questions": .array([.object([
            "question": .string(question), "header": .string("Sign in"),
            "options": .array(options), "multiSelect": .bool(false)])])])
        emit([.controlRequest(ControlRequest(requestID: rid, kind: .canUseTool(
            toolName: "AskUserQuestion", input: input, description: question, toolUseID: nil, suggestions: [])))])
        return await withCheckedContinuation { c in authWaiter = (rid, methods, c) }
    }

    private func answerAuth(_ rid: String, input: JSONValue?) {
        guard let waiter = authWaiter, waiter.rid == rid else { return }
        authWaiter = nil
        guard let answers = input?["answers"]?.objectValue, let label = answers.values.compactMap(\.stringValue).first else {
            waiter.continuation.resume(returning: nil)
            return
        }
        waiter.continuation.resume(returning: waiter.methods.first { ($0.name ?? $0.id) == label })
    }

    /// After a prompt failed with `auth_required`: offer the same card; once signed in the user sends the message again.
    private func offerLoginAfterPrompt() async {
        guard let conn = connection, authWaiter == nil else { return }
        switch await login(conn) {
        case .signedIn: emit([.notice(kind: .commandOutput, text: "Signed in. Send your message again.")])
        case .handedOff, .cancelled: break
        }
    }

    // MARK: incoming

    private func runIncoming(_ conn: ACPConnection, _ proc: ACPProcess) async {
        defer { incomingEnded = true }
        for await item in conn.incoming {
            defer { consumed += 1 }
            switch item {
            case .notification(let method, let params):
                guard method == "session/update",
                      let n = try? params.decode(ACPSessionNotification.self) else { continue }
                touch()
                if loading {
                    // The replay of a loaded session is Alloy's history already; only state updates are kept.
                    switch n.update {
                    case .availableCommands, .currentMode, .configOptions, .usage: emit(translator.translate(n.update))
                    default: break
                    }
                } else {
                    emit(translator.translate(n.update))
                }
            case .request(let id, let method, let params):
                await handleRequest(id: id, method: method, params: params, conn: conn)
            }
        }
        // Stdout ended. An agent that closed it but keeps running is killed, so the exit is reported.
        if proc.isRunning { await proc.stopAndWait(timeout: .seconds(2)) }
    }

    private func handleRequest(id: JSONValue, method: String, params: JSONValue, conn: ACPConnection) async {
        switch method {
        case "session/request_permission":
            guard let req = try? params.decode(ACPPermissionRequest.self) else {
                await conn.respondError(id: id, code: -32602, message: "Invalid params")
                return
            }
            await permissionRequested(id: id, request: req, conn: conn)
        case "fs/read_text_file":
            guard let p = try? params.decode(ACPReadTextFileParams.self) else {
                await conn.respondError(id: id, code: -32602, message: "Invalid params"); return
            }
            guard let files = configuration.fileService else {
                await conn.respondError(id: id, code: -32601, message: "Method not found"); return
            }
            Task {
                do {
                    let text = try await files.readTextFile(path: p.path, line: p.line, limit: p.limit)
                    await conn.respond(id: id, result: .object(["content": .string(text)]))
                } catch { await conn.respondError(id: id, code: -32603, message: Self.message(error)) }
            }
        case "fs/write_text_file":
            guard let p = try? params.decode(ACPWriteTextFileParams.self) else {
                await conn.respondError(id: id, code: -32602, message: "Invalid params"); return
            }
            guard let files = configuration.fileService else {
                await conn.respondError(id: id, code: -32601, message: "Method not found"); return
            }
            Task {
                do {
                    try await files.writeTextFile(path: p.path, content: p.content)
                    await conn.respond(id: id, result: .null)
                } catch { await conn.respondError(id: id, code: -32603, message: Self.message(error)) }
            }
        default:
            await conn.respondError(id: id, code: -32601, message: "Method not found")
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    private func permissionRequested(id: JSONValue, request: ACPPermissionRequest, conn: ACPConnection) async {
        touch()
        // After Stop (or with no prompt running) nothing waits for an answer: cancel it, never stick on the card.
        guard turnActive, !cancelRequested else {
            await conn.respond(id: id, result: ACPPermissionOutcome.cancelled.json)
            return
        }
        let tool = translator.permissionTool(request.toolCall)
        emit(tool.messages)
        if configuration.autoAllowAlloyTools, isAlloyTool(tool.name) || isAlloyTool(request.toolCall.title ?? ""),
           let option = ["allow_once", "allow_always"].lazy.compactMap({ k in request.options.first { $0.kind == k } }).first {
            await conn.respond(id: id, result: ACPPermissionOutcome.selected(optionId: option.optionId).json)
            return
        }
        permissionCounter += 1
        let rid = "acp-perm-\(permissionCounter)"
        pending[rid] = PendingPermission(rpcID: id, options: request.options)
        let suggestions: [JSONValue] = request.options.map {
            .object(["optionId": .string($0.optionId), "name": .string($0.name ?? $0.optionId),
                     "kind": .string($0.kind ?? "")])
        }
        emit([.controlRequest(ControlRequest(requestID: rid, kind: .canUseTool(
            toolName: tool.name, input: tool.input, description: request.toolCall.title,
            toolUseID: request.toolCall.toolCallId, suggestions: suggestions)))])
    }

    /// Whether a permission request is about one of Alloy's own tools (notes and coordination), by the name the agent shows.
    private func isAlloyTool(_ title: String) -> Bool {
        guard let server = configuration.mcp?.name else { return false }
        return Guidance.isAlloyToolTitle(title, server: server)
    }

    private func answerPermission(_ rid: String, allow: Bool, updated: [JSONValue]?) async {
        guard let p = pending.removeValue(forKey: rid), let conn = connection else { return }
        touch()
        let options = p.options
        func first(_ kinds: [String]) -> String? {
            for k in kinds { if let o = options.first(where: { $0.kind == k }) { return o.optionId } }
            return nil
        }
        var chosen: String?
        // The card passes the option the user picked as `{optionId}` among the "permissions".
        if let id = updated?.lazy.compactMap({ $0["optionId"]?.stringValue }).first(where: { id in options.contains { $0.optionId == id } }) {
            chosen = id
        } else if allow {
            chosen = first(["allow_once", "allow_always"])
        } else {
            chosen = first(["reject_once", "reject_always"])
        }
        let outcome: ACPPermissionOutcome = chosen.map { .selected(optionId: $0) } ?? .cancelled
        await conn.respond(id: p.rpcID, result: outcome.json)
    }

    /// Answers every open permission request `cancelled` and closes its card.
    private func cancelPermissions() async {
        guard let conn = connection else { return }
        let all = pending
        pending = [:]
        for (rid, p) in all.sorted(by: { $0.key < $1.key }) {
            await conn.respond(id: p.rpcID, result: ACPPermissionOutcome.cancelled.json)
            emit([.controlCancel(requestID: rid)])
        }
    }

    // MARK: exit

    private func watchExit(_ proc: ACPProcess) async {
        var code: Int32 = 0
        for await c in proc.exited { code = c }
        // Everything the agent wrote before it ended is delivered first.
        await incomingTask?.value
        watchdog?.cancel()
        queue.removeAll()
        if let waiter = authWaiter { authWaiter = nil; waiter.continuation.resume(returning: nil) }
        flushDeltas()
        flushHistoryBlock()
        deltaFlush?.cancel()
        turnActive = false
        let tail = proc.stderrTail
        events.yield(.exited(status: code, stderrTail: String(tail.suffix(4096))))
        finishStream()
    }

    private func finishStream() {
        guard !finished else { return }
        finished = true
        events.finish()
    }

    // MARK: prompts

    private func sendPrompt(_ content: [UserContent], uuid: UUID, priority: Priority?) async throws {
        guard ready != nil, connection != nil, !finished else { throw ACPProcessError.notRunning }
        if priority == .now {
            // Send now: this message goes first, and the running turn is cancelled so it starts at once.
            if let i = queue.firstIndex(where: { $0.uuid == uuid }) {
                let item = queue.remove(at: i)
                queue.insert(item, at: 0)
            } else if !content.isEmpty {
                queue.insert(QueuedPrompt(content: content, uuid: uuid), at: 0)
            } else {
                return
            }
            if turnActive { await cancelTurn() }
            pump()
            return
        }
        guard !content.isEmpty else { return }
        queue.append(QueuedPrompt(content: content, uuid: uuid))
        pump()
    }

    private func pump() {
        guard pumpTask == nil, !queue.isEmpty, !turnActive else { return }
        pumpTask = Task { await self.dispatchQueued() }
    }

    private func dispatchQueued() async {
        defer { pumpTask = nil }
        guard let ready, let conn = connection else { return }
        do { try await ready.value } catch { return }   // the handshake failed: the exit notice says so
        // No session (a terminal sign-in handed over to the workspace): nothing can be sent yet.
        guard !acpSessionID.isEmpty else { return }
        while !turnActive, !queue.isEmpty, !finished {
            let item = queue.removeFirst()
            await startPrompt(item, conn)
        }
    }

    private func startPrompt(_ item: QueuedPrompt, _ conn: ACPConnection) async {
        var blocks: [ACPContentBlock] = []
        var texts: [String] = []
        var images = 0, dropped = 0
        for c in item.content {
            switch c {
            case .text(let t): blocks.append(.text(t)); texts.append(t)
            case .image(let mediaType, let base64):
                if capabilities?.acceptsImages == true { blocks.append(.image(data: base64, mimeType: mediaType)); images += 1 }
                else { dropped += 1 }
            }
        }
        if dropped > 0 { emit([.notice(kind: .warning, text: "\(configuration.agent.name) does not accept images; they were not sent.")]) }
        if texts.count > 1, texts[0].hasPrefix(AlreadyRead.header) { texts.removeFirst() }
        else if texts.count == 1, AlreadyRead.isBlock(texts[0]) { texts.removeAll() }
        // What leads the prompt without being the user's: the guidance (once, for agents with no system prompt) and
        // the notices that gathered while the turn ran.
        var lead: [String] = []
        if let preface = prefacePending { lead.append(preface); prefacePending = nil }
        if let extra = await configuration.leadingContext?(), !extra.isEmpty { lead.append(extra) }
        guard !finished else { return }
        if !lead.isEmpty { blocks.insert(.text(lead.joined(separator: "\n\n")), at: 0) }
        emit([.userEcho(text: texts.joined(separator: "\n"), imageCount: images,
                        uuid: item.uuid.uuidString.lowercased(), isReplay: false)])
        turn += 1
        let myTurn = turn
        turnActive = true
        cancelRequested = false
        touch()
        startWatchdog(myTurn)
        let sessionID = acpSessionID
        promptTask = Task {
            do {
                let result = try await conn.request("session/prompt", ACPPromptParams(sessionId: sessionID, prompt: blocks),
                                                    as: ACPPromptResult.self,
                                                    onID: { id in Task { await self.notePromptID(id) } })
                await self.turnEnded(myTurn, .success(result))
            } catch {
                await self.turnEnded(myTurn, .failure(error))
            }
        }
    }

    private func notePromptID(_ id: Int) { promptRequestID = id }

    private func turnEnded(_ myTurn: Int, _ outcome: Result<ACPPromptResult, Error>) async {
        defer {
            if myTurn == turn { promptTask = nil }
            pump()
        }
        // The response can overtake the updates before it: let them be translated first, so nothing follows the result.
        if let conn = connection {
            let target = await conn.incomingCount()
            var waited = 0
            while consumed < target, !incomingEnded, waited < 2000 { try? await Task.sleep(for: .milliseconds(1)); waited += 1 }
        }
        guard myTurn == turn else { return }   // the watchdog already ended this turn
        watchdog?.cancel()
        turnActive = false
        flushDeltas()
        // Anything still asked is moot now.
        if !pending.isEmpty { await cancelPermissions() }
        switch outcome {
        case .success(let r):
            emit(translator.result(for: r, sessionID: acpSessionID))
        case .failure(let error):
            if let e = error as? ACPError, e == .connectionClosed { return }   // the exit event ends the turn
            let text: String
            if let e = error as? ACPError, e.isAuthRequired { text = "\(configuration.agent.name) needs you to sign in." }
            else if let e = error as? ACPError { text = "\(configuration.agent.name): \(e.message)" }
            else { text = "\(configuration.agent.name): \(error)" }
            emit([.notice(kind: .error, text: text)])
            emit(translator.result(for: ACPPromptResult(stopReason: "end_turn"), sessionID: acpSessionID))
            if let e = error as? ACPError, e.isAuthRequired, !authMethods.isEmpty {
                Task { await self.offerLoginAfterPrompt() }
            }
        }
    }

    /// Asks the agent to stop the running turn and answers its open permission requests `cancelled`.
    private func cancelTurn() async {
        guard turnActive, let conn = connection else { return }
        cancelRequested = true
        await conn.notify("session/cancel", ACPCancelParams(sessionId: acpSessionID))
        await cancelPermissions()
    }

    // MARK: controls

    private func control(_ subtype: ControlSubtype) async throws {
        guard let conn = connection else { return }
        switch subtype {
        case .interrupt:
            // Stop means stop: what waited behind the turn does not go out after it.
            queue.removeAll()
            await cancelTurn()
        case .setPermissionMode(let mode):
            try await ready?.value
            if let option = configOptions.first(where: { $0.category == "mode" }) {
                try await setConfigOption(option.id, mode, conn)
            } else {
                _ = try await conn.request("session/set_mode", ACPSetModeParams(sessionId: acpSessionID, modeId: mode),
                                           as: JSONValue.self)
                emit(translator.translate(.currentMode(mode)))
            }
        case .setModel(let model):
            try await ready?.value
            guard let option = configOptions.first(where: { $0.category == "model" }) else {
                emit([.notice(kind: .warning, text: "\(configuration.agent.name) does not let Alloy change the model.")])
                return
            }
            try await setConfigOption(option.id, model, conn)
        case .setEffort, .initialize: break
        }
    }

    private func setConfigOption(_ id: String, _ value: String, _ conn: ACPConnection) async throws {
        let result = try await conn.request("session/set_config_option",
                                            ACPSetConfigOptionParams(sessionId: acpSessionID, configId: id, value: value),
                                            as: ACPSessionStateResult.self)
        if let options = result.configOptions {
            configOptions = options
            emit(translator.state(modes: result.modes, models: result.models, options: options))
        }
    }

    // MARK: watchdog

    private func touch() { lastActivity = clock.now }

    private func startWatchdog(_ forTurn: Int) {
        watchdog?.cancel()
        watchdog = Task { await self.watch(forTurn) }
    }

    private func watch(_ forTurn: Int) async {
        while !Task.isCancelled {
            do { try await clock.sleep(until: lastActivity + watchdogSeconds) } catch { return }
            guard forTurn == turn, turnActive else { return }
            // A permission card can wait for the user as long as it likes.
            if !pending.isEmpty { touch(); continue }
            if clock.now >= lastActivity + watchdogSeconds { await timedOut(forTurn); return }
        }
    }

    private func timedOut(_ forTurn: Int) async {
        guard forTurn == turn, turnActive, let conn = connection else { return }
        turn += 1   // the late answer to this prompt, if it ever comes, is ignored
        turnActive = false
        flushDeltas()
        await conn.notify("session/cancel", ACPCancelParams(sessionId: acpSessionID))
        await cancelPermissions()
        emit([.notice(kind: .error, text: "The agent stopped responding. Stop it or restart the session."),
              .result(TurnResult(subtype: "agent_unresponsive", isError: false, costUSD: 0, inputTokens: 0, outputTokens: 0,
                                 sessionID: acpSessionID, terminalReason: "aborted_tools"))])
    }

    // MARK: output

    /// Text deltas are merged for one frame; every other message goes out in order behind them.
    private func emit(_ messages: [InboundMessage]) {
        for m in messages {
            recordHistory(m)
            switch m {
            case .delta(.text(_, let s)):
                if deltaIsThinking { flushDeltas() }
                deltaIsThinking = false
                deltaBuffer += s
                scheduleFlush()
            case .delta(.thinking(_, let s, _)):
                if !deltaIsThinking { flushDeltas() }
                deltaIsThinking = true
                deltaBuffer += s
                scheduleFlush()
            default:
                flushDeltas()
                events.yield(.message(m))
            }
        }
    }

    private func scheduleFlush() {
        guard deltaFlush == nil else { return }
        deltaFlush = Task {
            try? await Task.sleep(for: Self.deltaInterval)
            self.flushDeltas()
        }
    }

    private func flushDeltas() {
        deltaFlush?.cancel()
        deltaFlush = nil
        guard !deltaBuffer.isEmpty else { return }
        let text = deltaBuffer
        deltaBuffer = ""
        events.yield(.message(.delta(deltaIsThinking ? .thinking(index: 0, text, estimatedTokens: nil) : .text(index: 0, text))))
    }
}

// MARK: history

extension ACPTransport {
    /// Appends what a restored session shows later. Streamed text is kept until its block ends, then written whole.
    private func recordHistory(_ m: InboundMessage) {
        guard configuration.history != nil else { return }
        switch m {
        case .delta(.text(_, let s)):
            if histThinking { flushHistoryBlock() }
            histThinking = false
            histBuffer += s
        case .delta(.thinking(_, let s, _)):
            if !histThinking { flushHistoryBlock() }
            histThinking = true
            histBuffer += s
        case .delta(.blockStart): flushHistoryBlock()
        case .delta: break
        default:
            flushHistoryBlock()
            if let line = ACPHistory.encode(m) { configuration.history?.append(line) }
        }
    }

    fileprivate func flushHistoryBlock() {
        guard !histBuffer.isEmpty else { return }
        let text = histBuffer
        histBuffer = ""
        let block: ContentBlock = histThinking ? .thinking(text) : .text(text)
        if let line = ACPHistory.encode(.assistantBlock(messageID: "acp-h-\(UUID().uuidString.lowercased())", block: block)) {
            configuration.history?.append(line)
        }
    }
}
