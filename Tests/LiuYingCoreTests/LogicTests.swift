import XCTest
@testable import LiuYingCore

final class URLExtractorTests: XCTestCase {
    func testExtractsPlainVideoURL() {
        let urls = URLExtractor.extract(from: "看看这个 https://www.bilibili.com/video/BV1GJ411x7h7 不错")
        XCTAssertEqual(urls, ["https://www.bilibili.com/video/BV1GJ411x7h7"])
    }

    func testConcatenatedURLsWithoutNewlineAreSplit() {
        // iOS 快捷指令漏写换行时两条 URL 会粘成一条。负向前瞻就是为了这个。
        let text = "https://b23.tv/abc123https://b23.tv/def456"
        XCTAssertEqual(
            URLExtractor.extract(from: text),
            ["https://b23.tv/abc123", "https://b23.tv/def456"]
        )
    }

    func testStripsTrailingCJKPunctuation() {
        let cases: [(String, String)] = [
            ("https://b23.tv/abc123。", "https://b23.tv/abc123"),
            ("https://b23.tv/abc123，", "https://b23.tv/abc123"),
            ("https://b23.tv/abc123；", "https://b23.tv/abc123"),
            ("https://b23.tv/abc123）", "https://b23.tv/abc123"),
            ("https://b23.tv/abc123】", "https://b23.tv/abc123"),
            ("https://b23.tv/abc123.", "https://b23.tv/abc123"),
            ("https://b23.tv/abc123;", "https://b23.tv/abc123"),
            ("https://b23.tv/abc123)", "https://b23.tv/abc123"),
            ("https://b23.tv/abc123]", "https://b23.tv/abc123"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(URLExtractor.extract(from: input), [expected], "输入：\(input)")
        }
    }

    func testExtractsNonBilibiliURLsToo() {
        // 抓取面是所有 http(s) 链接；B 站之外的交给 Downie。
        let text = """
        https://www.youtube.com/watch?v=x
        https://www.xiaohongshu.com/explore/abc
        https://evil.com/bilibili.com
        """
        XCTAssertEqual(URLExtractor.extract(from: text).count, 3)
    }

    func testClassifiesBilibiliHosts() {
        XCTAssertTrue(URLExtractor.isBilibiliHost("https://b23.tv/abc"))
        XCTAssertTrue(URLExtractor.isBilibiliHost("https://www.bilibili.com/video/BV1GJ411x7h7"))
        XCTAssertTrue(URLExtractor.isBilibiliHost("https://bilibili.com/x"))
        XCTAssertTrue(URLExtractor.isBilibiliHost("https://bilibili.tv/zh/x"))
        XCTAssertFalse(URLExtractor.isBilibiliHost("https://m.bilibili.com/video/BV1"))
        XCTAssertFalse(URLExtractor.isBilibiliHost("https://www.xiaohongshu.com/explore/abc"))
        XCTAssertFalse(URLExtractor.isBilibiliHost("https://evil.com/bilibili.com"))
    }

    func testRejectsNonHTTPURLs() {
        let text = ["ftp://example.com/a", "file:///etc/passwd", "mailto:a@b.com"].joined(separator: " ")
        XCTAssertEqual(URLExtractor.extract(from: text), [])
    }

    func testAcceptsAllFourHosts() {
        let text = """
        https://b23.tv/a
        https://www.bilibili.com/video/BV1GJ411x7h7
        https://bilibili.com/video/BV1GJ411x7h7
        https://bilibili.tv/zh/video/BV1GJ411x7h7
        """
        XCTAssertEqual(URLExtractor.extract(from: text).count, 4)
    }

    func testUppercaseSchemeIsAccepted() {
        XCTAssertEqual(
            URLExtractor.extract(from: "HTTPS://B23.TV/abc123"),
            ["HTTPS://B23.TV/abc123"]
        )
    }

    func testDeduplicatesWithinOneCall() {
        let text = """
        https://b23.tv/abc123
        https://b23.tv/abc123
        """
        XCTAssertEqual(URLExtractor.extract(from: text), ["https://b23.tv/abc123"])
    }

    func testQueryStringAfterVideoPathIsKept() {
        let url = "https://www.bilibili.com/video/BV1GJ411x7h7?spm_id_from=333.999&vd_source=abc"
        XCTAssertEqual(URLExtractor.extract(from: url), [url])
    }

    func testNoURLsReturnsEmpty() {
        XCTAssertEqual(URLExtractor.extract(from: "今天天气不错\n没有链接"), [])
        XCTAssertEqual(URLExtractor.extract(from: ""), [])
    }
}

final class CanonicalKeyTests: XCTestCase {
    func testExtractsBVFromAnyForm() {
        XCTAssertEqual(
            CanonicalKey.localKey("https://www.bilibili.com/video/BV1GJ411x7h7?spm=x"),
            "BV1GJ411x7h7"
        )
        XCTAssertEqual(CanonicalKey.localKey("BV1GJ411x7h7"), "BV1GJ411x7h7")
    }

