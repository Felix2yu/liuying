import XCTest
@testable import LiuYingCore

/// 设置页「旧版 Python 服务」只在旧服务仍存在或仍有可恢复备份时出现，
/// 这里锁定「备份是否存在」的判定规则。
final class LegacyServiceBackupTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "liuying-legacy-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func write(_ name: String) {
        FileManager.default.createFile(
            atPath: (directory as NSString).appendingPathComponent(name),
            contents: Data()
        )
    }

    func testFindsDisabledPlistBackup() {
        write("\(LegacyService.label).plist.disabled-20261120-081500")
        XCTAssertTrue(LegacyService.hasDisabledBackup(in: directory))
    }

    func testIgnoresInstalledPlistAndUnrelatedFiles() {
        write("\(LegacyService.label).plist")
        write("\(LegacyService.label)-other.plist.disabled-20261120-081500")
        write("com.example.other.plist.disabled-20261120-081500")
        XCTAssertFalse(LegacyService.hasDisabledBackup(in: directory))
    }

    func testMissingDirectoryMeansNoBackup() {
        let missing = (directory as NSString).appendingPathComponent("missing")
        XCTAssertFalse(LegacyService.hasDisabledBackup(in: missing))
    }
}
