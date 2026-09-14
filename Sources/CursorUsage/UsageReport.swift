import Foundation

enum Lane: String, CaseIterable {
    case cursor = "Cursor Models"
    case other = "Other Models"
}

struct ModelRow: Identifiable {
    var id: String { name }
    let name: String
    let tokens: Int
    let chargedCents: Double
    let requests: Int
    /// Share of the lane's included quota, in percent (matches the dashboard column).
    let percentOfLane: Double
}

struct LaneReport: Identifiable {
    var id: String { lane.rawValue }
    let lane: Lane
    let tokens: Int
    let percentUsed: Double?     // from usage-summary (auto/api PercentUsed)
    let rows: [ModelRow]
}

/// Everything the popover needs, computed once per refresh.
struct UsageReport {
    let fetchedAt: Date
    let membershipType: String?
    let cycleStart: Date?
    let cycleEnd: Date?
    let headlinePercentUsed: Double     // 0...100
    let planUsedCents: Int?
    let planLimitCents: Int?
    let onDemandEnabled: Bool
    let onDemandUsedCents: Int
    let onDemandLimitCents: Int?
    let lanes: [LaneReport]
    let onDemandRows: [ModelRow]
    let eventCount: Int
    /// Which discriminator decided lane membership — surfaced in the UI so a
    /// wrong guess is visible instead of silently mis-bucketing.
    let laneRule: String

    var headlinePercentLeft: Double { max(0, 100 - headlinePercentUsed) }
    var extraSpendUSD: Double { Double(onDemandUsedCents) / 100 }

    static func build(summary: UsageSummary, events: [UsageEvent], now: Date = Date()) -> UsageReport {
        let plan = summary.individualUsage?.plan
        let onDemand = summary.individualUsage?.onDemand

        // Headline: Cursor's own totalPercentUsed, else averaged lanes, else cents ratio.
        let headline: Double
        if let t = plan?.totalPercentUsed {
            headline = t
        } else if let a = plan?.autoPercentUsed, let b = plan?.apiPercentUsed {
            headline = (a + b) / 2
        } else if let used = plan?.used, let limit = plan?.limit, limit > 0 {
            headline = Double(used) / Double(limit) * 100
        } else if let used = summary.individualUsage?.overall?.used,
                  let limit = summary.individualUsage?.overall?.limit, limit > 0 {
            headline = Double(used) / Double(limit) * 100
        } else {
            headline = 0
        }

        let included = events.filter { !$0.isOnDemand }
        let onDemandEvents = events.filter { $0.isOnDemand }

        let (assign, rule) = LaneClassifier.make(events: included)
        var byLane: [Lane: [UsageEvent]] = [.cursor: [], .other: []]
        for e in included { byLane[assign(e), default: []].append(e) }

        let lanePercent: [Lane: Double?] = [
            .cursor: plan?.autoPercentUsed,
            .other: plan?.apiPercentUsed,
        ]
        let lanes = Lane.allCases.map { lane -> LaneReport in
            let evs = byLane[lane] ?? []
            let laneCost = evs.reduce(0.0) { $0 + weight($1) }
            let pct = lanePercent[lane] ?? nil
            let rows = aggregate(evs) { modelWeight in
                guard let pct, laneCost > 0 else { return 0 }
                return modelWeight / laneCost * pct
            }
            return LaneReport(lane: lane, tokens: evs.reduce(0) { $0 + $1.totalTokens }, percentUsed: pct, rows: rows)
        }

        let onDemandRows = aggregate(onDemandEvents) { _ in 0 }

        return UsageReport(
            fetchedAt: now,
            membershipType: summary.membershipType,
            cycleStart: summary.cycleStart,
            cycleEnd: summary.cycleEnd,
            headlinePercentUsed: min(100, max(0, headline)),
            planUsedCents: plan?.used,
            planLimitCents: plan?.limit,
            onDemandEnabled: onDemand?.enabled ?? false,
            onDemandUsedCents: onDemand?.used ?? 0,
            onDemandLimitCents: onDemand?.limit,
            lanes: lanes,
            onDemandRows: onDemandRows,
            eventCount: events.count,
            laneRule: rule
        )
    }

    /// Cost weight of an event for percentage attribution: what the plan actually
    /// deducted, falling back to the weighted request unit, then to vendor cents.
    static func weight(_ e: UsageEvent) -> Double {
        if let c = e.chargedCents, c > 0 { return c }
        if let r = e.requestsCosts, r > 0 { return r * 4 }
        if let t = e.totalCents, t > 0 { return t }
        return 0
    }

    private static func aggregate(_ events: [UsageEvent], percent: (Double) -> Double) -> [ModelRow] {
        struct Acc { var tokens = 0; var cents = 0.0; var weight = 0.0; var requests = 0 }
        var acc: [String: Acc] = [:]
        for e in events {
            var a = acc[e.model, default: Acc()]
            a.tokens += e.totalTokens
            a.cents += e.chargedCents ?? 0
            a.weight += weight(e)
            a.requests += 1
            acc[e.model] = a
        }
        return acc.map { name, a in
            ModelRow(name: name, tokens: a.tokens, chargedCents: a.cents, requests: a.requests, percentOfLane: percent(a.weight))
        }
        .sorted { ($0.percentOfLane, $0.tokens, $1.name) > ($1.percentOfLane, $1.tokens, $0.name) }
    }
}

/// Decides whether an included event counts against the "Cursor Models" quota
/// (auto/composer) or the "Other Models" quota (named third-party models).
///
/// The dashboard's own rule isn't exposed anywhere documented — `auto-smart`
/// shows up in BOTH groups, so it is not a pure model-name split. We look for an
/// explicit discriminator field first, and fall back to a name heuristic. Run
/// `CursorUsage --dump` to see the raw event fields and tighten this.
enum LaneClassifier {
    static let candidateKeys = [
        "usageLane", "lane", "billingLane", "quotaLane", "includedUsageLane",
        "usageType", "quotaType", "modelLane", "includedUsageType", "pricingLane",
    ]

    static func make(events: [UsageEvent]) -> ((UsageEvent) -> Lane, String) {
        // 1. Explicit field present on the events?
        if let key = candidateKeys.first(where: { key in events.contains { $0.raw[key] != nil } }) {
            let rule = "field '\(key)'"
            return ({ e in
                let v = String(describing: e.raw[key] ?? "").lowercased()
                return (v.contains("auto") || v.contains("cursor") || v.contains("composer")) ? .cursor : .other
            }, rule)
        }
        // 2. Heuristic: Cursor-owned models by name; everything else third-party.
        return ({ e in Self.byName(e.model) }, "model-name heuristic")
    }

    static func byName(_ model: String) -> Lane {
        let m = model.lowercased()
        if m.hasPrefix("composer") || m.hasPrefix("cursor-") || m == "auto" || m.hasPrefix("auto-") || m == "default" {
            return .cursor
        }
        return .other
    }
}
