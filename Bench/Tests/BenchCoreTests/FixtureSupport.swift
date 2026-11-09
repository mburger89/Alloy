import Foundation
import Testing
@testable import BenchCore
@testable import BenchDrivers

/// macOS refuses to exec Apple platform apps (TextEdit is SIGKILLed: launch constraints), so the
/// "neutral app" is a tiny AppKit fixture compiled with swiftc. Argument "animate" moves a bar at
/// 60 Hz; any keyDown toggles a large panel.
let fixtureSource = """
import AppKit
final class V: NSView {
    var phase: CGFloat = 0, toggled = false
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ r: NSRect) {
        NSColor(calibratedWhite: 0.1, alpha: 1).setFill(); bounds.fill()
        NSColor.white.setFill(); NSRect(x: 20 + phase, y: 20, width: 80, height: 60).fill()
        if toggled { NSColor.systemOrange.setFill(); NSRect(x: 40, y: 150, width: 300, height: 150).fill() }
    }
    override func keyDown(with e: NSEvent) { toggled.toggle(); needsDisplay = true }
}
final class A: NSApplication {
    var countPath: String?
    var scrolls = 0
    override func sendEvent(_ e: NSEvent) {
        if e.type == .scrollWheel, let p = countPath {
            scrolls += 1
            try? String(scrolls).write(toFile: p, atomically: true, encoding: .utf8)
        }
        super.sendEvent(e)
    }
}
let app = A.shared as! A
if let c = CommandLine.arguments.first(where: { $0.hasPrefix("count=") }) {
    app.countPath = String(c.dropFirst(6))
    try? "0".write(toFile: String(c.dropFirst(6)), atomically: true, encoding: .utf8)
}
app.setActivationPolicy(.regular)
let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 400),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
let v = V(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
win.contentView = v; win.makeFirstResponder(v)
// A *.swift argument: show the file in an editable NSTextView inside an NSScrollView.
var blankThenPaintMs: Double?
var paintLater: (() -> Void)?
if let path = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".swift") }),
   let text = try? String(contentsOfFile: path, encoding: .utf8) {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    scroll.hasVerticalScroller = true
    let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    tv.minSize = NSSize(width: 0, height: 400)
    tv.maxSize = NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude)
    tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.textContainer?.widthTracksTextView = true
    tv.isEditable = true
    tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    tv.string = text
    scroll.documentView = tv
    if let b = CommandLine.arguments.first(where: { $0.hasPrefix("blankThenPaint=") }), let ms = Double(b.dropFirst(15)) {
        // The window first shows a uniform background, then (ms after the window is shown) paints the file text.
        let blank = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        blank.wantsLayer = true
        blank.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        win.contentView = blank
        blankThenPaintMs = ms
        paintLater = { win.contentView = scroll; win.makeFirstResponder(tv) }
    } else {
        win.contentView = scroll; win.makeFirstResponder(tv)
    }
}
func show() {
    win.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    if let ms = blankThenPaintMs, let paint = paintLater {
        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) { paint() }
    }
}
if let d = CommandLine.arguments.first(where: { $0.hasPrefix("delay=") }), let ms = Double(d.dropFirst(6)) {
    DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) { show() }
} else {
    show()
}
if CommandLine.arguments.contains("animate") {
    Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
        v.phase = (v.phase + 5).truncatingRemainder(dividingBy: 300); v.needsDisplay = true }
}
app.run()
"""

let fixtureBinary: String = {
    let dir = NSTemporaryDirectory() + "bench-fixture-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? fixtureSource.write(toFile: dir + "/main.swift", atomically: true, encoding: .utf8)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    p.arguments = ["-O", dir + "/main.swift", "-o", dir + "/fixture"]
    try? p.run(); p.waitUntilExit()
    return dir + "/fixture"
}()

/// `file` is passed through as the argument ("animate" or "static").
func fixtureApp(extra: [String] = []) -> TargetApp {
    TargetApp(id: "fixture", displayName: "Fixture", bundlePath: nil, executablePath: fixtureBinary,
              launchArguments: { f in (f.map { [$0] } ?? []) + extra })
}

/// Launches, runs the body, and always terminates the launched tree (also when the body throws).
func withLaunched<T>(_ app: TargetApp, file: String?,
                             _ body: (LaunchedApp) async throws -> T) async throws -> T {
    let l = try Launcher.launch(app, file: file)
    do {
        let r = try await body(l)
        await Launcher.terminate(l)
        return r
    } catch {
        await Launcher.terminate(l)
        throw error
    }
}


/// Parent for all live suites: they drive real windows and input, so they must not run concurrently.
@Suite(.serialized) struct LiveTests {}
