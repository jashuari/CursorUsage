import Foundation
import SQLite3

/// A dashboard session synthesized from Cursor.app's own login state.
struct CursorSession: Equatable {
    let userID: String
    let accessToken: String
    let expiresAt: Date

    /// `WorkosCursorSessionToken=<userId>%3A%3A<jwt>` — the separator is written
    /// pre-percent-encoded and must NOT be encoded again.
    var cookieHeader: String { "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)" }
}

enum CursorAuthError: LocalizedError {
    case dbMissing(String)
    case dbOpenFailed
    case tokenMissing
    case tokenExpired
    case tokenMalformed

    var errorDescription: String? {
        switch self {
        case .dbMissing(let p): return "Cursor.app state not found at \(p). Is Cursor installed and signed in?"
        case .dbOpenFailed: return "Could not open Cursor.app state database."
        case .tokenMissing: return "No access token in Cursor.app state. Sign in to Cursor first."
        case .tokenExpired: return "Cursor.app token is expired. Open Cursor so it refreshes its session."
        case .tokenMalformed: return "Cursor.app token could not be parsed."
        }
    }
}

/// Reads `cursorAuth/accessToken` from Cursor's VS Code-style global state DB.
/// Read-only, opened and closed per call. Cursor.app keeps the token fresh; we
/// simply re-read it on every refresh (no refresh-token exchange — the IDE owns that).
struct CursorAuthReader {
    static let defaultDBPath = NSHomeDirectory()
        + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

    var dbPath: String = defaultDBPath

    func read(now: Date = Date()) throws -> CursorSession {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw CursorAuthError.dbMissing(dbPath)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CursorAuthError.dbOpenFailed
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CursorAuthError.dbOpenFailed
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, "cursorAuth/accessToken", -1, transient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { throw CursorAuthError.tokenMissing }

        let raw: String
        switch sqlite3_column_type(stmt, 0) {
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, 0) else { throw CursorAuthError.tokenMissing }
            raw = String(cString: c)
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, 0))
            let ptr = sqlite3_column_blob(stmt, 0)
            let data = n > 0 && ptr != nil ? Data(bytes: ptr!, count: n) : Data()
            raw = Self.decodeBlob(data)
        default:
            throw CursorAuthError.tokenMissing
        }
        // The value may be stored bare or JSON-quoted.
        let jwt = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        guard !jwt.isEmpty else { throw CursorAuthError.tokenMissing }

        guard let claims = Self.parseJWTClaims(jwt), let userID = Self.userID(fromSub: claims.sub) else {
            throw CursorAuthError.tokenMalformed
        }
        guard claims.exp > now.addingTimeInterval(60) else { throw CursorAuthError.tokenExpired }
        return CursorSession(userID: userID, accessToken: jwt, expiresAt: claims.exp)
    }

    /// Some Cursor builds store the value as BOM-less UTF-16LE (ASCII with interleaved NULs).
    static func decodeBlob(_ data: Data) -> String {
        if data.count >= 2, data[0] >= 1, data[0] < 128, data[1] == 0,
           let s = String(data: data, encoding: .utf16LittleEndian) {
            return s
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func parseJWTClaims(_ jwt: String) -> (sub: String, exp: Date)? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String,
              let exp = json["exp"] as? TimeInterval
        else { return nil }
        return (sub, Date(timeIntervalSince1970: exp))
    }

    /// WorkOS subs look like `auth0|user_xxx`; the cookie wants the part after the last pipe.
    static func userID(fromSub sub: String) -> String? {
        let id: String
        if let idx = sub.lastIndex(of: "|") {
            id = String(sub[sub.index(after: idx)...])
        } else {
            id = sub
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !id.isEmpty, id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return id
    }
}