    func testExtractsAVWithBoundaries() {
        XCTAssertEqual(CanonicalKey.localKey("https://www.bilibili.com/video/av170001"), "av170001")
        XCTAssertEqual(CanonicalKey.localKey("https://www.bilibili.com/av170001?x=1"), "av170001")
        XCTAssertNil(CanonicalKey.localKey("https://www.bilibili.com/video/xav170001"))
    }

    func testShortLinkHasNoLocalKey() {
        XCTAssertNil(CanonicalKey.localKey("https://b23.tv/abc123"))
    }

    func testBVIDExtractionFromRedirectTarget() {
        XCTAssertEqual(
            CanonicalKey.bvid(in: "https://www.bilibili.com/video/BV1p8nh61Efm/?share_source=copy"),
            "BV1p8nh61Efm"
        )
        XCTAssertNil(CanonicalKey.bvid(in: "https://www.bilibili.com/"))
    }

    func testBVRequiresAtLeastTenBodyChars() {
        XCTAssertNil(CanonicalKey.localKey("https://www.bilibili.com/video/BV1GJ411x7h"))
        // 旧版用 search 取前 12 个字符，更长的串按前缀识别，行为保持一致。
        XCTAssertEqual(CanonicalKey.localKey("https://www.bilibili.com/video/BV1GJ411x7h7x"), "BV1GJ411x7h7")
    }
}

final class YuttoArgsTests: XCTestCase {
    private let url = "https://www.bilibili.com/video/BV1GJ411x7h7"

    func testDefaultArgvSnapshot() {
        let args = YuttoArgs.build(
            config: YuttoConfig(),
            url: url,
            downloadDir: "/Downloads/Bilibili",
            workDir: "/support/work/task-7",
            authFileExists: false,
            binaryPath: "/Users/yufei/.local/bin/yutto"
        )
        XCTAssertEqual(args, [
            "/Users/yufei/.local/bin/yutto",
            "--batch",
            url,
            "-d", "/Downloads/Bilibili",
            "--no-progress", "--no-color",
            "--tmp-dir", "/support/work/task-7",
            "-q", "127",
            "-aq", "30280",
            "--vcodec", "av1:copy",
            "--download-vcodec-priority", "av1,hevc,avc",
            "--output-format", "mp4",
            "-tp", "{owner_uname}/{title}",
            "--no-danmaku",
            "--no-subtitle",
            "--no-cover",
        ])
    }

    func testAllTogglesInverted() {
        var config = YuttoConfig()
        config.downloadAllPages = false
        config.downloadDanmaku = true
        config.downloadSubtitle = true
        config.saveCover = true
        let args = YuttoArgs.build(
            config: config, url: url, downloadDir: "/d",
            binaryPath: "yutto"
        )
        XCTAssertFalse(args.contains("--batch"))
        XCTAssertFalse(args.contains("--no-danmaku"))
        XCTAssertFalse(args.contains("--no-subtitle"))
        XCTAssertTrue(args.contains("--save-cover"))
        XCTAssertFalse(args.contains("--tmp-dir"))
    }

    func testAuthFileFlagsOnlyWhenFileExists() {
        let without = YuttoArgs.build(
            config: YuttoConfig(), url: url, downloadDir: "/d", authFileExists: false, binaryPath: "yutto"
        )
        XCTAssertFalse(without.contains("--auth-file"))
        XCTAssertFalse(without.contains("--auth-profile"))

        let with = YuttoArgs.build(
            config: YuttoConfig(), url: url, downloadDir: "/d", authFileExists: true, binaryPath: "yutto"
        )
        XCTAssertTrue(with.contains("--auth-file"))
        XCTAssertTrue(with.contains("--auth-profile"))
        XCTAssertTrue(with.contains(AppIdentity.expand("~/.config/yutto/auth.toml")))
    }

