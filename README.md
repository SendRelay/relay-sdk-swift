# RelaySDK for Swift

Official [Relay](https://sendrelay.com.ng) SDK for iOS and macOS: show a delivery's status, the rider on a map and a live arrival time.

## Install

In Xcode: **File → Add Package Dependencies…**, then `https://github.com/SendRelay/relay-sdk-swift`. Or in `Package.swift`:

```swift
.package(url: "https://github.com/SendRelay/relay-sdk-swift", from: "1.7.0")
```

iOS 15+ and macOS 12+. No dependencies.

## SwiftUI

```swift
import RelaySDK
import SwiftUI

// Your server mints the token with its API key (relay.auth.createWebSocketToken).
let relay = RelayRealtimeClient { taskIds in try await API.trackingToken(for: taskIds) }

struct OrderView: View {
    @StateObject var tracker: RelayTaskTracker

    init(taskId: String) {
        _tracker = StateObject(wrappedValue: RelayTaskTracker(client: relay, taskId: taskId))
    }

    var body: some View {
        VStack {
            Text(tracker.state.status?.rawValue ?? "Finding a rider")
            if let eta = tracker.state.eta {
                Text("Arriving \(eta.arrivesAt, style: .relative)")
            }
        }
        .task { await tracker.start() }
        .onDisappear { Task { await tracker.stop() } }
    }
}
```

`tracker.state` has `status`, `rider` (position, bearing, speed), `eta` (the rider's road ETA to their next stop), `events`, `connection`, `finished` and `error`.

## Without SwiftUI

```swift
Task {
    for await event in relay.events() {
        switch event {
        case .task(let e): print(e.type, e.status ?? "")
        case .riderLocation(let update): map.move(to: update.location, eta: update.eta)
        default: break
        }
    }
}
try await relay.listen(taskId)
```

The client reconnects with backoff, resubscribes after a reconnect, sends heartbeats, and refreshes the token before it expires.

[Full documentation](https://docs.sendrelay.com.ng/sdks/swift-sdk)
