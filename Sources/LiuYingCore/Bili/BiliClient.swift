import Foundation

/// B 站开放接口客户端。只读接口：nav（取 WBI 密钥）、arc/search（UP 主投稿）、view（视频详情）。
///
/// 纪律：**绝不把 SESSDATA 写进日志或错误信息**。风控（-352/-412）由调用方熔断。
public actor BiliClient {
    static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36 Edg/123.0.0.0"

    private let session: URLSession
    private var sessdata: String?
    private var keyCache: (img: String, sub: String, fetchedAt: Date)?
    /// bili-dl 用 10 分钟刷新一次密钥。
    private let keyTTL: TimeInterval = 600

    public init(sessdata: String? = nil, session: URLSession? = nil) {
        if let session {
            self.session = session
            self.managesCookies = false
        } else {
            // 用系统 cookie 存储：服务端下发的 buvid3/buvid4 必须收下并在后续请求带回去，
            // 否则每次都是「未被激活的指纹」，arc/search 会间歇性返回 HTTP 412（实测约一半失败）。
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpShouldSetCookies = true
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
            self.managesCookies = true
        }
        let trimmed = sessdata?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.sessdata = normalized
        if self.managesCookies { Self.installSessdataCookie(normalized) }
    }

    /// 外部注入 session 时（测试）不改动全局 cookie 存储。
    private let managesCookies: Bool

    public var hasSessdata: Bool { sessdata != nil }

    public func updateSessdata(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessdata = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if managesCookies { Self.installSessdataCookie(sessdata) }
    }

    /// 把 SESSDATA 写进系统 cookie 存储；URLSession 会自己带上它以及服务端下发的其它 cookie。
    /// static 是因为 init 里还不能调用 actor 隔离的方法。
    private static func installSessdataCookie(_ sessdata: String?) {
        guard let host = URL(string: "https://www.bilibili.com/") else { return }
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies(for: host) ?? [] where cookie.name == "SESSDATA" {
            storage.deleteCookie(cookie)
        }
        guard let sessdata else { return }
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: "SESSDATA",
            .value: sessdata,
            .domain: ".bilibili.com",
            .path: "/",
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 365),
        ]
        if let cookie = HTTPCookie(properties: properties) {
            storage.setCookie(cookie)
        }
    }

    // MARK: - WBI 密钥

    /// 失败时保留旧密钥且不更新时间戳，下一轮会再试。
    public func navKeys(forceRefresh: Bool = false) async throws -> (img: String, sub: String) {
        if !forceRefresh, let cached = keyCache, Date().timeIntervalSince(cached.fetchedAt) < keyTTL {
            return (cached.img, cached.sub)
        }
        do {
            let data = try dataObject(try await request("https://api.bilibili.com/x/web-interface/nav"))
            guard let wbi = data["wbi_img"] as? [String: Any],
                  let imgURL = wbi["img_url"] as? String,
                  let subURL = wbi["sub_url"] as? String,
                  let img = WBISigner.keyFromURL(imgURL),
                  let sub = WBISigner.keyFromURL(subURL) else {
                throw BiliError.missingWBIKeys
            }
            keyCache = (img, sub, Date())
            return (img, sub)
        } catch {
            if let cached = keyCache {
                Log.warning("WBI 密钥刷新失败，沿用旧密钥：\(error.localizedDescription)")
                return (cached.img, cached.sub)
            }
            throw error
        }
    }

    // MARK: - UP 主投稿

    /// UP 主投稿。B 站对空间接口按请求随机封禁（HTTP 412 / code -412），
    /// 而签名带秒级时间戳，换一次签名重试通常就能过，所以这里内置重试。
    public func arcSearch(
        mid: Int64, page: Int = 1, pageSize: Int = 49, attempts: Int = 3
    ) async throws -> ArcPage {
        var lastError: Error?
        for attempt in 1...max(1, attempts) {
            do {
                return try await arcSearchOnce(mid: mid, page: page, pageSize: pageSize)
            } catch let error as BiliError where error.isRiskControl || isBanned(error) {
                lastError = error
                Log.warning("arc/search 被风控（第 \(attempt)/\(attempts) 次）：\(error.localizedDescription)")
                if attempt < attempts {
                    try await Task.sleep(nanoseconds: UInt64(Double(attempt) * 500_000_000))
                }
            }
        }
        throw lastError ?? BiliError.decoding("arc/search 无结果")
    }

    private func isBanned(_ error: Error) -> Bool {
        if case .http = error as? BiliError { return true }
        return false
    }

    private func arcSearchOnce(mid: Int64, page: Int, pageSize: Int) async throws -> ArcPage {
        try await ensureBuvid()
        let keys = try await navKeys()
        let mixin = WBISigner.mixinKey(imgKey: keys.img, subKey: keys.sub)
        let params: [String: String] = [
            "mid": String(mid),
            "pn": String(page),
            "ps": String(pageSize),
            "order": "pubdate",
        ]
        let query = WBISigner.sign(params: params, mixinKey: mixin)
        Log.debug("arc/search query: \(query)")
        let data = try dataObject(
            try await request(
                "https://api.bilibili.com/x/space/wbi/arc/search?" + query,
                referer: "https://space.bilibili.com/\(mid)"
            )
        )

        let list = data["list"] as? [String: Any]
        let vlist = list?["vlist"] as? [[String: Any]] ?? []
        let videos = vlist.compactMap(Self.video(from:))
        let pageInfo = data["page"] as? [String: Any]
        let total = Self.int(pageInfo?["count"]).map(Int.init) ?? videos.count

        return ArcPage(
            videos: videos,
            totalCount: total,
            pageNumber: Int(Self.int(pageInfo?["pn"]) ?? Int64(page)),
            pageSize: pageSize
        )
    }

    /// 最近一页投稿（49 条）。增量轮询只需要这个。
    public func latestUploads(mid: Int64, pageSize: Int = 49) async throws -> [BiliVideo] {
        try await arcSearch(mid: mid, page: 1, pageSize: pageSize).videos
    }

    /// 全量投稿，按发布时间倒序。每页之间 1s，避免把风控惹毛。
    public func allUploads(mid: Int64, pageSize: Int = 49, maxPages: Int = 40) async throws -> [BiliVideo] {
        let first = try await arcSearch(mid: mid, page: 1, pageSize: pageSize)
        var all = first.videos
        let totalPages = max(1, (first.totalCount + pageSize - 1) / pageSize)
        let limit = min(totalPages, maxPages)
        var page = 2
        while page <= limit {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let next = try await arcSearch(mid: mid, page: page, pageSize: pageSize)
            if next.videos.isEmpty { break }
            all += next.videos
            page += 1
        }
        return all
    }

    // MARK: - 视频详情

    public func view(bvid: String) async throws -> BiliVideoDetail {
        let url = "https://api.bilibili.com/x/web-interface/view?bvid=" + WBISigner.formEscape(bvid)
        let data = try dataObject(try await request(url))
        let owner = data["owner"] as? [String: Any]
        let pages = (data["pages"] as? [[String: Any]] ?? []).map { raw in
            BiliPage(
                page: Int(Self.int(raw["page"]) ?? 0),
                cid: Self.int64(raw["cid"]),
                part: raw["part"] as? String ?? "",
                duration: Self.int(raw["duration"]).map(Int.init)
            )
        }
        return BiliVideoDetail(
            bvid: data["bvid"] as? String ?? bvid,
            aid: Self.int64(data["aid"]),
            title: data["title"] as? String ?? "",
            coverURL: data["pic"] as? String,
            pubdate: Self.int64(data["pubdate"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            duration: Self.int(data["duration"]).map(Int.init),
            ownerName: owner?["name"] as? String,
            ownerMid: Self.int64(owner?["mid"]),
            pages: pages
        )
    }

    /// 确保 cookie 里有 buvid3。`/x/frontend/finger/spi` 把 b_3 / b_4 放在**响应体**里
    /// （不是 Set-Cookie），所以必须自己写进 cookie 存储。
    private func ensureBuvid() async throws {
        guard managesCookies else { return }
        let host = URL(string: "https://www.bilibili.com/")!
        if (HTTPCookieStorage.shared.cookies(for: host) ?? []).contains(where: { $0.name == "buvid3" }) {
            return
        }
        do {
            let data = try dataObject(try await request("https://api.bilibili.com/x/frontend/finger/spi"))
            let b3 = data["b_3"] as? String ?? ""
            let b4 = data["b_4"] as? String ?? ""
            if !b3.isEmpty { Self.installCookie(name: "buvid3", value: b3) }
            if !b4.isEmpty { Self.installCookie(name: "buvid4", value: b4) }
            Self.installCookie(name: "b_nut", value: String(Int(Date().timeIntervalSince1970)))
            Log.debug("buvid 初始化完成，cookies=\(cookieNames)")
        } catch {
            Log.warning("获取 buvid 失败，继续请求：\(error.localizedDescription)")
        }
    }

    /// 仅用于诊断：cookie 名字清单（**不含值**）。
    private var cookieNames: [String] {
        let host = URL(string: "https://www.bilibili.com/")!
        return (HTTPCookieStorage.shared.cookies(for: host) ?? []).map(\.name).sorted()
    }

    /// 静态：init 与 actor 方法都要用。
    private static func installCookie(name: String, value: String) {
        guard let host = URL(string: "https://www.bilibili.com/") else { return }
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: ".bilibili.com",
            .path: "/",
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 365),
        ]
        if let cookie = HTTPCookie(properties: properties) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    // MARK: - 签名诊断

    public struct SignatureDebug: Sendable {
        public var imgKey: String
        public var subKey: String
        public var mixinKey: String
        public var timestamp: Int
        public var query: String
    }

    /// 把一次 arc/search 的签名中间量摊开，便于与 Go/Python 参考实现逐字段对比。
    /// 只含公开的 WBI 密钥与临时签名，不含任何 Cookie。
    public func signatureDebug(mid: Int64, page: Int = 1, pageSize: Int = 49) async throws -> SignatureDebug {
        let keys = try await navKeys()
        let mixin = WBISigner.mixinKey(imgKey: keys.img, subKey: keys.sub)
        let timestamp = Int(Date().timeIntervalSince1970)
        let query = WBISigner.sign(
            params: ["mid": String(mid), "pn": String(page), "ps": String(pageSize), "order": "pubdate"],
            mixinKey: mixin,
            timestamp: timestamp
        )
        return SignatureDebug(
            imgKey: keys.img, subKey: keys.sub, mixinKey: mixin,
            timestamp: timestamp, query: query
        )
    }

    // MARK: - 原始响应诊断

    /// 直接返回 arc/search 的原始响应体（截断）。不含 Cookie，可安全打印。
    public func rawArcSearch(mid: Int64, page: Int = 1, pageSize: Int = 49, limit: Int = 1200) async throws -> String {
        try await ensureBuvid()
        let keys = try await navKeys()
        let mixin = WBISigner.mixinKey(imgKey: keys.img, subKey: keys.sub)
        let query = WBISigner.sign(
            params: ["mid": String(mid), "pn": String(page), "ps": String(pageSize), "order": "pubdate"],
            mixinKey: mixin
        )
        let url = "https://api.bilibili.com/x/space/wbi/arc/search?" + query
        let (data, response) = try await send(url, referer: "https://space.bilibili.com/\(mid)")
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data.prefix(limit), as: UTF8.self)
        return "HTTP \(status)  bytes=\(data.count)  cookies=\(cookieNames)\n\(body)"
    }

    // MARK: - 传输

    private func request(_ urlString: String, referer: String = "https://www.bilibili.com/") async throws -> Any {
        let (data, response) = try await send(urlString, referer: referer)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(decoding: data.prefix(200), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Log.error("B 站 HTTP \(http.statusCode) cookies=\(cookieNames) body=\(body.prefix(120))")
            throw BiliError.http(http.statusCode, "cookies=\(cookieNames)")
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BiliError.decoding("响应不是合法 JSON")
        }
    }

    private func send(
        _ urlString: String,
        referer: String = "https://www.bilibili.com/"
    ) async throws -> (Data, URLResponse) {
        guard let url = URL(string: urlString) else {
            throw BiliError.decoding("非法 URL")
        }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        do {
            return try await session.data(for: request)
        } catch {
            throw BiliError.decoding("网络错误：\(error.localizedDescription)")
        }
    }

    private func dataObject(_ json: Any) throws -> [String: Any] {
        guard let root = json as? [String: Any] else {
            throw BiliError.decoding("根节点不是对象")
        }
        let code = Int(Self.int(root["code"]) ?? -1)
        let message = root["message"] as? String ?? ""
        if code != 0 {
            if code == -352 || code == -412 || code == -403 {
                throw BiliError.riskControl(code: code, message: message)
            }
            throw BiliError.api(code: code, message: message)
        }
        return root["data"] as? [String: Any] ?? [:]
    }

    // MARK: - 字段解码（B 站有时把数字给成字符串）

    static func video(from raw: [String: Any]) -> BiliVideo? {
        guard let bvid = raw["bvid"] as? String, !bvid.isEmpty else { return nil }
        return BiliVideo(
            bvid: bvid,
            aid: int64(raw["aid"]),
            title: raw["title"] as? String ?? bvid,
            coverURL: raw["pic"] as? String,
            length: raw["length"] as? String,
            created: int64(raw["created"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            summary: raw["description"] as? String
        )
    }

    static func int64(_ any: Any?) -> Int64? {
        if let number = any as? NSNumber { return number.int64Value }
        if let text = any as? String { return Int64(text) }
        return nil
    }

    static func int(_ any: Any?) -> Int64? { int64(any) }
}