    func testExtraArgsAppendedVerbatimAtEnd() {
        var config = YuttoConfig()
        config.extraArgs = ["--proxy", "http://127.0.0.1:6152", "-n", "4"]
        let args = YuttoArgs.build(
            config: config, url: url, downloadDir: "/d", binaryPath: "yutto"
        )
        XCTAssertEqual(Array(args.suffix(4)), ["--proxy", "http://127.0.0.1:6152", "-n", "4"])
    }

    func testEmptyOptionalValuesAreOmitted() {
        var config = YuttoConfig()
        config.vcodec = ""
        config.vcodecPriority = []
        config.outputFormat = ""
        config.subpathTemplate = ""
        config.videoQuality = 0
        config.audioQuality = 0
        let args = YuttoArgs.build(config: config, url: url, downloadDir: "/d", binaryPath: "yutto")
        for flag in ["--vcodec", "--download-vcodec-priority", "--output-format", "-tp", "-q", "-aq"] {
            XCTAssertFalse(args.contains(flag), "\(flag) 不该出现")
        }
    }
}

final class ContainerPolicyTests: XCTestCase {
    private let policy = ["av1": "mkv", "hevc": "mov", "avc": "mp4"]

    func testNormalizesAVCSpellings() {
        XCTAssertEqual(ContainerPolicy.normalizeVideoCodec("avc1"), "avc")
        XCTAssertEqual(ContainerPolicy.normalizeVideoCodec("H264"), "avc")
        XCTAssertEqual(ContainerPolicy.normalizeVideoCodec("HEVC"), "hevc")
        XCTAssertEqual(ContainerPolicy.normalizeVideoCodec("av1"), "av1")
    }

    func testAV1GoesToMKV() {
        XCTAssertEqual(
            ContainerPolicy.targetContainer(
                vcodec: "av1", acodec: "opus", policy: policy, currentExtension: "mp4"
            ),
            "mkv"
        )
    }

    func testHEVCGoesToMOV() {
        XCTAssertEqual(
            ContainerPolicy.targetContainer(
                vcodec: "hevc", acodec: "aac", policy: policy, currentExtension: "mp4"
            ),
            "mov"
        )
    }

    func testAVCStaysMP4() {
        XCTAssertNil(ContainerPolicy.targetContainer(
            vcodec: "h264", acodec: "aac", policy: policy, currentExtension: "mp4"
        ))
    }

    func testLosslessAudioForcesMKVForMP4Target() {
        XCTAssertEqual(
            ContainerPolicy.targetContainer(
                vcodec: "h264", acodec: "flac", policy: policy, currentExtension: "mp4"
            ),
            "mkv"
        )
        for codec in ContainerPolicy.losslessAudioCodecs {
            XCTAssertEqual(
                ContainerPolicy.targetContainer(
                    vcodec: "avc1", acodec: codec, policy: policy, currentExtension: "mp4"
                ),
                "mkv",
                codec
            )
        }
    }

    func testAlreadyCorrectExtensionReturnsNil() {
        XCTAssertNil(ContainerPolicy.targetContainer(
            vcodec: "av1", acodec: "opus", policy: policy, currentExtension: "MKV"
        ))
    }

    func testEmptyPolicyOrFailedProbeIsPassthrough() {
        XCTAssertNil(ContainerPolicy.targetContainer(
            vcodec: "av1", acodec: "opus", policy: [:], currentExtension: "mp4"
        ))
        XCTAssertNil(ContainerPolicy.targetContainer(
            vcodec: "", acodec: "aac", policy: policy, currentExtension: "mp4"
        ))
        XCTAssertNil(ContainerPolicy.targetContainer(
            vcodec: "vp9", acodec: "aac", policy: policy, currentExtension: "webm"
        ))
    }

    func testRemuxArgumentsForAV1() {
        let args = ContainerPolicy.remuxArguments(
            source: "/d/a.mp4", destination: "/d/a.mkv",
            videoCodec: "av1", audioCodec: "opus", targetExtension: "mkv"
        )
        XCTAssertEqual(args, ["-y", "-i", "/d/a.mp4", "-c:v", "copy", "-c:a", "copy", "/d/a.mkv"])
    }

    func testRemuxArgumentsForHEVCToMOV() {
        let args = ContainerPolicy.remuxArguments(
            source: "/d/a.mp4", destination: "/d/a.mov",
            videoCodec: "hevc", audioCodec: "aac", targetExtension: "mov"
        )
        XCTAssertEqual(
            args,
            ["-y", "-i", "/d/a.mp4", "-c:v", "copy", "-c:a", "copy", "-tag:v", "hvc1", "/d/a.mov"]
        )
    }

