import AppKit
import Foundation
import BenchCore
import BenchDrivers

public enum Runner {
    public static let defaultRuns: [Metric: Int] = [
        .startup: 10, .typingLatency: 1, .scrollFrames: 5, .memory: 5, .memoryIdle: 3, .largeFileOpen: 10, .idleCPU: 3,
    ]

    public static func scenario(for metric: Metric, cold: Bool = false) -> any Scenario {
        switch metric {
        case .startup: return StartupScenario(cold: cold)
        case .typingLatency: return TypingLatencyScenario()
        case .scrollFrames: return ScrollFramesScenario()
        case .memory: return MemoryScenario()
        case .memoryIdle: return MemoryIdleScenario()
        case .largeFileOpen: return LargeFileOpenScenario()
        case .idleCPU: return IdleCPUScenario()
        }
    }

    /// Every (app, metric) pair, with `.notApplicable` pre-filled where the app cannot do the metric.
    public static func plan(apps: [TargetApp], metrics: [Metric]) -> [(TargetApp, Metric, applicable: Outcome?)] {
        apps.flatMap { app in metrics.map { m in (app, m, app.unsupported[m].map { Outcome.notApplicable($0) }) } }
    }

    /// `preflight` is re-run before each app's block of metrics (the user may have started their own Zed or Delta
    /// mid-run); a non-nil message marks that app's metrics not measured without launching anything.
    public static func run(apps: [TargetApp], metrics: [Metric], corpus: Corpus, runsOverride: Int?,
                           cold: Bool = false,
                           attribute: Bool = false,
                           trace: TraceKind? = nil, traceRoot: String = BenchPaths.defaultDirectory("traces", cwd: FileManager.default.currentDirectoryPath),
                           preflight: (@Sendable (TargetApp) -> String?)? = nil,
                           coverCheck: (@Sendable (TargetApp) -> String?)? = nil) async throws -> RunResult {
        let preflight = preflight ?? { Preflight.check(apps: [$0])?.message }
        let coverCheck = coverCheck ?? { Preflight.coverMessage(for: $0) }
        var coverRefused: String?
        var refusal: [String: String?] = [:]
        var idle: [String: (cpu: Outcome, memory: Outcome)] = [:]
        var requested: [String: [Metric: Int]] = [:]
        let harnessStart = Launcher.nowMicroseconds()
        let coldApplies = cold && metrics.contains(.startup)   // --cold only affects startup
        var coldOK = false
        // --trace: traces go to <traceRoot>/<result stem>/, so the stem is fixed now and reused for the result.
        let startEnv = trace == nil ? nil : Environment.current(cold: false)
        let session = trace.map { kind in
            TraceSession(kind: kind, directory: traceRoot + "/" + Report.fileStem(RunResult(environment: startEnv!, apps: [:], outcomes: [:])))
        }
        if coldApplies { coldOK = Purge.run() }
        if runsOverride != nil, metrics.contains(.typingLatency) {
            FileHandle.standardError.write(Data("note: --runs does not apply to typingLatency (one launch, 200 keystrokes)\n".utf8))
        }
        var outcomes: [String: [Metric: Outcome]] = [:]
        for (app, metric, applicable) in plan(apps: apps, metrics: metrics) {
            if let a = applicable { outcomes[app.id, default: [:]][metric] = a; continue }
            if metric == .startup, coldApplies, !coldOK {
                outcomes[app.id, default: [:]][metric] = .notMeasured("purge needs sudo"); continue
            }
            if refusal[app.id] == nil { refusal[app.id] = .some(preflight(app)) }
            if let why = refusal[app.id] ?? nil {
                FileHandle.standardError.write(Data("[\(app.displayName)] \(metric.rawValue) skipped: \(why)\n".utf8))
                outcomes[app.id, default: [:]][metric] = .notMeasured(RunMarkers.refusedPrefix + why); continue
            }
            if refusal[app.id] == .some(nil), coverRefused == nil, let why = coverCheck(app) {
                coverRefused = why
                FileHandle.standardError.write(Data("[\(app.displayName)] \(metric.rawValue) refused: \(why)\n".utf8))
                outcomes[app.id, default: [:]][metric] = .notMeasured(RunMarkers.refusedPrefix + why)
                continue
            }
            if let why = coverRefused {   // the run is aborted: later metrics and apps are not attempted
                outcomes[app.id, default: [:]][metric] = .notMeasured(RunMarkers.abortedPrefix + why); continue
            }
            FileHandle.standardError.write(Data("[\(app.displayName)] \(metric.rawValue)...\n".utf8))
            let runs = runsOverride ?? defaultRuns[metric] ?? 1
            let o: Outcome
            // --attribute: Alloy's own frame phases are appended as notes; they never affect a verdict.
            let collector = attribute && app.id == "alloy" ? AttributionCollector() : nil
            if metric == .idleCPU || metric == .memoryIdle {   // one launch yields both
                let traceMetric = idleTraceMetric(metrics)
                if idle[app.id] == nil {
                    let both = await run(with: collector, trace: session, metric: traceMetric) { await IdleCPUScenario().runBoth(app, corpus: corpus, runs: runs) }
                    let notes = (collector?.notes ?? []) + (session?.notes(app: app.id, metric: traceMetric) ?? [])
                    idle[app.id] = attachIdleNotes(cpu: both.cpu, memory: both.memory, notes: notes, metrics: metrics)
                }
                o = metric == .idleCPU ? idle[app.id]!.cpu : idle[app.id]!.memory
            } else {
                let measured = await run(with: collector, trace: session, metric: metric) {
                    await scenario(for: metric, cold: coldApplies && coldOK).run(app, corpus: corpus, runs: runs)
                }
                o = measured.addingNotes((collector?.notes ?? []) + (session?.notes(app: app.id, metric: metric) ?? []))
            }
            requested[app.id, default: [:]][metric] = runs
            outcomes[app.id, default: [:]][metric] = o.addingNotes(app.caveats)
        }
        var versions: [String: String] = [:]
        for a in apps { versions[a.id] = a.version() }
        var env = Environment.current(cold: coldApplies && coldOK)
        if let startEnv { env.date = startEnv.date; env.time = startEnv.time }   // matches the trace directory's stem
        let result = RunResult(environment: env, apps: versions, outcomes: outcomes,
                         harnessSHA: harnessSHA(),
                         runCounts: runCounts(outcomes: outcomes, requested: { requested[$0.app]?[$0.metric] ?? 0 }),
                         notes: Leftovers.warnings(apps: apps, since: harnessStart),
                         attributed: attribute && apps.contains { $0.id == "alloy" },
                         traced: session != nil, traceKind: trace)
        if let why = coverRefused { throw CoverRefused(message: why, partial: result) }
        return result
    }

