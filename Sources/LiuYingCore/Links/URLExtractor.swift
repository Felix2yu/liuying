import Foundation

/// 从任意文本里提取 URL。
///
/// 抓取面是**所有 http(s) 链接**，而不再只认 B 站 —— 非 B 站链接交给 Downie 下载。
/// 分类（谁是 B 站）由 `isBilibiliHost` 负责，由 `AppConfig.backend(for:)` 决定路由。
///
/// 正则里那条负向前瞻不能省：iOS 快捷指令偶尔漏写换行，两条 URL 会粘成一条（实测踩过），
/// 没有前瞻就会把第一条的“路径”一路吃到第二条的 `https://` 上。
public enum URLExtractor {
    static let pattern = #"https?://(?:(?!https?://)[^\s，。、）】])+"#

    /// 分享文案里链接尾部常见的粘连标点。
    /// 中文引号/书名号这类符号后面往往还接着正文，单靠「从尾部剥」不够，
    /// 所以另有 boundaryPunctuation 负责从中间截断。
    static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", "\"", "'", "`", "，", "。", "；", ")", "）", "]", "】", "、",
        "“", "”", "‘", "’", "「", "」", "『", "』", "《", "》", "〈", "〉",
        "：", "！", "？", "＜", "＞", "…",
    ]

    /// 一旦出现就说明 URL 到头了（后面是正文），不能只按尾随标点处理。
    static let boundaryPunctuation: Set<Character> = [
        "“", "”", "‘", "’", "「", "」", "『", "』", "《", "》", "〈", "〉",
        "：", "！", "？", "＜", "＞", "`",
    ]

    /// B 站主机的精确白名单。
    static let bilibiliHosts: Set<String> = ["b23.tv", "www.bilibili.com", "bilibili.com", "bilibili.tv"]

    static let regex: NSRegularExpression = {
        // 模式是常量字面量，构造失败属于编译期错误之外的意外，用 force-try 暴露。
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    public struct Found: Sendable, Equatable {
        public var url: String
        /// 在输入文本里的范围（已剔除尾随标点）。
        public var range: Range<String.Index>
        public var isBilibili: Bool
    }

    /// 找出文本里所有 URL，保持出现顺序，**不去重**（去重是调用方的事）。
    public static func find(in text: String) -> [Found] {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var found: [Found] = []
        for match in matches {
            guard let rawRange = Range(match.range, in: text) else { continue }
            // 「https://…」后面直接跟中文引号/书名号 + 正文时，正则会把正文也吃进来；
            // 先从第一个正文边界截断，再剥尾随标点。
            var end = rawRange.lowerBound
            while end < rawRange.upperBound, !boundaryPunctuation.contains(text[end]) {
                end = text.index(after: end)
            }
            while end > rawRange.lowerBound, trailingPunctuation.contains(text[text.index(before: end)]) {
                end = text.index(before: end)
            }
            let range = rawRange.lowerBound..<end
            let url = String(text[range])
            guard !url.isEmpty, hasValidHost(url) else { continue }
            found.append(Found(url: url, range: range, isBilibili: isBilibiliHost(url)))
        }
        return found
    }

    /// 提取并按首次出现顺序去重。这是采集入口用的主接口。
    public static func extract(from text: String) -> [String] {
        var seen = Set<String>()
        var urls: [String] = []
        for item in find(in: text) where seen.insert(item.url).inserted {
            urls.append(item.url)
        }
        return urls
    }

    /// 主机必须精确命中 B 站白名单（含端口时剥掉端口）。
    public static func isBilibiliHost(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return bilibiliHosts.contains(host)
    }

    /// X（原 Twitter）的域名。公开推文由内嵌引擎直接下载（syndication 端点 + HLS）。
    static let xHosts: Set<String> = [
        "x.com", "twitter.com", "t.co", "mobile.x.com", "mobile.twitter.com",
    ]

    public static func isXHost(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return xHosts.contains(host)
    }

    /// 小红书的域名。首屏 SSR 里有直链，已由内嵌引擎直接下载。
    static let xiaohongshuHosts: Set<String> = [
        "xiaohongshu.com", "www.xiaohongshu.com",
        "xhslink.cn", "xhslink.com", "xhslink.me",
    ]

    public static func isXiaohongshuHost(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return xiaohongshuHosts.contains(host)
    }

    /// 抖音的域名。分享页带 ttwid 二次请求可拿到 play_addr，已由内嵌引擎直接下载。
    static let douyinHosts: Set<String> = [
        "douyin.com", "www.douyin.com", "douyin.com.cn", "www.douyin.com.cn",
        "iesdouyin.com", "www.iesdouyin.com", "v.douyin.com",
    ]

    public static func isDouyinHost(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return douyinHosts.contains(host)
    }

    /// 是否由内嵌引擎（bili-dl）处理。
    ///
    /// 引擎与客户端同仓演进、一起打包，所以这里判断的是「能力」而非「兼容」：
    /// 引擎支持哪一类站点，这里就路由哪一类，其余仍交给 Downie。
    public static func usesEmbeddedEngine(_ url: String) -> Bool {
        isBilibiliHost(url) || isXHost(url) || isXiaohongshuHost(url) || isDouyinHost(url)
    }

    /// 只放行 http/https 且主机非空的 URL，挡掉畸形链接。
    static func hasValidHost(_ url: String) -> Bool {
        guard let components = URLComponents(string: url) else { return false }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = components.host, !host.isEmpty else { return false }
        return true
    }
}