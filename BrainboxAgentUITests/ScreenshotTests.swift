import XCTest

/// Walks the main screens in light and dark mode with demo data (no server) and
/// keeps screenshots; CI exports them as the `ui-screenshots` artifact.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launch(demo: Bool, _ appearance: XCUIDevice.Appearance) {
        XCUIDevice.shared.appearance = appearance
        app = XCUIApplication()
        app.launchArguments = demo ? ["-BBDemo"] : []
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tab(_ label: String) {
        let button = app.tabBars.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "tab \(label)")
        button.tap()
        sleep(1)
    }

    func testOnboarding() {
        launch(demo: false, .light)
        XCTAssertTrue(app.staticTexts["Connect to Hermes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Copy command"].exists, "the authorized_keys command is offered")
        shot("01-connect-light")
        XCUIDevice.shared.appearance = .dark
        sleep(1)
        shot("01-connect-dark")
    }

    func testMainScreens() {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            let suffix = appearance == .dark ? "dark" : "light"
            launch(demo: true, appearance)
            XCTAssertTrue(app.tabBars.buttons["Chat"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Approve this command?"].waitForExistence(timeout: 5), "approval card renders")
            shot("02-chat-\(suffix)")
            app.swipeDown()
            shot("03-chat-top-\(suffix)")
            tab("Sessions")
            shot("04-sessions-\(suffix)")
            tab("Agents")
            shot("05-agents-\(suffix)")
            tab("Hub")
            shot("06-hub-\(suffix)")
            app.swipeUp()
            shot("07-hub-more-\(suffix)")
            let settings = app.buttons["Settings"]
            if settings.waitForExistence(timeout: 5) {
                settings.tap()
                sleep(1)
                shot("08-settings-\(suffix)")
            }
            app.terminate()
        }
    }
}
