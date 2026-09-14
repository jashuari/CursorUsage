import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var report: UsageReport?
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false
    @Published var showPercentLeft: Bool {
        didSet { UserDefaults.standard.set(showPercentLeft, forKey: "showPercentLeft") }
    }
    @Published var launchAtLogin: Bool = LaunchAtLogin.isEnabled {
        didSet {
            guard !syncingLoginItem, launchAtLogin != oldValue else { return }
            if let err = LaunchAtLogin.set(launchAtLogin) {
                error = err
                syncLoginItem(oldValue)
            }
        }
    }
    private var syncingLoginItem = false
    private func syncLoginItem(_ value: Bool) {
        syncingLoginItem = true
        launchAtLogin = value
        syncingLoginItem = false
    }

    /// Refresh cadence in seconds. Events for a whole billing cycle can be tens of
    /// thousands of rows, so don't hammer it.
    var interval: TimeInterval = 5 * 60
    private var timer: Timer?
    var onChange: (() -> Void)?

    init() {
        showPercentLeft = UserDefaults.standard.object(forKey: "showPercentLeft") as? Bool ?? true
    }

    /// Previews / `--screenshot` only: a store pinned to a fixed report. It never
    /// fetches, and it must not disturb the user's settings — `showPercentLeft` is
    /// set as part of initialization (so its UserDefaults `didSet` doesn't run) and
    /// `launchAtLogin` goes through `syncLoginItem`, which the `didSet` ignores, so
    /// no login item is ever registered.
    init(previewReport: UsageReport, showPercentLeft: Bool = true, launchAtLogin: Bool = true) {
        self.showPercentLeft = showPercentLeft
        syncLoginItem(launchAtLogin)
        report = previewReport
    }

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// Refresh only if the last successful fetch is stale — used when the popover opens.
    func refreshIfStale(olderThan seconds: TimeInterval = 60) {
        // System Settings may have toggled the login item behind our back.
        let live = LaunchAtLogin.isEnabled
        if live != launchAtLogin { syncLoginItem(live) }
        if let r = report, Date().timeIntervalSince(r.fetchedAt) < seconds { return }
        Task { await refresh() }
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false; onChange?() }
        do {
            let session = try CursorAuthReader().read()
            let api = CursorAPI(cookieHeader: session.cookieHeader)
            let summary = try await api.usageSummary()
            let now = Date()
            // Window = current billing cycle; fall back to the last 30 days if Cursor didn't send one.
            let start = summary.cycleStart ?? Calendar.current.date(byAdding: .day, value: -30, to: now)!
            let end = min(summary.cycleEnd ?? now, now)
            let events = try await api.usageEvents(start: start, end: end)
            report = UsageReport.build(summary: summary, events: events, now: now)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Menu bar text

    var menuTitle: String {
        guard let r = report else { return error == nil ? "…" : "!" }
        let v = showPercentLeft ? r.headlinePercentLeft : r.headlinePercentUsed
        return "\(Int(v.rounded()))%"
    }

    /// 0 = fine, 1 = warn, 2 = critical — keyed on % used regardless of display mode.
    var severity: Int {
        guard let r = report else { return error == nil ? 0 : 2 }
        if r.headlinePercentUsed >= 90 { return 2 }
        if r.headlinePercentUsed >= 70 { return 1 }
        return 0
    }
}
