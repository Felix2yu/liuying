import Foundation

/// Downie 历史记录里能被流影消费的一条记录。
///
/// 只有**原始页面 URL**是可执行的：它决定去重键，也是将来「重新下载」要用到的输入。
/// 标题仅用于队列显示；本地文件路径只作参考，不写进任务产出 —— 视频库靠扫盘建立索引，
/// 不能凭导出文件里的路径就认定本机一定有这个文件。
public struct DownieHistoryRecord: Sendable, Equatable {
    public var url: String
    public var title: String?
    public var filePath: String?

    public init(url: String, title: String? = nil, filePath: String? = nil) {
        self.url = url
        self.title = title
        self.filePath = filePath
    }
}

public enum DownieImportFormat: String, Sendable, Equatable {
    case xml
    case plist
    case csv
    case text

    public var displayName: String {
        switch self {
        case .xml: "XML"
        case .plist: "XML plist"
        case .csv: "CSV"
        case .text: "纯文本"
        }
    }
}

public enum DownieImportError: Error, Sendable, Equatable {
    case emptyFile
    case tooLarge(bytes: Int)
    case notText
    case malformedXML(String)
    case unrecognizedFormat
    case noRecords

    public var message: String {
        switch self {
        case .emptyFile:
            "文件是空的"
        case .tooLarge(let bytes):
            "文件太大（\(bytes / 1_048_576) MB）。导出时不要勾选「包含预览图」，或分批导出"
        case .notText:
            "这不是文本文件。请选择 Downie 导出的 XML / CSV / TXT"
        case .malformedXML(let detail):
            "XML 解析失败：\(detail)"
        case .unrecognizedFormat:
            "格式不匹配：不是 Downie 历史导出 XML、Downie 导入格式 XML/CSV，也不是链接清单。JSON 与二进制文件不支持"
        case .noRecords:
            "文件里没有可用的 http(s) 链接。Downie 的画质、字幕、后处理设置和预览图不能导入"
        }
    }
}

public struct DownieImportDocument: Sendable, Equatable {
    public var format: DownieImportFormat
    public var records: [DownieHistoryRecord]
    /// 有记录但没有可用 http(s) 链接的条目数（例如只有本地路径、或协议不是 http(s)）。
    public var skipped: Int

    public init(format: DownieImportFormat, records: [DownieHistoryRecord], skipped: Int = 0) {
        self.format = format
        self.records = records
        self.skipped = skipped
    }
}

/// 解析 Downie 的**导出文件**，而不是去读它的私有历史库。
///
/// 支持四类输入：
/// 1. `Downie History Export.xml`（Downie 4「窗口 → 显示历史记录 → 导出」）；
/// 2. Downie 官方文档定义的 `<downloads><download><url><title><path>` XML；
/// 3. XML plist（`<key>url</key><string>https://…</string>`）；
/// 4. Downie 官方 CSV（`url,title[,path]`）与每行一条链接的纯文本。
///
/// 刻意不读 `~/Library/Containers/com.charliemonroe.Downie-4/...`：那是别的 App 的沙盒，
/// 受 TCC 保护、格式未文档化、还会随 CloudKit 同步变化。由用户通过打开面板选文件，
/// 系统会自动授予该文件的访问权。
public enum DownieHistoryImporter {
    /// 带预览图的导出会很大；超过这个体积直接拒绝，避免把 base64 塞进解析器。
    public static let maxFileBytes = 32 * 1024 * 1024

    fileprivate static let xmlRoots: Set<String> = [
        "downloads", "downloadlist", "history", "historyitems", "downie",
        "items", "records", "queue", "array", "plist",
    ]

    public static func parse(
        data: Data,
        fileName: String = ""
    ) -> Result<DownieImportDocument, DownieImportError> {
        guard !data.isEmpty else { return .failure(.emptyFile) }
        guard data.count <= maxFileBytes else { return .failure(.tooLarge(bytes: data.count)) }

        let text = decode(data)
        guard let text else { return .failure(.notText) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyFile) }