    /// The one trace of the shared idle launch is keyed idleCPU, or memoryIdle when idleCPU was not requested.
    static func idleTraceMetric(_ metrics: [Metric]) -> Metric { metrics.contains(.idleCPU) ? .idleCPU : .memoryIdle }

    /// One launch yields both idle outcomes; the launch's notes go on the one that is reported.
    static func attachIdleNotes(cpu: Outcome, memory: Outcome, notes: [String], metrics: [Metric]) -> (cpu: Outcome, memory: Outcome) {
        idleTraceMetric(metrics) == .idleCPU ? (cpu.addingNotes(notes), memory) : (cpu, memory.addingNotes(notes))
    }

    private static func run<T>(with collector: AttributionCollector?, _ body: () async -> T) async -> T {
        guard let collector else { return await body() }
        return await collector.collecting(body)
    }

    private static func run<T>(with collector: AttributionCollector?, trace: TraceSession?, metric: Metric,
                               _ body: () async -> T) async -> T {
        guard let trace else { return await run(with: collector, body) }
        return await trace.within(metric: metric) { await run(with: collector, body) }
    }

    /// Another app's window covers where the target's windows open. Nothing was launched for the refused app;
    /// `partial` holds what was measured before (the refused app's metrics are not measured).
    public struct CoverRefused: Error, CustomStringConvertible {
        public var message: String
        public var partial: RunResult
        public var description: String { message }
    }

    /// Requested vs completed runs per (app, metric). Completed is `requested - failed runs` for a measured outcome
    /// and 0 for a not-measured one (no result was published); not-applicable metrics have no entry.
    static func runCounts(outcomes: [String: [Metric: Outcome]],
                          requested: ((app: String, metric: Metric)) -> Int) -> [String: [Metric: RunCount]] {
        var out: [String: [Metric: RunCount]] = [:]
        for (app, byMetric) in outcomes {
            for (metric, o) in byMetric {
                let n = requested((app, metric))
                switch o {
                case .measured(_, _, _, let failures): out[app, default: [:]][metric] = RunCount(requested: n, completed: max(0, n - failures.count))
                case .notMeasured: out[app, default: [:]][metric] = RunCount(requested: n, completed: 0)
                case .notApplicable: break
                }
            }
        }
        return out
    }

    /// `git rev-parse --short HEAD` of the checkout this harness was built from.
    static func harnessSHA() -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", repo, "rev-parse", "--short", "HEAD"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "unknown" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? s : "unknown"
    }
}

extension Environment {
    static func current(cold: Bool) -> Environment {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let tf = DateFormatter(); tf.dateFormat = "HHmmss"; tf.locale = f.locale
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return Environment(date: f.string(from: Date()), machine: sysctlString("hw.model") ?? "unknown-mac",
                           macOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                           refreshHz: Probe.refreshHz(), scale: Probe.scale(), onBattery: onBattery(), cold: cold,
                           time: tf.string(from: Date()), thermalState: thermal())
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func onBattery() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g", "batt"]
        let pipe = Pipe(); p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).contains("Battery Power")
    }
}

