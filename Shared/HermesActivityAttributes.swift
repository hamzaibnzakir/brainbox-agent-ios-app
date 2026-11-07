import ActivityKit
import Foundation

/// Live Activity for a Hermes turn in progress (lock screen + Dynamic Island).
/// Shared by the app (which starts/updates it) and the widget extension (which draws it).
struct HermesActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var detail: String
        var done: Bool
    }

    var chat: String
    var title: String
}
