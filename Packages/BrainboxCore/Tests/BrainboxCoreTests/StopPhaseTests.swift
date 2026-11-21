import XCTest
@testable import BrainboxCore

final class StopPhaseTests: XCTestCase {
    func testReducerOnlySettlesStopOnBackendEvents() {
        var message = Message(role: .assistant, content: "", state: .streaming)
        ChatReducer.apply(.stopRequested, to: &message)
        XCTAssertEqual(message.stop, .requested)
        XCTAssertEqual(message.state, .streaming)
        ChatReducer.apply(.stopAcknowledged, to: &message)
        ChatReducer.apply(.stopRequested, to: &message)   // a second press doesn't regress the phase
        XCTAssertEqual(message.stop, .acknowledged)
        ChatReducer.apply(.failed(.cancelled), to: &message)
        XCTAssertEqual(message.state, .cancelled)
        XCTAssertNil(message.stop)

        var raced = Message(role: .assistant, content: "", state: .streaming)
        ChatReducer.apply(.stopRequested, to: &raced)
        ChatReducer.apply(.completed, to: &raced)
        XCTAssertEqual(raced.state, .complete)
        XCTAssertEqual(raced.stop, .finishedFirst)

        var failed = Message(role: .assistant, content: "", state: .streaming)
        ChatReducer.apply(.stopRequested, to: &failed)
        ChatReducer.apply(.stopUnconfirmed("no answer"), to: &failed)
        XCTAssertEqual(failed.stop, .unconfirmed("no answer"))
        XCTAssertFalse(failed.stop!.isPending)
        ChatReducer.apply(.stopRequested, to: &failed)
        XCTAssertEqual(failed.stop, .requested, "retry after an unconfirmed stop")
    }

    func testMapperTreatsStoppingAsAcknowledgement() {
        var mapper = HermesRunMapper(runID: "run_1")
        XCTAssertEqual(mapper.map(.stopping), [.stopAcknowledged])
        XCTAssertEqual(mapper.reconcile(HermesRunStatus(runID: "run_1", status: .stopping)), [.stopAcknowledged])
        XCTAssertEqual(mapper.map(.cancelled), [.failed(.cancelled)])
        XCTAssertEqual(mapper.map(.messageDelta("late")), [], "nothing after a terminal event")
    }

    func testSavedMessagesWithoutStopStillDecode() throws {
        let saved = try JSONEncoder().encode(Message(role: .assistant, content: "hi"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        json.removeValue(forKey: "stop")
        let decoded = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.stop)
    }
}
