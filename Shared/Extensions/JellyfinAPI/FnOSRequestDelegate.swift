//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Get
import JellyfinAPI

/// 飞牛影视（fnOS 8005 Jellyfin 兼容层）请求适配器 —— delegate 层实现。
///
/// 背景：URLProtocol 方案（FnOSCompatURLProtocol）在真机上从未对 API 请求生效
/// （诊断计数显示只有图片管线被拦截），而 Get 的 `willSendRequest` 在真机上
/// 确定运行（鉴权头注入即由它完成，登录/浏览因此一直可用）。
/// 因此把全部 API 适配迁移到本 delegate。
///
/// 请求侧（直接改写 URLRequest）：
/// 1. 复制 Authorization → X-Emby-Authorization（字段值加引号，仿 Infuse）；
/// 2. 注入独立 `X-Emby-Token` 头（兼容层要求）；
/// 3. `/Items` 查询补必填的 Fields/Limit、剥离不支持的逗号多类型
///    IncludeItemTypes；
/// 4. PlaybackInfo 仅支持 GET（POST 未路由）。
///
/// 响应侧（需要改写响应体的场景）：
/// 5. `/Users/{uid}/Views` 注入 CollectionType（fnOS 不返回，而 App 按
///    collectionType ∈ {movies, tvshows, homevideos, musicvideos} 过滤媒体库）；
/// 6. 全局 `/Items` 查询（无 ParentId）按媒体库拆分请求后合并、排序、分页
///    （fnOS 无 ParentId 一律返回 0）；
/// 7. `/Items/Latest` 同样按库合并后输出纯数组（SDK 期望 [BaseItemDto]）；
/// 8. 未实现端点（Similar/LocalTrailers/Intros/SpecialFeatures/ThemeMedia/
///    Genres/Recommendations/Resume）合成与 SDK 期望形状一致的空响应；
/// 9. 库详情 `CollectionType: ""` 会炸解码 → 移除该键。
///
/// 响应改写的实现：在 willSendRequest（async）里用裸 URLSession（无任何
/// URLProtocol，避免递归）完成实际请求与改写，把结果 JSON 写入临时文件，
/// 再把请求 URL 重写为 file:// —— URLSession 原生支持 file 加载，
/// Get 对非 HTTP 响应跳过状态码校验后正常解码。
final class FnOSRequestDelegate: APIClientDelegate, @unchecked Sendable {

    // MARK: - 裸会话（不走任何 URLProtocol，避免递归改写）

