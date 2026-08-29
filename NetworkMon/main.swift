import AppKit
import Combine
import SwiftUI

private final class MonitorPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let monitor = NetworkMonitor()
    private var statusItem: NSStatusItem!
    private var panel: MonitorPanel!
    private var panelOpen = false
    private var statusItemClickMonitor: Any?
    private var outsideClickMonitor: Any?
    private var subscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: 96)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imageScaling = .scaleProportionallyDown
        }
        installStatusItemClickMonitor()

        let hosting = NSHostingView(rootView: PopoverView(monitor: monitor))
        panel = MonitorPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        hosting.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effectView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])

        panel.contentView = effectView
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .transient]
        panel.onCancel = { [weak self] in self?.closePanel() }

        subscription = monitor.$samples.sink { [weak self] _ in self?.updateStatusItem() }
        updateStatusItem()
        monitor.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPanel() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        closePanel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        closePanel()
        if let statusItemClickMonitor { NSEvent.removeMonitor(statusItemClickMonitor) }
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panelOpen, !self.panel.isKeyWindow else { return }
            self.closePanel()
        }
    }

    @objc private func togglePanel() {
        panelOpen ? closePanel() : showPanel()
    }

    private func installStatusItemClickMonitor() {
        statusItemClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self,
                  let button = self.statusItem.button,
                  event.window === button.window,
                  button.bounds.contains(button.convert(event.locationInWindow, from: nil)) else { return event }
            self.togglePanel()
            return nil
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let window = button.window, !panelOpen else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = window.screen?.visibleFrame ?? buttonFrame
        var x = buttonFrame.midX - panel.frame.width / 2
        x = min(max(x, visibleFrame.minX + 8), visibleFrame.maxX - panel.frame.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: buttonFrame.minY - panel.frame.height - 4))
        panelOpen = true
        button.highlight(true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.closePanel() }
        }
    }

    private func closePanel() {
        panelOpen = false
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let current = monitor.current
        let history = trayHistory(monitor.samples, now: Date().timeIntervalSinceReferenceDate)
        button.image = statusImage(current: current, history: history)
        button.imagePosition = .imageOnly
        button.highlight(panelOpen)
        button.toolTip = "Upload \(formatRate(current.sent)) · Download \(formatRate(current.received))"
        button.setAccessibilityLabel(button.toolTip)
    }
}

private func statusImage(current: TrafficSample, history: [TrafficSample?]) -> NSImage {
    let size = NSSize(width: 92, height: 22)
    let image = NSImage(size: size, flipped: false) { _ in
        let dark = NSAppearance.current.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let uploadColor = networkUploadColor(dark: dark)
        let downloadColor = networkDownloadColor(dark: dark)
        let guideColor = dark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.15)

        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let upload = NSAttributedString(
            string: formatRate(current.sent),
            attributes: [.font: font, .foregroundColor: uploadColor, .paragraphStyle: paragraph]
        )
        let download = NSAttributedString(
            string: formatRate(current.received),
            attributes: [.font: font, .foregroundColor: downloadColor, .paragraphStyle: paragraph]
        )
        upload.draw(in: NSRect(x: 2, y: 11, width: 54, height: 11))
        download.draw(in: NSRect(x: 2, y: 0, width: 54, height: 11))

        let ceiling = chartCeiling(for: history.compactMap { $0 })
        let barWidth: CGFloat = 2
        let gap: CGFloat = 0.7
        let startX: CGFloat = 60

        for index in 0..<12 {
            let x = startX + CGFloat(index) * (barWidth + gap)
            guideColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: barWidth, height: 20), xRadius: 1, yRadius: 1).fill()

            guard index < history.count, let sample = history[index] else { continue }
            let upHeight = CGFloat(sample.sent / ceiling) * 9
            let downHeight = CGFloat(sample.received / ceiling) * 9
            if upHeight > 0 {
                uploadColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 11, width: barWidth, height: upHeight), xRadius: 1, yRadius: 1).fill()
            }
            if downHeight > 0 {
                downloadColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 10 - downHeight, width: barWidth, height: downHeight), xRadius: 1, yRadius: 1).fill()
            }
        }
        return true
    }
    image.isTemplate = false
    return image
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
