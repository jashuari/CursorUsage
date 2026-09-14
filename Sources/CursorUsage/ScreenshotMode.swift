import AppKit
import SwiftUI

/// `CursorUsage --screenshot <out-dir>` renders the real `PopoverView` offscreen
/// and writes `popover-light.png` / `popover-dark.png` for the README.
///
/// The images land in a public repo, so this path is deliberately sealed off from
/// the user's account: it never reads the Cursor session, never hits the network,
/// and never registers or flips the login item. Everything it draws comes from
/// `SampleUsage` below, pinned to a fixed date so runs are reproducible.
@MainActor
enum ScreenshotMode {
    /// 380pt popover rendered at 2x, so the PNG is 760px wide.
    private static let scale: CGFloat = 2

    /// Returns the process exit status.
    static func run(outputDirectory: String) -> Int32 {
        let app = NSApplication.shared
        // No Dock icon, no focus stealing, no menu bar item.
        app.setActivationPolicy(.prohibited)

        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
            return 1
        }

        let report = SampleUsage.report
        let shots: [(name: String, appearance: NSAppearance.Name)] = [
            ("popover-light.png", .aqua),
            ("popover-dark.png", .darkAqua),
        ]
        for shot in shots {
            let url = dir.appendingPathComponent(shot.name)
            guard let data = png(report: report, appearance: shot.appearance) else {
                FileHandle.standardError.write(Data("ERROR: could not render \(shot.name)\n".utf8))
                return 1
            }
            do {
                try data.write(to: url)
            } catch {
                FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
                return 1
            }
            print("wrote \(url.path)")
        }
        return 0
    }

    /// Hosts the popover in a borderless offscreen window, lets SwiftUI settle,
    /// then caches the view into a 2x bitmap.
    private static func png(report: UsageReport, appearance name: NSAppearance.Name) -> Data? {
        // A fresh store per appearance: nothing is shared between the two renders.
        let store = UsageStore(previewReport: report)
        let root = PopoverView(store: store, onQuit: {}, onDump: {})
            // The popover chrome normally supplies the backdrop; offscreen there is
            // none, so paint the standard window background behind the unchanged view.
            .background(Color(nsColor: .windowBackgroundColor))

        let hosting = NSHostingView(rootView: root)
        let appearance = NSAppearance(named: name)
        hosting.appearance = appearance

        let fitting = hosting.fittingSize
        let size = NSSize(width: max(fitting.width, 380), height: max(fitting.height, 1))
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Off-screen, but ordered in: AppKit only pushes state into NSSwitch and
        // friends for a window that is actually in the window list, and without
        // this the toggles snapshot in their off position.
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        // Let the SwiftUI render loop commit before we snapshot.
        for _ in 0..<40 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let bounds = hosting.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((bounds.width * scale).rounded()),
            pixelsHigh: Int((bounds.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        // Point size + larger pixel dimensions is what makes this a 2x capture.
        rep.size = bounds.size

        var data: Data?
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        window.close()
        return data
    }
}

// MARK: - Sample data

/// Fabricated but self-consistent usage for the README screenshots: a Pro plan
/// two weeks into its cycle, both lanes busy, a little on-demand spend. Fed
/// through the real `UsageReport.build` so the percentages are aggregated exactly
/// the way live data would be.
@MainActor
enum SampleUsage {
    /// Fixed instant (2026-09-14 09:42 UTC) so repeated runs produce the same PNG.
    static let now = Date(timeIntervalSince1970: 1_789_378_920)

    static let report: UsageReport = {
        let summary = try! JSONDecoder().decode(UsageSummary.self, from: Data(summaryJSON.utf8))
        return UsageReport.build(summary: summary, events: sampleEvents, now: now)
    }()

    private static let summaryJSON = """
    {
      "billingCycleStart": "2026-09-01T00:00:00.000Z",
      "billingCycleEnd": "2026-10-01T00:00:00.000Z",
      "membershipType": "pro",
      "isUnlimited": false,
      "individualUsage": {
        "plan": {
          "enabled": true, "used": 1264, "limit": 2000, "remaining": 736,
          "autoPercentUsed": 41.8, "apiPercentUsed": 84.6, "totalPercentUsed": 63.2
        },
        "onDemand": { "enabled": true, "used": 742, "limit": 5000, "remaining": 4258 },
        "overall": { "enabled": true, "used": 2006, "limit": 7000, "remaining": 4994 }
      }
    }
    """

    /// model, event count, total tokens, total charged cents.
    /// Cursor-lane totals sum to 614¢ and other-lane totals to 650¢ (1264¢ = the
    /// plan spend in the summary); the on-demand rows sum to the 742¢ reported there.
    private static let included: [(String, Int, Int, Double)] = [
        ("composer-1", 438, 412_600_000, 470),
        ("auto", 306, 128_400_000, 144),
        ("claude-4.5-sonnet", 251, 268_300_000, 372),
        ("gpt-5", 112, 96_500_000, 168),
        ("gemini-2.5-pro", 58, 41_200_000, 78),
        ("o3", 21, 12_800_000, 32),
    ]
    private static let onDemand: [(String, Int, Int, Double)] = [
        ("claude-4.5-opus", 31, 18_400_000, 580),
        ("gpt-5-pro", 9, 4_900_000, 162),
    ]

    private static var sampleEvents: [UsageEvent] {
        included.flatMap { events(model: $0.0, count: $0.1, tokens: $0.2, cents: $0.3, kind: "USAGE_EVENT_KIND_INCLUDED_IN_PRO") }
            + onDemand.flatMap { events(model: $0.0, count: $0.1, tokens: $0.2, cents: $0.3, kind: "USAGE_EVENT_KIND_USAGE_BASED") }
    }

    /// Spreads a model's totals evenly over `count` events, so the aggregate the
    /// popover shows matches the numbers above exactly.
    private static func events(model: String, count: Int, tokens: Int, cents: Double, kind: String) -> [UsageEvent] {
        let per = tokens / count
        let centsPer = cents / Double(count)
        return (0..<count).compactMap { i in
            let t = i == count - 1 ? tokens - per * (count - 1) : per
            let input = t * 6 / 100
            let output = t * 4 / 100
            let cacheWrite = t * 10 / 100
            let json: [String: Any] = [
                "model": model,
                "kind": kind,
                "timestamp": String(Int64((now.timeIntervalSince1970 - Double(i) * 600) * 1000)),
                "isTokenBasedCall": true,
                "chargedCents": centsPer,
                "tokenUsage": [
                    "inputTokens": input,
                    "outputTokens": output,
                    "cacheWriteTokens": cacheWrite,
                    "cacheReadTokens": t - input - output - cacheWrite,
                    "totalCents": centsPer,
                ],
            ]
            return UsageEvent(json: json)
        }
    }
}
