import Foundation

/// 把链接归一化成去重键。同一个视频会以 b23.tv 短链、带 spm 参数的长链、av 号等多种形式出现，
/// 只有 BV/av 号才能保证不重复下载。
public enum CanonicalKey {
    static let bvRegex = try! NSRegularExpression(pattern: #"BV[0-9A-Za-z]{10}"#)
    /// 前后边界都要卡：`xav123` 不能匹配，`/av123?x=1` 要匹配。
    static let avRegex = try! NSRegularExpression(pattern: #"(?:^|/)av(\d+)(?:\D|$)"#, options: [.caseInsensitive])

    /// 纯本地解析，不发网络请求。返回 nil 表示这条链接里没有 BV/av 号（可能是短链）。
    public static func localKey(_ url: String) -> String? {
        let ns = url as NSString
        if let match = bvRegex.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(with: match.range)
        }
        if let match = avRegex.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)) {
            return "av" + ns.substring(with: match.range(at: 1))
        }
        return nil
    }

    /// 从任意文本（跳转后的最终 URL、API 返回）里抠 BV 号。
    public static func bvid(in text: String) -> String? {
        let ns = text as NSString
        guard let match = bvRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: match.range)
    }
}

/// 短链需要跟一次重定向才能拿到 BV。带缓存，避免同一轮里重复请求。
public actor KeyResolver {
    private var cache: [String: String] = [:]
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    /// 返回去重键。本地能解析就直接返回；b23.tv 短链跟一次重定向；
    /// 都失败则退化为原始 URL（与旧版行为一致，宁可多下一次也不丢链接）。
    public func key(for url: String) async -> String {
        if let cached = cache[url] { return cached }
        if let local = CanonicalKey.localKey(url) {
            cache[url] = local
            return local
        }
        guard url.contains("b23.tv") else {
            cache[url] = url
            return url
        }
        let resolved: String
        if let finalURL = await followRedirect(url), let bv = CanonicalKey.bvid(in: finalURL) {
            resolved = bv
        } else {
            resolved = url
        }
        cache[url] = resolved
        return resolved
    }

    private func followRedirect(_ url: String) async -> String? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (_, response) = try await session.data(for: request)
            return response.url?.absoluteString
        } catch {
            Log.debug("短链跳转失败 \(url)：\(error.localizedDescription)")
            return nil
        }
    }
}