    func testRemuxArgumentsForMP4AddsFaststart() {
        let args = ContainerPolicy.remuxArguments(
            source: "/d/a.mkv", destination: "/d/a.mp4",
            videoCodec: "avc", audioCodec: "aac", targetExtension: "mp4"
        )
        XCTAssertEqual(args.suffix(3), ["-movflags", "+faststart", "/d/a.mp4"])
    }

    func testRemuxArgumentsTranscodesLosslessAudioOnlyForMP4Family() {
        let mp4 = ContainerPolicy.remuxArguments(
            source: "/d/a.mkv", destination: "/d/a.mp4",
            videoCodec: "avc", audioCodec: "flac", targetExtension: "mp4"
        )
        XCTAssertTrue(mp4.contains("-c:a"))
        XCTAssertTrue(mp4.contains("aac"))

        let mkv = ContainerPolicy.remuxArguments(
            source: "/d/a.mp4", destination: "/d/a.mkv",
            videoCodec: "av1", audioCodec: "flac", targetExtension: "mkv"
        )
        XCTAssertEqual(Array(mkv[5..<7]), ["-c:a", "copy"])
    }
}

final class LinkPrunerTests: XCTestCase {
    private let bv1 = "https://www.bilibili.com/video/BV1GJ411x7h7"
    private let bv2 = "https://www.bilibili.com/video/BV1p8nh61Efm"

    func testEmptyConsumedIsIdentity() {
        let text = "\(bv1)\n\(bv2)\n"
        let outcome = LinkPruner.prune(text: text, consumed: [])
        XCTAssertEqual(outcome.text, text)
        XCTAssertFalse(outcome.changed)
    }

    func testUnrelatedLinesAreByteIdentical() {
        let text = "第 1 行\n\(bv1)\n第 3 行有全角标点「测试」：ok\n\(bv2)"
        let outcome = LinkPruner.prune(text: text, consumed: [bv1])
        XCTAssertEqual(outcome.text, "第 1 行\n第 3 行有全角标点「测试」：ok\n\(bv2)")
        XCTAssertEqual(outcome.removedLines, 1)
    }

    func testSameURLOnTwoLinesBothRemoved() {
        let text = "\(bv1)\n中间\n\(bv1)\n"
        let outcome = LinkPruner.prune(text: text, consumed: [bv1])
        XCTAssertEqual(outcome.text, "中间\n")
        XCTAssertEqual(outcome.removedLines, 2)
    }

    func testCRLFIsPreserved() {
        let text = "a\r\n\(bv1)\r\nb\r\n"
        let outcome = LinkPruner.prune(text: text, consumed: [bv1])
        XCTAssertEqual(outcome.text, "a\r\nb\r\n")
        XCTAssertEqual(outcome.text.utf8.filter { $0 == 0x0D }.count, 2, "CR 不能被吞掉")
    }

    func testLoneCarriageReturnIsPreserved() {
        let text = "a\r\(bv1)\rb\r"
        let outcome = LinkPruner.prune(text: text, consumed: [bv1])
        XCTAssertEqual(outcome.text, "a\rb\r")
    }

    func testMixedLineEndingsAreEachPreserved() {
        let text = "a\n\(bv2)\r\nb\r"
        let outcome = LinkPruner.prune(text: text, consumed: [bv2])
        XCTAssertEqual(outcome.text, "a\nb\r")
    }

    func testBOMIsPreserved() {
        let text = "\u{FEFF}a\n\(bv1)\n"
        let outcome = LinkPruner.prune(text: text, consumed: [bv1])
        XCTAssertEqual(outcome.text, "\u{FEFF}a\n")
    }

    func testMissingFinalNewlineIsNotInvented() {
        let text = "a\n\(bv1)"
        let outcome = LinkPruner.prune(text: text, consumed: [bv1])
        XCTAssertEqual(outcome.text, "a\n")
    }

    func testURLInsideProseKeepsProse() {
        let text = "分享 \(bv1) 好看\n"
        let outcome = LinkPruner.prune(text: text, consumed: [bv1])
        XCTAssertEqual(outcome.text, "分享 好看\n")
        XCTAssertEqual(outcome.removedLines, 0)
        XCTAssertEqual(outcome.modifiedLines, 1)
        XCTAssertEqual(outcome.removedURLs, 1)
    }

