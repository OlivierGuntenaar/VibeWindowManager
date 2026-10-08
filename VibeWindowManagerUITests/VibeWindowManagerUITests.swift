//
//  VibeWindowManagerUITests.swift
//  VibeWindowManagerUITests
//
//  Created by Thomas Guntenaar on 23/04/2026.
//

import XCTest

final class VibeWindowManagerUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testMainWindowAndUpdateMenu() throws {
        let app = makeVibeUITestApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.menuBars.menuBarItems["Quick layout"].exists)
        app.menuBars.menuBarItems["VibeWindowManager"].click()
        let update = app.menuItems["Check for Updates…"]
        XCTAssertTrue(update.waitForExistence(timeout: 3))
        // Development builds must not replace themselves with a distributed build.
        XCTAssertFalse(update.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            makeVibeUITestApplication().launch()
        }
    }
}

@MainActor
func makeVibeUITestApplication() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["VIBE_UI_TESTING"] = "1"
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    return app
}