    private static let bareSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.protocolClasses = []
        return URLSession(configuration: configuration)
    }()

    // MARK: - 媒体库 ID 缓存（全局查询合并用）

    private static let viewCacheLock = NSLock()
    private static var viewIDsByHost: [String: Set<String>] = [:]

    // MARK: - APIClientDelegate

    func client(_ client: APIClient, willSendRequest request: inout URLRequest) async throws {
        let authorization = request.value(forHTTPHeaderField: "Authorization")

        // 1) 老式鉴权头（原 LegacyAuthHeaderInjector 逻辑）
        if let authorization,
           authorization.hasPrefix("MediaBrowser"),
           request.value(forHTTPHeaderField: "X-Emby-Authorization") == nil
        {
            request.setValue(Self.quoted(authorization), forHTTPHeaderField: "X-Emby-Authorization")
        }

        // 2) 独立 X-Emby-Token（fnOS 要求；仅已登录请求携带）
        guard let token = Self.parseToken(fromAuthorization: authorization) else { return }
        if request.value(forHTTPHeaderField: "X-Emby-Token") == nil {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }

        // PlaybackInfo 仅支持 GET
        if request.httpMethod == "POST",
           let url = request.url,
           Self.normalizedPath(of: url).contains("/PlaybackInfo")
        {
            request.httpMethod = "GET"
            request.httpBody = nil
            request.httpBodyStream = nil
            request.setValue(nil, forHTTPHeaderField: "Content-Type")
            request.setValue(nil, forHTTPHeaderField: "Content-Length")
        }

        // 3) fnOS 请求/响应改写
        guard let url = request.url,
              url.scheme == "http" || url.scheme == "https"
        else { return }

        let embyAuthorization = request.value(forHTTPHeaderField: "X-Emby-Authorization")
            ?? Self.quoted(authorization ?? "MediaBrowser")

        // 静默失败：改写异常时保持原请求透传（与未适配行为一致）
        let outcome = await Self.computeRewrite(
            url: url,
            method: request.httpMethod ?? "GET",
            token: token,
            embyAuthorization: embyAuthorization
        )

        switch outcome {
        case .none:
            break
        case .url(let newURL):
            request.url = newURL
        case .body(let data):
            if let fileURL = try? Self.writeTempFile(data) {
                request.url = fileURL
            }
        }
    }

    // MARK: - 改写结果

    private enum RewriteOutcome {
        case none
        case url(URL)
        case body(Data)
    }

    private static func writeTempFile(_ data: Data) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fnos-\(UUID().uuidString).json")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    // MARK: - 改写入口

    private static func computeRewrite(
        url: URL,
        method: String,
        token: String,
        embyAuthorization: String
    ) async -> RewriteOutcome {
        let path = normalizedPath(of: url)

        // ---- 响应合成类：未实现端点 ----
        if let emptyBody = synthesizedBody(forPath: path) {
            return .body(emptyBody)
        }

        // ---- /Views：注入 CollectionType ----
        if path.hasSuffix("/Views") {
            guard let data = try? await fetchAndInjectCollectionTypes(url: url, token: token, embyAuthorization: embyAuthorization) else {
                return .none
            }
            return .body(data)
        }

        // ---- /Items/Latest：跨库合并 → 纯数组 ----
        if path.hasSuffix("/Items/Latest") {
            guard let queryURL = try? latestQueryURL(from: url, path: path),
                  let data = try? await mergedItemsData(
                      url: queryURL,
                      token: token,
                      embyAuthorization: embyAuthorization,
                      deliverAsArray: true
                  )
            else { return .none }
            return .body(data)
        }

        // ---- /Items 查询 ----
        if path.hasSuffix("/Items"), path.contains("/Users/") {
            let query = queryItems(of: url)
            let has = { (name: String) in query.contains { $0.name.lowercased() == name } }

            if !has("parentid"), !has("searchterm") {
                // 全局查询：fnOS 一律返回 0 → 按库拆分合并
                guard let data = try? await mergedItemsData(
                    url: url,
                    token: token,
                    embyAuthorization: embyAuthorization,
                    deliverAsArray: false
                ) else { return .none }
                return .body(data)
            }

            // 带 ParentId 的常规查询：仅做 URL 微调后透传
            return .url(adjustItemsQuery(url: url))
        }

        // ---- 库/项目详情（仅 GET）：移除会炸解码的空 CollectionType ----
        if method == "GET",
           path.contains("/Users/"),
           path.contains("/Items/"),
           let data = try? await bareGet(url: url, token: token, embyAuthorization: embyAuthorization),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if (object["CollectionType"] as? String)?.isEmpty == true {
                object.removeValue(forKey: "CollectionType")
                if let cleaned = try? JSONSerialization.data(withJSONObject: object) {
                    return .body(cleaned)
                }
            }
            // 无需改写：透传原请求
        }

        return .none
    }

    // MARK: - 未实现端点合成

    private static func synthesizedBody(forPath path: String) -> Data? {
        let envelope = Data(#"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#.utf8)
        let emptyArray = Data("[]".utf8)
        let themeMedia = Data(#"""
            {"ThemeSongsResult":{"Items":[],"TotalRecordCount":0,"StartIndex":0},"ThemeVideosResult":{"Items":[],"TotalRecordCount":0,"StartIndex":0}}
            """#.utf8)

        if path.hasSuffix("/Items/Resume") { return envelope }
        if path.contains("/Genres") { return envelope }
        if path.contains("/Similar") { return envelope }
        if path.contains("/Shows/Recommendations") || path.contains("/Programs/Recommended") { return envelope }
        if path.contains("/LocalTrailers") || path.contains("/Intros") || path.contains("/SpecialFeatures") { return emptyArray }
        if path.contains("/ThemeMedia") { return themeMedia }
        return nil
    }

    // MARK: - /Views：CollectionType 注入

    private static func fetchAndInjectCollectionTypes(
        url: URL,
        token: String,
        embyAuthorization: String
    ) async throws -> Data {
        let data = try await bareGet(url: url, token: token, embyAuthorization: embyAuthorization)

        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["Items"] as? [[String: Any]]
        else {
            // 非 JSON（异常情况）：原样返回，交由 SDK 报错
            return data
        }

        // 注册媒体库 ID（全局查询合并依赖）
        let ids = items.compactMap { $0["Id"] as? String }
        if let host = url.host, !ids.isEmpty {
            viewCacheLock.lock()
            viewIDsByHost[host, default: []].formUnion(ids)
            viewCacheLock.unlock()
        }

        let uid = Self.userID(fromAPIPath: url)
        var patchedItems: [[String: Any]] = []
        for var item in items {
            if item["CollectionType"] == nil, let id = item["Id"] as? String {
                let types = await Self.probeItemTypes(
                    baseURL: url,
                    viewID: id,
                    uid: uid,
                    token: token,
                    embyAuthorization: embyAuthorization
                )
                item["CollectionType"] = Self.collectionType(forItemTypes: types)
            }
            patchedItems.append(item)
        }
        object["Items"] = patchedItems

        return try JSONSerialization.data(withJSONObject: object)
    }

    /// 逐库探测内容类型（每个库一次小请求）
    private static func probeItemTypes(
        baseURL: URL,
        viewID: String,
        uid: String?,
        token: String,
        embyAuthorization: String
    ) async -> Set<String> {
        guard let uid,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return [] }

        // /Users/{uid}/Items 必须带 Fields + Limit（兼容层硬性要求）
        components.path = "/Users/\(uid)/Items"
        components.queryItems = [
            URLQueryItem(name: "ParentId", value: viewID),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "30"),
            URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio"),
        ]
        guard let probeURL = components.url else { return [] }

        if let data = try? await bareGet(url: probeURL, token: token, embyAuthorization: embyAuthorization),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = object["Items"] as? [[String: Any]]
        {
            return Set(items.compactMap { $0["Type"] as? String })
        }
        return []
    }

    // MARK: - 全局查询跨库合并

    private static func mergedItemsData(
        url: URL,
        token: String,
        embyAuthorization: String,
        deliverAsArray: Bool
    ) async throws -> Data {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }

        var query = components.queryItems ?? []
        let readInt = { (name: String) -> Int? in
            query.first { $0.name.lowercased() == name }?.value.flatMap(Int.init)
        }
        let limit = readInt("limit") ?? 100
        let startIndex = readInt("startindex") ?? 0
        let sortBy = (query.first { $0.name.lowercased() == "sortby" }?.value ?? "").lowercased()

        let ids = try await viewIDs(url: url, token: token, embyAuthorization: embyAuthorization)

        var merged: [[String: Any]] = []
        for viewID in ids {
            var perView = query.filter { !["parentid", "startindex", "limit"].contains($0.name.lowercased()) }
            perView.append(URLQueryItem(name: "ParentId", value: viewID))
            perView.append(URLQueryItem(name: "Limit", value: String(startIndex + limit)))

            var perComponents = components
            perComponents.queryItems = perView
            guard let perURL = perComponents.url else { continue }

            if let data = try? await bareGet(url: perURL, token: token, embyAuthorization: embyAuthorization),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = object["Items"] as? [[String: Any]]
            {
                merged.append(contentsOf: items)
            }
        }

        switch true {
        case sortBy.contains("datecreated"):
            merged.sort {
                ($0["DateCreated"] as? String ?? "") > ($1["DateCreated"] as? String ?? "")
            }
        case sortBy.contains("sortname"):
            merged.sort {
                (($0["SortName"] as? String) ?? ($0["Name"] as? String) ?? "")
                    .localizedStandardCompare(
                        ($1["SortName"] as? String) ?? ($1["Name"] as? String) ?? ""
                    ) == .orderedAscending
            }
        default:
            break
        }

        let total = merged.count
        let slice = Array(merged.dropFirst(startIndex).prefix(limit))

        if deliverAsArray {
            return try JSONSerialization.data(withJSONObject: slice)
        }

        let envelope: [String: Any] = [
            "Items": slice,
            "TotalRecordCount": total,
            "StartIndex": startIndex,
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    /// 媒体库 ID：优先取缓存，否则现场拉取 /Views
    private static func viewIDs(
        url: URL,
        token: String,
        embyAuthorization: String
    ) async throws -> [String] {
        guard let host = url.host else { return [] }

        viewCacheLock.lock()
        let cached = viewIDsByHost[host]
        viewCacheLock.unlock()
        if let cached, !cached.isEmpty { return Array(cached).sorted() }

        guard let uid = userID(fromAPIPath: url) else { return [] }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/Users/\(uid)/Views"
        components?.query = nil
        guard let viewsURL = components?.url else { return [] }

        let data = try await bareGet(url: viewsURL, token: token, embyAuthorization: embyAuthorization)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["Items"] as? [[String: Any]]
        else { return [] }

        let ids = items.compactMap { $0["Id"] as? String }
        if !ids.isEmpty {
            viewCacheLock.lock()
            viewIDsByHost[host, default: []].formUnion(ids)
            viewCacheLock.unlock()
        }
        return ids
    }

    // MARK: - URL 微调（透传类查询）

    /// /Items 查询：补 Fields/Limit、剥离多类型 IncludeItemTypes
    private static func adjustItemsQuery(url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var query = components.queryItems ?? []

        let has = { (name: String) in query.contains { $0.name.lowercased() == name } }
        if !has("fields") {
            query.append(URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio"))
        }
        if !has("limit") {
            query.append(URLQueryItem(name: "Limit", value: "100"))
        }
        if let includeTypes = query.first(where: { $0.name.lowercased() == "includeitemtypes" }),
           includeTypes.value?.contains(",") == true
        {
            query.removeAll { $0.name.lowercased() == "includeitemtypes" }
        }

        components.queryItems = query
        return components.url ?? url
    }

    /// /Items/Latest → /Items 等效查询（无类型过滤，DateCreated 降序）
    private static func latestQueryURL(from url: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.path = String(path.dropLast("/Latest".count))
        var query = (components.queryItems ?? [])
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

        components.queryItems = query
        guard let result = components.url else { throw URLError(.badURL) }
        return result
    }

    // MARK: - 基础工具

    private static func bareGet(url: URL, token: String, embyAuthorization: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue(embyAuthorization, forHTTPHeaderField: "X-Emby-Authorization")

        let (data, response) = try await bareSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// 去掉可选的 /emby 前缀后的规范化路径
    private static func normalizedPath(of url: URL) -> String {
        var path = url.path
        if path.hasPrefix("/emby") {
            path = String(path.dropFirst("/emby".count))
        }
        return path
    }

    private static func queryItems(of url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    /// 从 /Users/{uid}/... API 路径提取用户 ID
    private static func userID(fromAPIPath url: URL?) -> String? {
        guard let url else { return nil }
        let parts = normalizedPath(of: url).split(separator: "/").map(String.init)
        guard let usersIndex = parts.firstIndex(of: "Users"),
              usersIndex + 1 < parts.count
        else { return nil }
        return parts[usersIndex + 1]
    }

    /// 按库内容类型合成 CollectionType（保证落在 App 支持且首页不过滤的集合内）
    private static func collectionType(forItemTypes types: Set<String>) -> String {
        let hasSeries = types.contains("Series") || types.contains("Episode") || types.contains("Season")
        let hasMovie = types.contains("Movie")
        let hasMusicVideo = types.contains("MusicVideo")

        if hasSeries && hasMovie { return "homevideos" }
        if hasSeries { return "tvshows" }
        if hasMovie { return "movies" }
        if hasMusicVideo { return "musicvideos" }
        return "homevideos"
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

    /// `MediaBrowser Client=x, Device=y, Token=z`
    ///   -> `MediaBrowser Client="x", Device="y", Token="z"`
    private static func quoted(_ authorization: String) -> String {
        guard let schemeEnd = authorization.range(of: "MediaBrowser ") else {
            return authorization
        }

        let scheme = authorization[..<schemeEnd.upperBound]
        let fields = authorization[schemeEnd.upperBound...]
            .split(separator: ",")
            .map { field -> String in
                let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    return field.trimmingCharacters(in: .whitespaces)
                }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                return "\(key)=\"\(value)\""
            }

        return scheme + fields.joined(separator: ", ")
    }
}

// MARK: - 响应落地说明
//
// 改写后的响应通过临时文件 + file:// URL 交付：URLSession 原生支持 file 加载，
// Get 对非 HTTP 响应跳过状态码校验后正常解码（Get validate 函数对
// 非 HTTPURLResponse 直接 return），Pulse 的 URLSessionProxyDelegate 仅
// 拦截固定选择器，对非 HTTP 响应无强制类型转换，不会崩溃。
