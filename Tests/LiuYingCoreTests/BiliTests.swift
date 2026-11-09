import XCTest
@testable import LiuYingCore

final class WBISignerTests: XCTestCase {
    /// 黄金向量，取自 bili-history/internal/biliapi/client_unit_test.go:18-22。
    func testMixinKeyGoldenVector() {
        let input = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_-"
        XCTAssertEqual(input.count, 64)
        let img = String(input.prefix(32))
        let sub = String(input.suffix(32))
        XCTAssertEqual(WBISigner.mixinKey(imgKey: img, subKey: sub), "KLscRix6pOk5WdJ91HfN7jGt32oDmCFn")
    }

    func testMixinKeyOutputsExactly32Bytes() {
        let key = WBISigner.mixinKey(
            imgKey: "0123456789abcdef0123456789abcdef",
            subKey: "fedcba9876543210fedcba9876543210"
        )
        XCTAssertEqual(key.utf8.count, 32)
    }

    func testEncTableIsAPermutationOf0To63() {
        XCTAssertEqual(WBISigner.encTab.count, 64)
        XCTAssertEqual(Set(WBISigner.encTab), Set(0..<64))
    }

    func testFormEscapeMatchesGoQueryEscape() {
        XCTAssertEqual(WBISigner.formEscape("av1,hevc,avc"), "av1%2Chevc%2Cavc")
        XCTAssertEqual(WBISigner.formEscape("a b"), "a+b")
        XCTAssertEqual(WBISigner.formEscape("*"), "%2A")
        XCTAssertEqual(WBISigner.formEscape("~"), "~")
        XCTAssertEqual(WBISigner.formEscape("-_.~"), "-_.~")
        XCTAssertEqual(WBISigner.formEscape("中"), "%E4%B8%AD")
        XCTAssertEqual(WBISigner.formEscape("a+b"), "a%2Bb")
        XCTAssertEqual(WBISigner.formEscape("a/b"), "a%2Fb")
        XCTAssertEqual(WBISigner.formEscape("a&b=c"), "a%26b%3Dc")
        XCTAssertEqual(WBISigner.formEscape("'"), "%27")
    }

    func testSanitizeStripsOnlyTheFiveCharacters() {
        XCTAssertEqual(WBISigner.sanitize("a!b'c(d)e*f"), "abcdef")
        XCTAssertEqual(WBISigner.sanitize("a b,c;d"), "a b,c;d")
    }

    func testKeyFromURLTakesFilenameWithoutExtension() {
        XCTAssertEqual(
            WBISigner.keyFromURL("https://i0.hdslb.com/bfs/wbi/7cd08494123abc.png"),
            "7cd08494123abc"
        )
        XCTAssertNil(WBISigner.keyFromURL(""))
    }

    func testSignedQueryShapeAndDeterminism() {
        let params = ["mid": "42", "pn": "1", "ps": "49", "order": "pubdate"]
        let query = WBISigner.sign(params: params, mixinKey: "0123456789abcdef0123456789abcd", timestamp: 1_700_000_000)
        // 键按 UTF-8 字节序：mid < order < pn < ps < wts，w_rid 永远在最后。
        XCTAssertTrue(query.hasPrefix("mid=42&order=pubdate&pn=1&ps=49&wts=1700000000&w_rid="))
        XCTAssertEqual(query.components(separatedBy: "&w_rid=").count, 2)
        let wRid = query.components(separatedBy: "&w_rid=")[1]
        XCTAssertEqual(wRid.count, 32)
        XCTAssertTrue(wRid.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        let again = WBISigner.sign(params: params, mixinKey: "0123456789abcdef0123456789abcd", timestamp: 1_700_000_000)
        XCTAssertEqual(query, again)
    }

    func testSignatureChangesWithParameters() {
        let base = WBISigner.sign(params: ["mid": "42"], mixinKey: "k", timestamp: 1)
        let other = WBISigner.sign(params: ["mid": "43"], mixinKey: "k", timestamp: 1)
        XCTAssertNotEqual(base, other)
    }

    func testSanitizedValuesAreWhatGetSigned() {
        // 值里的 * 必须既参与签名也从发出的 query 里消失。
        let query = WBISigner.sign(params: ["k": "a*b"], mixinKey: "k", timestamp: 1)
        XCTAssertTrue(query.hasPrefix("k=ab&wts=1&w_rid="))
    }

    func testKeysAreSortedByUTF8BytesNotUnicodeCollation() {
        // UTF-8 字节序里大写字母排在小写之前；Unicode 归一化比较可能给出别的顺序。
        let query = WBISigner.sign(params: ["Zeta": "1", "aaa": "2"], mixinKey: "k", timestamp: 1)
        XCTAssertTrue(query.hasPrefix("Zeta=1&aaa=2&"))
    }
}

final class BiliModelDecodingTests: XCTestCase {
    func testVideoFromArcSearchRow() {
        let raw: [String: Any] = [
            "bvid": "BV1GJ411x7h7",
            "aid": NSNumber(value: 123456),
            "title": "标题",
            "pic": "https://i0.hdslb.com/x.jpg",
            "length": "03:45",
            "created": NSNumber(value: 1_700_000_000),
        ]
        let video = BiliClient.video(from: raw)
        XCTAssertEqual(video?.bvid, "BV1GJ411x7h7")
        XCTAssertEqual(video?.aid, 123456)
        XCTAssertEqual(video?.title, "标题")
        XCTAssertEqual(video?.length, "03:45")
        XCTAssertEqual(video?.created, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(video?.pageURL, "https://www.bilibili.com/video/BV1GJ411x7h7")
    }

    func testVideoRowWithoutBVIDIsRejected() {
        XCTAssertNil(BiliClient.video(from: ["title": "没有 bvid"]))
        XCTAssertNil(BiliClient.video(from: ["bvid": ""]))
    }

    func testNumericFieldsAcceptBothNumberAndString() {
        XCTAssertEqual(BiliClient.int64(NSNumber(value: 42)), 42)
        XCTAssertEqual(BiliClient.int64("42"), 42)
        XCTAssertNil(BiliClient.int64("not a number"))
        XCTAssertNil(BiliClient.int64(nil))
    }

    func testRiskControlErrorsAreClassified() {
        XCTAssertTrue(BiliError.riskControl(code: -352, message: "x").isRiskControl)
        XCTAssertTrue(BiliError.riskControl(code: -412, message: "x").isRiskControl)
        XCTAssertFalse(BiliError.api(code: -404, message: "x").isRiskControl)
        XCTAssertFalse(BiliError.http(500, "").isRiskControl)
        XCTAssertTrue(BiliError.http(412, "").isRiskControl)
    }
}

final class BiliClientOfflineTests: XCTestCase {
    func testHasSessdataReflectsTrimming() async {
        let client = BiliClient(sessdata: "  ")
        var has = await client.hasSessdata
        XCTAssertFalse(has)

        await client.updateSessdata("SECRET")
        has = await client.hasSessdata
        XCTAssertTrue(has)

        await client.updateSessdata(nil)
        has = await client.hasSessdata
        XCTAssertFalse(has)
    }
}