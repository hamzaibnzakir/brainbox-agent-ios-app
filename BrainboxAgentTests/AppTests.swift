import BrainboxCore
import HermesKit
import XCTest
@testable import BrainboxAgent

final class AppTests: XCTestCase {
    func testMessagingSessionsAreReadOnly() {
        let telegram = SessionSummary(["id": "1", "title": "x", "source": "telegram", "started_at": 1])
        let mine = SessionSummary(["id": "2", "title": "y", "source": "tui", "started_at": 1])
        XCTAssertEqual(telegram?.isReadOnly, true, "Brainbox never writes to Telegram history")
        XCTAssertEqual(mine?.isReadOnly, false)
        XCTAssertEqual(SessionSummary(["id": "3", "preview": "hello", "source": "tui"])?.displayTitle, "hello")
    }

    func testFindsSpeechAudioInHermesResponses() {
        let audio = Data("abc".utf8).base64EncodedString()
        XCTAssertEqual(Voice.findAudio(["data_url": .string("data:audio/mpeg;base64," + audio)]), Data("abc".utf8))
        XCTAssertEqual(Voice.findAudio(["result": ["audio": .string("data:audio/wav;base64," + audio)]]), Data("abc".utf8))
        XCTAssertNil(Voice.findAudio(["ok": true]))
    }

    func testPersonalityNamesParse() {
        let msg = "Unknown personality: `x`.\n\nAvailable: `none`, `concise`, `pirate`"
        XCTAssertEqual(SoulScreen.names(in: msg), ["none", "concise", "pirate"])
    }

    func testPreferencesRoundTrip() throws {
        var p = Preferences()
        p.theme = .dark
        p.textScale = 1.2
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }

    @MainActor
    func testDemoModeLoadsAChatWithAnApproval() {
        let model = AppModel()
        model.loadDemo()
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.transcripts["demo"]?.pendingRequests.count, 1)
        XCTAssertEqual(model.sessions.count, 3)
    }
}
