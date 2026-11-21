import ActivityKit
import SwiftUI
import WidgetKit

@main
struct BrainboxWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickActionsWidget()
        HermesLiveActivity()
    }
}

private let volt = Color(red: 0.36, green: 0.30, blue: 0.96)

// MARK: - Home screen: quick actions

struct QuickEntry: TimelineEntry { let date: Date }

struct QuickProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickEntry { QuickEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (QuickEntry) -> Void) { completion(QuickEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickEntry>) -> Void) {
        completion(Timeline(entries: [QuickEntry(date: Date())], policy: .never))
    }
}

struct QuickActionsView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        if family == .systemSmall {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(volt)
                Spacer()
                Text("Ask Hermes").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("Tap to start a chat").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(URL(string: "brainbox://new"))
        } else {
            HStack(spacing: 12) {
                action("New chat", "square.and.pencil", "brainbox://new")
                action("Talk", "waveform", "brainbox://voice")
                action("Sessions", "clock.arrow.circlepath", "brainbox://chat/")
            }
        }
    }

    private func action(_ title: String, _ symbol: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(volt)
                    .frame(width: 52, height: 52).background(volt.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct QuickActionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BrainboxQuickActions", provider: QuickProvider()) { _ in
            QuickActionsView().containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Hermes")
        .description("Start a chat or talk to Hermes.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Live Activity: a turn in progress

struct HermesLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.done ? "checkmark.circle.fill" : "sparkles")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(context.state.done ? .green : volt)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(context.state.status).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    if !context.state.detail.isEmpty {
                        Text(context.state.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(16)
            .widgetURL(URL(string: "brainbox://chat/\(context.attributes.chat)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.done ? "checkmark.circle.fill" : "sparkles").foregroundStyle(context.state.done ? .green : volt)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.status).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: "sparkles").foregroundStyle(volt)
            } compactTrailing: {
                Text(context.state.done ? "Done" : "…").font(.system(size: 12, weight: .semibold))
            } minimal: {
                Image(systemName: context.state.done ? "checkmark" : "sparkles").foregroundStyle(volt)
            }
            .widgetURL(URL(string: "brainbox://chat/\(context.attributes.chat)"))
        }
    }
}
