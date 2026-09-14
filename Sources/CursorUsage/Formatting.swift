import Foundation

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch d {
        case 1_000_000_000...: return String(format: "%.1fB tokens", d / 1e9)
        case 1_000_000...: return String(format: "%.1fM tokens", d / 1e6)
        case 1_000...: return String(format: "%.1fK tokens", d / 1e3)
        default: return "\(n) tokens"
        }
    }

    static func percent(_ p: Double?) -> String {
        guard let p else { return "—" }
        return String(format: "%.1f%%", p)
    }

    static func usd(cents: Double) -> String {
        String(format: "$%.2f", cents / 100)
    }

    static func usd(_ d: Double) -> String { String(format: "$%.2f", d) }

    static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
    static let resetFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d 'at' HH:mm"
        return f
    }()
    static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func cycle(_ start: Date?, _ end: Date?) -> String {
        switch (start, end) {
        case let (s?, e?): return "\(dayFmt.string(from: s)) – \(dayFmt.string(from: e))"
        case let (nil, e?): return "until \(dayFmt.string(from: e))"
        default: return "current period"
        }
    }

    static func countdown(to date: Date, from now: Date = Date()) -> String {
        let secs = max(0, date.timeIntervalSince(now))
        let days = Int(secs / 86400)
        let hours = Int(secs.truncatingRemainder(dividingBy: 86400) / 3600)
        if days > 0 { return "\(days)d \(hours)h" }
        let mins = Int(secs.truncatingRemainder(dividingBy: 3600) / 60)
        return "\(hours)h \(mins)m"
    }
}
