import Foundation

/// The published SDK version. Kept in sync with the release tag by scripts/check-sdk-versions.mjs.
public let relaySDKVersion = "1.13.0"

/// A task lifecycle event from the server.
public enum TaskEventType: String, Sendable, CaseIterable {
    /// A booked task's search opened: SendRelay is now looking for a rider.
    case dispatchStarted = "TASK_DISPATCH_STARTED"
    /// The task keeps looking for a rider after its first offers, until `searchExpiresAt`.
    case searching = "TASK_SEARCHING"
    /// A waiting manual task has eligible riders near its pickup (`ridersNearby`, a count only).
    case ridersNearby = "TASK_RIDERS_NEARBY"
    case offered = "TASK_OFFERED"
    case assigned = "TASK_ASSIGNED"
    case inProgress = "TASK_IN_PROGRESS"
    case stageCompleted = "STAGE_COMPLETED"
    /// The rider reached a stop (`stageIndex`, `stageType`), once per stop.
    case stageArrived = "STAGE_ARRIVED"
    /// The business edited notes, instructions or a stop's contact; read the task again.
    case detailsUpdated = "TASK_DETAILS_UPDATED"
    /// Opt-in (`onRiderCancel: FIND_ANOTHER`): the rider cancelled before pickup and SendRelay is
    /// finding another. The task is PENDING again.
    case riderUnassigned = "TASK_RIDER_UNASSIGNED"
    /// Pooled delivery: the rider started the shared route; `finalTotal` is the price (never above
    /// `maxTotal`). Comes after TASK_ASSIGNED.
    case poolingGrouped = "TASK_POOLING_GROUPED"
    /// Pooled delivery: it goes alone at `maxTotal` through ordinary dispatch; dispatch events follow.
    case poolingSolo = "TASK_POOLING_SOLO"
    /// Errand: a work stop did not get done (`stage.status` FAILED, `stage.reason` why). The task
    /// goes on at `nextStageIndex`, or ends when nothing is left to do.
    case stageFailed = "STAGE_FAILED"
    /// Errand: the rider asks you something (`approval`). Answer through the server API before
    /// `approval.expiresAt`.
    case approvalRequested = "APPROVAL_REQUESTED"
    /// Errand: a question was answered, timed out or withdrawn (`approval.status`).
    case approvalResolved = "APPROVAL_RESOLVED"
    case completed = "TASK_COMPLETED"
    case failed = "TASK_FAILED"
    case cancelled = "TASK_CANCELLED"

    /// The task status this event moves the task to, if it changes status.
    public var status: TaskStatus? {
        switch self {
        case .dispatchStarted: return .pending
        case .searching: return .searching
        case .ridersNearby: return nil
        case .offered: return .offered
        case .assigned: return .assigned
        case .inProgress: return .inProgress
        case .stageCompleted: return nil
        case .stageArrived: return nil
        case .detailsUpdated: return nil
        case .riderUnassigned: return .pending
        case .poolingGrouped: return nil
        case .poolingSolo: return nil
        case .stageFailed: return nil
        case .approvalRequested: return nil
        case .approvalResolved: return nil
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }
}

public enum TaskStatus: String, Sendable, Codable {
    /// Booked for a pickup time; SendRelay has not started looking yet.
    case scheduled = "SCHEDULED"
    case pending = "PENDING"
    /// Still looking for a rider after the first offers.
    case searching = "SEARCHING"
    case offered = "OFFERED"
    case assigned = "ASSIGNED"
    case inProgress = "IN_PROGRESS"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
    case paymentFailed = "PAYMENT_FAILED"

    /// True for COMPLETED, FAILED and CANCELLED.
    public var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }
}

/// STAGE_FAILED: the errand stop that did not get done.
public struct ErrandStageOutcome: Sendable, Decodable, Equatable {
    /// QUEUE, PURCHASE, PAYMENT, INSPECTION, CUSTOM (or a newer type).
    public let type: String
    /// Your name for the stop, if you gave one.
    public let reference: String?
    /// FAILED or SKIPPED (or a newer status).
    public let status: String
    /// OUT_OF_STOCK, CLOSED, REFUSED, NOT_READY, PAYMENT_FAILED, OTHER (or a newer reason).
    public let reason: String?
    /// What the rider wrote.
    public let note: String?
    /// When it ended (ISO 8601).
    public let endedAt: String?
}

