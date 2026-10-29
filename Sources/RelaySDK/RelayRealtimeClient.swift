import Foundation

/// How the client reconnects after the socket drops.
public struct ReconnectOptions: Sendable {
    public var enabled = true
    public var initialDelay: TimeInterval = 1
    public var maxDelay: TimeInterval = 30
    public var backoffMultiplier: Double = 1.5
    public init() {}
}

/// How often the client checks the socket is alive.
public struct HeartbeatOptions: Sendable {
    public var enabled = true
    public var interval: TimeInterval = 30
    /// Reconnect when no pong arrives within this long after a ping.
    public var timeout: TimeInterval = 10
    public init() {}
}

public struct RelayClientOptions: Sendable {
    /// Realtime URL. Point it at a local API during development.
    public var url = RelayProtocol.defaultURL
    /// Device ID sent on connect. Defaults to one generated per install and kept in UserDefaults.
    public var deviceId: String?
    public var reconnect = ReconnectOptions()
    public var heartbeat = HeartbeatOptions()
    /// Fetch a fresh token this long before the current one expires.
    public var tokenRefreshBeforeExpiry: TimeInterval = 300
    public init() {}
}

/// Tracks tasks live over Relay's realtime socket.
///
/// Your server mints a short-lived token (`relay.auth.createWebSocketToken` in the server SDKs);
/// the client asks for one through `getToken` whenever it connects.
///
/// ```swift
/// let relay = RelayRealtimeClient { taskIds in try await api.trackingToken(for: taskIds) }
/// Task {
///     for await event in relay.events() {
///         if case .riderLocation(let update) = event { map.move(to: update.location) }
///     }
/// }
/// try await relay.listen(taskId)
/// ```
public actor RelayRealtimeClient {
    public typealias TokenProvider = @Sendable ([String]) async throws -> String

    public nonisolated let options: RelayClientOptions
    private let getToken: TokenProvider
    private let session: URLSession
    private let broadcaster = Broadcaster()
    private let deviceId: String

    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var listening: [String] = []
    private var intentionalClose = false
    private var reconnectAttempt = 0
    private var lastPongAt = Date()
    private var background: [Task<Void, Never>] = []

    public init(options: RelayClientOptions = RelayClientOptions(), session: URLSession = .shared, getToken: @escaping TokenProvider) {
        self.options = options
        self.getToken = getToken
        self.session = session
        self.deviceId = options.deviceId?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? RelayRealtimeClient.installDeviceId()
    }

    /// A stream of every event from now on. Each call returns its own stream; stop iterating to
    /// unsubscribe.
    public nonisolated func events() -> AsyncStream<RelayEvent> {
        broadcaster.stream()
    }

    public var isConnected: Bool { socket?.state == .running }
    public var listeningTo: [String] { listening }

    /// Start receiving events for a task. Connects (asking `getToken`) if needed.
    public func listen(_ taskId: String) async throws {
        if !listening.contains(taskId) { listening.append(taskId) }
        if isConnected {
            try await send(RelayProtocol.subscribe(taskId: taskId))
        } else {
            try await connect()
        }
    }

    /// Stop receiving events for a task. The socket stays open for other tasks.
    public func stopListening(_ taskId: String) async {
        listening.removeAll { $0 == taskId }
        if isConnected { try? await send(RelayProtocol.unsubscribe(taskId: taskId)) }
    }

    /// Open the socket and subscribe to every task being listened to.
    public func connect() async throws {
        intentionalClose = false
        let token = try await validToken()
        let url = try RelayProtocol.webSocketURL(baseURL: options.url, token: token, deviceId: deviceId)
        teardown()
        generation += 1
        let current = generation
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                task.sendPing { error in error.map { done.resume(throwing: $0) } ?? done.resume() }
            }
        } catch {
            socket = nil
            broadcaster.emit(.connectionError(error.localizedDescription))
            throw RelayError.connectionFailed(error.localizedDescription)
        }
        reconnectAttempt = 0
        lastPongAt = Date()
        broadcaster.emit(.connectionOpen)
        background = [
            Task { [weak self] in await self?.receiveLoop(task, generation: current) },
            Task { [weak self] in await self?.heartbeatLoop(generation: current) },
            Task { [weak self] in await self?.refreshLoop(token: token, generation: current) },
        ]
        for taskId in listening {
            try? await send(RelayProtocol.subscribe(taskId: taskId))
        }
    }

    /// Close the socket and stop reconnecting.
    public func disconnect() {
        intentionalClose = true
        teardown()
        broadcaster.emit(.connectionClose(code: 1000, reason: "client disconnect"))
    }

    // MARK: - Internals

    private func teardown() {
        background.forEach { $0.cancel() }
        background = []
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func send(_ message: [String: String]) async throws {
        guard let socket else { throw RelayError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func validToken() async throws -> String {
        var token = try await getToken(listening)
        if let left = RelayProtocol.secondsUntilExpiry(of: token), left <= 0 {
            token = try await getToken(listening)
            if let left = RelayProtocol.secondsUntilExpiry(of: token), left <= 0 { throw RelayError.tokenExpired }
        }
        return token
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, generation current: Int) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                await socketDropped(generation: current, code: task.closeCode.rawValue, reason: error.localizedDescription)
                return
            }
            let data: Data
            switch message {
            case .data(let bytes): data = bytes
            case .string(let text): data = Data(text.utf8)
            @unknown default: continue
            }
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["type"] as? String == "pong" {
                lastPongAt = Date()
                continue
            }
            if let event = RelayProtocol.parse(data) { broadcaster.emit(event) }
        }
    }

    private func heartbeatLoop(generation current: Int) async {
        guard options.heartbeat.enabled else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(options.heartbeat.interval * 1_000_000_000))
            guard !Task.isCancelled, current == generation else { return }
            let sentAt = Date()
            try? await send(RelayProtocol.ping)
            try? await Task.sleep(nanoseconds: UInt64(options.heartbeat.timeout * 1_000_000_000))
            guard !Task.isCancelled, current == generation else { return }
            if lastPongAt < sentAt {
                await socketDropped(generation: current, code: nil, reason: "heartbeat timeout")
                return
            }
        }
    }

    private func refreshLoop(token: String, generation current: Int) async {
        guard let left = RelayProtocol.secondsUntilExpiry(of: token) else { return }
        let wait = max(0, left - options.tokenRefreshBeforeExpiry)
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        guard !Task.isCancelled, current == generation, !intentionalClose else { return }
        try? await connect()
    }

    private func socketDropped(generation current: Int, code: Int?, reason: String) async {
        guard current == generation, !intentionalClose else { return }
        socket = nil
        broadcaster.emit(.connectionClose(code: code, reason: reason))
        guard options.reconnect.enabled else { return }
        while !intentionalClose, current == generation {
            let r = options.reconnect
            let base = min(r.initialDelay * pow(r.backoffMultiplier, Double(reconnectAttempt)), r.maxDelay)
            // ±25% jitter so many clients don't reconnect in lockstep.
            let delay = max(0, base + base * 0.25 * Double.random(in: -1...1))
            reconnectAttempt += 1
            broadcaster.emit(.reconnecting(attempt: reconnectAttempt, delay: delay))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !intentionalClose, current == generation else { return }
            if (try? await connect()) != nil { return }
        }
    }

    private static func installDeviceId() -> String {
        let key = "relay.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = "ios-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

/// Fans events out to every `events()` stream. Thread-safe.
final class Broadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RelayEvent>.Continuation] = [:]

    func stream() -> AsyncStream<RelayEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    func emit(_ event: RelayEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(event) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
