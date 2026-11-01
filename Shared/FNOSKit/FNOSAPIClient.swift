import Foundation

/// 飞牛影视（FNOS）API 客户端。
///
/// - 纯 URLSession + async/await 实现，无第三方依赖
/// - 所有请求经由 `FNOSRequestInterceptor` 注入 Authx（签名）+ Authorization（token）头
/// - 响应统一解析 `{code, msg, data}` 信封；`code == -2` 时自动触发重登并重试一次
///
/// 端点对照：`_reference/fnos_tv_danmu/.../api/FnApiService.java`
public final class FNOSAPIClient {

    // MARK: - 状态

    private let baseURL: URL
    private let session: URLSession
    private let interceptor: FNOSRequestInterceptor
    private let lock = NSLock()
    private var _username: String?
    private var _password: String?

    /// 自动重登回调。收到 code == -2 时由客户端调用；
    /// 典型实现是取出保存的账号密码调用 `login` 并持久化新 token。
    public var reloginHandler: (() async throws -> String)?

    public var token: String? {
        get { interceptor.token }
        set { interceptor.token = newValue }
    }

    // MARK: - 生命周期

    public init(baseURL: URL, interceptor: FNOSRequestInterceptor = .shared) {
        self.baseURL = baseURL
        self.interceptor = interceptor

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    /// 便捷构造：主机字符串自动规范化（如 "192.168.1.10" → http://192.168.1.10:5666/）
    public convenience init?(host: String) {
        guard let url = FNOSConfig.serverURL(fromHost: host) else { return nil }
        self.init(baseURL: url)
    }

    // MARK: - 认证

    /// 登录并保存 token。账号密码同时缓存，供 -2 自动重登使用。
    @discardableResult
    public func login(username: String, password: String) async throws -> String {
        lock.lock()
        _username = username
        _password = password
        lock.unlock()

        let data = try FNOSJSON.encode(FNOSLoginRequest(
            appName: FNOSConfig.appName,
            username: username,
            password: password
        ))

        let result: FNOSLoginData = try await send(
            method: "POST", path: "/api/v1/login", body: data, allowRelogin: false
        )
        token = result.token
        return result.token
    }

    /// 使用缓存的账号密码重新登录（登录成功后账号密码会缓存于此）。
    /// 典型用法：
    /// ```swift
    /// client.reloginHandler = { try await client.reloginWithCachedCredentials() }
    /// ```
    /// 生产环境建议替换为"从 Keychain 读取账号密码 → login → 持久化新 token"的实现。
    @discardableResult
    public func reloginWithCachedCredentials() async throws -> String {
        lock.lock()
        let username = _username
        let password = _password
        lock.unlock()
        guard let username, let password else {
            throw FNOSClientError.authFailed
        }
        return try await login(username: username, password: password)
    }

    /// 登出（清空本地 token，服务端登出失败不视为错误）
    public func logout() async {
        try? await sendVoid(method: "POST", path: "/api/v1/logout", allowRelogin: false)
        token = nil
        lock.lock()
        _username = nil
        _password = nil
        lock.unlock()
    }

    /// 当前用户信息
    public func userInfo() async throws -> FNOSUserInfo {
        try await send(method: "GET", path: "/api/v1/user/info")
    }

    // MARK: - 媒体库

    /// 媒体库列表（首页海报墙的顶层入口）
    public func mediaDbList() async throws -> [FNOSMediaDb] {
        try await send(method: "GET", path: "/api/v1/mediadb/list")
    }

    /// 浏览媒体库 / 文件夹条目
    public func itemList(_ request: FNOSItemListRequest) async throws -> FNOSItemListResponse {
        try await send(
            method: "POST",
            path: "/api/v1/item/list",
            body: try FNOSJSON.encode(request)
        )
    }

    /// 剧集列表（一部剧下的所有集）
    public func episodeList(guid: String) async throws -> [FNOSPlayListItem] {
        try await send(method: "GET", path: "/api/v1/episode/list/\(guid)")
    }

    /// 季列表
    public func seasonList(guid: String) async throws -> [FNOSPlayListItem] {
        try await send(method: "GET", path: "/api/v1/season/list/\(guid)")
    }

    /// 搜索
    public func search(_ keyword: String) async throws -> [FNOSPlayListItem] {
        let q = keyword.addingPercentEncoding(withAllowedCharacters: .fnosQueryAllowed) ?? keyword
        return try await send(method: "GET", path: "/api/v1/search/list", query: "q=\(q)")
    }

    // MARK: - 播放

    /// 获取播放信息（拿到 media_guid 等关键 guid）
    public func playInfo(itemGuid: String) async throws -> FNOSPlayInfo {
        try await send(
            method: "POST",
            path: "/api/v1/play/info",
            body: try FNOSJSON.encode(FNOSPlayInfoRequest(itemGuid: itemGuid))
        )
    }

    /// 构造视频播放直链 URL（支持 HTTP Range，可直接交给播放器）。
    /// 播放该 URL 时务必同时使用 `mediaHeaders(for:)` 生成的请求头。
    public func mediaRangeURL(mediaGuid: String, qualityIndex: Int? = nil) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = "/v/api/v1/media/range/\(mediaGuid)"
        if let qualityIndex {
            components.queryItems = [URLQueryItem(name: "direct_link_quality_index",
                                                  value: String(qualityIndex))]
        }
        return components.url!
    }

