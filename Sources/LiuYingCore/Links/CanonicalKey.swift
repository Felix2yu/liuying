import Foundation

/// 把链接归一化成去重键。同一个视频会以 b23.tv 短链、带 spm 参数的长链、av 号等多种形式出现，
/// 只有 BV/av 号才能保证不重复下载。
public enum CanonicalKey {
    /// 前缀允许小写 bv，后 10 位保持原样（BV 号的正文是大小写敏感的）。
    static let bvRegex = try! NSRegularExpression(pattern: #"[bB][vV]([0-9A-Za-z]{10})"#)
    /// 前后边界都要卡：`xav123` 不能匹配，`/av123?x=1` 要匹配。
    static let avRegex = try! NSRegularExpression(pattern: #"(?:^|/)av(\d+)(?:\D|$)"#, options: [.caseInsensitive])

    /// 纯视频 ID，不带分 P 后缀。用于 bvid 字段与 B 站 API —— 那里只认 BV 号。
    /// 完整 URL 必须是 B 站域名，否则别的站点路径里恰好出现 BV 串会撞掉真正的视频。
    /// 裸文本（无 scheme）仍按 BV/av 识别，兼容「直接贴 BV 号」的用法。
    public static func videoID(in text: String) -> String? {
        if text.contains("://") {
            guard let host = URLComponents(string: text)?.host?.lowercased(),
                  URLExtractor.bilibiliHosts.contains(host) else { return nil }
        }
        let ns = text as NSString
        if let match = bvRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            return "BV" + ns.substring(with: match.range(at: 1))
        }
        if let match = avRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            return "av" + ns.substring(with: match.range(at: 1))
        }
        return nil
    }

    /// 去重键 = 视频 ID + 分 P。`?p=1` 与不带 p 等价，`?p=2` 起单独成键，
    /// 否则同一个多 P 视频的分 P 链接会被当成重复而互相挤掉。
    public static func localKey(_ url: String) -> String? {
        guard let id = videoID(in: url) else { return nil }
        return id + pageSuffix(url)
    }

    static func pageSuffix(_ url: String) -> String {
        guard let items = URLComponents(string: url)?.queryItems,
              let raw = items.first(where: { $0.name.lowercased() == "p" })?.value,
              let page = Int(raw), page > 1 else { return "" }
        return "#p\(page)"
    }

    /// 从任意文本（跳转后的最终 URL、API 返回）里抠 BV 号。
    public static func bvid(in text: String) -> String? {
        let ns = text as NSString
        guard let match = bvRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return "BV" + ns.substring(with: match.range(at: 1))
    }
}

/// 短链需要跟一次重定向才能拿到 BV。带缓存，避免同一轮里重复请求。
public actor KeyResolver {
    /// 只缓存解析成功的结果。失败绝不缓存，网络恢复后同一短链仍有机会归一成 BV。
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
    /// 都失败则退化为原始 URL（与旧版行为一致，宁可多下一次也不丢链接），
    /// 但**不缓存失败结果**：网络恢复后同一短链还能解析成 BV 并被去重。
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
        guard let finalURL = await followRedirect(url),
              let host = URLComponents(string: finalURL)?.host?.lowercased(),
              URLExtractor.bilibiliHosts.contains(host),
              let bv = CanonicalKey.bvid(in: finalURL) else {
            return url
        }
        let resolved = bv + CanonicalKey.pageSuffix(url)
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