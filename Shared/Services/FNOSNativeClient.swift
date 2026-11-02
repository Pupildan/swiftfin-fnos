//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CryptoKit
import Foundation

/// 飞牛影视「原生」API 客户端（`/v/api/v1/` + Authx 签名）。
///
/// 为什么需要它：
/// 8005 的 Jellyfin 兼容层只给 BaseItemDto，**演员（People）和精确时长拿不到**
/// （Series 的 People 恒为空、RunTimeTicks 单位混乱）。飞牛自己的 TV 端是走原生
/// 接口拿这些数据的，本类照搬其实现：
///
/// - 演员：`POST /v/api/v1/person/list/{guid}` → `{name, job: Actor/Director, role, profile_path}`
/// - 时长：条目 / `GET /v/api/v1/episode/list/{guid}` 里的 `duration`（**秒**）
/// - 搜索：`POST /v/api/v1/item/list` 按标题换 guid（兼容层 Item Id ≠ 飞牛 guid）
///
/// 签名：`sign = md5(apiKey_path_nonce_ts_md5(body)_apiSecret)`，
/// 头 `Authx: nonce=..&timestamp=..&sign=..` + `Cookie: mode=relay` + `Authorization: <token>`。
final class FNOSNativeClient {

    /// 飞牛官方 Web/TV 端使用的固定应用凭据（非用户密钥）
    private static let apiKey = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh"
    private static let apiSecret = "16CCEB3D-AB42-077D-36A1-F355324E4237"

    struct Person {
        let name: String
        let role: String?
        let job: String?
        /// 头像相对路径（配合 `/v/api/v1/sys/img` 使用）
        let profilePath: String?
    }

    /// 一次解析的结果（演员 + 时长 + 诊断）
    struct Resolved {
        var guid: String?
        var persons: [Person] = []
        /// episode_number → 时长（秒）
        var episodeDurations: [Int: Int] = [:]
        /// 电影/单集的时长（秒）
        var durationSeconds: Int?
        var debug: [String] = []
    }

    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - 原生登录（换飞牛自己的 token，与兼容层 token 不是一套）