        if trimmed.hasPrefix("<") {
            return parseXML(text)
        }
        // JSON / plist 之外的结构化文本一律拒绝，避免把随手一份配置误当成下载记录。
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return .failure(.unrecognizedFormat)
        }

        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let looksLikeCSV = firstLine.contains(",")
            && firstLine.lowercased().split(separator: ",").contains("url")
        if looksLikeCSV || fileName.lowercased().hasSuffix(".csv") {
            return parseCSV(text)
        }
        return parsePlainText(text)
    }

    // MARK: - 解码

    private static func decode(_ data: Data) -> String? {
        // isoLatin1 对任意字节都能解码，不能靠它是否成功判断「是不是文本」。
        // NUL 是二进制文件最可靠的信号，先挡掉。
        guard !data.contains(0) else { return nil }
        let candidates: [String.Encoding] = [.utf8, .utf16, .isoLatin1]
        for encoding in candidates {
            if var value = String(data: data, encoding: encoding) {
                if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
                return value
            }
        }
        return nil
    }

    // MARK: - XML

    private static func parseXML(_ text: String) -> Result<DownieImportDocument, DownieImportError> {
        let collector = XMLCollector()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = collector
        guard parser.parse() else {
            return .failure(.malformedXML(
                parser.parserError?.localizedDescription ?? "未知解析错误"
            ))
        }
        guard collector.sawStructure else { return .failure(.unrecognizedFormat) }
        guard !collector.records.isEmpty else { return .failure(.noRecords) }
        return .success(DownieImportDocument(
            format: collector.isPlist ? .plist : .xml,
            records: collector.records,
            skipped: collector.skipped
        ))
    }

    // MARK: - CSV

    private static func parseCSV(_ text: String) -> Result<DownieImportDocument, DownieImportError> {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first else { return .failure(.emptyFile) }
        let columns = csvRow(header).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        guard let urlIndex = columns.firstIndex(of: "url") else {
            return .failure(.unrecognizedFormat)
        }
        let titleIndex = columns.firstIndex(of: "title")
        let pathIndex = columns.firstIndex(of: "path")

        var records: [DownieHistoryRecord] = []
        var skipped = 0
        for line in lines.dropFirst() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let fields = csvRow(line)
            let raw = urlIndex < fields.count ? fields[urlIndex] : ""
            guard let url = firstHTTPURL(in: raw) else {
                skipped += 1
                continue
            }
            func field(_ index: Int?) -> String? {
                guard let index, index < fields.count else { return nil }
                let value = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            records.append(DownieHistoryRecord(
                url: url, title: field(titleIndex), filePath: field(pathIndex)
            ))
        }
        guard !records.isEmpty else { return .failure(.noRecords) }
        return .success(DownieImportDocument(format: .csv, records: records, skipped: skipped))
    }

    /// 支持引号包裹的字段（标题里常有逗号）。不追求完整 RFC 4180，够覆盖 Downie 的导出。
    static func csvRow(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = line.makeIterator()
        while let ch = chars.next() {
            if ch == "\"" {
                if inQuotes {
                    inQuotes = false
                } else {
                    inQuotes = true
                }
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - 纯文本

    private static func parsePlainText(_ text: String) -> Result<DownieImportDocument, DownieImportError> {
        // 用 find 而不是 extract：保留重复，让引擎统一统计「文件内重复」。
        let records = URLExtractor.find(in: text).map {
            DownieHistoryRecord(url: $0.url)
        }
        guard !records.isEmpty else { return .failure(.noRecords) }
        return .success(DownieImportDocument(format: .text, records: records))
    }

    // MARK: - 共用工具

    static func firstHTTPURL(in text: String) -> String? {
        URLExtractor.find(in: text).first?.url
    }
}

// MARK: - XML 收集器

/// 不假设 Downie 导出的确切 tag 名：按「URL 类字段 + 记录类元素」两条线索收集，
/// 兼容官方 `<downloads>/<download>` 格式与导出文件里可能出现的
/// `originalWebSiteURLString` / plist `<key>` 形式。
private final class XMLCollector: NSObject, XMLParserDelegate {
    private struct Fields {
        var urls: [String] = []
        var title: String?
        var path: String?
    }

    private static let recordNames: Set<String> = [
        "download", "downloaditem", "item", "historyitem", "entry", "record", "dict",
    ]
    private static let urlKeys: Set<String> = [
        "url", "originalwebsiteurlstring", "originalwebsitestring", "originalurl",
        "link", "href", "websiteurl", "webpageurl", "pageurl", "sourceurl", "page_url",
    ]
    private static let titleKeys: Set<String> = ["title", "name", "pagetitle", "videotitle", "filename"]
    private static let pathKeys: Set<String> = ["path", "filepath", "fileurl", "localpath", "destination"]

    private(set) var records: [DownieHistoryRecord] = []
    private(set) var skipped = 0
    private(set) var sawStructure = false
    private(set) var isPlist = false

    private var stack: [String] = []
    private var recordDepth: Int?
    private var fields = Fields()
    private var textBuffer = ""
    private var lastPlistKey: String?

    private static func normalized(_ raw: String) -> String {
        let tail = raw.split(separator: ":").last.map(String.init) ?? raw
        return tail.lowercased()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.normalized(elementName)
        stack.append(name)
        if stack.count == 1 {
            isPlist = name == "plist"
            if DownieHistoryImporter.xmlRoots.contains(name) { sawStructure = true }
        }
        if recordDepth == nil, Self.recordNames.contains(name) {
            recordDepth = stack.count
            fields = Fields()
            sawStructure = true
        }
        textBuffer = ""
        for (rawKey, value) in attributeDict {
            let key = Self.normalized(rawKey)
            if Self.urlKeys.contains(key) { collectURL(from: value) }
            if Self.titleKeys.contains(key), fields.title == nil { fields.title = clean(value) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8) { textBuffer += value }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = Self.normalized(elementName)
        let value = clean(textBuffer)

        if isPlist && name == "key" {
            lastPlistKey = value?.lowercased()
        }
        let plistURLValue = isPlist && name == "string"
            && lastPlistKey.map(Self.urlKeys.contains) == true

        if Self.urlKeys.contains(name) || plistURLValue {
            if let value { collectURL(from: value) }
            if plistURLValue { lastPlistKey = nil }
        }
        let plistTitleValue = isPlist && name == "string"
            && lastPlistKey.map(Self.titleKeys.contains) == true
        let plistPathValue = isPlist && name == "string"
            && lastPlistKey.map(Self.pathKeys.contains) == true
        if Self.titleKeys.contains(name) || plistTitleValue, fields.title == nil {
            fields.title = value
        }
        if Self.pathKeys.contains(name) || plistPathValue, fields.path == nil {
            fields.path = value
        }

        if let depth = recordDepth, depth == stack.count {
            finalizeRecord()
            recordDepth = nil
        }
        if !stack.isEmpty { stack.removeLast() }
        textBuffer = ""
    }

    private func collectURL(from raw: String) {
        let found = URLExtractor.find(in: raw).map(\.url)
        guard !found.isEmpty else { return }
        fields.urls.append(contentsOf: found)
        // 不在记录元素里的 URL（例如 <downloads><url> 或 plist 的顶层 <string>）直接成记录。
        if recordDepth == nil {
            for url in found { records.append(DownieHistoryRecord(url: url)) }
            fields.urls.removeAll()
        }
    }

    private func finalizeRecord() {
        guard !fields.urls.isEmpty else {
            skipped += 1
            fields = Fields()
            return
        }
        // 同一条记录里出现多个 URL 时，后续 URL 也保留（多 P / 转载页），
        // 由引擎按去重键决定是否重复。
        for (index, candidate) in fields.urls.enumerated() {
            records.append(DownieHistoryRecord(
                url: candidate,
                title: index == 0 ? fields.title : nil,
                filePath: index == 0 ? fields.path : nil
            ))
        }
        fields = Fields()
    }

    private func clean(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
