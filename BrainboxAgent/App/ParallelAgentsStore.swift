import SwiftUI
import BrainboxCore

/// App-side home of parallel agent tasks: observable state for the Agent
/// Workspace, saved to disk so in-flight runs are followed again after a
/// relaunch (by polling their real status — never restarted blindly).
@MainActor
@Observable
final class ParallelAgentsStore {
    private(set) var tasks: [ParallelTask] = []
    var maxConcurrent: Int {
        didSet {
            engine.maxConcurrent = maxConcurrent
            defaults.set(maxConcurrent, forKey: "bb.parallel.max")
        }
    }

    @ObservationIgnored private let engine: ParallelRunEngine
    @ObservationIgnored private let cache: JSONFileCache<[ParallelTask]>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onTaskChange: ((ParallelTask) -> Void)?

    init(cacheURL: URL?, defaults: UserDefaults, client: @escaping () -> HermesAPIClient?) {
        self.defaults = defaults
        cache = cacheURL.map { JSONFileCache<[ParallelTask]>(url: $0) }
        let saved = cache?.load() ?? []
        let limit = (defaults.object(forKey: "bb.parallel.max") as? Int) ?? 3
        maxConcurrent = limit
        engine = ParallelRunEngine(tasks: saved, maxConcurrent: limit, client: client)
        tasks = saved
        engine.onChange = { [weak self] task in self?.changed(task) }
    }

    private func changed(_ task: ParallelTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.insert(task, at: 0) }
        onTaskChange?(task)
        scheduleSave()
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Output streams in token by token; write to disk at most once a second.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            self.cache?.store(Array(self.tasks.prefix(50)))
            self.saveTask = nil
        }
    }

    var active: [ParallelTask] { tasks.filter { !$0.isFinished } }
    var finished: [ParallelTask] { tasks.filter(\.isFinished) }
    func task(_ id: UUID) -> ParallelTask? { tasks.first { $0.id == id } }

    @discardableResult
    func start(title: String, prompts: [(title: String, prompt: String, instructions: String?, model: String?)], synthesize: Bool,
               origin: UUID? = nil) -> ParallelTask {
        engine.start(title: title, prompts: prompts, synthesize: synthesize, originConversationID: origin)
    }

    func cancel(agent: UUID, in task: UUID) { engine.cancel(agent: agent, in: task) }
    func cancelAll(in task: UUID) { engine.cancelAll(in: task) }
    func retry(agent: UUID, in task: UUID) { engine.retry(agent: agent, in: task) }
    func resume() { engine.resumeAfterRelaunch() }

    func remove(_ id: UUID) {
        engine.remove(id)
        tasks.removeAll { $0.id == id && $0.isFinished }
        cache?.store(tasks)
    }
}
