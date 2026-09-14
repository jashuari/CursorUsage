import AppKit
import SwiftUI
import Combine

@main
@MainActor
struct CursorUsageMain {
    static func main() {
        if CommandLine.arguments.contains("--dump") {
            runDump()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// `CursorUsage --dump` prints raw API payloads for field discovery.
    static func runDump() {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let s = try CursorAuthReader().read()
                print("session user=\(s.userID) expires=\(s.expiresAt)")
                let api = CursorAPI(cookieHeader: s.cookieHeader)
                let summary = try await api.usageSummaryRaw()
                print("\n=== /api/usage-summary ===\n\(summary)")
                let decoded = try JSONDecoder().decode(UsageSummary.self, from: Data(summary.utf8))
                let start = decoded.cycleStart ?? Calendar.current.date(byAdding: .day, value: -30, to: Date())!
                let events = try await api.usageEventsRaw(start: start, end: Date())
                print("\n=== /api/dashboard/get-filtered-usage-events (first 25 since \(start)) ===\n\(events)")
                let dir = NSHomeDirectory() + "/Library/Logs/CursorUsage"
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let stamp = Int(Date().timeIntervalSince1970)
                try summary.write(toFile: "\(dir)/usage-summary-\(stamp).json", atomically: true, encoding: .utf8)
                try events.write(toFile: "\(dir)/events-\(stamp).json", atomically: true, encoding: .utf8)
                print("\nWritten to \(dir)/  (contains only usage data, no token)")
            } catch {
                print("ERROR: \(error.localizedDescription)")
            }
            sem.signal()
        }
        sem.wait()
    }
}

// MARK: - Menu bar app

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = UsageStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LaunchAtLogin.registerOnFirstRun()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Cursor usage")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: PopoverView(store: store, onQuit: { NSApp.terminate(nil) }, onDump: { [weak self] in self?.runDump() })
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        store.onChange = { [weak self] in self?.updateTitle() }
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }.store(in: &bag)
        updateTitle()
        store.start()
    }

    private var bag = Set<AnyCancellable>()

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let color: NSColor = switch store.severity {
        case 2: .systemRed
        case 1: .systemOrange
        default: .labelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .foregroundColor: color,
            .baselineOffset: 0,
        ]
        button.attributedTitle = NSAttributedString(string: " " + store.menuTitle, attributes: attrs)
        if let r = store.report {
            let mode = store.showPercentLeft ? "left" : "used"
            button.toolTip = "Cursor: \(Int(r.headlinePercentUsed.rounded()))% used" +
                (store.showPercentLeft ? " (\(store.menuTitle) \(mode))" : "") +
                (r.cycleEnd.map { " · resets \(Fmt.resetFmt.string(from: $0))" } ?? "")
        } else {
            button.toolTip = store.error ?? "Cursor usage"
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            store.refreshIfStale()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func runDump() {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--dump"]
        try? p.run()
        p.waitUntilExit()
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/CursorUsage"))
    }
}

