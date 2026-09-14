import SQLite3
import XCTest
@testable import CursorUsage

/// Fixtures are built from scratch in a temp directory. Nothing here ever touches
/// the real `~/Library/Application Support/Cursor` database.
final class CursorAuthTests: XCTestCase {
    private var tempDir: URL!
    private var dbPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A space in the directory name mirrors "Application Support" and keeps the
        // URI-building path honest.
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Cursor Usage Tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbPath = tempDir.appendingPathComponent("state.vscdb").path
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    // MARK: - Reading the database

    func testReadsTokenWhileWALSidecarsArePresent() throws {
        try makeWALDatabase(value: .text(Self.jwt(sub: "auth0|user_abc", expiresIn: 3600)))
        // Hold a connection open so `-wal`/`-shm` exist, as they do while Cursor runs.
        let keeper = try openKeeper()
        defer { sqlite3_close(keeper) }
        XCTAssertTrue(sidecarsExist, "fixture should have -wal/-shm while a connection is open")

        let session = try CursorAuthReader(dbPath: dbPath).read()
        XCTAssertEqual(session.userID, "user_abc")
    }

    /// The regression under test: Cursor.app quits, checkpoints, and deletes its
    /// `-wal`/`-shm`. A plain `SQLITE_OPEN_READONLY` connection then fails at
    /// prepare time with SQLITE_CANTOPEN because it cannot create the WAL index.
    func testReadsTokenAfterCursorQuitRemovedWALSidecars() throws {
        try makeWALDatabase(value: .text(Self.jwt(sub: "auth0|user_abc", expiresIn: 3600)))
        try removeSidecars()
        XCTAssertFalse(sidecarsExist)

        let session = try CursorAuthReader(dbPath: dbPath).read()
        XCTAssertEqual(session.userID, "user_abc")
        // The `immutable=1` rung should have served this, leaving the directory
        // exactly as Cursor left it.
        XCTAssertFalse(sidecarsExist, "reading must not create SQLite sidecar files")
    }

    func testMissingDatabaseThrowsDBMissing() {
        let path = tempDir.appendingPathComponent("nope.vscdb").path
        assertThrows(CursorAuthReader(dbPath: path)) { error in
            guard case .dbMissing(let p) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(p, path)
        }
    }

    func testDatabaseWithoutTokenRowThrowsTokenMissing() throws {
        try makeWALDatabase(value: nil)
        try removeSidecars()
        assertThrows(CursorAuthReader(dbPath: dbPath)) { error in
            guard case .tokenMissing = error else { return XCTFail("got \(error)") }
        }
    }

