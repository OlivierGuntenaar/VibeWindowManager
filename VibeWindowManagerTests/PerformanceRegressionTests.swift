import CoreGraphics
import XCTest
@testable import VibeWindowManager

/// Baselines are recorded by XCTest; correctness checks prevent measuring skipped work.
final class PerformanceRegressionTests: XCTestCase {
    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }

    @MainActor func testServerDiscoveryParsingPerformance() {
        let fixture = (1...500).map { index in
            "p\(index)\ncnode\nLtester\nf1\ntIPv4\nPTCP\nn127.0.0.1:\(3000 + index)\n"
        }.joined()
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            for _ in 0..<10 {
                let listeners = LSOFListenParser.mergeProcesses(LSOFListenParser.parse(fixture))
                XCTAssertEqual(listeners.count, 500)
            }
        }
    }

    @MainActor func testLayoutGenerationPerformance() {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            for _ in 0..<1000 {
                XCTAssertEqual(WindowLayoutEngine.slotRects(visibleFrame: screen, mode: .grid(16), count: 16).count, 16)
                XCTAssertEqual(WindowLayoutEngine.cascadeFrames(visibleFrame: screen, count: 16, insetStep: 20, margin: 8).count, 16)
            }
        }
    }

    @MainActor func testUsageParsingPerformance() {
        let fixture: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 42, "windowDurationMins": 300],
                                                                  "secondary": ["usedPercent": 15, "windowDurationMins": 10080]]]
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            for _ in 0..<1000 {
                XCTAssertEqual(CodexUsageEngine.parseLive(fixture)?.windows.count, 2)
            }
        }
    }
}
