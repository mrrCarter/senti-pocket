import Foundation
import PocketUI
import XCTest
@testable import SentiPocketApp

private enum ReasoningConnectivityMonitorTestError: Error {
    case timeout
}

private final class ReasoningPathMonitorProbe: ReasoningPathStatusMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandler: (@Sendable (ReasoningPathStatus) -> Void)?
    private var startCount = 0
    private var cancelCount = 0

    var statusUpdateHandler: (@Sendable (ReasoningPathStatus) -> Void)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    func start() {
        lock.withLock { startCount += 1 }
    }

    func cancel() {
        lock.withLock { cancelCount += 1 }
    }

    func emit(_ status: ReasoningPathStatus) {
        let handler = lock.withLock { storedHandler }
        handler?(status)
    }

    func snapshot() -> (starts: Int, cancels: Int, hasHandler: Bool) {
        lock.withLock { (startCount, cancelCount, storedHandler != nil) }
    }
}

private final class ReasoningPathMonitorFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMonitors: [ReasoningPathMonitorProbe] = []

    func makeMonitor() -> any ReasoningPathStatusMonitoring {
        let monitor = ReasoningPathMonitorProbe()
        lock.withLock { storedMonitors.append(monitor) }
        return monitor
    }

    func monitors() -> [ReasoningPathMonitorProbe] {
        lock.withLock { storedMonitors }
    }
}

private final class ReasoningConnectivityValueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [PocketConnectivity] = []

    func append(_ value: PocketConnectivity) {
        lock.withLock { storedValues.append(value) }
    }

    func values() -> [PocketConnectivity] {
        lock.withLock { storedValues }
    }
}

private actor ReasoningConnectivityConsumerGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class ReasoningConnectivityMonitorTests: XCTestCase {
    func test_stream_starts_reconnecting_maps_every_path_status_and_cancels_exact_monitor() async throws {
        let factory = ReasoningPathMonitorFactoryProbe()
        let values = ReasoningConnectivityValueProbe()
        let updates = ReasoningConnectivityUpdates(makeMonitor: factory.makeMonitor)
        let consumer = Task {
            for await value in updates.stream() {
                values.append(value)
            }
        }

        try await waitUntil { factory.monitors().count == 1 && values.values().count == 1 }
        let monitor = try XCTUnwrap(factory.monitors().first)
        XCTAssertEqual(values.values(), [.reconnecting])
        XCTAssertEqual(monitor.snapshot().starts, 1)

        monitor.emit(.satisfied)
        try await waitUntil { values.values().count == 2 }
        monitor.emit(.requiresConnection)
        try await waitUntil { values.values().count == 3 }
        monitor.emit(.unsatisfied)
        try await waitUntil { values.values().count == 4 }
        monitor.emit(.unknown)
        try await waitUntil { values.values().count == 5 }

        XCTAssertEqual(values.values(), [
            .reconnecting,
            .online,
            .reconnecting,
            .offline(cachedAt: nil),
            .offline(cachedAt: nil)
        ])

        consumer.cancel()
        await consumer.value
        try await waitUntil { monitor.snapshot().cancels == 1 }
        XCTAssertEqual(monitor.snapshot().starts, 1)
        XCTAssertEqual(monitor.snapshot().cancels, 1)
        XCTAssertFalse(monitor.snapshot().hasHandler)
        monitor.emit(.satisfied)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(values.values().count, 5, "a terminated monitor must not deliver a late callback")
    }

    func test_stream_buffers_only_the_newest_unconsumed_path_update() async throws {
        let factory = ReasoningPathMonitorFactoryProbe()
        let values = ReasoningConnectivityValueProbe()
        let gate = ReasoningConnectivityConsumerGate()
        let updates = ReasoningConnectivityUpdates(makeMonitor: factory.makeMonitor)
        let consumer = Task {
            var isFirst = true
            for await value in updates.stream() {
                values.append(value)
                if isFirst {
                    isFirst = false
                    await gate.wait()
                }
            }
        }

        try await waitUntil { factory.monitors().count == 1 && values.values() == [.reconnecting] }
        let monitor = try XCTUnwrap(factory.monitors().first)
        monitor.emit(.satisfied)
        monitor.emit(.requiresConnection)
        monitor.emit(.unsatisfied)
        await gate.open()
        try await waitUntil { values.values().count == 2 }

        XCTAssertEqual(values.values(), [.reconnecting, .offline(cachedAt: nil)])

        consumer.cancel()
        await consumer.value
        try await waitUntil { monitor.snapshot().cancels == 1 }
    }

    func test_each_stream_owns_and_terminates_a_fresh_monitor() async throws {
        let factory = ReasoningPathMonitorFactoryProbe()
        let updates = ReasoningConnectivityUpdates(makeMonitor: factory.makeMonitor)
        let first = Task { for await _ in updates.stream() {} }
        let second = Task { for await _ in updates.stream() {} }

        try await waitUntil {
            let monitors = factory.monitors()
            return monitors.count == 2 && monitors.allSatisfy { $0.snapshot().starts == 1 }
        }
        let monitors = factory.monitors()
        XCTAssertFalse(monitors[0] === monitors[1])

        first.cancel()
        await first.value
        try await waitUntil { monitors.filter { $0.snapshot().cancels == 1 }.count == 1 }
        XCTAssertEqual(monitors.map { $0.snapshot().cancels }.sorted(), [0, 1])

        second.cancel()
        await second.value
        try await waitUntil { monitors.allSatisfy { $0.snapshot().cancels == 1 } }
        XCTAssertTrue(monitors.allSatisfy { !$0.snapshot().hasHandler })
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("condition did not become true", file: file, line: line)
        throw ReasoningConnectivityMonitorTestError.timeout
    }
}
