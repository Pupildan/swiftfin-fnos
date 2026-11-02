//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// 飞牛影视（fnOS 8005 兼容层）直连客户端 —— 最原始的 URLSession 实现。
///
/// 设计原则（本轮最高优先级）：
/// 1. 不依赖任何 SDK / URLProtocol / delegate 魔法，就是普通 URLSession；
/// 2. 每个请求都必须带 `X-Emby-Authorization` 头（fnOS 硬性要求，缺失返回 400）；
/// 3. 全代码禁用 `try?`：所有失败走 do-catch 并 `print` 真实报错，绝不静默。
final class FNOSDirectClient {

    let baseURL: URL
    let token: String

    private let session: URLSession

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    /// fnOS 要求的老式鉴权头（内嵌 Token=，实测缺它一律 400）
    var authorizationHeader: String {
        "MediaBrowser Client=\"Swiftfin\", Device=\"AppleTV\", DeviceId=\"fnos-direct\", Version=\"1.0\", Token=\"\(token)\""
    }

    var requestHeaders: [String: String] {
        [
            "X-Emby-Authorization": authorizationHeader,
            "X-Emby-Token": token,
            "Accept": "application/json",
        ]
    }

    // MARK: - URL 构造

    func url(path: String, query: [String: String] = [:]) throws -> URL {
        let joined = baseURL
            .appendingPathComponent(path)
        guard var components = URLComponents(url: joined, resolvingAgainstBaseURL: false) else {
            throw FNOSDirectError("URL 构造失败: \(baseURL)/\(path)")
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let result = components.url else {
            throw FNOSDirectError("URL 构造失败(query): \(baseURL)/\(path)")
        }
        return result
    }

    /// 海报地址（无图时返回 nil 并打印原因）
    func imageURL(itemID: String, maxWidth: Int = 400) -> URL? {
        do {
            return try url(
                path: "Items/\(itemID)/Images/Primary",
                query: ["maxWidth": String(maxWidth), "quality": "85"]
            )
        } catch {
            print("FNOS❗️海报 URL 构造失败 \(itemID): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - GET

    func get(path: String, query: [String: String] = [:]) async throws -> Data {
        let requestURL: URL
        do {
            requestURL = try url(path: path, query: query)
        } catch {
            print("FNOS❗️GET URL 构造失败 \(path): \(error.localizedDescription)")
            throw error
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                let message = "GET \(path): 非 HTTP 响应 \(String(describing: response))"
                print("FNOS❗️\(message)")
                throw FNOSDirectError(message)
            }

            guard (200..<300).contains(http.statusCode) else {
                let bodySnippet = String(data: data.prefix(300), encoding: .utf8) ?? "(二进制响应)"
                let message = "GET \(path) → HTTP \(http.statusCode): \(bodySnippet)"
                print("FNOS❗️\(message)")
                throw FNOSDirectError(message)
            }

            print("FNOS✅ GET \(path) \(http.statusCode) \(data.count)B")
            return data
        } catch let error as FNOSDirectError {
            throw error
        } catch {
            print("FNOS❗️GET \(path): \(error)")
            throw FNOSDirectError("网络错误 \(path): \(error.localizedDescription)")
        }
    }
}

/// 带可读信息的错误（界面上能直接看到原因）
struct FNOSDirectError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

// MARK: - fnOS JSON 模型（PascalCase，与响应键名一致）

struct FNOSViewsEnvelope: Decodable {
    let Items: [FNOSLibrary]
}

struct FNOSLibrary: Decodable, Identifiable {
    let Id: String
    let Name: String?

    var id: String { Id }
}

struct FNOSItemsEnvelope: Decodable {
    let Items: [FNOSItem]
}

struct FNOSItem: Decodable, Identifiable {
    let Id: String
    let Name: String?
    let ItemType: String?
    let ProductionYear: Int?
    let Overview: String?
    let ImageTags: [String: String]?
    // Jellyfin/Emby 标准：Backdrop 的 tag 在独立数组里，不在 ImageTags 字典中
    let BackdropImageTags: [String]?
    let RunTimeTicks: Int64?
    let OfficialRating: String?
    let Genres: [String]?
    // 剧集排序用的序号
    let ParentIndexNumber: Int?
    let IndexNumber: Int?

    var id: String { Id }
    var type: String? { ItemType }

    /// fnOS 的内容类型键叫 "Type"（Swift 属性不能用 Type 命名，故改名映射）
    enum CodingKeys: String, CodingKey {
        case Id, Name
        case ItemType = "Type"
        case ProductionYear, Overview, ImageTags, BackdropImageTags
        case RunTimeTicks, OfficialRating, Genres
        case ParentIndexNumber, IndexNumber
    }
}

extension FNOSItem {
    /// 时长展示文案（RunTimeTicks 单位为 100 纳秒）
    var durationString: String? {
        guard let ticks = RunTimeTicks, ticks > 0 else { return nil }
        let seconds = ticks / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(hours) 小时"
        } else {
            return "\(minutes) 分钟"
        }
    }
}
