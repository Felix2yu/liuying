//  POSIX 风格的 shell 词法切分/拼接，移植自 ntfyx/Sources/NtfyxCore/ScriptRunner.swift。
//  用途：把 extra_args 数组在一个 TextField 里往返，不真的起 shell。

import Foundation

public enum ShellWord {
    /// 单/双引号与反斜杠转义。未闭合引号或尾随反斜杠返回 nil，让调用方决定如何回退。
    public static func split(_ input: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var hasContent = false

        func flush() {
            if hasContent {
                words.append(current)
                current = ""
                hasContent = false
            }
        }

        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            switch c {
            case " ", "\t", "\n":
                flush()
                i = input.index(after: i)

            case "'":
                hasContent = true
                i = input.index(after: i)
                var closed = false
                while i < input.endIndex {
                    if input[i] == "'" {
                        closed = true
                        i = input.index(after: i)
                        break
                    }
                    current.append(input[i])
                    i = input.index(after: i)
                }
                if !closed { return nil }

            case "\"":
                hasContent = true
                i = input.index(after: i)
                var closed = false
                while i < input.endIndex {
                    let ch = input[i]
                    if ch == "\"" {
                        closed = true
                        i = input.index(after: i)
                        break
                    }
                    if ch == "\\" {
                        let after = input.index(after: i)
                        if after < input.endIndex, ["\"", "\\", "$", "`"].contains(input[after]) {
                            current.append(input[after])
                            i = input.index(after: after)
                            continue
                        }
                        current.append("\\")
                        i = after
                        continue
                    }
                    current.append(ch)
                    i = input.index(after: i)
                }
                if !closed { return nil }

            case "\\":
                hasContent = true
                let after = input.index(after: i)
                guard after < input.endIndex else { return nil }
                current.append(input[after])
                i = input.index(after: after)

            default:
                hasContent = true
                current.append(c)
                i = input.index(after: i)
            }
        }
        flush()
        return words
    }

    /// split 的逆运算：只在词会被 shell 重新切分时才加引号。
    public static func join(_ words: [String]) -> String {
        words.map { word in
            if word.isEmpty
                || word.rangeOfCharacter(from: .whitespaces) != nil
                || word.contains(where: { "\"'\\|&;<>()$`*?[]{}!#~".contains($0) }) {
                return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            return word
        }
        .joined(separator: " ")
    }
}