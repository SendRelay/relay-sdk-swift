import Foundation
#if canImport(Combine)
import Combine
#endif

/// The rider's ETA as an absolute arrival time. Same shape as `liveEta` on the server's task read.
public struct TrackedEta: Sendable, Equatable {
    public let stageIndex: Int
    /// Driving time left when the rider last reported, in seconds.
    public let seconds: Int
    /// Road distance left when the rider last reported, in metres.
    public let meters: Int
    /// When the rider is expected at the stop. Count down to this.
    public let arrivesAt: Date
    /// When the rider last reported this.
    public let updatedAt: Date

    public init(stageIndex: Int, seconds: Int, meters: Int, arrivesAt: Date, updatedAt: Date) {
        self.stageIndex = stageIndex
        self.seconds = seconds
        self.meters = meters
        self.arrivesAt = arrivesAt
        self.updatedAt = updatedAt
    }

    /// Seconds left from `now`, never below zero.
    public func secondsRemaining(now: Date = Date()) -> Int {
        max(0, Int(arrivesAt.timeIntervalSince(now).rounded()))
    }
}

public enum TrackerConnection: String, Sendable {
    case idle, connecting, live, reconnecting, offline
}

/// Everything known about one tracked task. Mirrors the web SDKs' tracker state.
public struct TaskTrackerState: Sendable, Equatable {
    public var taskId: String
    public var connection: TrackerConnection = .idle
    public var status: TaskStatus?
    public var currentStageIndex: Int?
    public var rider: RiderLocation?
    public var riderId: String?
    public var eta: TrackedEta?
    /// Lifecycle events, newest first (location updates excluded).
    public var events: [TaskEvent] = []
    public var finished = false
    public var error: String?

    public init(taskId: String, status: TaskStatus? = nil, currentStageIndex: Int? = nil, eta: TrackedEta? = nil) {
        self.taskId = taskId
        self.status = status
        self.currentStageIndex = currentStageIndex
        self.eta = eta
        self.finished = status?.isFinished ?? false
    }

    /// The state after an event. Events for other tasks change nothing.
    public func applying(_ event: RelayEvent, maxEvents: Int = 50) -> TaskTrackerState {
        var next = self
        switch event {
        case .task(let e):
            guard e.taskId == taskId else { return self }
            if let status = e.type.status { next.status = status }
            next.finished = next.status?.isFinished ?? false
            if let index = e.currentStageIndex ?? e.nextStageIndex { next.currentStageIndex = index }
            // The ETA belongs to a stop; drop it once the task moves on or ends.
            if next.finished || (next.eta != nil && next.currentStageIndex != nil && next.eta?.stageIndex != next.currentStageIndex) {
                next.eta = nil
            }
            next.events = Array(([e] + events).prefix(maxEvents))
        case .riderLocation(let update):
            guard update.taskId == taskId else { return self }
            next.connection = .live
            next.rider = update.location
            next.riderId = update.riderId ?? riderId
            if let eta = update.eta {
                let reported = update.timestamp.flatMap(parseISODate) ?? Date()
                next.eta = TrackedEta(
                    stageIndex: eta.stageIndex,
                    seconds: eta.seconds,
                    meters: eta.meters,
                    arrivesAt: reported.addingTimeInterval(TimeInterval(eta.seconds)),
                    updatedAt: reported
                )
            }
        case .connectionOpen:
            next.connection = .live
            next.error = nil
        case .reconnecting:
            next.connection = .reconnecting
        case .connectionClose:
            next.connection = finished ? .idle : .offline
        case .connectionError(let message):
            next.connection = .offline
            next.error = message
        }
        return next
    }
}

#if canImport(Combine)
/// An `ObservableObject` tracking one task, for SwiftUI.
///
/// ```swift
/// @StateObject var tracker = RelayTaskTracker(client: relay, taskId: order.relayTaskId)
/// var body: some View {
///     Text(tracker.state.status?.rawValue ?? "Finding a rider")
///         .task { await tracker.start() }
/// }
/// ```
@MainActor
public final class RelayTaskTracker: ObservableObject {
    @Published public private(set) var state: TaskTrackerState
    private let client: RelayRealtimeClient
    private var consumer: Task<Void, Never>?

    public init(client: RelayRealtimeClient, taskId: String, initial: TaskTrackerState? = nil) {
        self.client = client
        self.state = initial ?? TaskTrackerState(taskId: taskId)
    }

    /// Start listening. Safe to call more than once.
    public func start() async {
        guard consumer == nil else { return }
        let stream = client.events()
        consumer = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.state = self.state.applying(event)
            }
        }
        state.connection = .connecting
        do {
            try await client.listen(state.taskId)
            if state.connection == .connecting { state.connection = .live }
        } catch {
            state.connection = .offline
            state.error = error.localizedDescription
        }
    }

    /// Stop listening. The client stays connected for other tasks.
    public func stop() async {
        consumer?.cancel()
        consumer = nil
        await client.stopListening(state.taskId)
        state.connection = .idle
    }
}
#endif