    func testMixedConsumedAndKeptOnOneLine() {
        let text = "\(bv1) \(bv2)\n"
        let outcome = LinkPruner.prune(text: text, consumed: [bv1])
        XCTAssertEqual(outcome.text, "\(bv2)\n")
        XCTAssertEqual(outcome.removedURLs, 1)
    }

    func testCanonicalKeyMatchesURLWithParams() {
        let withParams = "https://www.bilibili.com/video/BV1GJ411x7h7?spm_id_from=333.999"
        let outcome = LinkPruner.prune(text: "\(withParams)\n", consumed: ["BV1GJ411x7h7"])
        XCTAssertEqual(outcome.text, "")
    }

    func testConsumedRawShortLinkIsRemoved() {
        let short = "https://b23.tv/abc123"
        let outcome = LinkPruner.prune(text: "\(short)\n\(bv1)\n", consumed: [short])
        XCTAssertEqual(outcome.text, "\(bv1)\n")
    }

    func testPreviewListsTouchedLines() {
        let text = "\(bv1)\n分享 \(bv2) 好看\n"
        let outcome = LinkPruner.prune(text: text, consumed: [bv1, bv2])
        XCTAssertEqual(outcome.previews.count, 2)
        XCTAssertEqual(outcome.removedLines, 1)
        XCTAssertEqual(outcome.modifiedLines, 1)
    }

    func testEmptyLinesAndWhitespaceOnlyLinesSurvive() {
        let text = "\n\n   \n\(bv1)\n\n"
        let outcome = LinkPruner.prune(text: text, consumed: [bv1])
        XCTAssertEqual(outcome.text, "\n\n   \n\n")
    }

    func testIndentedURLOnlyLineIsDroppedEntirely() {
        let outcome = LinkPruner.prune(text: "  \(bv1)  \nkeep\n", consumed: [bv1])
        XCTAssertEqual(outcome.text, "keep\n")
    }
}

final class TOMLReaderTests: XCTestCase {
    func testReadsProfileTable() {
        let text = """
        # yutto 登录态
        [profiles.default]
        sessdata = "abc%2C123"
        bili_jct = "deadbeef"
        updated_at = 1760000000
        """
        let tables = TOMLReader.parse(text)
        XCTAssertEqual(tables["profiles.default"]?["sessdata"], "abc%2C123")
        XCTAssertEqual(tables["profiles.default"]?["bili_jct"], "deadbeef")
        XCTAssertEqual(tables["profiles.default"]?["updated_at"], "1760000000")
    }

    func testCommentInsideQuotesIsNotAComment() {
        let tables = TOMLReader.parse(#"[a]"# + "\n" + #"k = "value # not comment""#)
        XCTAssertEqual(tables["a"]?["k"], "value # not comment")
    }

    func testValueContainingEqualsSign() {
        let tables = TOMLReader.parse("[a]\nk = \"x=y=z\"")
        XCTAssertEqual(tables["a"]?["k"], "x=y=z")
    }

    func testLiteralStringAndBareValue() {
        let tables = TOMLReader.parse("[a]\nlit = 'raw\\n'\nnum = 42\nflag = true")
        XCTAssertEqual(tables["a"]?["lit"], "raw\\n")
        XCTAssertEqual(tables["a"]?["num"], "42")
        XCTAssertEqual(tables["a"]?["flag"], "true")
    }

    func testNestedTablePath() {
        let tables = TOMLReader.parse("[basic]\ndir = \"/x\"\n\n[auth]\nauth_profile = \"p\"")
        XCTAssertEqual(tables["basic"]?["dir"], "/x")
        XCTAssertEqual(tables["auth"]?["auth_profile"], "p")
    }

    func testCRLFLineEndings() {
        let tables = TOMLReader.parse("[profiles.default]\r\nsessdata = \"S\"\r\n")
        XCTAssertEqual(tables["profiles.default"]?["sessdata"], "S")
    }
}

final class AuthFileTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "liuying-auth-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func write(_ text: String, name: String = "auth.toml") -> String {
        let path = (directory as NSString).appendingPathComponent(name)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testReadsSessdataFromDefaultProfile() {
        let path = write("[profiles.default]\nsessdata = \"SECRET1\"\nbili_jct = \"j\"\n")
        XCTAssertEqual(AuthFile.sessdata(path: path, profile: "default"), "SECRET1")
    }

    func testReadsUppercaseAlias() {
        let path = write("[profiles.default]\nSESSDATA = \"SECRET2\"\n")
        XCTAssertEqual(AuthFile.sessdata(path: path, profile: "default"), "SECRET2")
    }

