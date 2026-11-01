//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// 飞牛影视（8005 端口 Jellyfin 兼容层）请求适配器。
///
/// 兼容层与标准 Jellyfin 的差异（2026-11 对 fnOS 实测）：
/// 1. 鉴权令牌必须放在独立 `X-Emby-Token` 头（Emby 老式约定），
///    而非 `X-Emby-Authorization` 内的 `Token=` 字段；
/// 2. 图片请求同样要求携带 `X-Emby-Authorization` + `X-Emby-Token` 双头；
/// 3. `/Users/{uid}/Items` 查询**必须**带 `Fields` 参数（否则 400），
///    且**必须**带 `Limit` 参数（否则返回 `Items: []`）；
/// 4. `IncludeItemTypes` 不支持逗号多类型（传 "Movie,Series" 返回 0 条），
///    多类型时整体移除该参数（单类型保留）；
/// 5. `/Users/{uid}/Items` **必须带 ParentId**，全局查询一律返回 0 →
///    无 ParentId 且无 SearchTerm 时，按已注册的媒体库逐库请求后合并；
/// 6. `/Users/{uid}/Items/Latest` 返回信封且不可全局 → 改写为
///    `/Users/{uid}/Items?ParentId&SortBy=DateCreated` 并把响应信封
///    转回纯数组（SDK 期望 `[BaseItemDto]`）；
/// 7. `/Users/{uid}/Items/Resume` 未实现 → 返回空信封；
/// 8. `PlaybackInfo` 仅支持 GET（POST 未路由）→ POST 转为 GET；
/// 9. `/Genres`、`/Similar` 未实现（返回网页）→ 返回空信封。
///
/// 通过 `URLSessionConfiguration.swiftfin` 注册，同时覆盖
/// jellyfin-sdk 的 API 请求与 Nuke 的图片请求。
final class FnOSCompatURLProtocol: URLProtocol {

    // MARK: - Token / 媒体库注册表

    private static let registryLock = NSLock()
    private static var tokensByHost: [String: String] = [:]
    private static var viewIDsByHost: [String: Set<String>] = [:]

    static func registerToken(host: String, token: String) {
        guard !token.isEmpty else { return }
        registryLock.lock()
        defer { registryLock.unlock() }
        tokensByHost[host] = token
    }

