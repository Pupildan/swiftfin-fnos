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
/// 9. `/Genres`、`/Similar`、`/LocalTrailers`、`/Intros`、`/SpecialFeatures`、
///    `/ThemeMedia` 未实现（返回 200 + 网页 HTML）→ 合成与 SDK 期望形状
///    一致的空响应；其余漏网端点由 passthrough 的 text/html 检测兜底；
/// 10. `/Users/{uid}/Views` 不返回 `CollectionType`，而 Swiftfin 首页按
///     collectionType ∈ {movies, tvshows, homevideos, musicvideos} 过滤媒体库
///     → 逐库探测内容类型后合成（tvshows/movies/musicvideos/homevideos），
///     并在响应头 `X-FnOS-Shim: collection-type-synthesized` 标注。
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

    // MARK: 诊断计数器（设置页「飞牛适配诊断」显示，用于定位拦截链断点）

    private static let statsLock = NSLock()
    private static var _canInitCount = 0
    private static var _startLoadingCount = 0
    private static var _injectedCount = 0

    static func stats() -> (canInit: Int, startLoading: Int, injected: Int) {
        statsLock.lock()
        defer { statsLock.unlock() }
        return (_canInitCount, _startLoadingCount, _injectedCount)
    }

    private static func noteCanInit() {
        statsLock.lock()
        _canInitCount += 1
        statsLock.unlock()
    }

    private static func noteStartLoading() {
        statsLock.lock()
        _startLoadingCount += 1
        statsLock.unlock()
    }

    private static func noteInjected() {
        statsLock.lock()
        _injectedCount += 1
        statsLock.unlock()
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        noteCanInit()

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
        Self.noteStartLoading()

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
            // Latest 改写为无 ParentId 的全局查询 → fnOS 返回 0，
            // 必须走跨库合并；SDK 期望纯数组，交付时转换。
            responseMode = .latestArray
            deliverMergeAsArray = true
            if Self.viewIDs(for: host).isEmpty {
                startViewsBootstrap(baseRequest: mutable, host: host)
                return
            }
            startMergedLoad(baseRequest: mutable, host: host)
            return
        } else if originalPath.hasSuffix("/Views") {
            // /Views：正常透传，同时收集媒体库 ID
            responseMode = .viewsCollect
        } else if Self.needsViewMerge(path: originalPath, queryItems(of: url)) {
            // 全局 Items 查询：拆分为逐库请求后合并。
            // 库 ID 注册表为空（/Views 尚未被调用，如 App 启动直接进电影/剧集页签）时，
            // 先引导拉取一次 /Views 注册库 ID，再合并——否则 fnOS 全局查询一律返回 0。
            if Self.viewIDs(for: host).isEmpty {
                responseMode = .viewsBootstrap
                startViewsBootstrap(baseRequest: mutable, host: host)
                return
            }
            responseMode = .multiView
            deliverMergeAsArray = false
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
            let envelope = Self.synthesizedBody(forUnimplementedPath: originalPath)
            let response = HTTPURLResponse(
                url: rewrittenURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "X-FnOS-Shim": "unimplemented-endpoint",
                    "X-FnOS-Original-Path": originalPath,
                ]
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
        probeRemaining.removeAll()
        probeCurrentID = nil
        pendingMergeRequest = nil
        pendingMergeHost = nil
        forwardingSession?.invalidateAndCancel()
        forwardingSession = nil
    }

    // MARK: - 转发状态

    private enum ResponseMode {
        case passthrough
        case latestArray
        case viewsCollect
        case multiView
        /// 全局查询到达但库 ID 注册表为空：先拉取 /Views 注册，再进入合并
        case viewsBootstrap
        /// fnOS 对未实现端点返回 200 + text/html 网页 → 缓冲后合成空响应
        case htmlBlocked
    }

    private var responseMode: ResponseMode = .passthrough
    private var dataTask: URLSessionDataTask?
    private var forwardingSession: URLSession?

    // 缓冲（latestArray / viewsCollect / multiView / htmlBlocked 共用）
    private var bufferedData = Data()
    private var bufferedResponse: HTTPURLResponse?

    // multiView 合并状态
    private var mergeRequests: [URLRequest] = []
    private var mergeSort: MergeSort = .none
    private var mergeStartIndex = 0
    private var mergeLimit = 100
    private var mergedItems: [[String: Any]] = []
    /// Latest 场景：合并结果以纯数组交付（SDK 期望 [BaseItemDto]）
    private var deliverMergeAsArray = false

    /// 全局查询的跨库合并排序方式
    private enum MergeSort {
        case none
        case dateCreated
        case sortName
    }

    // 全局查询到达但库 ID 注册表为空时：先引导拉取 /Views 再合并
    private var pendingMergeRequest: NSMutableURLRequest?
    private var pendingMergeHost: String?

    // /Views CollectionType 探测链状态
    // fnOS 不返回库类型，而 Swiftfin 首页/媒体库按 collectionType 过滤 → 缺失全被丢弃。
    // 这里逐库请求一次内容，按内容类型合成 CollectionType。
    private var probeRemaining: [(id: String, item: [String: Any])] = []
    private var probeTypes: [String: Set<String>] = [:]
    private var probeCurrentID: String?
    private var probeHost: String?
    private var viewsObject: [String: Any] = [:]
}