    func testSelectsNamedProfile() {
        let path = write("[profiles.default]\nsessdata = \"A\"\n[profiles.alt]\nsessdata = \"B\"\n")
        XCTAssertEqual(AuthFile.sessdata(path: path, profile: "alt"), "B")
        XCTAssertEqual(AuthFile.sessdata(path: path, profile: "missing"), nil)
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(AuthFile.sessdata(path: directory + "/nope.toml", profile: "default"))
        XCTAssertFalse(AuthFile.exists(path: directory + "/nope.toml"))
    }

    func testOverrideWinsOverFile() {
        let path = write("[profiles.default]\nsessdata = \"FROM_FILE\"\n")
        XCTAssertEqual(
            AuthFile.resolveSessdata(override: "FROM_SETTINGS", path: path, profile: "default"),
            "FROM_SETTINGS"
        )
        XCTAssertEqual(
            AuthFile.resolveSessdata(override: "  ", path: path, profile: "default"),
            "FROM_FILE"
        )
    }
}

final class LibraryPathTests: XCTestCase {
    private let root = "/Users/x/Downloads/Bilibili"

    private func parse(_ relative: String) -> LibraryVideo? {
        LibraryPath.parse(
            path: root + "/" + relative, root: root, bytes: 1024, modified: Date(timeIntervalSince1970: 0)
        )
    }

    func testParsesOwnerAndEmojiTitle() {
        let item = parse("白依Baii/🖤拜托 什么叫黑白通吃啊🤍.mkv")
        XCTAssertEqual(item?.owner, "白依Baii")
        XCTAssertEqual(item?.title, "🖤拜托 什么叫黑白通吃啊🤍")
        XCTAssertEqual(item?.container, "mkv")
    }

    func testParsesFullWidthPunctuationInTitle() {
        let item = parse("萌爱moi/四种风格一次看够！：全角「测试」.mp4")
        XCTAssertEqual(item?.title, "四种风格一次看够！：全角「测试」")
    }

    func testParsesDashPageLabel() {
        let item = parse("UP主 😀/标题：全角「测试」 - 01 - 分P名.mkv")
        XCTAssertEqual(item?.title, "标题：全角「测试」")
        XCTAssertEqual(item?.pageLabel, "01 · 分P名")
        XCTAssertEqual(item?.displayTitle, "标题：全角「测试」 · P01 · 分P名")
    }

    func testParsesTrailingParenPageLabel() {
        let item = parse("UP/标题(3).mp4")
        XCTAssertEqual(item?.title, "标题")
        XCTAssertEqual(item?.pageLabel, "3")
    }

    /// yutto 的真实多 P 命名：P1 无后缀，P2 起是 `标题 (1).mkv`（括号前有一个空格）。
    func testParsesRealYuttoMultiPartNaming() {
        let item = parse("黑马程序员/AI 名词课，什么是 LLM、Token、Agent？ (1).mkv")
        XCTAssertEqual(item?.title, "AI 名词课，什么是 LLM、Token、Agent？")
        XCTAssertEqual(item?.pageLabel, "1")
    }

    func testFileAtRootHasNoOwner() {
        let item = parse("散装视频.mp4")
        XCTAssertNil(item?.owner)
        XCTAssertEqual(item?.title, "散装视频")
    }

    func testRejectsNonMediaFiles() {
        XCTAssertNil(parse("UP/.DS_Store"))
        XCTAssertNil(parse("UP/标题.jpg"))
        XCTAssertNil(parse("UP/标题.nfo"))
        XCTAssertNil(parse("UP/标题.ass"))
    }

    func testSiblingDirectoryWithSharedPrefixIsNotTreatedAsRoot() {
        let item = LibraryPath.parse(
            path: "/Users/x/Downloads/Bilibili2/UP/a.mp4",
            root: root, bytes: 1, modified: Date()
        )
        // 不在 root 下：整条路径都算相对路径，第一段是 Users。
        XCTAssertNotEqual(item?.owner, "UP")
    }