    private static func token(for host: String) -> String? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return tokensByHost[host]
    }

    /// 从 /Views 响应中收集媒体库 ID，供全局查询拆分合并使用
    static func registerViewIDs(host: String, ids: [String]) {
        guard !ids.isEmpty else { return }
        registryLock.lock()
        defer { registryLock.unlock() }
        viewIDsByHost[host, default: []].formUnion(ids)
    }

    private static func viewIDs(for host: String) -> [String] {
        registryLock.lock()
        defer { registryLock.unlock() }
        return Array(viewIDsByHost[host] ?? []).sorted()
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url,
              url.scheme == "http" || url.scheme == "https"
        else { return false }

        // 已登录的 API 请求（Authorization 带 Token）或已知飞牛主机的请求
        if Self.parseToken(fromAuthorization: request.value(forHTTPHeaderField: "Authorization")) != nil {
            return true
        }
        if let host = url.host, Self.token(for: host) != nil {
            return true
        }
        return false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        // ---- 1. 令牌：优先取请求头里的，其次注册表 ----
        var token = Self.parseToken(fromAuthorization: request.value(forHTTPHeaderField: "Authorization"))
        if token == nil {
            token = Self.token(for: host)
        }
        if let token {
            Self.registerToken(host: host, token: token)
        }

        // ---- 2. 构造改写后的请求 ----
        let originalPath = Self.normalizedPath(of: url)
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        mutable.url = Self.rewrite(url: url)

        if let token {
            mutable.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        if mutable.value(forHTTPHeaderField: "X-Emby-Authorization") == nil {
            let authorization = mutable.value(forHTTPHeaderField: "Authorization")
                ?? "MediaBrowser Client=\"Swiftfin\", Device=\"AppleTV\", DeviceId=\"swiftfin-fnos\", Version=\"1.0\""
            mutable.setValue(Self.quoted(authorization), forHTTPHeaderField: "X-Emby-Authorization")
        }

        // PlaybackInfo 仅支持 GET
        if mutable.httpMethod == "POST", originalPath.contains("/PlaybackInfo") {
            mutable.httpMethod = "GET"
            mutable.httpBody = nil
            mutable.httpBodyStream = nil
            mutable.setValue(nil, forHTTPHeaderField: "Content-Type")
            mutable.setValue(nil, forHTTPHeaderField: "Content-Length")
        }

        guard let rewrittenURL = mutable.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        // ---- 3. 响应模式判定 ----
        if originalPath.hasSuffix("/Items/Latest") {
            // Latest 改写：响应需从信封转回纯数组（SDK 期望 [BaseItemDto]）
            responseMode = .latestArray
        } else if originalPath.hasSuffix("/Views") {
            // /Views：正常透传，同时收集媒体库 ID
            responseMode = .viewsCollect
        } else if Self.needsViewMerge(path: originalPath, queryItems(of: url)), !Self.viewIDs(for: host).isEmpty {
            // 全局 Items 查询：拆分为逐库请求后合并
            responseMode = .multiView
            startMergedLoad(baseRequest: mutable, host: host)
            return
        } else {
            responseMode = .passthrough
        }

        // ---- 4. 未实现端点：合成响应，避免上层报错 ----
        // 码率测试：返回 size 字节的零填充（瞬时完成 → 实测码率极高 → 直接原码播放）
        if originalPath.contains("/Playback/BitrateTest") {
            let sizeParameter = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name.lowercased() == "size" }?
                .value
            let size = min(sizeParameter.flatMap(Int.init) ?? 1_000_000, 20_000_000)

            let response = HTTPURLResponse(
                url: rewrittenURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream"]
            )
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(count: size))
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }

        if Self.isUnimplementedPath(originalPath) {
            let envelope = Data(#"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#.utf8)
            let response = HTTPURLResponse(
                url: rewrittenURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: envelope)
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }

        // ---- 5. 转发 ----
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        forwardingSession = session
        dataTask = session.dataTask(with: mutable as URLRequest)
        dataTask?.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
        mergeRequests.removeAll()
        forwardingSession?.invalidateAndCancel()
        forwardingSession = nil
    }

    // MARK: - 转发状态

    private enum ResponseMode {
        case passthrough
        case latestArray
        case viewsCollect
        case multiView
    }

    private var responseMode: ResponseMode = .passthrough
    private var dataTask: URLSessionDataTask?
    private var forwardingSession: URLSession?

    // 缓冲（latestArray / viewsCollect / multiView 共用）
    private var bufferedData = Data()
    private var bufferedResponse: HTTPURLResponse?

    // multiView 合并状态
    private var mergeRequests: [URLRequest] = []
    private var mergeSortByDate = false
    private var mergeStartIndex = 0
    private var mergeLimit = 100
    private var mergedItems: [[String: Any]] = []
}

// MARK: - 转发代理

extension FnOSCompatURLProtocol: URLSessionDataDelegate {

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if responseMode == .passthrough {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        } else {
            bufferedResponse = response as? HTTPURLResponse
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        if responseMode == .passthrough {
            client?.urlProtocol(self, didLoad: data)
        } else {
            bufferedData.append(data)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        // 持有"刚刚完成"的那个会话，避免误杀 multiView 链中刚启动的下一个会话
        let completedSession = forwardingSession

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            cleanup(session: completedSession)
            return
        }

        switch responseMode {
        case .passthrough:
            client?.urlProtocolDidFinishLoading(self)
        case .latestArray:
            deliverLatestAsArray()
        case .viewsCollect:
            collectViewsAndDeliver()
        case .multiView:
            handleMergeStepCompletion()
        }

        cleanup(session: completedSession)
    }