    /// `POST /v/api/v1/login` → `data.token`
    static func login(baseURL: URL, username: String, password: String) async throws -> String {
        let nonce = String(Int.random(in: 100000 ... 999999))
        let body = "{\"app_name\":\"trimemedia-web\",\"username\":\"\(Self.escape(username))\",\"password\":\"\(Self.escape(password))\",\"nonce\":\"\(nonce)\"}"

        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/v/api/v1/login") else {
            throw FNOSDirectError("原生登录 URL 构造失败")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("mode=relay", forHTTPHeaderField: "Cookie")
        request.setValue(Self.authx(path: "/v/api/v1/login", body: body), forHTTPHeaderField: "Authx")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FNOSDirectError("原生登录 HTTP 失败")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FNOSDirectError("原生登录响应非 JSON")
        }
        let code = (json["code"] as? NSNumber)?.intValue ?? -999
        guard code == 0,
              let tokenData = json["data"] as? [String: Any],
              let token = tokenData["token"] as? String, !token.isEmpty
        else {
            let msg = json["msg"] as? String ?? "?"
            throw FNOSDirectError("原生登录 code=\(code) msg=\(msg)")
        }
        print("FNOS✅原生登录成功，已获得飞牛 token")
        return token
    }

    // MARK: - 对外入口

    /// 诊断日志容器（class 才有引用语义，async 函数不能用 inout）
    private final class DebugLog {
        var lines: [String] = []
        func add(_ line: String) { lines.append(line) }
    }

    /// 按标题解析飞牛条目，拿演员与时长。全部失败也返回诊断信息，绝不 throw。
    func resolve(title: String?, isSeries: Bool) async -> Resolved {
        var result = Resolved()
        let log = DebugLog()
        guard let title, !title.isEmpty else {
            result.debug = ["原生: 标题为空，跳过"]
            return result
        }

        // 1) 标题搜索 → guid
        guard let hit = await searchItem(title: title, isSeries: isSeries, log: log) else {
            result.debug = log.lines
            return result
        }
        result.guid = hit.guid
        result.durationSeconds = hit.duration > 0 ? hit.duration : nil

        // 2) 演员
        result.persons = await fetchPersons(guid: hit.guid, log: log)

        // 3) 剧集：逐集时长
        if isSeries {
            result.episodeDurations = await fetchEpisodeDurations(guid: hit.guid, log: log)
        }

        result.debug = log.lines
        return result
    }

    /// 演员头像 URL（走 sys/img，需要 Authx 头）
    func personImageURL(profilePath: String, width: Int = 300) -> URL? {
        guard !profilePath.isEmpty else { return nil }
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/v/api/v1/sys/img\(profilePath)?w=\(width)") else { return nil }
        return url
    }

    /// 头像/图片请求头（Authx 用 sys/img 路径签名，body 为空）
    var imageHeaders: [String: String] {
        [
            "Authx": Self.authx(path: "/v/api/v1/sys/img", body: nil),
            "Cookie": "mode=relay",
            "Authorization": token,
        ]
    }

    // MARK: - 搜索（标题 → guid）

    private struct ItemHit {
        let guid: String
        let title: String
        let duration: Int
    }

    private func searchItem(title: String, isSeries: Bool, log: DebugLog) async -> ItemHit? {
        // 飞牛类型：剧集=TV、电影=Movie
        let type = isSeries ? "TV" : "Movie"
        // 单行 JSON：签名的 md5(body) 必须与实际发送字节完全一致，避免多行字符串的缩进/换行差异
        let body = "{\"name\":\"\(Self.escape(title))\",\"tags\":{\"type\":[\"\(type)\"]},\"page\":1,\"page_size\":20}"
        do {
            let json = try await post(path: "api/v1/item/list", body: body)
            let list = (json["data"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
            log.add("原生搜索[\(type)]: \(list.count) 条")

            // 标题完全相等优先，其次包含关系
            let exact = list.first { ($0["title"] as? String) == title }
            let fuzzy = list.first { item in
                guard let name = item["title"] as? String else { return false }
                return name.contains(title) || title.contains(name)
            }
            guard let picked = exact ?? fuzzy,
                  let guid = picked["guid"] as? String, !guid.isEmpty
            else {
                log.add("原生搜索: 未命中「\(title)」")
                return nil
            }
            let duration = (picked["duration"] as? NSNumber)?.intValue ?? 0
            let runtime = (picked["runtime"] as? NSNumber)?.intValue ?? 0
            let epsCount = (picked["number_of_episodes"] as? NSNumber)?.intValue
                ?? (picked["local_number_of_episodes"] as? NSNumber)?.intValue ?? 0
            log.add("原生命中「\(picked["title"] as? String ?? "?")」guid=\(guid.prefix(8)) dur=\(duration)s run=\(runtime)m 集=\(epsCount)")
            return ItemHit(guid: guid, title: picked["title"] as? String ?? title, duration: duration)
        } catch {
            log.add("原生搜索失败: \(short(error))")
            return nil
        }
    }

    // MARK: - 演员

    private func fetchPersons(guid: String, log: DebugLog) async -> [Person] {
        do {
            let json = try await post(path: "api/v1/person/list/\(guid)", body: #"{"page":1,"page_size":200}"#)
            let list = Self.extractList(json["data"])
            log.add("原生演员结构: \(Self.describeStructure(json["data"])) → \(list.count) 条")
            let people: [Person] = list.compactMap { dict in
                guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
                return Person(
                    name: name,
                    role: dict["role"] as? String,
                    job: dict["job"] as? String,
                    profilePath: dict["profile_path"] as? String
                )
            }
            log.add("原生演员: \(people.count) 人")
            print("FNOSℹ️原生演员 \(people.count) 人")
            if !people.isEmpty { return people }
        } catch {
            log.add("原生演员失败: \(short(error))")
        }

        // 兜底：部分版本 person/list 走 body 传 item_guid
        do {
            let body = "{\"item_guid\":\"\(Self.escape(guid))\",\"page\":1,\"page_size\":200}"
            let json = try await post(path: "api/v1/person/list", body: body)
            let list = Self.extractList(json["data"])
            let people: [Person] = list.compactMap { dict in
                guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
                return Person(
                    name: name,
                    role: dict["role"] as? String,
                    job: dict["job"] as? String,
                    profilePath: dict["profile_path"] as? String
                )
            }
            log.add("原生演员(body形式): \(Self.describeStructure(json["data"])) → \(people.count) 人")
            return people
        } catch {
            log.add("原生演员(body)失败: \(short(error))")
            return []
        }
    }

    // MARK: - 逐集时长

    private func fetchEpisodeDurations(guid: String, log: DebugLog) async -> [Int: Int] {
        do {
            let json = try await get(path: "api/v1/episode/list/\(guid)")
            let list = Self.extractList(json["data"])
            log.add("原生分集结构: \(Self.describeStructure(json["data"])) → \(list.count) 条")
            var map: [Int: Int] = [:]
            for dict in list {
                let number = (dict["episode_number"] as? NSNumber)?.intValue
                    ?? (dict["episode"] as? NSNumber)?.intValue
                guard let number else { continue }
                var seconds = (dict["duration"] as? NSNumber)?.intValue ?? 0
                // runtime 单位是分钟
                if seconds <= 0, let minutes = (dict["runtime"] as? NSNumber)?.intValue, minutes > 0 {
                    seconds = minutes * 60
                }
                if seconds > 0 { map[number] = seconds }
            }
            log.add("原生分集时长: \(map.count) 集")
            return map
        } catch {
            log.add("原生分集失败: \(short(error))")
            return [:]
        }
    }

    // MARK: - HTTP

    private func get(path: String) async throws -> [String: Any] {
        try await send(path: path, method: "GET", bodyString: nil)
    }

    private func post(path: String, body: String) async throws -> [String: Any] {
        try await send(path: path, method: "POST", bodyString: body)
    }

    private func send(path: String, method: String, bodyString: String?) async throws -> [String: Any] {
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/v/\(path)") else {
            throw FNOSDirectError("原生 URL 构造失败: \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("mode=relay", forHTTPHeaderField: "Cookie")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        // 签名的 path 必须与请求路径完全一致（含 /v 前缀）
        request.setValue(Self.authx(path: "/v/\(path)", body: bodyString), forHTTPHeaderField: "Authx")
        if let bodyString {
            request.httpBody = Data(bodyString.utf8)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FNOSDirectError("原生非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw FNOSDirectError("原生 HTTP \(http.statusCode) \(snippet)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FNOSDirectError("原生响应非 JSON")
        }
        let code = (json["code"] as? NSNumber)?.intValue ?? -999
        guard code == 0 else {
            let msg = json["msg"] as? String ?? "?"
            throw FNOSDirectError("原生 code=\(code) msg=\(msg)")
        }
        return json
    }

    // MARK: - 响应结构兼容

    /// 飞牛各版本把列表放在 data.list / data(数组) / data.persons 都可能，一律兼容
    private static func extractList(_ data: Any?) -> [[String: Any]] {
        if let array = data as? [[String: Any]] { return array }
        if let dict = data as? [String: Any] {
            for key in ["list", "persons", "items", "actors", "data"] {
                if let array = dict[key] as? [[String: Any]] { return array }
            }
        }
        return []
    }

    /// 诊断用：data 的真实形状
    private static func describeStructure(_ data: Any?) -> String {
        guard let data else { return "data=nil" }
        if let array = data as? [Any] { return "数组(\(array.count))" }
        if let dict = data as? [String: Any] {
            return "keys[\(dict.keys.sorted().joined(separator: ","))]"
        }
        return String(describing: type(of: data))
    }

    // MARK: - Authx 签名

    private static func authx(path: String, body: String?) -> String {
        let nonce = String(Int.random(in: 100000 ... 999999))
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let bodyMD5 = Self.md5(body ?? "")
        let sign = Self.md5([Self.apiKey, path, nonce, timestamp, bodyMD5, Self.apiSecret].joined(separator: "_"))
        return "nonce=\(nonce)&timestamp=\(timestamp)&sign=\(sign)"
    }

    private static func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func short(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.count > 60 ? String(text.prefix(60)) : text
    }
}