    func testBytesAndModifiedAreCarried() {
        let item = parse("UP/a.mkv")
        XCTAssertEqual(item?.bytes, 1024)
        XCTAssertEqual(item?.modified, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(item?.fileName, "a.mkv")
    }
}

final class ConfigTests: XCTestCase {
    func testDefaultsMatchLegacyPython() {
        let config = AppConfig()
        XCTAssertEqual(config.pollInterval, 15)
        XCTAssertEqual(config.downloadDir, "~/Downloads/Bilibili")
        XCTAssertEqual(config.bilibiliBackend, .yutto)
        XCTAssertEqual(config.otherBackend, .downie, "非 B 站链接默认走 Downie")
        XCTAssertEqual(config.maxTasksPerRound, 20)
        XCTAssertTrue(config.notify)
        XCTAssertEqual(config.yutto.videoQuality, 127)
        XCTAssertEqual(config.yutto.audioQuality, 30_280)
        XCTAssertEqual(config.yutto.vcodec, "av1:copy")
        XCTAssertEqual(config.yutto.vcodecPriority, ["av1", "hevc", "avc"])
        XCTAssertEqual(config.yutto.outputFormat, "mp4")
        XCTAssertEqual(config.yutto.subpathTemplate, "{owner_uname}/{title}")
        XCTAssertTrue(config.yutto.downloadAllPages)
        XCTAssertFalse(config.yutto.downloadDanmaku)
        XCTAssertFalse(config.yutto.downloadSubtitle)
        XCTAssertFalse(config.yutto.saveCover)
        XCTAssertEqual(config.yutto.authFile, "~/.config/yutto/auth.toml")
        XCTAssertEqual(config.yutto.authProfile, "default")
        XCTAssertEqual(config.yutto.outputContainers, ["av1": "mkv", "hevc": "mov", "avc": "mp4"])
        XCTAssertEqual(config.downie.appName, "Downie 4")
        XCTAssertEqual(config.downie.postprocessing, "mp4")
        XCTAssertFalse(config.clipboardMonitor)
    }

    func testDecodesLegacyConfigJSON() throws {
        let json = """
        {
          "watch_file": "",
          "poll_interval": 20,
          "download_dir": "~/Movies/Bili",
          "bilibili_backend": "downie",
          "other_backend": "yutto",
          "notify": false,
          "yutto": {
            "binary": "/Users/yufei/.local/bin/yutto",
            "video_quality": 120,
            "vcodec_priority": ["hevc", "av1", "avc"],
            "extra_args": ["-x", "auto"]
          },
          "downie": {"app_name": "Downie", "postprocessing": "audio"}
        }
        """
        let config = try AppConfig.decode(fromJSON: Data(json.utf8))
        XCTAssertEqual(config.pollInterval, 20)
        XCTAssertEqual(config.downloadDir, "~/Movies/Bili")
        XCTAssertEqual(config.bilibiliBackend, .downie)
        XCTAssertEqual(config.otherBackend, .yutto)
        XCTAssertFalse(config.notify)
        XCTAssertEqual(config.yutto.binary, "/Users/yufei/.local/bin/yutto")
        XCTAssertEqual(config.yutto.videoQuality, 120)
        XCTAssertEqual(config.yutto.vcodecPriority, ["hevc", "av1", "avc"])
        XCTAssertEqual(config.yutto.extraArgs, ["-x", "auto"])
        XCTAssertEqual(config.downie.appName, "Downie")
        XCTAssertEqual(config.downie.postprocessing, "audio")
        // 未出现的键保持默认
        XCTAssertEqual(config.yutto.audioQuality, 30_280)
        XCTAssertTrue(config.yutto.downloadAllPages)
    }

    func testPartialAndMalformedFieldsFallBackToDefaults() throws {
        let json = """
        {"poll_interval": "not-a-number", "other_backend": "bogus", "yutto": {"video_quality": null}}
        """
        let config = try AppConfig.decode(fromJSON: Data(json.utf8))
        XCTAssertEqual(config.pollInterval, 15)
        XCTAssertEqual(config.bilibiliBackend, .yutto)
        XCTAssertEqual(config.otherBackend, .downie, "畸形值应退回默认")
        XCTAssertEqual(config.yutto.videoQuality, 127)
    }

    func testRoundTrip() throws {
        var config = AppConfig()
        config.watchFile = "/tmp/links.txt"
        config.pollInterval = 60
        config.yutto.extraArgs = ["--proxy", "auto"]
        config.yutto.outputContainers = ["av1": "mkv"]
        let decoded = try AppConfig.decode(fromJSON: config.encodedJSON())
        XCTAssertEqual(decoded, config)
    }

