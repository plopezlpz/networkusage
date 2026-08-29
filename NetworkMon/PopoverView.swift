import AppKit
import SwiftUI

func networkUploadColor(dark: Bool) -> NSColor {
    dark
        ? NSColor(srgbRed: 1.00, green: 0.38, blue: 0.84, alpha: 1)
        : NSColor(srgbRed: 0.64, green: 0.11, blue: 0.69, alpha: 1)
}

func networkDownloadColor(dark: Bool) -> NSColor {
    dark
        ? NSColor(srgbRed: 0.35, green: 0.78, blue: 1.00, alpha: 1)
        : NSColor(srgbRed: 0.00, green: 0.40, blue: 0.80, alpha: 1)
}

struct PopoverView: View {
    @ObservedObject var monitor: NetworkMonitor
    @Environment(\.colorScheme) private var colorScheme

    private var uploadColor: Color { Color(nsColor: networkUploadColor(dark: colorScheme == .dark)) }
    private var downloadColor: Color { Color(nsColor: networkDownloadColor(dark: colorScheme == .dark)) }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(HeaderButtonStyle())
                    .keyboardShortcut("q", modifiers: .command)
                    .help("Quit NetworkMon")
            }
            .frame(height: 24)

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TrafficGraph(samples: monitor.samples, uploadColor: uploadColor, downloadColor: downloadColor)
                    VStack(alignment: .leading) {
                        rateBadge(arrow: "↑", rate: formatRate(monitor.current.sent, padded: true), color: uploadColor)
                        Spacer()
                        rateBadge(arrow: "↓", rate: formatRate(monitor.current.received, padded: true), color: downloadColor)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 12)
                }
                .frame(height: 92)

                HStack {
                    Text("5 minutes ago")
                    Spacer()
                    Text("now")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
                .frame(height: 18)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(width: 240)
    }

    private func rateBadge(arrow: String, rate: String, color: Color) -> some View {
        Text("\(arrow) \(rate)")
            .font(.system(.caption, design: .monospaced).bold())
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.38), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : isHovered ? 0.08 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.08), value: isHovered)
    }
}

private struct TrafficGraph: View {
    let samples: [TrafficSample]
    let uploadColor: Color
    let downloadColor: Color

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            let columnWidth = size.width / 300
            let ceiling = chartCeiling(for: samples)

            for index in 0..<60 {
                let x = CGFloat(index) * size.width / 60
                let path = Path(CGRect(x: x, y: 8, width: 2, height: size.height - 16))
                context.fill(path, with: .color(.secondary.opacity(0.12)))
            }

            let now = Date().timeIntervalSinceReferenceDate
            for sample in samples {
                let x = size.width - CGFloat((now - sample.timestamp) / 300) * size.width - columnWidth
                let upHeight = CGFloat(sample.sent / ceiling) * (middle - 10)
                let downHeight = CGFloat(sample.received / ceiling) * (middle - 10)
                context.fill(
                    Path(CGRect(x: x, y: middle - upHeight, width: max(1, columnWidth), height: upHeight)),
                    with: .color(uploadColor.opacity(0.8))
                )
                context.fill(
                    Path(CGRect(x: x, y: middle, width: max(1, columnWidth), height: downHeight)),
                    with: .color(downloadColor.opacity(0.9))
                )
            }

            context.stroke(Path { path in
                path.move(to: CGPoint(x: 0, y: middle))
                path.addLine(to: CGPoint(x: size.width, y: middle))
            }, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Five-minute network traffic graph")
        .accessibilityValue(graphAccessibilityValue(for: samples))
    }
}