/// APPROVAL_REQUESTED / APPROVAL_RESOLVED: a question from the rider on an errand. Answer it with
/// the server SDK (`tasks.decideApproval`); the full request, with what approving does to the price,
/// is on `tasks.approvals`.
public struct ErrandApproval: Sendable, Decodable, Equatable {
    public let id: String
    public let stageIndex: Int?
    /// SUBSTITUTE, PRICE_ABOVE_MAX, OVER_SPEND_LIMIT, MORE_TIME, QUESTION (or a newer kind).
    public let kind: String
    /// PENDING, APPROVED, DECLINED, EXPIRED (or a newer status).
    public let status: String
    /// The question in plain words, as the rider app shows it.
    public let question: String?
    /// A photo the rider attached (a file path; open it through the server API).
    public let photo: String?
    /// When the rider stops waiting (ISO 8601).
    public let expiresAt: String?
    /// The note sent with the answer.
    public let note: String?
    public let decidedAt: String?

    enum CodingKeys: String, CodingKey { case id, stageIndex, kind, status, question, photo, expiresAt, note, decidedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        status = try c.decode(String.self, forKey: .status)
        stageIndex = try? c.decodeIfPresent(Int.self, forKey: .stageIndex)
        question = try? c.decodeIfPresent(String.self, forKey: .question)
        photo = try? c.decodeIfPresent(String.self, forKey: .photo)
        expiresAt = try? c.decodeIfPresent(String.self, forKey: .expiresAt)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        decidedAt = try? c.decodeIfPresent(String.self, forKey: .decidedAt)
    }

    /// True while the rider is waiting for your answer.
    public var isPending: Bool { status == "PENDING" }
}

/// One task lifecycle event. Fields the server didn't send are nil.
public struct TaskEvent: Sendable, Decodable, Equatable {
    public let type: TaskEventType
    public let taskId: String
    /// Nil when the server sent no status, or one this SDK version does not know: SendRelay adds
    /// statuses over time, and `rawStatus` keeps whatever the server sent.
    public let status: TaskStatus?
    /// The status exactly as the server sent it, including ones newer than this SDK.
    public let rawStatus: String?
    public let riderId: String?
    public let developerId: String?
    public let currentStageIndex: Int?
    /// STAGE_COMPLETED: the stage that was completed, and the one the rider moves to next.
    public let stageIndex: Int?
    public let nextStageIndex: Int?
    /// TASK_FAILED / TASK_CANCELLED: why.
    public let reason: String?
    /// TASK_CANCELLED: `DEVELOPER` or `RIDER`.
    public let cancelledBy: String?
    public let deliveryFee: Int?
    /// TASK_COMPLETED for tasks created with a completion code.
    public let completionCodeVerified: Bool?
    /// TASK_SEARCHING: WAIT_FOR_RIDER or SCHEDULED (or a newer strategy).
    public let strategy: String?
    /// TASK_DISPATCH_STARTED: when the rider should reach the pickup (ISO 8601).
    public let pickupAt: String?
    /// TASK_DISPATCH_STARTED / TASK_SEARCHING: when SendRelay stops looking (ISO 8601).
    public let searchExpiresAt: String?
    /// TASK_RIDERS_NEARBY: how many eligible riders were found.
    public let ridersNearby: Int?
    /// STAGE_ARRIVED: PICKUP or DROPOFF (or, on an errand, the work stop's type). STAGE_FAILED: the
    /// failed stop's type.
    public let stageType: String?
    /// STAGE_FAILED: the stop that did not get done.
    public let stage: ErrandStageOutcome?
    /// STAGE_FAILED: how many stops the task has.
    public let totalStages: Int?
    /// APPROVAL_REQUESTED / APPROVAL_RESOLVED: the rider's question.
    public let approval: ErrandApproval?
    /// TASK_RIDER_UNASSIGNED: further rider cancels the task can survive before it ends CANCELLED.
    public let researchesLeft: Int?
    /// TASK_POOLING_*: the wave (for example MIDDAY) and its date (YYYY-MM-DD, Lagos).
    public let wave: String?
    public let waveDate: String?
    /// TASK_POOLING_GROUPED: how many other deliveries share the route (never who they are).
    public let sharedWith: Int?
    /// TASK_POOLING_*: the most it can cost, in kobo.
    public let maxTotal: Int?
    /// TASK_POOLING_GROUPED: what it costs, in kobo.
    public let finalTotal: Int?
    /// TASK_POOLING_GROUPED: the planned pickup and delivery times (ISO 8601).
    public let plannedPickupAt: String?
    public let plannedDeliveryAt: String?
    /// When it happened (ISO 8601), from whichever timestamp the event carries.
    public let at: String?
    /// The task's revision after this event, as on webhooks and task reads; nil when the frame has
    /// none (older servers). The client drops a frame at or below the last revision it delivered for
    /// the task, so events arrive in order and once.
    public let revision: Int?

