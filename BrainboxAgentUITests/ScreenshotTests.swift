import XCTest

/// Captures the main screens in light and dark mode (mock backend, so no real
/// data appears). Screenshots are exported by CI as the `ui-screenshots` artifact.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launch(_ appearance: XCUIDevice.Appearance) {
        XCUIDevice.shared.appearance = appearance
        app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tapTab(_ id: String) {
        let tab = app.buttons[id]
        if !tab.waitForExistence(timeout: 5), app.keyboards.count > 0 { app.swipeDown() }
        guard tab.waitForExistence(timeout: 5) else { return XCTFail("\(id) not visible") }
        tab.tap()
        sleep(1)
    }

    private func capture(_ suffix: String) {
        XCTAssertTrue(app.buttons["tab.home"].waitForExistence(timeout: 10))
        app.buttons["tab.home"].tap()
        _ = app.descendants(matching: .any)["home.bot"].waitForExistence(timeout: 5)
        shot("01-home-\(suffix)")

        app.buttons["tab.agent"].tap()
        if app.buttons["suggestion.0"].waitForExistence(timeout: 5) { shot("02-chat-empty-\(suffix)") ; app.buttons["suggestion.0"].tap() }
        _ = app.descendants(matching: .any)["assistant.complete"].firstMatch.waitForExistence(timeout: 20)
        shot("03-chat-reply-\(suffix)")
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        if field.waitForExistence(timeout: 3) {
            field.tap()
            field.typeText("/st")
            shot("04-chat-commands-\(suffix)")
            // Clear the draft and dismiss the keyboard (the tab bar hides while it's up).
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
            app.scrollViews.firstMatch.swipeDown()
            if app.keyboards.count > 0 { app.swipeDown() }
        }

        tapTab("tab.team")
        shot("05-workspace-\(suffix)")
        tapTab("tab.tasks")
        shot("06-tasks-\(suffix)")
        tapTab("tab.vps")
        sleep(1)
        shot("07-server-\(suffix)")
        tapTab("tab.home")
        if app.buttons["home.settings"].waitForExistence(timeout: 5) {
            app.buttons["home.settings"].tap()
            sleep(1)
            shot("08-settings-\(suffix)")
        }
    }

    func testScreenshotsLight() {
        launch(.light)
        capture("light")
    }

    func testScreenshotsDark() {
        launch(.dark)
        capture("dark")
        XCUIDevice.shared.appearance = .light
    }
}