public enum Preflight {
    /// Refusal text naming the main app pid (never a crash-handler helper); nil when no instance is running.
    public static func runningMessage(for app: TargetApp) -> String? {
        Launcher.runningInstance(of: app).map {
            "\(app.displayName) is already running (pid \($0)). Quit it first; alloy-bench never touches apps it didn't launch."
        }
    }

    /// Exit code for "another app's window covers the target's window area".
    public static let coverExitCode: Int32 = 4

    /// Refusal text when any other app's (the harness's own terminal included) normal window covers more than 10 %
    /// of the central 60 % x 60 % of the main display; nil when clear. Skips harness-launched apps.
    public static func coverMessage(for app: TargetApp) -> String? {
        WindowCover.refusalMessage(WindowCover.current(launchedPids: ActiveLaunches.current.map(\.pid)), targetName: app.displayName)
    }

    /// Pure check of `DevToolsSecurity -status` output; Instruments cannot attach without Developer Tools access.
    /// "currently disabled" must not count as enabled.
    public static func checkDevTools(status: String) -> (code: Int32, message: String)? {
        if status.contains("currently enabled") { return nil }
        return (2, "Instruments needs Developer Tools access to attach. Run once: sudo DevToolsSecurity -enable")
    }

    /// nil when clear; otherwise the exit code and message. Nothing is launched before this passes.
    public static func check(apps: [TargetApp]) -> (code: Int32, message: String)? {
        for app in apps {
            if let m = runningMessage(for: app) { return (2, m) }
        }
        let missing = Permissions.missing()
        if !missing.isEmpty {
            return (3, "Missing permissions for this terminal:\n" + missing.map { "  - \($0)" }.joined(separator: "\n")
                    + "\nGrant them in System Settings, then restart the terminal.")
        }
        for app in apps where !FileManager.default.isExecutableFile(atPath: app.executablePath) {
            return (5, "\(app.displayName) executable not found: \(app.executablePath)")
        }
        return nil
    }
}

/// Command-line argument resolution (kept out of main so it is testable).
public enum CLIArguments {
    public struct Invalid: Error, CustomStringConvertible { public var description: String }

    /// Default apps are zed and delta; alloy is added only when a build directory is given.
    /// Naming alloy explicitly without `--alloy-build` is an error.
    public static func resolveApps(_ apps: String?, alloyBuild: String?) throws -> [TargetApp] {
        let ids: [String]
        if let apps { ids = apps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        else { ids = ["zed", "delta"] + (alloyBuild == nil ? [] : ["alloy"]) }
        return try ids.map { id in
            switch id {
            case "zed": return .zed
            case "delta": return .delta
            case "alloy":
                guard let dir = alloyBuild else { throw Invalid(description: "--alloy-build <dir> is required for alloy") }
                return .alloy(buildDir: dir)
            default: throw Invalid(description: "unknown app '\(id)' (zed, delta, alloy)")
            }
        }
    }

    public static func resolveMetrics(_ metrics: String?) throws -> [Metric] {
        guard let metrics else { return Metric.allCases }
        return try metrics.split(separator: ",").map {
            guard let m = Metric(rawValue: $0.trimmingCharacters(in: .whitespaces)) else {
                throw Invalid(description: "unknown metric '\($0)' (\(Metric.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            return m
        }
    }
}

/// SIGINT/SIGTERM: terminate every harness-launched app through `Launcher.terminate`, then exit.
public enum SignalGuard {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    public static func install() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                Task {
                    FileHandle.standardError.write(Data("\nsignal \(sig): terminating launched apps\n".utf8))
                    ActiveRecorders.killAll()
                    await ActiveLaunches.terminateAll()
                    exit(128 + sig)
                }
            }
            src.resume()
            sources.append(src)
        }
    }
}

/// Report-only (never kills) detection of target-app processes that started after the harness did and are still alive.
public enum Leftovers {
    public struct Found: Sendable, Equatable { public var app: String; public var pid: pid_t; public var path: String }

    public static func find(apps: [TargetApp], since: UInt64) -> [Found] {
        var out: [Found] = []
        var seen = Set<pid_t>()
        for app in apps {
            var pids = Launcher.pidsRunning(path: app.executablePath)
            if let id = app.bundleID {
                pids += NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.processIdentifier)
            }
            for pid in pids where seen.insert(pid).inserted {
                guard let st = Launcher.startTime(of: pid), st > since else { continue }
                out.append(Found(app: app.displayName, pid: pid, path: app.executablePath))
            }
        }
        return out
    }

    public static func warnings(apps: [TargetApp], since: UInt64) -> [String] {
        find(apps: apps, since: since).map {
            "leftover process: \($0.app) pid \($0.pid) (\($0.path)) started after the harness and is still running; not killed"
        }
    }
}
