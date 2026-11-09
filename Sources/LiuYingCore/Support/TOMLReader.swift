import Foundation

/// 极小的 TOML 子集读取器。只覆盖本项目需要的那一种形状：
///
/// ```toml
/// [profiles.default]
/// sessdata = "…"
/// bili_jct = "…"
/// ```
///
/// 支持 `[a.b]` 表头、`key = "basic string"` / `'literal string'` / 裸值、`#` 注释。
/// 不是通用 TOML 实现：数组、内联表、多行字符串一律当裸值原样保留或忽略该行。
/// 这么做是为了不引第三方依赖 —— 本机 GitHub/代理不稳，SPM 解析可能卡死。
public enum TOMLReader {
    /// 返回 `表路径 → (键 → 值)`，表路径用 `.` 连接，例如 `profiles.default`。
    public static func parse(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var table = ""

        // isNewline 认 CRLF（在 Swift 里它是单个 Character）与 LF。
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else { continue }
                let inner = String(line[line.index(after: line.startIndex)..<close])
                table = inner
                    .split(separator: ".", omittingEmptySubsequences: true)
                    .map { unquote(String($0).trimmingCharacters(in: .whitespaces)) }
                    .joined(separator: ".")
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = unquote(String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces))
            guard !key.isEmpty else { continue }
            let rawValue = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            result[table, default: [:]][key] = parseValue(rawValue)
        }
        return result
    }

    /// 引号内的 `#` 不算注释。
    static func stripComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var escaped = false
        var output = ""
        for ch in line {
            if escaped {
                output.append(ch)
                escaped = false
                continue
            }
            switch ch {
            case "\\" where inDouble:
                output.append(ch)
                escaped = true
            case "'" where !inDouble:
                inSingle.toggle()
                output.append(ch)
            case "\"" where !inSingle:
                inDouble.toggle()
                output.append(ch)
            case "#" where !inSingle && !inDouble:
                return output
            default:
                output.append(ch)
            }
        }
        return output
    }

    static func parseValue(_ raw: String) -> String {
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return unescapeBasic(String(raw.dropFirst().dropLast()))
        }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast())
        }
        return unquote(raw)
    }

    static func unquote(_ raw: String) -> String {
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return unescapeBasic(String(raw.dropFirst().dropLast()))
        }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    static func unescapeBasic(_ raw: String) -> String {
        var output = ""
        var iterator = raw.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\" else {
                output.append(ch)
                continue
            }
            switch iterator.next() {
            case "n": output.append("\n")
            case "t": output.append("\t")
            case "r": output.append("\r")
            case "\"": output.append("\"")
            case "\\": output.append("\\")
            case let other?: output.append(other)
            case nil: output.append("\\")
            }
        }
        return output
    }
}