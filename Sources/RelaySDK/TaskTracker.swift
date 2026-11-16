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

/// A pooled delivery's route: grouped with other deliveries at its final price, or going alone at
/// its maximum. From TASK_POOLING_GROUPED and TASK_POOLING_SOLO.
public struct TrackedPooling: Sendable, Equatable {
    public enum State: String, Sendable { case grouped = "GROUPED", solo = "SOLO" }
    public let state: State
    /// Most it can cost, in kobo.
    public let maxTotal: Int?
    /// What it costs once grouped, in kobo; nil while going alone (it pays `maxTotal`).
    public let finalTotal: Int?
    /// How many other deliveries share the route (never who they are).
    public let sharedWith: Int?
    public let plannedPickupAt: String?
    public let plannedDeliveryAt: String?
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
    /// When SendRelay stops looking for a rider (ISO 8601), for tasks that keep looking or are booked.
    /// Count down to this while `status` is `.searching`.
    public var searchExpiresAt: String?
    /// Pooled delivery only: its route and price, once grouped or sent alone.
    public var pooling: TrackedPooling?
    /// Pooled delivery only: stops the rider makes before this delivery's next one (0 when it is
    /// next). While above 0 there is no ETA and the position may be withheld: show the planned times.
    public var stopsBefore: Int?
    /// Errand only: the rider's open question, waiting for your answer; nil once it is answered,
    /// times out, or the task ends.
    public var approval: ErrandApproval?
    /// Lifecycle events, newest first (location updates excluded).
    public var events: [TaskEvent] = []
    public var finished = false
    public var error: String?

    public init(
        taskId: String,
        status: TaskStatus? = nil,
        currentStageIndex: Int? = nil,
        eta: TrackedEta? = nil,
        searchExpiresAt: String? = nil,
        stopsBefore: Int? = nil
    ) {
        self.stopsBefore = stopsBefore
        self.taskId = taskId
        self.status = status
        self.currentStageIndex = currentStageIndex
        self.eta = eta
        self.searchExpiresAt = searchExpiresAt
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
            if let deadline = e.searchExpiresAt { next.searchExpiresAt = deadline }
            // The ETA belongs to a stop; drop it once the task moves on or ends.
            if next.finished || (next.eta != nil && next.currentStageIndex != nil && next.eta?.stageIndex != next.currentStageIndex) {
                next.eta = nil
            }
            // The rider who cancelled is gone; their last position and ETA no longer apply.
            if e.type == .riderUnassigned {
                next.rider = nil
                next.riderId = nil
                next.eta = nil
            }
            if e.type == .poolingGrouped || e.type == .poolingSolo {
                let grouped = e.type == .poolingGrouped
                next.pooling = TrackedPooling(
                    state: grouped ? .grouped : .solo,
                    maxTotal: e.maxTotal,
                    finalTotal: grouped ? e.finalTotal : nil,
                    sharedWith: grouped ? e.sharedWith : nil,
                    plannedPickupAt: grouped ? e.plannedPickupAt : nil,
                    plannedDeliveryAt: grouped ? e.plannedDeliveryAt : nil
                )
                // A pooled delivery going alone is tracked like any other task from here.
                if !grouped { next.stopsBefore = nil }
            }
            if e.type == .approvalRequested, let approval = e.approval, approval.isPending {
                next.approval = approval
            } else if e.type == .approvalResolved, next.approval == nil || next.approval?.id == e.approval?.id {
                next.approval = nil
            }
            if next.finished { next.approval = nil }
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
            } else if let before = update.stopsBefore, before > 0 {
                // Pooled delivery: an ETA only while this delivery's stop is next.
                next.eta = nil
            }
            if let before = update.stopsBefore { next.stopsBefore = before }
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
