import Foundation

/// The published SDK version. Kept in sync with the release tag by scripts/check-sdk-versions.mjs.
public let relaySDKVersion = "1.7.0"

/// A task lifecycle event from the server.
public enum TaskEventType: String, Sendable, CaseIterable {
    case offered = "TASK_OFFERED"
    case assigned = "TASK_ASSIGNED"
    case inProgress = "TASK_IN_PROGRESS"
    case stageCompleted = "STAGE_COMPLETED"
    case completed = "TASK_COMPLETED"
    case failed = "TASK_FAILED"
    case cancelled = "TASK_CANCELLED"

    /// The task status this event moves the task to, if it changes status.
    public var status: TaskStatus? {
        switch self {
        case .offered: return .offered
        case .assigned: return .assigned
        case .inProgress: return .inProgress
        case .stageCompleted: return nil
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }
}

public enum TaskStatus: String, Sendable, Codable {
    case pending = "PENDING"
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

/// One task lifecycle event. Fields the server didn't send are nil.
public struct TaskEvent: Sendable, Decodable, Equatable {
    public let type: TaskEventType
    public let taskId: String
    public let status: TaskStatus?
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
    /// When it happened (ISO 8601), from whichever timestamp the event carries.
    public let at: String?

    enum CodingKeys: String, CodingKey {
        case type, taskId, status, riderId, developerId, currentStageIndex, stageIndex, nextStageIndex, reason
        case cancelledBy, deliveryFee, completionCodeVerified, timestamp, assignedAt, startedAt, completedAt
        case failedAt, cancelledAt, offeredAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = TaskEventType(rawValue: try c.decode(String.self, forKey: .type)) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "not a task event")
        }
        self.type = type
        taskId = try c.decode(String.self, forKey: .taskId)
        status = try? c.decodeIfPresent(TaskStatus.self, forKey: .status)
        riderId = try? c.decodeIfPresent(String.self, forKey: .riderId)
        developerId = try? c.decodeIfPresent(String.self, forKey: .developerId)
        currentStageIndex = try? c.decodeIfPresent(Int.self, forKey: .currentStageIndex)
        stageIndex = try? c.decodeIfPresent(Int.self, forKey: .stageIndex)
        nextStageIndex = try? c.decodeIfPresent(Int.self, forKey: .nextStageIndex)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        cancelledBy = try? c.decodeIfPresent(String.self, forKey: .cancelledBy)
        deliveryFee = try? c.decodeIfPresent(Int.self, forKey: .deliveryFee)
        completionCodeVerified = try? c.decodeIfPresent(Bool.self, forKey: .completionCodeVerified)
        let timestamps: [CodingKeys] = [.timestamp, .completedAt, .cancelledAt, .failedAt, .assignedAt, .startedAt, .offeredAt]
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
    /// When the rider reported this (ISO 8601). `eta.seconds` counts down from here.
    public let timestamp: String?
    /// True when the server replayed the last known position on subscribe.
    public let replayed: Bool?

    enum CodingKeys: String, CodingKey { case taskId, riderId, location, eta, timestamp, replayed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try c.decode(String.self, forKey: .taskId)
        riderId = try? c.decodeIfPresent(String.self, forKey: .riderId)
        location = try c.decode(RiderLocation.self, forKey: .location)
        // A malformed ETA is dropped rather than losing the position.
        eta = try? c.decodeIfPresent(RiderRouteEta.self, forKey: .eta)
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
