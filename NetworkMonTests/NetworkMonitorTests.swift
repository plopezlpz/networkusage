import XCTest
@testable import NetworkMon

final class NetworkMonitorTests: XCTestCase {
    func testRateCalculationUses64BitCountersAndHandlesInterfaceChanges() {
        let base = UInt64(UInt32.max) + 1_000
        let previous = [
            "en0": InterfaceCounters(received: base, sent: base),
            "en7": InterfaceCounters(received: 9_000, sent: 9_000)
        ]
        let current = [
            "en0": InterfaceCounters(received: base + 8_000_000_000, sent: base + 4_000_000_000),
            "en1": InterfaceCounters(received: 1_000_000, sent: 1_000_000),
            "en7": InterfaceCounters(received: 100, sent: 100)
        ]

        XCTAssertEqual(
            calculateRate(current: current, previous: previous, elapsed: 2),
            TrafficSample(received: 4_000_000_000, sent: 2_000_000_000)
        )
        XCTAssertEqual(
            calculateRate(current: current, previous: [:], elapsed: 1),
            TrafficSample(received: 0, sent: 0)
        )
        XCTAssertNil(calculateRate(current: current, previous: previous, elapsed: 0))
        XCTAssertNil(calculateRate(current: current, previous: previous, elapsed: 10))
    }

    func testCounterReadFailurePreservesBaselineAndTimestamp() {
        let initial = ["en0": InterfaceCounters(received: 1_000, sent: 2_000)]
        let updated = ["en0": InterfaceCounters(received: 5_000, sent: 8_000)]
        var reads: [[String: InterfaceCounters]?] = [initial, nil, updated]
        let monitor = NetworkMonitor(counterReader: { reads.removeFirst() }, now: 100)

        monitor.tick(now: 101)
        XCTAssertTrue(monitor.samples.isEmpty)

        monitor.tick(now: 102)
        XCTAssertEqual(
            monitor.samples,
            [TrafficSample(received: 2_000, sent: 3_000, timestamp: 102)]
        )
    }

    func testProlongedReadFailureExpiresHistoryWithoutAdvancingBaseline() {
        let initial = ["en0": InterfaceCounters(received: 1_000, sent: 2_000)]
        let first = ["en0": InterfaceCounters(received: 2_000, sent: 4_000)]
        let afterFailure = ["en0": InterfaceCounters(received: 5_000, sent: 8_000)]
        let final = ["en0": InterfaceCounters(received: 5_500, sent: 9_000)]
        var reads: [[String: InterfaceCounters]?] = [initial, first, nil, afterFailure, final]
        let monitor = NetworkMonitor(counterReader: { reads.removeFirst() }, now: 100)

        monitor.tick(now: 101)
        XCTAssertEqual(monitor.samples.count, 1)

        monitor.tick(now: 402)
        XCTAssertTrue(monitor.samples.isEmpty)

        monitor.tick(now: 403)
        XCTAssertTrue(monitor.samples.isEmpty)

        monitor.tick(now: 404)
        XCTAssertEqual(
            monitor.samples,
            [TrafficSample(received: 500, sent: 1_000, timestamp: 404)]
        )
    }

    func testRouteParserRejectsTruncatedMessagesAndLiveReadSucceeds() {
        XCTAssertNil(InterfaceCounters.parse(Data([1, 0, UInt8(RTM_VERSION), UInt8(RTM_IFINFO2)])))
        XCTAssertNotNil(InterfaceCounters.read())
    }

    func testTimeWindowsAndTrayHistoryKeepGaps() {
        let history = [
            TrafficSample(received: 1, sent: 1, timestamp: 0),
            TrafficSample(received: 2, sent: 2, timestamp: 10),
            TrafficSample(received: 3, sent: 3, timestamp: 301)
        ]
        XCTAssertEqual(samplesInWindow(history, now: 301).map(\.timestamp), [10, 301])

        let tray = trayHistory([
            TrafficSample(received: 1, sent: 1, timestamp: 89.2),
            TrafficSample(received: 2, sent: 2, timestamp: 96.2),
            TrafficSample(received: 3, sent: 3, timestamp: 99.8),
            TrafficSample(received: 4, sent: 4, timestamp: 88)
        ], now: 100)
        XCTAssertEqual(tray.count, 12)
        XCTAssertEqual(tray[1]?.timestamp, 89.2)
        XCTAssertEqual(tray[8]?.timestamp, 96.2)
        XCTAssertEqual(tray[11]?.timestamp, 99.8)
        XCTAssertNil(tray[0])
        XCTAssertNil(tray[10])
    }

    func testChartUsesOneCeilingAndAccessibilitySummaryReportsBothDirections() {
        XCTAssertEqual(chartCeiling(for: []), 1_000)
        XCTAssertEqual(chartCeiling(for: [TrafficSample(received: 1_100, sent: 4_900)]), 5_000)
        XCTAssertEqual(chartCeiling(for: [TrafficSample(received: 5_100, sent: 1_100)]), 10_000)

        let samples = [
            TrafficSample(received: 1_000, sent: 2_000),
            TrafficSample(received: 3_000, sent: 6_000)
        ]
        XCTAssertEqual(
            graphAccessibilityValue(for: samples),
            "Upload average 4.0 kB/s, peak 6.0 kB/s; download average 2.0 kB/s, peak 3.0 kB/s"
        )
    }

    func testRateFormatting() {
        XCTAssertEqual(formatRate(0), "0.0 kB/s")
        XCTAssertEqual(formatRate(100_300_000), "100.3 MB/s")
        XCTAssertEqual(formatRate(1_100_000, padded: true), "  1.1 MB/s")
        XCTAssertEqual(formatRate(1_000_000_000), "1.0 GB/s")
    }
}