    func testExpiredTokenThrowsTokenExpired() throws {
        // Stored as UTF-16LE blob, the way some Cursor builds write it.
        let jwt = Self.jwt(sub: "auth0|user_abc", expiresIn: -60)
        try makeWALDatabase(value: .blob(Data(jwt.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })))
        try removeSidecars()
        assertThrows(CursorAuthReader(dbPath: dbPath)) { error in
            guard case .tokenExpired = error else { return XCTFail("got \(error)") }
        }
    }

    func testGarbageTokenThrowsTokenMalformed() throws {
        try makeWALDatabase(value: .text("not-a-jwt"))
        try removeSidecars()
        assertThrows(CursorAuthReader(dbPath: dbPath)) { error in
            guard case .tokenMalformed = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: - Open ladder

    func testOpenModesLadderOrder() {
        let modes = CursorAuthReader.openModes(for: "/tmp/Application Support/state.vscdb")
        XCTAssertEqual(modes.count, 3)
        XCTAssertEqual(modes[0].flags, SQLITE_OPEN_READONLY)
        XCTAssertEqual(modes[1].flags, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
        XCTAssertEqual(modes[2].flags, SQLITE_OPEN_READWRITE)
    }

    func testImmutableURIPercentEncodesSpaces() {
        let uri = CursorAuthReader.immutableURI(for: "/tmp/Application Support/state.vscdb")
        XCTAssertEqual(uri, "file:///tmp/Application%20Support/state.vscdb?immutable=1")
        XCTAssertNil(CursorAuthReader.immutableURI(for: "relative/state.vscdb"))
    }

    // MARK: - Pure helpers

    func testParseJWTClaims() {
        let exp = Date(timeIntervalSince1970: 1_800_000_000)
        let claims = CursorAuthReader.parseJWTClaims(Self.jwt(sub: "auth0|user_abc", exp: exp))
        XCTAssertEqual(claims?.sub, "auth0|user_abc")
        XCTAssertEqual(claims?.exp, exp)

        XCTAssertNil(CursorAuthReader.parseJWTClaims("only.two"))
        XCTAssertNil(CursorAuthReader.parseJWTClaims("a.b.c"))
        XCTAssertNil(CursorAuthReader.parseJWTClaims(""))
        // Well-formed base64url payload, but missing the claims we need.
        XCTAssertNil(CursorAuthReader.parseJWTClaims(Self.jwt(payload: ["sub": "x"])))
        XCTAssertNil(CursorAuthReader.parseJWTClaims(Self.jwt(payload: ["exp": 1_800_000_000])))
    }

    func testParseJWTClaimsHandlesUnpaddedBase64URL() {
        // Pad the sub until the base64url payload needs each of the 3 pad lengths.
        for extra in 0..<3 {
            let sub = "user_" + String(repeating: "a", count: extra)
            let claims = CursorAuthReader.parseJWTClaims(Self.jwt(sub: sub, expiresIn: 60))
            XCTAssertEqual(claims?.sub, sub, "padding case \(extra)")
        }
    }

    func testUserIDFromSub() {
        XCTAssertEqual(CursorAuthReader.userID(fromSub: "auth0|user_abc"), "user_abc")
        XCTAssertEqual(CursorAuthReader.userID(fromSub: "user_abc"), "user_abc")
        XCTAssertEqual(CursorAuthReader.userID(fromSub: "a|b|user-01.x"), "user-01.x")
        XCTAssertNil(CursorAuthReader.userID(fromSub: ""))
        XCTAssertNil(CursorAuthReader.userID(fromSub: "auth0|"))
        XCTAssertNil(CursorAuthReader.userID(fromSub: "auth0|user abc"))
        XCTAssertNil(CursorAuthReader.userID(fromSub: "auth0|user/abc"))
        XCTAssertNil(CursorAuthReader.userID(fromSub: "auth0|user%3Aabc"))
    }

    func testDecodeBlob() {
        XCTAssertEqual(CursorAuthReader.decodeBlob(Data("hello".utf8)), "hello")
        // BOM-less UTF-16LE: ASCII with interleaved NULs.
        let utf16 = Data([0x68, 0x00, 0x69, 0x00])
        XCTAssertEqual(CursorAuthReader.decodeBlob(utf16), "hi")
        XCTAssertEqual(CursorAuthReader.decodeBlob(Data()), "")
        // Multi-byte UTF-8 must not be mistaken for UTF-16LE.
        XCTAssertEqual(CursorAuthReader.decodeBlob(Data("héllo".utf8)), "héllo")
    }

    // MARK: - Fixtures

    private enum StoredValue {
        case text(String)
        case blob(Data)
    }

    private var sidecarsExist: Bool {
        FileManager.default.fileExists(atPath: dbPath + "-wal")
            || FileManager.default.fileExists(atPath: dbPath + "-shm")
    }

    /// Builds a WAL-mode `ItemTable` database, optionally holding the token row.
    private func makeWALDatabase(value: StoredValue?) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        try XCTUnwrap(rc == SQLITE_OK ? true : nil, "open fixture db rc=\(rc)")
        defer { sqlite3_close(db) }
        try exec(db, "PRAGMA journal_mode=WAL;")
        try exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);")
        try exec(db, "INSERT INTO ItemTable VALUES ('someOtherKey', 'ignored');")

        guard let value else { return }
        var stmt: OpaquePointer?
        let prc = sqlite3_prepare_v2(db, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', ?);", -1, &stmt, nil)
        try XCTUnwrap(prc == SQLITE_OK ? true : nil, "prepare insert rc=\(prc)")
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch value {
        case .text(let s):
            sqlite3_bind_text(stmt, 1, s, -1, transient)
        case .blob(let d):
            _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(d.count), transient) }
        }
        let src = sqlite3_step(stmt)
        try XCTUnwrap(src == SQLITE_DONE ? true : nil, "insert rc=\(src)")
    }

    /// A live read-write connection, which materializes `-wal`/`-shm`.
    private func openKeeper() throws -> OpaquePointer? {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        try XCTUnwrap(rc == SQLITE_OK ? true : nil, "open keeper rc=\(rc)")
        try exec(db, "SELECT count(*) FROM ItemTable;")
        return db
    }

    /// What a clean Cursor.app exit leaves behind: the main file and nothing else.
    private func removeSidecars() throws {
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: dbPath + suffix) {
            try FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        try XCTUnwrap(rc == SQLITE_OK ? true : nil, "exec \(sql) rc=\(rc)")
    }

    private func assertThrows(
        _ reader: CursorAuthReader,
        now: Date = Date(),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: (CursorAuthError) -> Void
    ) {
        XCTAssertThrowsError(try reader.read(now: now), file: file, line: line) { error in
            guard let authError = error as? CursorAuthError else {
                return XCTFail("expected CursorAuthError, got \(error)", file: file, line: line)
            }
            check(authError)
        }
    }

    // MARK: - JWT construction (clearly fake signature)

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func jwt(payload: [String: Any]) -> String {
        let header = base64URL(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        let body = base64URL((try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
        let signature = base64URL(Data("fake-test-signature".utf8))
        return "\(header).\(body).\(signature)"
    }

    private static func jwt(sub: String, exp: Date) -> String {
        jwt(payload: ["sub": sub, "exp": Int(exp.timeIntervalSince1970)])
    }

    private static func jwt(sub: String, expiresIn seconds: TimeInterval) -> String {
        jwt(sub: sub, exp: Date().addingTimeInterval(seconds))
    }
}
