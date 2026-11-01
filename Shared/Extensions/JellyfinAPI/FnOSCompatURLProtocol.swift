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
/// 4. `/Users/{uid}/Items/Latest` 未实现（400）→ 改写为
///    `/Items?Recursive&IncludeItemTypes&SortBy=SortName` 等效查询；
/// 5. `/Users/{uid}/Items/Resume` 未实现（400）→ 返回空信封，
///    避免首页"继续观看"分区报错；
/// 6. `PlaybackInfo` 仅支持 GET（POST 未路由）→ POST 转为 GET；
/// 7. `/Genres` 未实现（返回网页）→ 返回空信封。
///
/// 通过 `URLSessionConfiguration.swiftfin` 注册，同时覆盖
/// jellyfin-sdk 的 API 请求与 Nuke 的图片请求。
final class FnOSCompatURLProtocol: URLProtocol {

    // MARK: - Token 注册表

    private static let registryLock = NSLock()
    private static var tokensByHost: [String: String] = [:]

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
        let path = Self.normalizedPath(of: url)
        if mutable.httpMethod == "POST", path.contains("/PlaybackInfo") {
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

        // ---- 3. 未实现端点：合成响应，避免上层报错 ----
        // 码率测试：返回 size 字节的零填充（瞬时完成 → 实测码率极高 → 直接原码播放）
        if path.contains("/Playback/BitrateTest") {
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

        if Self.isUnimplementedPath(path) {
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

        // ---- 4. 转发 ----
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
    }

    // MARK: - 转发

    private var dataTask: URLSessionDataTask?
    private var forwardingSession: URLSession?
}

extension FnOSCompatURLProtocol: URLSessionDataDelegate {

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }

        // 释放本次请求的内部会话，避免泄漏
        forwardingSession?.invalidateAndCancel()
        forwardingSession = nil
        dataTask = nil
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
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
        if path.hasSuffix("/Items/Latest") {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.path = String(path.dropLast("/Latest".count))
            var query = components?.queryItems ?? []

            let existing = { (name: String) in query.first { $0.name.lowercased() == name.lowercased() }?.value }
            if existing("Limit") == nil {
                query.append(URLQueryItem(name: "Limit", value: "12"))
            }
            query.append(URLQueryItem(name: "Recursive", value: "true"))
            query.append(URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"))
            query.append(URLQueryItem(name: "SortBy", value: "SortName"))
            query.append(URLQueryItem(name: "SortOrder", value: "Ascending"))
            if existing("Fields") == nil {
                query.append(URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio"))
            }

            components?.queryItems = query
            return components?.url ?? url
        }

        // /Users/{uid}/Items（媒体库内容查询）：补 Fields 与 Limit
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
