import Foundation

/// 从 links.txt 里删掉已消费的链接。
///
/// 定位：**卫生行为，不是正确性关键路径**。即使删失败，URL 在任务表里已有 UNIQUE 键，
/// 重新采集也是 no-op。所以这里宁可保守放弃一轮，也不冒覆盖 iPhone 并发追加的风险。
public enum LinkPruner {
    public struct Outcome: Sendable, Equatable {
        public var text: String
        /// 整行被删掉的行数。
        public var removedLines: Int
        /// 被抠掉的 URL 个数（含同一行里的多个）。
        public var removedURLs: Int
        /// 行保留了、只抠掉链接的行数。
        public var modifiedLines: Int
        /// 被删/被改的原始行（去首尾空白），给预览用。
        public var previews: [String]

        public var changed: Bool { removedURLs > 0 }

        public static let unchanged = Outcome(
            text: "", removedLines: 0, removedURLs: 0, modifiedLines: 0, previews: []
        )
    }

    /// - Parameter consumed: 已消费的集合。调用方应同时放入原始 URL 和 canonical key
    ///   （BV/av），这样短链和它的完整链接会一起被清掉。
    public static func prune(text: String, consumed: Set<String>) -> Outcome {
        guard !consumed.isEmpty else {
            return Outcome(text: text, removedLines: 0, removedURLs: 0, modifiedLines: 0, previews: [])
        }

        let bom = "\u{FEFF}"
        let hadBOM = text.hasPrefix(bom)
        let body = hadBOM ? String(text.dropFirst()) : text

        var output = ""
        var removedLines = 0
        var removedURLs = 0
        var modifiedLines = 0
        var previews: [String] = []

        for line in splitLines(body) {
            let found = URLExtractor.find(in: line.content)
            guard !found.isEmpty else {
                // 没有链接的行逐字节原样复制。
                output += line.content + line.terminator
                continue
            }

            let consumedSpans = found.filter { isConsumed($0.url, consumed) }
            guard !consumedSpans.isEmpty else {
                output += line.content + line.terminator
                continue
            }

            // 按顺序拼未消费片段，避免在 String 上做会失效的索引删除。
            var pieces: [String] = []
            var cursor = line.content.startIndex
            for item in found where isConsumed(item.url, consumed) {
                pieces.append(String(line.content[cursor..<item.range.lowerBound]))
                cursor = item.range.upperBound
            }
            pieces.append(String(line.content[cursor...]))
            let remaining = pieces.joined()

            removedURLs += consumedSpans.count
            let trimmedOriginal = line.content.trimmingCharacters(in: .whitespaces)

            if remaining.trimmingCharacters(in: .whitespaces).isEmpty {
                // 整行只有已消费链接（可能带空白）→ 连终止符一起删掉。
                removedLines += 1
                previews.append(trimmedOriginal)
                continue
            }

            // 行内还有别的文字：只抠链接，收敛空白后保留。
            modifiedLines += 1
            previews.append(trimmedOriginal)
            output += normalizeKeptLine(remaining) + line.terminator
        }

        return Outcome(
            text: hadBOM ? bom + output : output,
            removedLines: removedLines,
            removedURLs: removedURLs,
            modifiedLines: modifiedLines,
            previews: previews
        )
    }

    static func isConsumed(_ url: String, _ consumed: Set<String>) -> Bool {
        if consumed.contains(url) { return true }
        if let key = CanonicalKey.localKey(url), consumed.contains(key) { return true }
        return false
    }

    /// 被修改过的行允许收敛空白：把连续空白压成一个空格并去掉首尾空白。
    /// 未修改的行不受影响，仍然逐字节相同。
    static func normalizeKeptLine(_ line: String) -> String {
        var result = ""
        var lastWasSpace = false
        for ch in line {
            if ch == " " || ch == "\t" {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(ch)
                lastWasSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    struct TextLine: Sendable, Equatable {
        var content: String
        var terminator: String
    }

    /// 按行切分但保留 `\n` / `\r\n` / `\r`。文本末尾没有换行时不会凭空补一个。
    ///
    /// 必须按 UTF-8 字节扫描：Swift 里 `"\r\n"` 是**单个 Character**（grapheme cluster），
    /// 按 Character 遍历时它既不等于 `"\r"` 也不等于 `"\n"`，CRLF 文件会被当成一整行。
    static func splitLines(_ text: String) -> [TextLine] {
        var lines: [TextLine] = []
        var current: [UInt8] = []
        let bytes = Array(text.utf8)
        var i = 0

        func flush(_ terminator: String) {
            lines.append(TextLine(content: String(decoding: current, as: UTF8.self), terminator: terminator))
            current.removeAll(keepingCapacity: true)
        }

        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x0A {
                flush("\n")
                i += 1
            } else if byte == 0x0D {
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                    flush("\r\n")
                    i += 2
                } else {
                    flush("\r")
                    i += 1
                }
            } else {
                current.append(byte)
                i += 1
            }
        }
        if !current.isEmpty { flush("") }
        return lines
    }
}