// MARK: - 转发代理

extension FnOSCompatURLProtocol: URLSessionDataDelegate {

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // passthrough 模式下检测 fnOS「未实现端点返回网页」：200 + text/html
        // → 切入 htmlBlocked 模式缓冲，结束时合成空响应（App 的日志页可凭
        //   X-FnOS-Shim 响应头确认拦截发生）。
        if responseMode == .passthrough,
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true
        {
            responseMode = .htmlBlocked
        }

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
            // 探测链中的请求失败不算致命：记录空结果后继续下一库
            if responseMode == .viewsCollect, probeCurrentID != nil {
                probeTypes[probeCurrentID ?? ""] = []
                probeCurrentID = nil
                bufferedData.removeAll()
                bufferedResponse = nil
                continueViewProbes()
                cleanup(session: completedSession)
                return
            }
            // 引导 /Views 失败：降级为直发原请求（fnOS 返回 0 但不报错）
            if responseMode == .viewsBootstrap, let baseRequest = pendingMergeRequest {
                pendingMergeRequest = nil
                pendingMergeHost = nil
                responseMode = deliverMergeAsArray ? .latestArray : .passthrough
                deliverMergeAsArray = false
                startForwarding(baseRequest)
                cleanup(session: completedSession)
                return
            }
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
            if probeCurrentID != nil {
                handleViewProbeCompletion()
            } else {
                collectViewsAndDeliver()
            }
        case .multiView:
            handleMergeStepCompletion()
        case .viewsBootstrap:
            handleViewsBootstrapCompletion()
        case .htmlBlocked:
            deliverSynthesizedEmptyForHTML()
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
                url: bufferedResponse?.url ?? request.url ?? URL(fileURLWithPath: "/"),
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

    // MARK: viewsCollect：透传 /Views 响应、注册媒体库 ID 并合成 CollectionType

    private func collectViewsAndDeliver() {
        guard let object = try? JSONSerialization.jsonObject(with: bufferedData) as? [String: Any],
              let items = object["Items"] as? [[String: Any]]
        else {
            deliverBufferedAsIs()
            return
        }

        // 注册媒体库 ID（multiView 合并依赖）
        let ids = items.compactMap { $0["Id"] as? String }
        if let host = request.url?.host, !ids.isEmpty {
            Self.registerViewIDs(host: host, ids: ids)
        }

        // fnOS 不返回 CollectionType（实测 detail 里是空串），
        // 而 Swiftfin 首页按 collectionType ∈ {movies, tvshows, homevideos, musicvideos}
        // 过滤媒体库 → 缺失时全部被丢弃（空库根因）。逐库探测内容类型后合成。
        guard let host = request.url?.host else {
            deliverBufferedAsIs()
            return
        }

        probeRemaining = items.compactMap { dict -> (id: String, item: [String: Any])? in
            guard dict["CollectionType"] == nil, let id = dict["Id"] as? String else { return nil }
            return (id, dict)
        }

        guard !probeRemaining.isEmpty else {
            deliverBufferedAsIs()
            return
        }

        probeHost = host
        probeTypes = [:]
        viewsObject = object
        continueViewProbes()
    }