    /// 一站式解析播放地址：play/info → 直链 URL（+ 播放器请求头）。
    /// HLS/转码播放走 `stream(...)`，这里默认给直链（本地局域网最优路径）。
    public func resolvePlayback(itemGuid: String) async throws -> (url: URL, headers: [String: String], playInfo: FNOSPlayInfo) {
        let info = try await playInfo(itemGuid: itemGuid)
        guard let mediaGuid = info.mediaGuid else {
            throw FNOSClientError.missingData
        }
        let url = mediaRangeURL(mediaGuid: mediaGuid)
        return (url, interceptor.mediaHeaders(for: url), info)
    }

    /// 获取流信息（直链质量列表 / 外挂字幕流列表）
    public func streamList(guid: String) async throws -> FNOSStreamResponse {
        try await send(method: "GET", path: "/api/v1/stream/list/\(guid)")
    }

    /// 字幕下载地址（返回的是接口路径，需要播放器带鉴权头请求）
    public func subtitleURL(subtitleGuid: String) -> URL {
        baseURL.appendingPathComponent("v/api/v1/subtitle/dl/\(subtitleGuid)")
    }

    // MARK: - 观看状态

    /// 标记已看 / 未看
    public func setWatched(itemGuid: String, watched: Bool) async throws {
        struct Body: Encodable { let itemGuid: String; let watched: Int }
        let body = try FNOSJSON.encode(Body(itemGuid: itemGuid, watched: watched ? 1 : 0))
        try await sendVoid(method: "POST", path: "/api/v1/item/watched", body: body)
    }

    /// 播放进度上报（需 Referer 头，由拦截器按路径自动附加）
    public func reportProgress(_ status: FNOSPlayStatus) async throws {
        try await sendVoid(
            method: "POST",
            path: "/api/v1/play/record",
            body: try FNOSJSON.encode(status)
        )
    }

    // MARK: - 图片

    /// 拼接海报完整 URL（poster 为接口返回的相对路径）
    public func imageURL(fromPath path: String, width: Int = 400) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = "/v/api/v1/sys/img" + path
        components.queryItems = [URLQueryItem(name: "w", value: String(width))]
        return components.url!
    }

    // MARK: - 底层请求

    /// 统一请求 + 信封解析 + 自动重登。
    /// - Returns: 信封中的 data
    private func send<T: Decodable>(
        method: String,
        path: String,
        query: String? = nil,
        body: Data? = nil,
        allowRelogin: Bool = true
    ) async throws -> T {
        let envelope: FNOSResponse<T> = try await perform(
            method: method, path: path, query: query, body: body, allowRelogin: allowRelogin
        )
        guard envelope.code == 0 else {
            throw FNOSClientError.server(code: envelope.code, message: envelope.msg)
        }
        guard let data = envelope.data else {
            throw FNOSClientError.missingData
        }
        return data
    }

    /// 同 `send`，但忽略 data（用于 logout / watched / record 等 data 为 null 的接口）。
    /// 仍会校验业务错误码，失败时抛错。
    private func sendVoid(
        method: String,
        path: String,
        body: Data? = nil,
        allowRelogin: Bool = true
    ) async throws {
        let envelope: FNOSResponse<FNOSEmpty> = try await perform(
            method: method, path: path, query: nil, body: body, allowRelogin: allowRelogin
        )
        guard envelope.code == 0 else {
            throw FNOSClientError.server(code: envelope.code, message: envelope.msg)
        }
    }

    private func perform<T: Decodable>(
        method: String,
        path: String,
        query: String?,
        body: Data?,
        allowRelogin: Bool
    ) async throws -> FNOSResponse<T> {
        let envelope: FNOSResponse<T> = try await execute(
            method: method, path: path, query: query, body: body
        )
        // code == -2：token 失效 → 尝试自动重登后重试一次
        if envelope.code == -2 {
            guard allowRelogin, let relogin = reloginHandler else {
                throw FNOSClientError.authFailed
            }
            let newToken = try await relogin()
            token = newToken
            return try await execute(
                method: method, path: path, query: query, body: body
            )
        }
        return envelope
    }

    /// 真正执行一次 HTTP 请求
    private func execute<T: Decodable>(
        method: String,
        path: String,
        query: String?,
        body: Data?
    ) async throws -> FNOSResponse<T> {
        let fullPath = "/v" + path   // 完整路径参与签名：/v/api/v1/...

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = fullPath
        if let query {
            // query 已在外部做好百分号编码，这里直接拼
            components.percentEncodedQuery = query
        }
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        // ★ 拦截器注入 Authx + Authorization 等全部头
        for (key, value) in interceptor.headers(method: method, path: fullPath, query: query, body: body) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FNOSClientError.server(code: -http.statusCode, message: "HTTP \(http.statusCode)")
        }

        return try FNOSJSON.decoder.decode(FNOSResponse<T>.self, from: data)
    }
}

// MARK: - 工具

/// 统一的 JSON 编解码配置。
/// 编解码均启用 snake_case 转换，且编码使用 sortedKeys —— 保证
/// "编码结果 == 参与签名的原文" 稳定一致。
public enum FNOSJSON {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

extension CharacterSet {
    /// URL query 允许字符集（含中文）
    static let fnosQueryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?")
        return set
    }()
}
