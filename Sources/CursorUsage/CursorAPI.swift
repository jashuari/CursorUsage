import Foundation

// MARK: - Models

struct UsageSummary: Decodable {
    struct Individual: Decodable {
        let plan: Plan?
        let onDemand: Bucket?
        let overall: Bucket?
    }
    struct Plan: Decodable {
        let enabled: Bool?
        let used: Int?          // cents
        let limit: Int?         // cents
        let remaining: Int?     // cents
        let autoPercentUsed: Double?    // "Cursor models" lane (auto + composer)
        let apiPercentUsed: Double?     // "Other models" lane (named third-party models)
        let totalPercentUsed: Double?   // headline
    }
    struct Bucket: Decodable {
        let enabled: Bool?
        let used: Int?
        let limit: Int?
        let remaining: Int?
    }

    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let isUnlimited: Bool?
    let autoModelSelectedDisplayMessage: String?
    let namedModelSelectedDisplayMessage: String?
    let individualUsage: Individual?

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    var cycleStart: Date? { Self.date(billingCycleStart) }
    var cycleEnd: Date? { Self.date(billingCycleEnd) }
}

/// One row from `get-filtered-usage-events`. Decoded leniently: Cursor serializes
/// numbers as strings in places, and the schema shifts without notice, so we keep
/// the raw dictionary around for diagnostics (`--dump`).
struct UsageEvent {
    let timestamp: Date?
    let model: String
    let kind: String?
    let isTokenBasedCall: Bool?
    let requestsCosts: Double?
    let chargedCents: Double?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let totalCents: Double?
    let raw: [String: Any]

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
    var isOnDemand: Bool { kind == "USAGE_EVENT_KIND_USAGE_BASED" }

    init?(json: [String: Any]) {
        guard let model = json["model"] as? String else { return nil }
        self.model = model
        self.raw = json
        if let ms = Self.number(json["timestamp"]) {
            self.timestamp = Date(timeIntervalSince1970: ms / 1000)
        } else {
            self.timestamp = nil
        }
        self.kind = json["kind"] as? String
        self.isTokenBasedCall = json["isTokenBasedCall"] as? Bool
        self.requestsCosts = Self.number(json["requestsCosts"])
        self.chargedCents = Self.number(json["chargedCents"])
        let tu = json["tokenUsage"] as? [String: Any] ?? [:]
        self.inputTokens = Int(Self.number(tu["inputTokens"]) ?? 0)
        self.outputTokens = Int(Self.number(tu["outputTokens"]) ?? 0)
        self.cacheReadTokens = Int(Self.number(tu["cacheReadTokens"]) ?? 0)
        self.cacheWriteTokens = Int(Self.number(tu["cacheWriteTokens"]) ?? 0)
        self.totalCents = Self.number(tu["totalCents"])
    }

    static func number(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
}

enum CursorAPIError: LocalizedError {
    case unauthorized
    case http(Int, String)
    case badPayload(String)
    case paginationIncomplete

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "cursor.com rejected the session (401/403). Re-open Cursor to refresh its login."
        case .http(let c, let body): return "cursor.com returned HTTP \(c): \(body.prefix(160))"
        case .badPayload(let s): return "Unexpected response from cursor.com: \(s)"
        case .paginationIncomplete: return "Too many usage events to fetch this cycle; showing nothing rather than a partial total."
        }
    }
}

// MARK: - Client

/// Thin client for the undocumented dashboard endpoints. Bare host only —
/// the POST endpoints enforce `Origin: https://cursor.com` (www. fails CSRF).
struct CursorAPI {
    let cookieHeader: String
    let base = URL(string: "https://cursor.com")!

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Macintosh) CursorUsage/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CursorAPIError.badPayload("no HTTP response") }
        switch http.statusCode {
        case 200..<300:
            // Cursor answers an expired session on some GETs with 204 / empty body instead of 401.
            if data.isEmpty { throw CursorAPIError.unauthorized }
            return data
        case 401, 403:
            throw CursorAPIError.unauthorized
        default:
            throw CursorAPIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    func usageSummary() async throws -> UsageSummary {
        let data = try await send(try request("/api/usage-summary"))
        do {
            return try JSONDecoder().decode(UsageSummary.self, from: data)
        } catch {
            throw CursorAPIError.badPayload("usage-summary: \(error)")
        }
    }

    func usageSummaryRaw() async throws -> String {
        let data = try await send(try request("/api/usage-summary"))
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Fetches every usage event in [start, end]. Newest-first, paginated.
    func usageEvents(start: Date, end: Date, pageSize: Int = 1000, maxPages: Int = 100) async throws -> [UsageEvent] {
        var events: [UsageEvent] = []
        var expectedTotal: Int?
        for page in 1...maxPages {
            let body: [String: Any] = [
                "page": page,
                "pageSize": pageSize,
                "startDate": String(Int64((start.timeIntervalSince1970 * 1000).rounded())),
                "endDate": String(Int64((end.timeIntervalSince1970 * 1000).rounded())),
            ]
            let data = try await send(try request("/api/dashboard/get-filtered-usage-events", method: "POST", body: body))
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CursorAPIError.badPayload("events page \(page) is not an object")
            }
            if let err = obj["error"] as? String { throw CursorAPIError.badPayload(err) }
            let total = (obj["totalUsageEventsCount"] as? NSNumber)?.intValue
            if expectedTotal == nil { expectedTotal = total }
            let rows = obj["usageEventsDisplay"] as? [[String: Any]] ?? []
            if rows.isEmpty { return events }   // empty terminal page (array is omitted when empty)
            events.append(contentsOf: rows.compactMap(UsageEvent.init(json:)))
            if rows.count < pageSize { return events }
            if let expectedTotal, events.count >= expectedTotal { return events }
        }
        throw CursorAPIError.paginationIncomplete
    }

    /// First page, raw — for `--dump` field discovery.
    func usageEventsRaw(start: Date, end: Date, pageSize: Int = 25) async throws -> String {
        let body: [String: Any] = [
            "page": 1, "pageSize": pageSize,
            "startDate": String(Int64(start.timeIntervalSince1970 * 1000)),
            "endDate": String(Int64(end.timeIntervalSince1970 * 1000)),
        ]
        let data = try await send(try request("/api/dashboard/get-filtered-usage-events", method: "POST", body: body))
        return String(data: data, encoding: .utf8) ?? ""
    }
}
