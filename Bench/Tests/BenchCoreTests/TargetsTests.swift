import CoreGraphics
import Testing
@testable import BenchCore

@Suite struct TargetsTests {
    @Test func targetsHaveStableIDs() {
        #expect(TargetApp.zed.id == "zed")
        #expect(TargetApp.delta.id == "delta")
        #expect(TargetApp.alloy(buildDir: "/tmp/Alloy").id == "alloy")
    }

    @Test func unsupportedMetricsHaveReasons() {
        for t in [TargetApp.zed, .delta, .alloy(buildDir: "/tmp/Alloy")] {
            for (m, reason) in t.unsupported {
                #expect(!reason.isEmpty, "\(t.id) \(m)")
            }
        }
    }

    @Test func alloyTypingSupported() {
        #expect(TargetApp.alloy(buildDir: "/tmp/Alloy").unsupported[.typingLatency] == nil)
    }

    @Test func alloyTypingClickPointIsPanel() {
        let w = CGRect(x: 100, y: 50, width: 1200, height: 800)
        let alloy = TargetApp.alloy(buildDir: "/tmp/Alloy")
        // Same point scrolling uses: the file panel centre, well below the tab strip at the panel's top edge.
        #expect(alloy.typingClickPoint?(w) == alloy.scrollPoint(w))
        #expect(alloy.typingClickPoint?(w) == CGPoint(x: 1300 - 180, y: 450))
        #expect(TargetApp.zed.typingClickPoint == nil)
        #expect(TargetApp.delta.typingClickPoint == nil)
    }

    @Test func zedLaunchArgsIncludeFile() {
        #expect(TargetApp.zed.launchArguments("/tmp/a.swift").contains("/tmp/a.swift"))
        #expect(!TargetApp.zed.launchArguments(nil).contains("/tmp/a.swift"))
    }

    @Test func scrollPointDefaultsToWindowCentreAndAlloyUsesItsFilePanel() {
        let w = CGRect(x: 100, y: 50, width: 1200, height: 800)
        #expect(TargetApp.zed.scrollPoint(w) == CGPoint(x: 700, y: 450))
        #expect(TargetApp.delta.scrollPoint(w) == CGPoint(x: 700, y: 450))
        // Alloy: file panel (360 pt ideal width, trailing column) centre; the window centre would be in the chat column.
        let p = TargetApp.alloy(buildDir: "/tmp/Alloy").scrollPoint(w)
        #expect(p == CGPoint(x: 1300 - 180, y: 450))
        #expect(p.x > w.minX + 1200 - 360 && p.x < w.maxX)
    }
}