    private func continueViewProbes() {
        guard let next = probeRemaining.first else {
            finishViewProbes()
            return
        }
        probeRemaining.removeFirst()
        probeCurrentID = next.id

        guard let originalURL = request.url,
              let uid = Self.viewUserID(fromViewsURL: originalURL),
              let base = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
        else {
            finishViewProbes()
            return
        }

        // /Users/{uid}/Items 必须带 Fields + Limit（兼容层硬性要求）
        var components = base
        components.path = "/Users/\(uid)/Items"
        components.queryItems = [
            URLQueryItem(name: "ParentId", value: next.id),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "30"),
            URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio"),
        ]

        guard let probeURL = components.url else {
            finishViewProbes()
            return
        }

        var probeRequest = URLRequest(url: probeURL)
        probeRequest.httpMethod = "GET"
        probeRequest.timeoutInterval = 15
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            guard key.caseInsensitiveCompare("Host") != .orderedSame else { continue }
            probeRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let token = Self.token(for: probeHost ?? "") {
            probeRequest.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        if probeRequest.value(forHTTPHeaderField: "X-Emby-Authorization") == nil {
            let authorization = probeRequest.value(forHTTPHeaderField: "Authorization")
                ?? "MediaBrowser Client=\"Swiftfin\", Device=\"AppleTV\", DeviceId=\"swiftfin-fnos\", Version=\"1.0\""
            probeRequest.setValue(Self.quoted(authorization), forHTTPHeaderField: "X-Emby-Authorization")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        forwardingSession = session
        dataTask = session.dataTask(with: probeRequest)
        dataTask?.resume()
    }

    private func handleViewProbeCompletion() {
        if let id = probeCurrentID,
           let object = try? JSONSerialization.jsonObject(with: bufferedData) as? [String: Any],
           let items = object["Items"] as? [[String: Any]]
        {
            probeTypes[id] = Set(items.compactMap { $0["Type"] as? String })
        }
        probeCurrentID = nil
        bufferedData.removeAll()
        bufferedResponse = nil

        continueViewProbes()
    }

    // MARK: viewsBootstrap：全局查询先于 /Views 到达时，先引导注册库 ID

    private func startViewsBootstrap(baseRequest: NSMutableURLRequest, host: String) {
        guard let originalURL = request.url,
              let uid = Self.userID(fromAPIPath: originalURL),
              var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
        else {
            // 无法构造引导请求：退化为直发（fnOS 全局查询会返回 0，但不至于报错）
            responseMode = .passthrough
            startForwarding(baseRequest)
            return
        }

        pendingMergeRequest = baseRequest
        pendingMergeHost = host

        components.path = "/Users/\(uid)/Views"
        components.query = nil

        guard let viewsURL = components.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        var bootstrapRequest = URLRequest(url: viewsURL)
        bootstrapRequest.httpMethod = "GET"
        bootstrapRequest.timeoutInterval = 15
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            guard key.caseInsensitiveCompare("Host") != .orderedSame,
                  key.caseInsensitiveCompare("Content-Length") != .orderedSame,
                  key.caseInsensitiveCompare("Content-Type") != .orderedSame
            else { continue }
            bootstrapRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let token = Self.token(for: host) {
            bootstrapRequest.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        if bootstrapRequest.value(forHTTPHeaderField: "X-Emby-Authorization") == nil {
            let authorization = bootstrapRequest.value(forHTTPHeaderField: "Authorization")
                ?? "MediaBrowser Client=\"Swiftfin\", Device=\"AppleTV\", DeviceId=\"swiftfin-fnos\", Version=\"1.0\""
            bootstrapRequest.setValue(Self.quoted(authorization), forHTTPHeaderField: "X-Emby-Authorization")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        forwardingSession = session
        dataTask = session.dataTask(with: bootstrapRequest)
        dataTask?.resume()
    }

    private func handleViewsBootstrapCompletion() {
        if let host = pendingMergeHost,
           let object = try? JSONSerialization.jsonObject(with: bufferedData) as? [String: Any],
           let items = object["Items"] as? [[String: Any]]
        {
            let ids = items.compactMap { $0["Id"] as? String }
            if !ids.isEmpty {
                Self.registerViewIDs(host: host, ids: ids)
            }
        }

        guard let baseRequest = pendingMergeRequest, let host = pendingMergeHost else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        pendingMergeRequest = nil
        pendingMergeHost = nil
        bufferedData.removeAll()
        bufferedResponse = nil

        responseMode = .multiView
        startMergedLoad(baseRequest: baseRequest, host: host)
    }

    private func startForwarding(_ baseRequest: NSMutableURLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        forwardingSession = session
        dataTask = session.dataTask(with: baseRequest as URLRequest)
        dataTask?.resume()
    }

    private func finishViewProbes() {
        probeCurrentID = nil

        guard var items = viewsObject["Items"] as? [[String: Any]] else {
            deliverBufferedAsIs()
            return
        }

        items = items.map { dict in
            guard let id = dict["Id"] as? String, dict["CollectionType"] == nil else { return dict }
            var patched = dict
            patched["CollectionType"] = Self.collectionType(forItemTypes: probeTypes[id] ?? [])
            return patched
        }
        viewsObject["Items"] = items
        Self.noteInjected()

        let payload = (try? JSONSerialization.data(withJSONObject: viewsObject)) ?? bufferedData

        let response = HTTPURLResponse(
            url: bufferedResponse?.url ?? request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "X-FnOS-Shim": "collection-type-synthesized",
            ]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    // MARK: htmlBlocked：fnOS 未实现端点返回网页 → 合成正确形状的空响应

    private func deliverSynthesizedEmptyForHTML() {
        let path = Self.normalizedPath(of: request.url ?? URL(fileURLWithPath: "/"))
        let payload = Self.emptyBody(forHTMLPath: path)

        let response = HTTPURLResponse(
            url: bufferedResponse?.url ?? request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "X-FnOS-Shim": "html-blocked",
                "X-FnOS-Original-Path": path,
            ]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    // MARK: 透传缓冲

    private func deliverBufferedAsIs() {
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
        let sortBy = query.first { $0.name.lowercased() == "sortby" }?
            .value?.lowercased() ?? ""
        if sortBy.contains("datecreated") {
            mergeSort = .dateCreated
        } else if sortBy.contains("sortname") {
            mergeSort = .sortName
        } else {
            mergeSort = .none
        }

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
            startForwarding(baseRequest)
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
        switch mergeSort {
        case .dateCreated:
            items.sort {
                ($0["DateCreated"] as? String ?? "") > ($1["DateCreated"] as? String ?? "")
            }
        case .sortName:
            items.sort {
                ($0["SortName"] as? String ?? $0["Name"] as? String ?? "")
                    .localizedStandardCompare($1["SortName"] as? String ?? $1["Name"] as? String ?? "") == .orderedAscending
            }
        case .none:
            break
        }
        let total = items.count
        let slice = Array(items.dropFirst(mergeStartIndex).prefix(mergeLimit))
        mergedItems.removeAll()

        let payload: Data
        if deliverMergeAsArray {
            // Latest：SDK 期望 [BaseItemDto] 纯数组
            payload = (try? JSONSerialization.data(withJSONObject: slice))
                ?? Data("[]".utf8)
        } else {
            let envelope: [String: Any] = [
                "Items": slice,
                "TotalRecordCount": total,
                "StartIndex": mergeStartIndex,
            ]
            payload = (try? JSONSerialization.data(withJSONObject: envelope))
                ?? Data(#"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#.utf8)
        }
        deliverMergeAsArray = false

        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
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

    /// 未实现、需要合成空响应的路径
    private static func isUnimplementedPath(_ path: String) -> Bool {
        // /Users/{uid}/Items/Resume（GET/POST 均未实现）
        if path.hasSuffix("/Items/Resume") { return true }
        // /Genres（返回网页）
        if path == "/Genres" || path.hasSuffix("/Genres") { return true }
        // 相似推荐（返回网页）
        if path.contains("/Similar") { return true }
        // 本地预告片/映前广告/特别收录（返回网页，SDK 期望 [BaseItemDto]）
        if path.contains("/LocalTrailers") || path.contains("/Intros") || path.contains("/SpecialFeatures") {
            return true
        }
        // 主题音乐/视频（返回网页，SDK 期望 ThemeMediaResult 对象）
        if path.contains("/ThemeMedia") { return true }
        return false
    }

    /// isUnimplementedPath 命中时应合成的响应体（形状必须与 SDK 期望一致）
    private static func synthesizedBody(forUnimplementedPath path: String) -> Data {
        if path.contains("/ThemeMedia") {
            return Data(#"""
                {"ThemeSongsResult":{"Items":[],"TotalRecordCount":0,"StartIndex":0},"ThemeVideosResult":{"Items":[],"TotalRecordCount":0,"StartIndex":0}}
                """#.utf8)
        }
        if path.contains("/LocalTrailers") || path.contains("/Intros") || path.contains("/SpecialFeatures") {
            return Data("[]".utf8)
        }
        return Data(#"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#.utf8)
    }

    /// htmlBlocked 兜底：按路径猜测 SDK 期望的空响应形状
    private static func emptyBody(forHTMLPath path: String) -> Data {
        // 纯数组端点
        if path.hasSuffix("/Latest") { return Data("[]".utf8) }
        if path.contains("/LocalTrailers") || path.contains("/Intros") || path.contains("/SpecialFeatures") {
            return Data("[]".utf8)
        }
        if path.contains("/ThemeMedia") {
            return Data(#"""
                {"ThemeSongsResult":{"Items":[],"TotalRecordCount":0,"StartIndex":0},"ThemeVideosResult":{"Items":[],"TotalRecordCount":0,"StartIndex":0}}
                """#.utf8)
        }
        // 其余一律给查询结果信封（Items/Genres/Similar/... 兼容）
        return Data(#"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#.utf8)
    }

    /// 从 /Users/{uid}/Views 请求 URL 提取用户 ID
    private static func viewUserID(fromViewsURL url: URL?) -> String? {
        guard let url else { return nil }
        let path = normalizedPath(of: url)
        guard path.hasSuffix("/Views") else { return nil }
        return userID(fromAPIPath: url)
    }

    /// 从 /Users/{uid}/... API 路径提取用户 ID
    private static func userID(fromAPIPath url: URL?) -> String? {
        guard let url else { return nil }
        let path = normalizedPath(of: url)
        let parts = path.split(separator: "/").map(String.init)
        guard let usersIndex = parts.firstIndex(of: "Users"),
              usersIndex + 1 < parts.count
        else { return nil }
        return parts[usersIndex + 1]
    }

    /// 按库内容类型合成 CollectionType（保证落在 Swiftfin 支持且首页不过滤的集合内）
    private static func collectionType(forItemTypes types: Set<String>) -> String {
        let hasSeries = types.contains("Series") || types.contains("Episode") || types.contains("Season")
        let hasMovie = types.contains("Movie")
        let hasMusicVideo = types.contains("MusicVideo")

        if hasSeries && hasMovie { return "homevideos" }
        if hasSeries { return "tvshows" }
        if hasMovie { return "movies" }
        if hasMusicVideo { return "musicvideos" }
        // 空库/未知内容：homevideos 不会被首页与媒体库页过滤
        return "homevideos"
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