    enum CodingKeys: String, CodingKey {
        case type, taskId, status, riderId, developerId, currentStageIndex, stageIndex, nextStageIndex, reason
        case cancelledBy, deliveryFee, completionCodeVerified, timestamp, assignedAt, startedAt, completedAt
        case failedAt, cancelledAt, offeredAt, strategy, pickupAt, searchExpiresAt, ridersNearby, searchingAt, detectedAt
        case stageType, arrivedAt, researchesLeft, revision
        case window, sharedWith, maxTotal, finalTotal, plannedPickupAt, plannedDeliveryAt, groupedAt, soloAt
        case stage, totalStages, approval
    }

    private struct PooledWindow: Decodable {
        let wave: String?
        let date: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = TaskEventType(rawValue: try c.decode(String.self, forKey: .type)) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "not a task event")
        }
        self.type = type
        taskId = try c.decode(String.self, forKey: .taskId)
        rawStatus = try? c.decodeIfPresent(String.self, forKey: .status)
        status = rawStatus.flatMap(TaskStatus.init(rawValue:))
        riderId = try? c.decodeIfPresent(String.self, forKey: .riderId)
        developerId = try? c.decodeIfPresent(String.self, forKey: .developerId)
        currentStageIndex = try? c.decodeIfPresent(Int.self, forKey: .currentStageIndex)
        stageIndex = try? c.decodeIfPresent(Int.self, forKey: .stageIndex)
        nextStageIndex = try? c.decodeIfPresent(Int.self, forKey: .nextStageIndex)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        cancelledBy = try? c.decodeIfPresent(String.self, forKey: .cancelledBy)
        deliveryFee = try? c.decodeIfPresent(Int.self, forKey: .deliveryFee)
        completionCodeVerified = try? c.decodeIfPresent(Bool.self, forKey: .completionCodeVerified)
        strategy = try? c.decodeIfPresent(String.self, forKey: .strategy)
        pickupAt = try? c.decodeIfPresent(String.self, forKey: .pickupAt)
        searchExpiresAt = try? c.decodeIfPresent(String.self, forKey: .searchExpiresAt)
        ridersNearby = try? c.decodeIfPresent(Int.self, forKey: .ridersNearby)
        // A malformed stage or approval is dropped rather than losing the event.
        stage = try? c.decodeIfPresent(ErrandStageOutcome.self, forKey: .stage)
        totalStages = try? c.decodeIfPresent(Int.self, forKey: .totalStages)
        approval = try? c.decodeIfPresent(ErrandApproval.self, forKey: .approval)
        stageType = (try? c.decodeIfPresent(String.self, forKey: .stageType)) ?? stage?.type
        researchesLeft = try? c.decodeIfPresent(Int.self, forKey: .researchesLeft)
        revision = try? c.decodeIfPresent(Int.self, forKey: .revision)
        let window = try? c.decodeIfPresent(PooledWindow.self, forKey: .window)
        wave = window?.wave
        waveDate = window?.date
        sharedWith = try? c.decodeIfPresent(Int.self, forKey: .sharedWith)
        maxTotal = try? c.decodeIfPresent(Int.self, forKey: .maxTotal)
        finalTotal = try? c.decodeIfPresent(Int.self, forKey: .finalTotal)
        plannedPickupAt = try? c.decodeIfPresent(String.self, forKey: .plannedPickupAt)
        plannedDeliveryAt = try? c.decodeIfPresent(String.self, forKey: .plannedDeliveryAt)
        let timestamps: [CodingKeys] = [
            .timestamp, .completedAt, .cancelledAt, .failedAt, .assignedAt, .startedAt, .searchingAt, .detectedAt, .offeredAt,
            .arrivedAt, .groupedAt, .soloAt,
        ]
        at = timestamps.lazy.compactMap { try? c.decodeIfPresent(String.self, forKey: $0) }.first
    }
}

