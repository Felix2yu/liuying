import CryptoKit
import Foundation

/// B 站 WBI 签名。移植自 `bili-dl/api/wbi.go`（arc/search 实际用的就是这份）。
///
/// 三个 Swift 移植陷阱，改动前务必先看懂：
///  1. **必须手写 form-escape**。`URLComponents.queryItems` 的编码规则与 Go/Python 的
///     query encoding 不同（空格→`%20` vs `+`、保留 `+`/`/`），会算出不同的 MD5 → 服务端 -352。
///     签名的字符串必须与实际发出的 query 逐字节一致。
///  2. mixin key 按 **UTF-8 字节**索引并截前 32 **字节**，不能用 Character/String.Index。
///  3. 键排序必须用 **UTF-8 字节序**（Go 的 sort.Strings）。Swift 的 `<` 是 Unicode 归一化比较，不等价。
public enum WBISigner {
    /// 官方混淆表，64 项，顺序不能动。
    public static let encTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
        61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
        36, 20, 34, 44, 52,
    ]

    /// 从 nav 接口拿到的是 `https://i0.hdslb.com/bfs/wbi/<32hex>.png`，取最后一段去掉扩展名。
    public static func keyFromURL(_ url: String) -> String? {
        guard let last = url.split(separator: "/").last else { return nil }
        let name = last.split(separator: ".").first.map(String.init) ?? String(last)
        return name.isEmpty ? nil : name
    }

    public static func mixinKey(imgKey: String, subKey: String) -> String {
        let orig = Array((imgKey + subKey).utf8)
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for index in encTab where index < orig.count {
            out.append(orig[index])
            if out.count == 32 { break }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Go `url.QueryEscape` / Python `quote_plus` 的等价实现。
    /// 未保留字符：`A-Za-z0-9-_.~`；空格→`+`；其余按 UTF-8 字节 `%XX`（大写）。
    public static func formEscape(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.utf8.count)
        for byte in raw.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x7E:
                out.append(Character(UnicodeScalar(byte)))
            case 0x20:
                out.append("+")
            default:
                out.append("%")
                out.append(hexDigit(byte >> 4))
                out.append(hexDigit(byte & 0x0F))
            }
        }
        return out
    }

    /// 只从**值**里剥掉这几个字符，且剥过的值就是要发出去的。
    public static func sanitize(_ value: String) -> String {
        value.filter { !"!'()*".contains($0) }
    }

    /// 返回可直接拼到 URL 后面的 query 串，含 `wts` 与 `w_rid`（`w_rid` 排在最后）。
    /// - Parameter timestamp: unix **秒**。测试注入固定值。
    public static func sign(
        params: [String: String],
        mixinKey: String,
        timestamp: Int = Int(Date().timeIntervalSince1970)
    ) -> String {
        var fields = params
        fields["wts"] = String(timestamp)
        for (key, value) in fields { fields[key] = sanitize(value) }

        // Go sort.Strings 是 UTF-8 字节序。
        let keys = fields.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let canonical = keys
            .map { "\(formEscape($0))=\(formEscape(fields[$0] ?? ""))" }
            .joined(separator: "&")

        let digest = Insecure.MD5.hash(data: Data((canonical + mixinKey).utf8))
        let wRid = digest.map { byte in
            String(format: "%02x", byte)
        }.joined()

        return canonical + "&w_rid=" + wRid
    }

    private static func hexDigit(_ value: UInt8) -> Character {
        Character(String(value, radix: 16, uppercase: true))
    }
}