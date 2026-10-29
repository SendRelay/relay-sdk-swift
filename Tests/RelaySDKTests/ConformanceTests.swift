// Runs the shared realtime conformance fixtures (packages/sdks/conformance) against this SDK.
// Every Relay UI SDK runs the same fixtures, which is how they stay at parity.
import Foundation
import XCTest
@testable import RelaySDK

private let conformanceDir: URL = {
    if let dir = ProcessInfo.processInfo.environment["RELAY_CONFORMANCE_DIR"] { return URL(fileURLWithPath: dir) }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../conformance").standardized
}()

private func read(_ name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: conformanceDir.appendingPathComponent(name))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The event under the API's field names, so fixture paths apply to typed events.
private func apiJSON(_ event: RelayEvent) -> [String: Any] {
    switch event {
    case .task(let e):
        var out: [String: Any] = ["taskId": e.taskId]
        out["status"] = e.status?.rawValue
        out["riderId"] = e.riderId
        out["stageIndex"] = e.stageIndex
        out["reason"] = e.reason
        out["cancelledBy"] = e.cancelledBy
        return out
    case .riderLocation(let u):
        var out: [String: Any] = [
            "taskId": u.taskId,
            "location": ["latitude": u.location.latitude, "longitude": u.location.longitude],
        ]
        out["riderId"] = u.riderId
        out["timestamp"] = u.timestamp
        if let eta = u.eta { out["eta"] = ["stageIndex": eta.stageIndex, "seconds": eta.seconds, "meters": eta.meters] }
        return out
    default:
        return [:]
    }
}

private func lookup(_ value: Any?, _ dotted: String) -> Any? {
    dotted.split(separator: ".").reduce(value) { node, key in (node as? [String: Any])?[String(key)] }
}

private func same(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil), (nil, is NSNull), (is NSNull, nil): return true
    case let (x as NSNumber, y as NSNumber): return x.doubleValue == y.doubleValue
    case let (x as String, y as String): return x == y
    default: return false
    }
}

final class ConformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: conformanceDir.appendingPathComponent("manifest.json").path),
            "conformance folder not found"
        )
    }

    func testFrames() throws {
        let cases = try XCTUnwrap(read("realtime/frames.json")["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 5)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let frame = try JSONSerialization.data(withJSONObject: c["frame"]!)
            let expect = c["expect"] as! [String: Any]
            let event = RelayProtocol.parse(frame)
            guard let wanted = expect["event"] as? String else {
                XCTAssertNil(event, name)
                continue
            }
            let parsed = try XCTUnwrap(event, name)
            XCTAssertEqual(parsed.name, wanted, name)
            let json = apiJSON(parsed)
            for (key, want) in expect["fields"] as? [String: Any] ?? [:] {
                XCTAssertTrue(same(lookup(json, key), want), "\(name): \(key) = \(String(describing: lookup(json, key))), want \(want)")
            }
        }
    }

    func testURLs() throws {
        let fixture = try read("realtime/url.json")
        for c in fixture["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let url = try RelayProtocol.webSocketURL(
                baseURL: c["baseUrl"] as! String,
                token: c["token"] as! String,
                deviceId: c["deviceId"] as? String
            )
            let want = c["expect"] as! [String: Any]
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.scheme, want["scheme"] as? String, name)
            XCTAssertEqual(parts.host, want["host"] as? String, name)
            XCTAssertEqual(parts.port, want["port"] as? Int, name)
            XCTAssertEqual(parts.path, want["path"] as? String, name)
            let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, want["query"] as? [String: String], name)
        }
    }

    func testDefaults() throws {
        let d = try read("realtime/url.json")["defaults"] as! [String: Any]
        let options = RelayClientOptions()
        let reconnect = d["reconnect"] as! [String: Any]
        let heartbeat = d["heartbeat"] as! [String: Any]
        XCTAssertEqual(options.url, d["url"] as? String)
        XCTAssertEqual(options.reconnect.enabled, reconnect["enabled"] as? Bool)
        XCTAssertEqual(options.reconnect.initialDelay * 1000, reconnect["initialDelayMs"] as? Double)
        XCTAssertEqual(options.reconnect.maxDelay * 1000, reconnect["maxDelayMs"] as? Double)
        XCTAssertEqual(options.reconnect.backoffMultiplier, reconnect["backoffMultiplier"] as? Double)
        XCTAssertEqual(options.heartbeat.enabled, heartbeat["enabled"] as? Bool)
        XCTAssertEqual(options.heartbeat.interval * 1000, heartbeat["intervalMs"] as? Double)
        XCTAssertEqual(options.heartbeat.timeout * 1000, heartbeat["timeoutMs"] as? Double)
        XCTAssertEqual(options.tokenRefreshBeforeExpiry * 1000, d["tokenRefreshBeforeExpiryMs"] as? Double)
    }

    func testOutgoingMessages() throws {
        let messages = try read("realtime/outgoing.json")["messages"] as! [String: [String: String]]
        let fill = { (m: [String: String]) in m.mapValues { $0 == "<taskId>" ? "task-1" : $0 } }
        XCTAssertEqual(RelayProtocol.subscribe(taskId: "task-1"), fill(messages["subscribe"]!))
        XCTAssertEqual(RelayProtocol.unsubscribe(taskId: "task-1"), fill(messages["unsubscribe"]!))
        XCTAssertEqual(RelayProtocol.ping, messages["ping"]!)
    }
}

