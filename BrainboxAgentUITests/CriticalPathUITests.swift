import XCTest

/// Critical user journeys, run against the in-app mock providers
/// (`-uitesting` launches with fast mocks, no biometrics, throwaway storage).
final class CriticalPathUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()
    }

    func testChatWithMockAgentStreamsAReply() throws {
        let tab = app.buttons["tab.agent"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()

        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("check server status")
        app.buttons["composer.send"].tap()

        let done = app.descendants(matching: .any)["assistant.complete"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 20), "The mock agent's streamed reply should complete")
        let summary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "looks healthy")).firstMatch
        XCTAssertTrue(summary.exists, "Streamed markdown should be rendered")
    }

    func testSuggestionStartsAConversation() throws {
        app.buttons["tab.agent"].tap()
        let suggestion = app.buttons["suggestion.0"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        suggestion.tap()
        let done = app.descendants(matching: .any)["assistant.complete"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 20))
    }

    func testEveryTabOpens() throws {
        for (tab, marker) in [("tab.home", "Brainbox Agent"), ("tab.vps", "Services"), ("tab.files", "Files"), ("tab.settings", "Settings")] {
            let button = app.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(tab) missing")
            button.tap()
            let label = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", marker)).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 8), "\(tab) did not show \(marker)")
        }
    }

    func testTerminalRunsMockCommand() throws {
        app.buttons["tab.vps"].tap()
        let terminal = app.buttons["vps.terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 8))
        terminal.tap()
        let input = app.textFields["terminal.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap()
        input.typeText("uname -a\n")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "GNU/Linux")).firstMatch.waitForExistence(timeout: 8))
    }

    func testOpenConfigFileInEditor() throws {
        app.buttons["tab.files"].tap()
        let root = app.descendants(matching: .any)["file.brainbox./etc/brainbox"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        root.tap()
        let file = app.descendants(matching: .any)["file.gateway.yaml./etc/brainbox/gateway.yaml"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 8))
        file.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "yaml")).firstMatch.waitForExistence(timeout: 8))
    }
}