    func testNormalizeClampsAndFills() {
        var config = AppConfig()
        config.pollInterval = 1
        config.maxTasksPerRound = 0
        config.subscriptionInterval = 5
        config.yuttoTimeout = 1
        config.downloadDir = "   "
        config.yutto.vcodecPriority = []
        config.yutto.subpathTemplate = "  "
        config.normalize()
        XCTAssertEqual(config.pollInterval, 5)
        XCTAssertEqual(config.maxTasksPerRound, 1)
        XCTAssertEqual(config.subscriptionInterval, 60)
        XCTAssertEqual(config.yuttoTimeout, 60)
        XCTAssertEqual(config.downloadDir, "~/Downloads/Bilibili")
        XCTAssertEqual(config.yutto.vcodecPriority, ["av1", "hevc", "avc"])
        XCTAssertEqual(config.yutto.subpathTemplate, "{owner_uname}/{title}")
    }

    func testBackendRoutingByHost() {
        var config = AppConfig()
        XCTAssertEqual(config.backend(for: "https://www.bilibili.com/video/BV1GJ411x7h7"), .yutto)
        XCTAssertEqual(config.backend(for: "https://b23.tv/abc123"), .yutto)
        XCTAssertEqual(config.backend(for: "https://bilibili.tv/zh/video/BV1GJ411x7h7"), .yutto)
        XCTAssertEqual(config.backend(for: "https://www.xiaohongshu.com/explore/abc"), .downie)
        XCTAssertEqual(config.backend(for: "https://xhslink.com/a/abc"), .downie)
        XCTAssertEqual(config.backend(for: "https://x.com/i/status/1"), .downie)

        // 两个方向都能由用户改
        config.bilibiliBackend = .downie
        config.otherBackend = .yutto
        XCTAssertEqual(config.backend(for: "https://b23.tv/abc"), .downie)
        XCTAssertEqual(config.backend(for: "https://example.com/a"), .yutto)
    }

    func testRoutingSurvivesRoundTrip() throws {
        var config = AppConfig()
        config.otherBackend = .yutto
        let decoded = try AppConfig.decode(fromJSON: config.encodedJSON())
        XCTAssertEqual(decoded.backend(for: "https://example.com"), .yutto)
    }

    func testQualityOptionTablesMatchYutto() {
        XCTAssertEqual(YuttoQuality.videoOptions.first?.value, 127)
        XCTAssertEqual(YuttoQuality.audioOptions.first?.value, 30_251)
        XCTAssertTrue(YuttoQuality.videoOptions.contains { $0.value == 116 })
        XCTAssertEqual(YuttoQuality.videoLabel(127), "127 · 8K")
        XCTAssertEqual(YuttoQuality.audioLabel(99_999), "99999")
    }
}
final class ShareTextTests: XCTestCase {
    /// 真实分享文案：标题在【】里，链接后面挂着 vd_source 追踪参数。
    private let shareText = "【给孩子做了一个半飞行的玩具车】https://www.bilibili.com/video/BV1QUW46oEuT?vd_source=6201f106793887d0ae2bb2a58c19b20f"

    func testExtractsURLFromShareText() {
        XCTAssertEqual(
            URLExtractor.extract(from: shareText),
            ["https://www.bilibili.com/video/BV1QUW46oEuT?vd_source=6201f106793887d0ae2bb2a58c19b20f"]
        )
    }

    func testShareTextRoutesToYutto() {
        let config = AppConfig()
        let url = try! XCTUnwrap(URLExtractor.extract(from: shareText).first)
        XCTAssertTrue(URLExtractor.isBilibiliHost(url))
        XCTAssertEqual(config.backend(for: url), .yutto)
        XCTAssertEqual(CanonicalKey.localKey(url), "BV1QUW46oEuT")
    }

    func testDifferentTrackingParamsShareOneKey() {
        // 同一个视频以不同 vd_source / spm 分享多次，去重键必须一致，否则会重复下载。
        let a = "https://www.bilibili.com/video/BV1QUW46oEuT?vd_source=aaa"
        let b = "https://www.bilibili.com/video/BV1QUW46oEuT?spm_id_from=333.999"
        let c = "https://b23.tv/BV1QUW46oEuT"
        XCTAssertEqual(CanonicalKey.localKey(a), CanonicalKey.localKey(b))
        XCTAssertEqual(CanonicalKey.localKey(b), CanonicalKey.localKey(c))
    }

    func testTitleInBracketsIsNotPartOfURL() {
        let text = "【标题里有逗号，也有空格】 https://www.bilibili.com/video/BV1QUW46oEuT"
        XCTAssertEqual(
            URLExtractor.extract(from: text),
            ["https://www.bilibili.com/video/BV1QUW46oEuT"]
        )
    }
}