final class TaskTrackerStateTests: XCTestCase {
    private func event(_ json: String) -> RelayEvent { RelayProtocol.parse(Data(json.utf8))! }

    func testFollowsADelivery() {
        var state = TaskTrackerState(taskId: "t1")
        state = state.applying(event(#"{"type":"TASK_ASSIGNED","taskId":"t1","status":"ASSIGNED","currentStageIndex":0}"#))
        state = state.applying(event(#"{"type":"RIDER_LOCATION_UPDATE","taskId":"t1","riderId":"r1","location":{"latitude":6.45,"longitude":3.39},"eta":{"stageIndex":0,"seconds":420,"meters":2350},"timestamp":"2026-10-28T10:00:00.000Z"}"#))
        XCTAssertEqual(state.status, .assigned)
        XCTAssertEqual(state.rider?.latitude, 6.45)
        XCTAssertEqual(state.eta?.meters, 2350)
        XCTAssertEqual(state.eta?.arrivesAt, parseISODate("2026-10-28T10:07:00.000Z"))

        state = state.applying(event(#"{"type":"STAGE_COMPLETED","taskId":"t1","stageIndex":0,"nextStageIndex":1}"#))
        XCTAssertEqual(state.currentStageIndex, 1)
        XCTAssertNil(state.eta, "the pickup's ETA no longer applies")

        state = state.applying(event(#"{"type":"TASK_COMPLETED","taskId":"t1","status":"COMPLETED"}"#))
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.events.map(\.type), [.completed, .stageCompleted, .assigned])
    }

    func testIgnoresOtherTasks() {
        let state = TaskTrackerState(taskId: "t1")
            .applying(event(#"{"type":"TASK_CANCELLED","taskId":"other","status":"CANCELLED"}"#))
        XCTAssertNil(state.status)
        XCTAssertTrue(state.events.isEmpty)
    }

    func testCountdown() {
        let now = Date()
        let eta = TrackedEta(stageIndex: 0, seconds: 90, meters: 500, arrivesAt: now.addingTimeInterval(90), updatedAt: now)
        XCTAssertEqual(eta.secondsRemaining(now: now.addingTimeInterval(30)), 60)
        XCTAssertEqual(eta.secondsRemaining(now: now.addingTimeInterval(500)), 0)
    }

    func testTokenExpiry() {
        let payload = Data(#"{"exp":2000}"#.utf8).base64EncodedString()
        let token = "h.\(payload).s"
        XCTAssertEqual(RelayProtocol.secondsUntilExpiry(of: token, now: Date(timeIntervalSince1970: 1400)), 600)
        XCTAssertNil(RelayProtocol.secondsUntilExpiry(of: "not-a-jwt"))
    }
}