public struct RiderLocation: Sendable, Decodable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let bearing: Double?
    public let heading: Double?
    /// Metres per second.
    public let speed: Double?
    /// Metres.
    public let accuracy: Double?
}

/// The rider's remaining time and road distance to a stop, as of a location update.
public struct RiderRouteEta: Sendable, Decodable, Equatable {
    /// Index of the stage the rider is heading to.
    public let stageIndex: Int
    /// Driving time left when the rider reported, in seconds.
    public let seconds: Int
    /// Road distance left, in metres.
    public let meters: Int

    enum CodingKeys: String, CodingKey { case stageIndex, seconds, meters }

    public init(stageIndex: Int, seconds: Int, meters: Int) {
        self.stageIndex = stageIndex
        self.seconds = seconds
        self.meters = meters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stageIndex = try c.decode(Int.self, forKey: .stageIndex)
        seconds = Int(try c.decode(Double.self, forKey: .seconds).rounded())
        meters = Int(try c.decode(Double.self, forKey: .meters).rounded())
    }
}

public struct RiderLocationUpdate: Sendable, Decodable, Equatable {
    public let taskId: String
    public let riderId: String?
    public let location: RiderLocation
    /// The rider's ETA to their next stop, from their navigation route and live traffic. Nil when
    /// the rider's app hasn't reported one.
    public let eta: RiderRouteEta?
    /// Pooled delivery: stops the rider makes before this delivery's next one; 0 when it is next
    /// (the update then has an `eta`). Nil on every other task.
    public let stopsBefore: Int?
    /// When the rider reported this (ISO 8601). `eta.seconds` counts down from here.
    public let timestamp: String?
    /// True when the server replayed the last known position on subscribe.
    public let replayed: Bool?

    enum CodingKeys: String, CodingKey { case taskId, riderId, location, eta, stopsBefore, timestamp, replayed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try c.decode(String.self, forKey: .taskId)
        riderId = try? c.decodeIfPresent(String.self, forKey: .riderId)
        location = try c.decode(RiderLocation.self, forKey: .location)
        // A malformed ETA is dropped rather than losing the position.
        eta = try? c.decodeIfPresent(RiderRouteEta.self, forKey: .eta)
        stopsBefore = try? c.decodeIfPresent(Int.self, forKey: .stopsBefore)
        timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
        replayed = try? c.decodeIfPresent(Bool.self, forKey: .replayed)
    }

    /// When the rider is expected at the stop, or nil without an ETA.
    public var arrivesAt: Date? {
        guard let eta else { return nil }
        let reported = timestamp.flatMap(parseISODate) ?? Date()
        return reported.addingTimeInterval(TimeInterval(eta.seconds))
    }
}

/// Everything the realtime client tells you about.
public enum RelayEvent: Sendable {
    case task(TaskEvent)
    case riderLocation(RiderLocationUpdate)
    case connectionOpen
    case connectionClose(code: Int?, reason: String?)
    case connectionError(String)
    case reconnecting(attempt: Int, delay: TimeInterval)

    /// The server's event name, for task and location events.
    public var name: String? {
        switch self {
        case .task(let event): return event.type.rawValue
        case .riderLocation: return "RIDER_LOCATION_UPDATE"
        case .connectionOpen: return "CONNECTION_OPEN"
        case .connectionClose: return "CONNECTION_CLOSE"
        case .connectionError: return "CONNECTION_ERROR"
        case .reconnecting: return "CONNECTION_RECONNECTING"
        }
    }
}

public enum RelayError: Error, LocalizedError, Equatable {
    case invalidURL(String)
    case tokenExpired
    case notConnected
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let detail): return "Invalid realtime URL: \(detail)"
        case .tokenExpired:
            return "getToken returned an expired token. Make sure your backend issues a fresh one."
        case .notConnected: return "The realtime connection isn't open."
        case .connectionFailed(let detail): return "Realtime connection failed: \(detail)"
        }
    }
}

func parseISODate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}