    /// 回收已完成的内部会话并清理缓冲
    private func cleanup(session: URLSession?) {
        session?.invalidateAndCancel()
        if forwardingSession === session {
            forwardingSession = nil
            dataTask = nil
        }
        bufferedData.removeAll()
        bufferedResponse = nil
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: latestArray：把 /Items 信封 `{Items:[...]}` 转回 `[...]`

    private func deliverLatestAsArray() {
        var payload: Data?
        if let object = try? JSONSerialization.jsonObject(with: bufferedData) as? [String: Any],
           let items = object["Items"] {
            payload = try? JSONSerialization.data(withJSONObject: items)
        }

        if let payload {
            let response = HTTPURLResponse(
                url: bufferedResponse?.url ?? request.url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: payload)
            }
        } else {
            // 转换失败：原样透传
            if let bufferedResponse {
                client?.urlProtocol(self, didReceive: bufferedResponse, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: bufferedData)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    // MARK: viewsCollect：透传 /Views 响应并注册媒体库 ID

    private func collectViewsAndDeliver() {
        if let object = try? JSONSerialization.jsonObject(with: bufferedData) as? [String: Any],
           let items = object["Items"] as? [[String: Any]] {
            let ids = items.compactMap { $0["Id"] as? String }
            if let host = request.url?.host, !ids.isEmpty {
                Self.registerViewIDs(host: host, ids: ids)
            }
        }

        if let bufferedResponse {
            client?.urlProtocol(self, didReceive: bufferedResponse, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: bufferedData)
        client?.urlProtocolDidFinishLoading(self)
    }

    // MARK: multiView：逐库请求 → 合并 → 分页切片

    private func startMergedLoad(baseRequest: NSMutableURLRequest, host: String) {
        guard let url = baseRequest.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        var query = components.queryItems ?? []
        let readParam = { (name: String) -> Int? in
            query.first { $0.name.lowercased() == name }?.value.flatMap(Int.init)
        }
        mergeLimit = readParam("limit") ?? 100
        mergeStartIndex = readParam("startindex") ?? 0
        mergeSortByDate = query.first { $0.name.lowercased() == "sortby" }?
            .value?.lowercased() == "datecreated"

        // 每库请求多取一些以支持跨库排序后的分页
        query.removeAll { $0.name.lowercased() == "parentid" }
        query.removeAll { $0.name.lowercased() == "startindex" }
        query.removeAll { $0.name.lowercased() == "limit" }
        query.append(URLQueryItem(name: "Limit", value: String(mergeStartIndex + mergeLimit)))

        var requests: [URLRequest] = []
        for viewID in Self.viewIDs(for: host) {
            var perView = query
            perView.append(URLQueryItem(name: "ParentId", value: viewID))
            var perComponents = components
            perComponents.queryItems = perView
            guard let perURL = perComponents.url else { continue }

            var perRequest = URLRequest(url: perURL)
            perRequest.httpMethod = "GET"
            perRequest.timeoutInterval = 20
            for (key, value) in baseRequest.allHTTPHeaderFields ?? [:] {
                perRequest.setValue(value, forHTTPHeaderField: key)
            }
            requests.append(perRequest)
        }

        guard !requests.isEmpty else {
            // 没有可拆分的库：退化为单请求直发
            responseMode = .passthrough
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            forwardingSession = session
            dataTask = session.dataTask(with: baseRequest as URLRequest)
            dataTask?.resume()
            return
        }

        mergeRequests = requests
        loadNextMergeRequest()
    }

    private func loadNextMergeRequest() {
        guard !mergeRequests.isEmpty else { return }
        let next = mergeRequests.removeFirst()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        forwardingSession = session
        dataTask = session.dataTask(with: next)
        dataTask?.resume()
    }

    private func handleMergeStepCompletion() {
        if let object = try? JSONSerialization.jsonObject(with: bufferedData) as? [String: Any],
           let items = object["Items"] as? [[String: Any]] {
            mergedItems.append(contentsOf: items)
        }
        bufferedData.removeAll()
        bufferedResponse = nil

        if !mergeRequests.isEmpty {
            loadNextMergeRequest()
            return
        }

        // 全部库完成：排序 → 总数 → 分页切片
        var items = mergedItems
        if mergeSortByDate {
            items.sort {
                ($0["DateCreated"] as? String ?? "") > ($1["DateCreated"] as? String ?? "")
            }
        }
        let total = items.count
        let slice = Array(items.dropFirst(mergeStartIndex).prefix(mergeLimit))
        mergedItems.removeAll()

        let envelope: [String: Any] = [
            "Items": slice,
            "TotalRecordCount": total,
            "StartIndex": mergeStartIndex,
        ]
        let payload = (try? JSONSerialization.data(withJSONObject: envelope))
            ?? Data(#"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#.utf8)

        let response = HTTPURLResponse(
            url: request.url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - 改写规则

extension FnOSCompatURLProtocol {

    /// 去掉可选的 /emby 前缀后的规范化路径
    private static func normalizedPath(of url: URL) -> String {
        var path = url.path
        if path.hasPrefix("/emby") {
            path = String(path.dropFirst("/emby".count))
        }
        return path
    }

    private func queryItems(of url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    /// 全局 Items 查询判定（无 ParentId 且无 SearchTerm）
    private static func needsViewMerge(path: String, _ query: [URLQueryItem]) -> Bool {
        guard path.hasSuffix("/Items"),
              path.contains("/Users/"),
              !path.hasSuffix("/Items/Latest")
        else { return false }

        let has = { (name: String) in query.contains { $0.name.lowercased() == name } }
        return !has("parentid") && !has("searchterm")
    }

    /// 未实现、需要合成空信封的路径
    private static func isUnimplementedPath(_ path: String) -> Bool {
        // /Users/{uid}/Items/Resume（GET/POST 均未实现）
        if path.hasSuffix("/Items/Resume") { return true }
        // /Genres（返回网页）
        if path == "/Genres" || path.hasSuffix("/Genres") { return true }
        // 相似推荐（返回网页）
        if path.contains("/Similar") { return true }
        return false
    }

    /// 主改写入口：返回替换后的 URL（仅改 URL，不动 header/method）
    private static func rewrite(url: URL) -> URL {
        let path = normalizedPath(of: url)

        // /Users/{uid}/Items/Latest → /Users/{uid}/Items + 等效查询
        // 注意：兼容层的 IncludeItemTypes 不支持逗号多类型（实测传 "Movie,Series" 返回 0 条），
        // 因此这里不能带类型过滤，用 DateCreated 降序模拟"最新"语义。
        if path.hasSuffix("/Items/Latest") {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.path = String(path.dropLast("/Latest".count))
            var query = (components?.queryItems ?? [])
                .filter { $0.name.lowercased() != "includeitemtypes" }

            let existing = { (name: String) in query.first { $0.name.lowercased() == name.lowercased() }?.value }
            if existing("Limit") == nil {
                query.append(URLQueryItem(name: "Limit", value: "12"))
            }
            if existing("SortBy") == nil {
                query.append(URLQueryItem(name: "SortBy", value: "DateCreated"))
            }
            if existing("SortOrder") == nil {
                query.append(URLQueryItem(name: "SortOrder", value: "Descending"))
            }
            query.append(URLQueryItem(name: "Recursive", value: "true"))
            if existing("Fields") == nil {
                query.append(URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio"))
            }

            components?.queryItems = query
            return components?.url ?? url
        }

        // /Users/{uid}/Items（媒体库内容查询）：
        // 1. 补 Fields 与 Limit（缺失时兼容层 400 / 返回空数组）
        // 2. IncludeItemTypes 多类型（逗号分隔）兼容层解析失败返回 0 条 → 整个参数移除，
        //    由 ParentId/库范围兜底（单类型参数正常，保留）
        if path.hasSuffix("/Items") {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var query = components?.queryItems ?? []

            let hasField = { (name: String) in query.contains { $0.name.lowercased() == name.lowercased() } }
            if !hasField("Fields") {
                query.append(URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio"))
            }
            if !hasField("Limit") {
                query.append(URLQueryItem(name: "Limit", value: "100"))
            }
            if let includeTypes = query.first(where: { $0.name.lowercased() == "includeitemtypes" }),
               includeTypes.value?.contains(",") == true {
                query.removeAll { $0.name.lowercased() == "includeitemtypes" }
            }

            components?.queryItems = query
            return components?.url ?? url
        }

        return url
    }

    /// 从 `Authorization: MediaBrowser ..., Token=xxx` 提取令牌
    private static func parseToken(fromAuthorization authorization: String?) -> String? {
        guard let authorization else { return nil }

        for pair in authorization.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            if key == "Token", value.isNotEmpty {
                return value
            }
        }
        return nil
    }

    /// 字段值统一加引号（与 Infuse 发出的格式一致）
    private static func quoted(_ authorization: String) -> String {
        guard let schemeEnd = authorization.range(of: "MediaBrowser ")
            ?? authorization.range(of: "Emby ")
        else { return authorization }

        let scheme = String(authorization[..<schemeEnd.upperBound])
        let fields = authorization[schemeEnd.upperBound...]
            .split(separator: ",")
            .map { field -> String in
                let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    return field.trimmingCharacters(in: .whitespaces)
                }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return "\(key)=\"\(value)\""
            }

        return scheme + fields.joined(separator: ", ")
    }
}
