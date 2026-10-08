import XCTest

final class LifecycleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func assertUsableMainWindow(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(app.staticTexts["Your Mac, in flow"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(app.menuBars.menuBarItems["Quick layout"].exists, file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
    }

    @MainActor
    func testClosingAndReopeningMainWindowRepeatedlyKeepsAppUsable() {
        let app = makeVibeUITestApplication()
        app.launch()
        defer { app.terminate() }
        assertUsableMainWindow(app)
        for _ in 0..<3 {
            app.typeKey("w", modifierFlags: .command)
            let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.windows.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 5), .completed)
            XCTAssertNotEqual(app.state, .notRunning)
            app.activate()
            app.typeKey("n", modifierFlags: .command)
            assertUsableMainWindow(app)
            XCTAssertEqual(app.windows.count, 1, "Reopening must not duplicate the main window")
        }
    }

    @MainActor
    func testTerminateAndRelaunchRestoresUsableMainWindow() {
        let app = makeVibeUITestApplication()
        defer { app.terminate() }
        for _ in 0..<3 {
            app.launch()
            assertUsableMainWindow(app)
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        }
        app.launch()
        assertUsableMainWindow(app)
    }

    @MainActor
    func testRelaunchAfterLastWindowClosedKeepsUpdateMenuUsable() {
        let app = makeVibeUITestApplication()
        app.launch()
        defer { app.terminate() }
        assertUsableMainWindow(app)
        app.typeKey("w", modifierFlags: .command)
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launch()
        assertUsableMainWindow(app)
        app.menuBars.menuBarItems["VibeWindowManager"].click()
        let update = app.menuItems["Check for Updates…"]
        XCTAssertTrue(update.waitForExistence(timeout: 3))
        XCTAssertFalse(update.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        assertUsableMainWindow(app)
    }
}
