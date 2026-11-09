import XCTest
@testable import LiuYingCore

final class ShellWordTests: XCTestCase {
    func testSplitPlainWords() {
        XCTAssertEqual(ShellWord.split("--batch -q 127"), ["--batch", "-q", "127"])
    }

    func testSplitQuotedPathWithSpaces() {
        XCTAssertEqual(
            ShellWord.split("--tmp-dir '/Users/x/My Work/task 1'"),
            ["--tmp-dir", "/Users/x/My Work/task 1"]
        )
    }

    func testSplitDoubleQuoteEscapes() {
        XCTAssertEqual(ShellWord.split(#"a "b\"c" d"#), ["a", "b\"c", "d"])
    }

    func testSplitEmptyQuotedWordIsPreserved() {
        XCTAssertEqual(ShellWord.split("a '' b"), ["a", "", "b"])
    }

    func testUnmatchedQuoteReturnsNil() {
        XCTAssertNil(ShellWord.split("a 'unterminated"))
        XCTAssertNil(ShellWord.split(#"a "unterminated"#))
    }

    func testTrailingBackslashReturnsNil() {
        XCTAssertNil(ShellWord.split("abc\\"))
    }

    func testJoinSplitRoundTrip() {
        let words = ["--tp", "{owner_uname}/{title}", "-x", "http://127.0.0.1:6152", "a b", "it's", ""]
        XCTAssertEqual(ShellWord.split(ShellWord.join(words)), words)
    }

    func testJoinLeavesSimpleWordsUnquoted() {
        XCTAssertEqual(ShellWord.join(["--batch", "-q", "127"]), "--batch -q 127")
    }
}

final class SubprocessTests: XCTestCase {
    func testEchoCapturesStdout() {
        let result = Subprocess.runBlocking(
            executable: "/bin/echo", arguments: ["你好", "liuying"],
            environment: Subprocess.environment()
        )
        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "你好 liuying")
    }

    func testMissingExecutableReportsNotLaunched() {
        let result = Subprocess.runBlocking(
            executable: "/nonexistent/binary-xyz", arguments: [],
            environment: Subprocess.environment()
        )
        XCTAssertFalse(result.launched)
        XCTAssertFalse(result.stderr.isEmpty)
    }

    func testTimeoutTerminatesSleep() {
        let start = Date()
        let result = Subprocess.runBlocking(
            executable: "/bin/sleep", arguments: ["30"],
            environment: Subprocess.environment(), timeout: 0.5
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }

    func testExtraEnvCannotClobberPATH() {
        let env = Subprocess.environment(extra: ["PATH": "/evil", "LIUYING_TEST": "1"])
        XCTAssertEqual(env["PATH"], Subprocess.enhancedPATH)
        XCTAssertEqual(env["LIUYING_TEST"], "1")
    }

    func testEnhancedPATHContainsHomebrewAndLocalBin() {
        XCTAssertTrue(Subprocess.enhancedPATH.contains("/opt/homebrew/bin"))
        XCTAssertTrue(Subprocess.enhancedPATH.contains(".local/bin"))
    }

    func testCurrentDirectoryIsHonored() {
        let dir = NSTemporaryDirectory() + "liuying-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = Subprocess.runBlocking(
            executable: "/bin/pwd", arguments: [],
            environment: Subprocess.environment(), currentDirectory: dir
        )
        // /tmp 会符号链接到 /private/tmp，两边都标准化后比较。
        let reported = (result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .resolvingSymlinksInPath
        let expected = (dir as NSString).resolvingSymlinksInPath
        XCTAssertEqual(reported, expected)
    }

    func testStreamingReceivesLinesAndFlushesUnterminatedTail() {
        let box = LineBox()
        let result = Subprocess.runBlocking(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'first\\nsecond\\n'; printf 'tail-no-newline'"],
            environment: Subprocess.environment(),
            onOutputLine: { line in box.append(line) }
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(box.lines, ["first", "second", "tail-no-newline"])
    }

    func testStreamingSplitsMultibyteCharactersAcrossChunks() {
        let box = LineBox()
        // 用 dd 把一行中文切成 1 字节小块，逼出跨 chunk 的多字节边界。
        let result = Subprocess.runBlocking(
            executable: "/bin/sh",
            arguments: ["-c", "printf '编码优先级 av1 > hevc\\n' | dd bs=1 2>/dev/null"],
            environment: Subprocess.environment(),
            onOutputLine: { line in box.append(line) }
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(box.lines, ["编码优先级 av1 > hevc"])
    }

    func testHandleCancelTerminatesRunningProcess() {
        let handle = ProcessHandle()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { handle.cancel() }
        let start = Date()
        let result = Subprocess.runBlocking(
            executable: "/bin/sleep", arguments: ["30"],
            environment: Subprocess.environment(), timeout: 20, handle: handle
        )
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }

    func testLookupOnPATHFindsSystemBinary() {
        XCTAssertEqual(Subprocess.lookupOnPATH("echo"), "/bin/echo")
        XCTAssertNil(Subprocess.lookupOnPATH("definitely-not-a-real-binary-xyz"))
    }

    private final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) {
            lock.lock(); storage.append(line); lock.unlock()
        }
        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }
}

final class SQLiteDatabaseTests: XCTestCase {
    private var path: String!

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "liuying-db-\(UUID().uuidString).sqlite"
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        super.tearDown()
    }

    func testBindAndQuery() throws {
        let db = try SQLiteDatabase(path: path)
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL);")
        try db.run("INSERT INTO t (name, score) VALUES (?, ?);", [.text("全角「测试」"), .double(1.5)])
        let row = try XCTUnwrap(db.queryOne("SELECT * FROM t;"))
        XCTAssertEqual(row.text("name"), "全角「测试」")
        XCTAssertEqual(row.double("score"), 1.5)
        XCTAssertEqual(row.int("id"), 1)
    }

    func testBindingPreventsInjection() throws {
        let db = try SQLiteDatabase(path: path)
        try db.exec("CREATE TABLE t (name TEXT);")
        let evil = "'); DROP TABLE t; --"
        try db.run("INSERT INTO t VALUES (?);", [.text(evil)])
        XCTAssertEqual(try db.queryOne("SELECT name FROM t;")?.text("name"), evil)
    }

    func testTransactionRollsBackOnError() throws {
        let db = try SQLiteDatabase(path: path)
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT UNIQUE);")
        try db.run("INSERT INTO t (name) VALUES (?);", [.text("a")])
        struct Boom: Error {}
        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO t (name) VALUES (?);", [.text("b")])
            throw Boom()
        })
        XCTAssertEqual(try db.query("SELECT * FROM t;").count, 1)
    }

    func testUserVersionPersists() throws {
        do {
            let db = try SQLiteDatabase(path: path)
            XCTAssertEqual(db.userVersion, 0)
            db.userVersion = 7
        }
        let reopened = try SQLiteDatabase(path: path)
        XCTAssertEqual(reopened.userVersion, 7)
    }

    func testReadOnlyRejectsWrites() throws {
        do {
            let db = try SQLiteDatabase(path: path)
            try db.exec("CREATE TABLE t (name TEXT);")
            try db.run("INSERT INTO t VALUES (?);", [.text("seed")])
        }
        let readOnly = try SQLiteDatabase(path: path, readOnly: true)
        XCTAssertTrue(readOnly.readOnly)
        XCTAssertEqual(try readOnly.queryOne("SELECT name FROM t;")?.text("name"), "seed")
        XCTAssertThrowsError(try readOnly.run("INSERT INTO t VALUES (?);", [.text("nope")]))
    }

    func testNullHandling() throws {
        let db = try SQLiteDatabase(path: path)
        try db.exec("CREATE TABLE t (a TEXT, b INTEGER);")
        try db.run("INSERT INTO t VALUES (?, ?);", [.text(nil), .int(nil)])
        let row = try XCTUnwrap(db.queryOne("SELECT * FROM t;"))
        XCTAssertNil(row.text("a"))
        XCTAssertNil(row.int("b"))
        XCTAssertEqual(row[SQLValueKey.a], SQLValue.null)
    }

    private enum SQLValueKey {
        static let a = "a"
    }
}