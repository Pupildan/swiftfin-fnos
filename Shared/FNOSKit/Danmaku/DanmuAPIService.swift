import Foundation

/// danmu-api 弹幕服务客户端。
///
/// 支持两种接口（自动回退）：
/// 1. **dandanplay 兼容协议**（danmu_api 默认，`http://<NAS>:9321`）：
///    - `POST /api/v2/match`  body `{"fileName": "<文件名/标题>"}` → 匹配 episodeId
///    - `GET  /api/v2/comment/{episodeId}?format=json` → `{count, comments:[{cid, p:"时间,模式,颜色,...", m:"文本"}]}`
///    - `GET  /api/v2/search/anime?keyword=` / `GET /api/v2/bangumi/{animeId}`（手动匹配预留）
/// 2. **fnos-tv Python 版协议**（`http://<NAS>:5000`）：
///    - `GET /danmu/get?douban_id=` 或 `?title=&season_number=&episode_number=`
///      → `{"1": [{time, mode, color:"#FFFFFF", text}]}`
///
/// 解析在协作线程池执行（不占主线程），结果以 `DanmakuTimeline`（已排序）返回。
public final class DanmuAPIService {

    // MARK: - 错误

    public enum DanmuServiceError: LocalizedError {
        case badURL
        case notMatched
        case emptyComments
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .badURL:        return "弹幕服务地址无效"
            case .notMatched:    return "未匹配到对应剧集的弹幕"
            case .emptyComments: return "该剧集暂无弹幕"
            case .http(let s):   return "弹幕服务 HTTP \(s)"
            }
        }
    }

    // MARK: - 状态

    private let baseURL: URL
    private let session: URLSession
    private let cache = NSCache<NSString, DanmakuTimeline>()
    /// danmu_api 的访问密钥（部署时设置的 KEY，401 时必填）
    private let apiKey: String?

    public init(baseURL: URL, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
        cache.totalCostLimit = 32   // 最多缓存 32 集的内存副本
    }

    public convenience init?(host: String, port: Int = 9321, apiKey: String? = nil) {
        guard let url = URL(string: "http://\(host):\(port)") else { return nil }
        self.init(baseURL: url, apiKey: apiKey)
    }

    // MARK: - 对外主入口

    /// 为一集视频获取弹幕时间轴。
    /// 优先级：doubanId 直查 → dandanplay match → /danmu/get 标题兜底。
    /// - Parameters:
    ///   - fileName: 用于 match 的文件名/标题（如 "海贼王 第1000集"）
    ///   - title: 剧名（/danmu/get 兜底用）
    ///   - seasonNumber / episodeNumber: 季集号
    ///   - doubanId: 飞牛刮削的豆瓣 ID（FNOSPlayListItem.doubanId）
    public func fetchTimeline(
        fileName: String,
        title: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        doubanId: Int? = nil
    ) async throws -> DanmakuTimeline {
        let cacheKey = danmuCacheKey(fileName: fileName, season: seasonNumber,
                                     episode: episodeNumber, doubanId: doubanId)
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached
        }

        var lastError: Error?

        // ① doubanId 直查（fnos-tv /danmu/get，最准）
        if let doubanId {
            do {
                let timeline = try await fetchViaDanmuGet(doubanId: doubanId)
                if !timeline.items.isEmpty {
                    cache.setObject(timeline, forKey: cacheKey as NSString)
                    return timeline
                }
            } catch { lastError = error }
        }

        // ② dandanplay match → comment（danmu_api 主协议）
        do {
            let timeline = try await fetchViaDandanplay(fileName: fileName)
            if !timeline.items.isEmpty {
                cache.setObject(timeline, forKey: cacheKey as NSString)
                return timeline
            }
            lastError = DanmuServiceError.notMatched
        } catch { lastError = error }

        // ③ /danmu/get 标题 + 季集兜底
        if title != nil {
            do {
                let timeline = try await fetchViaDanmuGet(
                    title: title, seasonNumber: seasonNumber, episodeNumber: episodeNumber
                )
                if !timeline.items.isEmpty {
                    cache.setObject(timeline, forKey: cacheKey as NSString)
                    return timeline
                }
            } catch { lastError = error }
        }

        throw lastError ?? DanmuServiceError.notMatched
    }

    // MARK: - dandanplay 协议

    // MARK: - dandanplay 兼容协议模型

    public struct DanmuMatch: Decodable {
        public let episodeId: Int
        public let animeId: Int?
        public let animeTitle: String?
        public let episodeTitle: String?
    }

    struct MatchResponse: Decodable {
        let matches: [DanmuMatch]?
        let matched: Bool?
    }

    struct DanmuComment: Decodable {
        let cid: Int?
        let p: String?
        let m: String?
    }

    struct CommentResponse: Decodable {
        let count: Int?
        let comments: [DanmuComment]?
    }

    /// 文件名匹配 → episodeId
    public func match(fileName: String) async throws -> DanmuMatch {
        guard let url = authorizedURL("/api/v2/match") else {
            throw DanmuServiceError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["fileName": fileName])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DanmuServiceError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(MatchResponse.self, from: data)
        guard let first = decoded.matches?.first, first.episodeId > 0 else {
            throw DanmuServiceError.notMatched
        }
        return first
    }

    /// 拉取并解析弹幕（dandanplay comment 格式）
    public func fetchViaDandanplay(fileName: String) async throws -> DanmakuTimeline {
        let matched = try await match(fileName: fileName)
        return try await comments(episodeId: matched.episodeId,
                                  source: "dandanplay#\(matched.episodeId)")
    }

    /// GET /api/v2/comment/{episodeId}?format=json
    public func comments(episodeId: Int, source: String? = nil) async throws -> DanmakuTimeline {
        let cacheKey = "dandan-\(episodeId)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }

        guard let url = authorizedURL("/api/v2/comment/\(episodeId)", query: "format=json") else {
            throw DanmuServiceError.badURL
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DanmuServiceError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        // 海量弹幕（数万条）解码在后台协作线程执行 —— async 方法本身不在主线程
        let decoded = try JSONDecoder().decode(CommentResponse.self, from: data)
        guard let rawComments = decoded.comments else {
            throw DanmuServiceError.emptyComments
        }

        var items = [DanmakuItem]()
        items.reserveCapacity(rawComments.count)
        for comment in rawComments {
            guard let text = comment.m, !text.isEmpty, let p = comment.p else { continue }
            if let item = DanmakuParsing.item(fromCommentP: p, text: text) {
                items.append(item)
            }
        }
        guard !items.isEmpty else { throw DanmuServiceError.emptyComments }

        let timeline = DanmakuTimeline(items: items,
                                       source: source ?? "dandanplay#\(episodeId)")
        cache.setObject(timeline, forKey: cacheKey, cost: items.count)
        return timeline
    }

    // MARK: - fnos-tv /danmu/get 协议

    struct DanmuGetEntry: Decodable {
        let time: Double?
        let mode: Int?
        let color: String?
        let text: String?
    }

    /// GET /danmu/get?douban_id=... 或 ?title=&season_number=&episode_number=
    public func fetchViaDanmuGet(
        doubanId: Int? = nil,
        title: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil
    ) async throws -> DanmakuTimeline {
        var query = [String]()
        if let doubanId {
            query.append("douban_id=\(doubanId)")
        } else {
            guard let title, !title.isEmpty else { throw DanmuServiceError.badURL }
            query.append("title=\(encodeURIComponent(title))")
            if let seasonNumber { query.append("season_number=\(seasonNumber)") }
            if let episodeNumber { query.append("episode_number=\(episodeNumber)") }
        }
        guard !query.isEmpty,
              let url = authorizedURL("/danmu/get", query: query.joined(separator: "&")) else {
            throw DanmuServiceError.badURL
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DanmuServiceError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        // 响应形如 {"1": [ {...}, ... ], "2": [ ... ]}（key 为分页）
        let pages = try JSONDecoder().decode([String: [DanmuGetEntry]].self, from: data)
        var items = [DanmakuItem]()
        for (_, entries) in pages {
            for entry in entries {
                if let item = DanmakuParsing.item(fromDanmuGet: entry.time, mode: entry.mode,
                                                  colorHex: entry.color, text: entry.text) {
                    items.append(item)
                }
            }
        }
        guard !items.isEmpty else { throw DanmuServiceError.emptyComments }

        let timeline = DanmakuTimeline(items: items, source: url.path)
        cache.setObject(timeline, forKey: "get-\(doubanId.map(String.init) ?? title ?? "")" as NSString)
        return timeline
    }

    // MARK: - 手动匹配预留（搜索面板）

    /// 关键词搜索番剧（弹幕面板手动选择用）
    public struct AnimeSearchResult: Decodable {
        public let animeId: Int
        public let animeTitle: String?
    }

    struct SearchResponse: Decodable {
        let data: [AnimeSearchResult]?
    }

    public func searchAnime(keyword: String) async throws -> [AnimeSearchResult] {
        guard let url = authorizedURL("/api/v2/search/anime", query: "keyword=" + encodeURIComponent(keyword)) else {
            throw DanmuServiceError.badURL
        }
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(SearchResponse.self, from: data).data ?? []
    }

    // MARK: - 工具

    /// 给 URL 追加 API Key（danmu_api 鉴权：?key= 或 Authorization Bearer 均可）
    private func authorizedURL(_ path: String, query: String? = nil) -> URL? {
        var string = baseURL.absoluteString + path
        var pairs = [String]()
        if let query, !query.isEmpty { pairs.append(query) }
        if let apiKey, !apiKey.isEmpty { pairs.append("key=\(encodeURIComponent(apiKey))") }
        if !pairs.isEmpty { string += "?" + pairs.joined(separator: "&") }
        return URL(string: string)
    }

    private func encodeURIComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    private func danmuCacheKey(fileName: String, season: Int?, episode: Int?, doubanId: Int?) -> String {
        if let doubanId { return "key-douban-\(doubanId)-ep\(episode ?? -1)" }
        return "key-\(fileName)-s\(season ?? -1)-e\(episode ?? -1)"
    }
}
