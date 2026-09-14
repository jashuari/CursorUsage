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
    /// SQLite could not get at the file itself (every fallback open was refused).
    case dbOpenFailed(code: Int32, message: String)
    /// SQLite opened the file but the token query failed.
    case dbQueryFailed(code: Int32, message: String)
    case tokenMissing
    case tokenExpired
    case tokenMalformed

    var errorDescription: String? {
        switch self {
        case .dbMissing(let p): return "Cursor.app state not found at \(p). Is Cursor installed and signed in?"
        case .dbOpenFailed(let code, let message):
            return "Could not open Cursor.app state database (SQLite \(code): \(message)). Open Cursor.app and try again."
        case .dbQueryFailed(let code, let message):
            return "Could not read Cursor.app state database (SQLite \(code): \(message)). Open Cursor.app and try again."
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

    private static let tokenKey = "cursorAuth/accessToken"
    private static let tokenSQL = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"

    /// One rung of the open ladder: what to hand `sqlite3_open_v2` and with which flags.
    struct OpenMode {
        let filename: String
        let flags: Int32
    }

    private enum Stage { case open, query }
    private struct SQLiteFailure {
        let stage: Stage
        let code: Int32
        let message: String
    }
    private enum FetchOutcome {
        case value(String)
        /// The query ran to completion and there simply is no such row.
        case noRow
        case failed(SQLiteFailure)
    }

    func read(now: Date = Date()) throws -> CursorSession {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw CursorAuthError.dbMissing(dbPath)
        }
        var lastFailure: SQLiteFailure?
        for mode in Self.openModes(for: dbPath) {
            switch fetchTokenValue(mode) {
            case .value(let raw):
                return try Self.session(fromStoredValue: raw, now: now)
            case .noRow:
                // SQLite answered; the row is absent. No other rung changes that.
                throw CursorAuthError.tokenMissing
            case .failed(let failure):
                lastFailure = failure
            }
        }
        let failure = lastFailure
            ?? SQLiteFailure(stage: .open, code: SQLITE_ERROR, message: "unknown error")
        switch failure.stage {
        case .open: throw CursorAuthError.dbOpenFailed(code: failure.code, message: failure.message)
        case .query: throw CursorAuthError.dbQueryFailed(code: failure.code, message: failure.message)
        }
    }

    /// Cursor's DB is in WAL mode. A read-only connection cannot create the `-shm`
    /// WAL index, so as soon as Cursor.app quits — it checkpoints and deletes
    /// `-wal`/`-shm` on exit — the plain read-only open fails at *prepare* time with
    /// SQLITE_CANTOPEN. Hence a ladder, cheapest and least invasive first:
    ///
    /// 1. read-only — the normal path while Cursor is running. No side effects.
    /// 2. read-only + `immutable=1` — reads the main database file alone, ignoring
    ///    WAL, taking no locks and creating no files. Correct precisely in the
    ///    Cursor-quit case, because a clean exit already checkpointed the WAL in.
    ///    (If Cursor instead *crashed* and left an orphan `-wal`, this can read a
    ///    slightly older token; that is harmless — it is either still valid or
    ///    reported as `.tokenExpired`, which tells the user to open Cursor.)
    /// 3. read-write — last resort, lets SQLite rebuild `-shm`. The only rung that
    ///    writes anything, and only SQLite's own sidecar files, never Cursor's data.
    static func openModes(for path: String) -> [OpenMode] {
        var modes = [OpenMode(filename: path, flags: SQLITE_OPEN_READONLY)]
        if let uri = immutableURI(for: path) {
            modes.append(OpenMode(filename: uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI))
        }
        modes.append(OpenMode(filename: path, flags: SQLITE_OPEN_READWRITE))
        return modes
    }

    /// `file:` URI with `immutable=1`. The real path contains spaces ("Application
    /// Support"), so let Foundation percent-encode it rather than splicing strings.
    /// Returns nil for anything that would not round-trip cleanly as a SQLite URI.
    static func immutableURI(for path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let encoded = URL(fileURLWithPath: path).absoluteString
        guard encoded.hasPrefix("file:///"),
              !encoded.contains("?"), !encoded.contains("#") else { return nil }
        return encoded + "?immutable=1"
    }

    private func fetchTokenValue(_ mode: OpenMode) -> FetchOutcome {
        var db: OpaquePointer?
        let orc = sqlite3_open_v2(mode.filename, &db, mode.flags, nil)
        guard orc == SQLITE_OK, db != nil else {
            let failure = Self.failure(stage: .open, code: orc, db: db)
            sqlite3_close(db)
            return .failed(failure)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        // Belt and braces: we only ever SELECT, including on the read-write rung.
        sqlite3_exec(db, "PRAGMA query_only = 1;", nil, nil, nil)

        var stmt: OpaquePointer?
        // NB: on a WAL database with no `-shm`, this — not the open above — is where
        // a read-only connection fails, with SQLITE_CANTOPEN.
        let prc = sqlite3_prepare_v2(db, Self.tokenSQL, -1, &stmt, nil)
        guard prc == SQLITE_OK, stmt != nil else {
            let failure = Self.failure(stage: .query, code: prc, db: db)
            sqlite3_finalize(stmt)
            return .failed(failure)
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, Self.tokenKey, -1, transient)

        switch sqlite3_step(stmt) {
        case SQLITE_ROW: break
        case SQLITE_DONE: return .noRow
        case let src: return .failed(Self.failure(stage: .query, code: src, db: db))
        }

        switch sqlite3_column_type(stmt, 0) {
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, 0) else { return .noRow }
            return .value(String(cString: c))
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, 0))
            let ptr = sqlite3_column_blob(stmt, 0)
            let data = n > 0 && ptr != nil ? Data(bytes: ptr!, count: n) : Data()
            return .value(Self.decodeBlob(data))
        default:
            return .noRow
        }
    }

    /// SQLITE_CANTOPEN is a file-access problem wherever it surfaces, so report it
    /// as such even when it comes back from prepare or step.
    private static func failure(stage: Stage, code: Int32, db: OpaquePointer?) -> SQLiteFailure {
        let stage: Stage = (code & 0xFF) == SQLITE_CANTOPEN ? .open : stage
        return SQLiteFailure(stage: stage, code: code, message: errorMessage(code, db))
    }

    private static func errorMessage(_ code: Int32, _ db: OpaquePointer?) -> String {
        if let db, let msg = sqlite3_errmsg(db) { return String(cString: msg) }
        if let msg = sqlite3_errstr(code) { return String(cString: msg) }
        return "unknown error"
    }

    /// Turns the raw stored column value into a validated session.
    static func session(fromStoredValue raw: String, now: Date) throws -> CursorSession {
        // The value may be stored bare or JSON-quoted.
        let jwt = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        guard !jwt.isEmpty else { throw CursorAuthError.tokenMissing }

        guard let claims = parseJWTClaims(jwt), let userID = userID(fromSub: claims.sub) else {
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
