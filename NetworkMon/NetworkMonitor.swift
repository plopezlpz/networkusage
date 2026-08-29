import Combine
import Darwin
import Foundation

struct TrafficSample: Equatable {
    let received: Double
    let sent: Double
    let timestamp: TimeInterval

    init(received: Double, sent: Double, timestamp: TimeInterval = 0) {
        self.received = received
        self.sent = sent
        self.timestamp = timestamp
    }
}

struct InterfaceCounters: Equatable {
    let received: UInt64
    let sent: UInt64

    static func read() -> [String: InterfaceCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_LINK, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        guard size > 0 else { return [:] }

        var data = Data(count: size)
        var bytesRead = size
        let status = data.withUnsafeMutableBytes {
            sysctl(&mib, u_int(mib.count), $0.baseAddress, &bytesRead, nil, 0)
        }
        guard status == 0, bytesRead <= size else { return nil }
        data.count = bytesRead
        return parse(data)
    }

    static func parse(_ data: Data) -> [String: InterfaceCounters]? {
        data.withUnsafeBytes { bytes in
            var result: [String: InterfaceCounters] = [:]
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr2>.size
            guard let nameOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) else { return nil }

            while offset < bytes.count {
                guard bytes.count - offset >= 4 else { return nil }
                let messageLength = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                let version = bytes[offset + 2]
                let type = bytes[offset + 3]
                guard messageLength >= 4, messageLength <= bytes.count - offset,
                      version == UInt8(RTM_VERSION) else { return nil }

                if type == UInt8(RTM_IFINFO2) {
                    guard messageLength >= headerSize + MemoryLayout<sockaddr_dl>.size else { return nil }
                    let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    guard header.ifm_addrs & RTA_IFP != 0 else { return nil }

                    let addressOffset = offset + headerSize
                    let address = bytes.loadUnaligned(fromByteOffset: addressOffset, as: sockaddr_dl.self)
                    let addressLength = Int(address.sdl_len)
                    let nameLength = Int(address.sdl_nlen)
                    guard address.sdl_family == UInt8(AF_LINK),
                          address.sdl_index == header.ifm_index,
                          addressLength >= nameOffset + nameLength,
                          headerSize + addressLength <= messageLength else { return nil }

                    let nameStart = addressOffset + nameOffset
                    guard let name = String(bytes: bytes[nameStart..<(nameStart + nameLength)], encoding: .utf8) else { return nil }
                    let flags = header.ifm_flags
                    if flags & IFF_UP != 0,
                       flags & IFF_LOOPBACK == 0,
                       name.hasPrefix("en") {
                        result[name] = InterfaceCounters(
                            received: header.ifm_data.ifi_ibytes,
                            sent: header.ifm_data.ifi_obytes
                        )
                    }
                }
                offset += messageLength
            }
            return result
        }
    }
}

func calculateRate(
    current: [String: InterfaceCounters],
    previous: [String: InterfaceCounters],
    elapsed: TimeInterval
) -> TrafficSample? {
    guard elapsed > 0, elapsed <= 5 else { return nil }
    var received: UInt64 = 0
    var sent: UInt64 = 0

    for (name, counters) in current {
        guard let old = previous[name],
              counters.received >= old.received,
              counters.sent >= old.sent else { continue }
        let (newReceived, receivedOverflow) = received.addingReportingOverflow(counters.received - old.received)
        let (newSent, sentOverflow) = sent.addingReportingOverflow(counters.sent - old.sent)
        guard !receivedOverflow, !sentOverflow else { return nil }
        received = newReceived
        sent = newSent
    }

    return TrafficSample(received: Double(received) / elapsed, sent: Double(sent) / elapsed)
}

func samplesInWindow(_ samples: [TrafficSample], now: TimeInterval, seconds: TimeInterval = 300) -> [TrafficSample] {
    samples.filter { $0.timestamp <= now && now - $0.timestamp <= seconds }
}

func trayHistory(
    _ samples: [TrafficSample],
    now: TimeInterval,
    seconds: Int = 12
) -> [TrafficSample?] {
    guard seconds > 0 else { return [] }
    var slots = [TrafficSample?](repeating: nil, count: seconds)
    for sample in samples {
        let age = now - sample.timestamp
        guard age >= 0, age < Double(seconds) else { continue }
        slots[seconds - 1 - Int(age)] = sample
    }
    return slots
}

func chartCeiling(for samples: [TrafficSample]) -> Double {
    let peak = max(samples.map { max($0.received, $0.sent) }.max() ?? 0, 1_000)
    let magnitude = pow(10, floor(log10(peak)))
    let normalized = peak / magnitude
    let step = normalized <= 1 ? 1.0 : normalized <= 2 ? 2.0 : normalized <= 5 ? 5.0 : 10.0
    return step * magnitude
}

func graphAccessibilityValue(for samples: [TrafficSample]) -> String {
    let count = Double(samples.count)
    let averageSent = count > 0 ? samples.reduce(0) { $0 + $1.sent } / count : 0
    let averageReceived = count > 0 ? samples.reduce(0) { $0 + $1.received } / count : 0
    let peakSent = samples.map(\.sent).max() ?? 0
    let peakReceived = samples.map(\.received).max() ?? 0
    return "Upload average \(formatRate(averageSent)), peak \(formatRate(peakSent)); download average \(formatRate(averageReceived)), peak \(formatRate(peakReceived))"
}

final class NetworkMonitor: ObservableObject {
    @Published private(set) var samples: [TrafficSample] = []

    var current: TrafficSample { samples.last ?? TrafficSample(received: 0, sent: 0) }

    private let counterReader: () -> [String: InterfaceCounters]?
    private var previous: [String: InterfaceCounters]?
    private var previousTime: TimeInterval
    private var timer: Timer?

    init(
        counterReader: @escaping () -> [String: InterfaceCounters]? = { InterfaceCounters.read() },
        now: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) {
        self.counterReader = counterReader
        previous = counterReader()
        previousTime = now
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func tick(now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        guard let counters = counterReader() else {
            samples = samplesInWindow(samples, now: now)
            return
        }
        guard let previous else {
            self.previous = counters
            previousTime = now
            return
        }
        if let rate = calculateRate(current: counters, previous: previous, elapsed: now - previousTime) {
            samples.append(TrafficSample(received: rate.received, sent: rate.sent, timestamp: now))
        }
        samples = samplesInWindow(samples, now: now)
        self.previous = counters
        previousTime = now
    }
}

func formatRate(_ bytesPerSecond: Double, padded: Bool = false) -> String {
    let units = ["kB", "MB", "GB", "TB"]
    var value = max(0, bytesPerSecond) / 1_000
    var unit = 0
    while value >= 999.95, unit < units.count - 1 {
        value /= 1_000
        unit += 1
    }
    return String(format: padded ? "%5.1f %@/s" : "%.1f %@/s", value, units[unit])
}
