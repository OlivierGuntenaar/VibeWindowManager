import CoreGraphics
import Foundation
import Testing
@testable import VibeWindowManager

@MainActor
struct LayoutCrashTests {
    private let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)

    @Test(arguments: [Int.min, -1, 0]) func nonpositiveCountsReturnNoFrames(count: Int) {
        for mode in [TileMode.equalColumns(3), .equalRows(3), .grid(3), .onePlusTwo] {
            #expect(WindowLayoutEngine.slotRects(visibleFrame: screen, mode: mode, count: count).isEmpty)
        }
        #expect(WindowLayoutEngine.cascadeFrames(visibleFrame: screen, count: count, insetStep: 30, margin: 8).isEmpty)
        #expect(TileMode.suggestedModes(forWindowCount: count).isEmpty)
    }

    @Test(arguments: [Int.max, Int.max - 1, 1_025])
    func excessiveAllocationsAreRejected(count: Int) {
        for mode in [TileMode.equalColumns(count), .equalRows(count), .grid(count)] {
            #expect(WindowLayoutEngine.slotRects(visibleFrame: screen, mode: mode, count: count).isEmpty)
        }
        #expect(WindowLayoutEngine.cascadeFrames(visibleFrame: screen, count: count, insetStep: 30, margin: 8).isEmpty)
    }

    @Test func hugeAvailableWindowCountStillAllowsSmallRequestedLayout() {
        for mode in [TileMode.equalColumns(3), .equalRows(3), .grid(3), .onePlusTwo] {
            #expect(WindowLayoutEngine.slotRects(visibleFrame: screen, mode: mode, count: Int.max).count == 3)
        }
    }

    @Test(arguments: [Int.min, -1, 0, Int.max])
    func requestedCountsAreBoundedByActualWindowCount(requested: Int) {
        for mode in [TileMode.equalColumns(requested), .equalRows(requested), .grid(requested)] {
            let frames = WindowLayoutEngine.slotRects(visibleFrame: screen, mode: mode, count: 2)
            #expect(frames.count == (requested <= 0 ? 1 : 2))
            #expect(frames.allSatisfy { $0.width.isFinite && $0.height.isFinite })
        }
    }

    @Test func maximumSupportedCountCompletesWithoutUnboundedAllocation() {
        let count = WindowLayoutEngine.maximumLayoutCount
        for mode in [TileMode.equalColumns(count), .equalRows(count), .grid(count)] {
            let frames = WindowLayoutEngine.slotRects(visibleFrame: screen, mode: mode, count: count)
            #expect(frames.count == count)
            #expect(frames.allSatisfy { $0.origin.x.isFinite && $0.origin.y.isFinite })
        }
        #expect(WindowLayoutEngine.cascadeFrames(visibleFrame: screen, count: count, insetStep: 30, margin: 8).count == count)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func nonfiniteScreenComponentsAreRejected(value: Double) {
        let bad = CGFloat(value)
        let frames = [CGRect(x: bad, y: 0, width: 1920, height: 1080),
                      CGRect(x: 0, y: bad, width: 1920, height: 1080),
                      CGRect(x: 0, y: 0, width: bad, height: 1080),
                      CGRect(x: 0, y: 0, width: 1920, height: bad)]
        for frame in frames {
            for mode in [TileMode.equalColumns(2), .equalRows(2), .grid(2), .onePlusTwo] {
                #expect(WindowLayoutEngine.slotRects(visibleFrame: frame, mode: mode, count: 2).isEmpty)
            }
            #expect(WindowLayoutEngine.cascadeFrames(visibleFrame: frame, count: 2, insetStep: 30, margin: 8).isEmpty)
        }
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -1.0])
    func invalidCascadeSpacingIsRejected(value: Double) {
        #expect(WindowLayoutEngine.cascadeFrames(visibleFrame: screen, count: 2, insetStep: CGFloat(value), margin: 8).isEmpty)
        #expect(WindowLayoutEngine.cascadeFrames(visibleFrame: screen, count: 2, insetStep: 30, margin: CGFloat(value)).isEmpty)
    }

    @Test func finiteSpacingThatOverflowsDuringArithmeticIsRejected() {
        #expect(WindowLayoutEngine.cascadeFrames(visibleFrame: screen, count: 3,
                                               insetStep: .greatestFiniteMagnitude, margin: 8).isEmpty)
        #expect(WindowLayoutEngine.cascadeFrames(visibleFrame: screen, count: 2,
                                               insetStep: 30, margin: .greatestFiniteMagnitude).isEmpty)
        #expect(WindowLayoutEngine.cascadeFrames(visibleFrame: screen, count: 3,
                                               insetStep: .greatestFiniteMagnitude / 3,
                                               margin: .greatestFiniteMagnitude / 3).isEmpty)
    }

    @Test func overflowingScreenExtentIsRejected() {
        let frame = CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                           width: CGFloat.greatestFiniteMagnitude, height: 1080)
        #expect(WindowLayoutEngine.slotRects(visibleFrame: frame, mode: .grid(2), count: 2).isEmpty)
        #expect(WindowLayoutEngine.cascadeFrames(visibleFrame: frame, count: 2, insetStep: 30, margin: 8).isEmpty)
    }

    @Test func cascadeCoordinateOverflowIsRejected() {
        let frame = CGRect(x: -CGFloat.greatestFiniteMagnitude, y: 0, width: 1920, height: 1080)
        #expect(WindowLayoutEngine.cascadeFrames(visibleFrame: frame, count: 2, insetStep: 0,
                                               margin: .greatestFiniteMagnitude / 4).isEmpty)
    }

    @Test func emptyOrDegenerateScreenHasNoLayout() {
        for frame in [CGRect.zero, CGRect.null, CGRect(x: 0, y: 0, width: 1, height: 1080),
                      CGRect(x: 0, y: 0, width: 1920, height: 1)] {
            #expect(WindowLayoutEngine.slotRects(visibleFrame: frame, mode: .grid(2), count: 2).isEmpty)
            #expect(WindowLayoutEngine.cascadeFrames(visibleFrame: frame, count: 2, insetStep: 30, margin: 8).isEmpty)
        }
    }

    @Test func zeroSpacingProducesValidCoincidentCascadeFrames() {
        let frames = WindowLayoutEngine.cascadeFrames(visibleFrame: screen, count: 3, insetStep: 0, margin: 0)
        #expect(frames == [screen, screen, screen])
    }

    @Test(arguments: [1, 2, 3, 5, 17, 64]) func ordinaryNegativeOriginLayoutsRemainFinite(count: Int) {
        for mode in [TileMode.equalColumns(count), .equalRows(count), .grid(count)] {
            let frames = WindowLayoutEngine.slotRects(visibleFrame: screen, mode: mode, count: count)
            #expect(frames.count == count)
            #expect(frames.allSatisfy { $0.origin.x.isFinite && $0.origin.y.isFinite &&
                $0.width.isFinite && $0.height.isFinite && $0.width >= 0 && $0.height >= 0 })
        }
    }
}
