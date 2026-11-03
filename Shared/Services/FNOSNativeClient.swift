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
        /// 第一个季的 guid（分集接口要的是季 guid，不是剧集 guid）
        var seasonGuid: String?
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

        // 2) 演员（剧集 → 条目 guid；为空时下面再退季 guid / 条目详情）
        result.persons = await fetchPersons(guid: hit.guid, log: log, label: "条目")

        // 3) 剧集：先拿季，再逐季取分集（飞牛 episode/list 必须传**季** guid）
        if isSeries {
            let episodes = await fetchEpisodeDurations(tvGuid: hit.guid, log: log)
            result.episodeDurations = episodes.durations
            result.seasonGuid = episodes.firstSeasonGuid

            if result.persons.isEmpty, let seasonGuid = episodes.firstSeasonGuid, seasonGuid != hit.guid {
                result.persons = await fetchPersons(guid: seasonGuid, log: log, label: "季")
            }
        }

        // 4) 演员最后一招：条目详情里可能带 cast
        if result.persons.isEmpty {
            result.persons = await fetchPersonsFromItemDetail(guid: hit.guid, log: log)
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

    private func fetchPersons(guid: String, log: DebugLog, label: String) async -> [Person] {
        do {
            let json = try await post(path: "api/v1/person/list/\(guid)", body: #"{"page":1,"page_size":200}"#)
            let list = Self.extractList(json["data"])
            let total = Self.totalCount(json["data"])
            log.add("原生演员(\(label)): \(Self.describeStructure(json["data"])) total=\(total) → \(list.count) 条")
            let people = Self.parsePersons(list)
            if !people.isEmpty {
                log.add("原生演员(\(label)): \(people.count) 人")
                print("FNOSℹ️原生演员(\(label)) \(people.count) 人")
                return people
            }
            // total > 0 但 list 为空 → 多半是 page_size 超出上限，用小页重试
            if total > 0 {
                let retry = try await post(path: "api/v1/person/list/\(guid)", body: #"{"page":1,"page_size":30}"#)
                let retryList = Self.extractList(retry["data"])
                let retryPeople = Self.parsePersons(retryList)
                log.add("原生演员(\(label))小页重试: \(retryList.count) 条 → \(retryPeople.count) 人")
                return retryPeople
            }
            return []
        } catch {
            log.add("原生演员(\(label))失败: \(short(error))")
            return []
        }
    }

    /// 条目详情里可能带 cast/actors（不同版本字段名不同）
    private func fetchPersonsFromItemDetail(guid: String, log: DebugLog) async -> [Person] {
        do {
            let json = try await get(path: "api/v1/item/\(guid)")
            guard let data = json["data"] as? [String: Any] else {
                log.add("原条目详情: data 非对象")
                return []
            }
            log.add("原条目详情 keys[\(data.keys.sorted().joined(separator: ","))]")
            for key in ["persons", "actors", "cast", "peoples", "credits"] {
                if let list = data[key] as? [[String: Any]], !list.isEmpty {
                    let people = Self.parsePersons(list)
                    if !people.isEmpty {
                        log.add("详情演员(\(key)): \(people.count) 人")
                        return people
                    }
                }
            }
            return []
        } catch {
            log.add("原条目详情失败: \(short(error))")
            return []
        }
    }

    private static func parsePersons(_ list: [[String: Any]]) -> [Person] {
        list.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            return Person(
                name: name,
                role: dict["role"] as? String,
                job: dict["job"] as? String,
                profilePath: dict["profile_path"] as? String
            )
        }
    }

    // MARK: - 逐集时长（飞牛：先 season/list 拿季 guid，再 episode/list 取集）

    private func fetchEpisodeDurations(
        tvGuid: String,
        log: DebugLog
    ) async -> (durations: [Int: Int], firstSeasonGuid: String?) {
        var seasonGuids: [String] = []
        do {
            let json = try await get(path: "api/v1/season/list/\(tvGuid)")
            let list = Self.extractList(json["data"])
            log.add("原生季列表: \(Self.describeStructure(json["data"])) → \(list.count) 季")
            seasonGuids = list.compactMap { $0["guid"] as? String }.filter { !$0.isEmpty }
        } catch {
            log.add("原生季列表失败: \(short(error))")
        }

        // 没有季数据时，退回直接用剧集 guid 试一次
        if seasonGuids.isEmpty { seasonGuids = [tvGuid] }

        var map: [Int: Int] = [:]
        for (index, seasonGuid) in seasonGuids.enumerated() {
            do {
                let json = try await get(path: "api/v1/episode/list/\(seasonGuid)")
                let list = Self.extractList(json["data"])
                log.add("原生分集(\(index + 1)/\(seasonGuids.count)): \(Self.describeStructure(json["data"])) total=\(Self.totalCount(json["data"])) → \(list.count) 条")
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
            } catch {
                log.add("原生分集(\(index + 1))失败: \(short(error))")
            }
        }
        log.add("原生分集时长: \(map.count) 集")
        return (map, seasonGuids.first)
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

    /// data 里的 total（用于判断「有总数但列表为空」的分页异常）
    private static func totalCount(_ data: Any?) -> Int {
        (data as? [String: Any]).flatMap { ($0["total"] as? NSNumber)?.intValue } ?? -1
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

// MARK: - mpv 引擎（实验）：飞牛原生直链解析
//
// 为什么单独一条链路：
// - 兼容层 8005 的播放流要求 `X-Emby-Authorization` 头，该头的值含逗号
//   （`MediaBrowser Client="…", Device="…"`），而 mpv 的 `http-header-fields`
//   是以逗号分隔的多值选项，没法原样透传。
// - 实测原生 `GET /v/api/v1/media/range/{media_guid}` **只需要 `Authorization: <token>`
//   一个头**（纯十六进制，无逗号），且支持 Range 随机读取（1GB/3GB 处均返回 206）。
// 所以 mpv 走原生直链：头少、字段无逗号、seek 可行。

extension FNOSNativeClient {

    /// 分集引用（换集用；飞牛原生 guid 与兼容层 Id 不是一套）
    struct EpisodeRef: Identifiable, Hashable {
        let number: Int
        let guid: String
        var id: Int { number }
    }

    /// 一次播放直链解析的结果
    struct MediaRange {
        let url: URL
        let itemGUID: String
        let mediaGUID: String
        let episodeNumber: Int?
        /// 同季全部分集（电影为空）
        let episodes: [EpisodeRef]
    }

    /// 解析播放直链。
    /// - 剧集：`seriesTitle` + `episodeNumber` → 剧集 guid → 季 guid → 该集 guid，并带回整季分集
    /// - 电影：`itemTitle` → 条目 guid
    func mediaRange(itemTitle: String?, seriesTitle: String?, episodeNumber: Int?) async -> MediaRange? {
        let log = DebugLog()
        var itemGUID: String?
        var episodes: [EpisodeRef] = []

        // 1) 剧集走「剧名 → 季 → 集」，因为分集标题常常是空的（实测第 23 集 title 为空串）
        if let seriesTitle, !seriesTitle.isEmpty, let episodeNumber, episodeNumber > 0 {
            if let hit = await searchItem(title: seriesTitle, isSeries: true, log: log) {
                if let seasonGUID = await firstSeasonGUID(tvGuid: hit.guid, log: log) {
                    episodes = await episodeRefs(seasonGuid: seasonGUID, log: log)
                    itemGUID = episodes.first { $0.number == episodeNumber }?.guid
                }
            }
        }

        // 2) 电影 / 兜底：按标题搜索
        if itemGUID == nil, let itemTitle, !itemTitle.isEmpty {
            if let hit = await searchItem(title: itemTitle, isSeries: false, log: log) {
                itemGUID = hit.guid
            }
        }

        guard let itemGUID, let info = await playInfo(itemGUID: itemGUID, log: log) else {
            print("FNOS❗️mpv 直链解析失败 \(log.lines.joined(separator: " | "))")
            return nil
        }

        print("FNOS✅mpv 直链就绪 media=\(info.mediaGUID) item=\(itemGUID) 分集 \(episodes.count)")
        return MediaRange(
            url: mediaURL(mediaGUID: info.mediaGUID),
            itemGUID: itemGUID,
            mediaGUID: info.mediaGUID,
            episodeNumber: episodeNumber,
            episodes: episodes
        )
    }

    /// 已知条目 guid 时直接换直链（播放器内换集用）
    func mediaRange(itemGUID: String) async -> MediaRange? {
        let log = DebugLog()
        guard let info = await playInfo(itemGUID: itemGUID, log: log) else { return nil }
        return MediaRange(
            url: mediaURL(mediaGUID: info.mediaGUID),
            itemGUID: itemGUID,
            mediaGUID: info.mediaGUID,
            episodeNumber: nil,
            episodes: []
        )
    }

    // MARK: - 私有步骤

    private func mediaURL(mediaGUID: String) -> URL {
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/v/api/v1/media/range/\(mediaGUID)")!
    }

    /// `POST /v/api/v1/play/info` → media_guid + 条目字典（评分等元数据）
    private func playInfo(itemGUID: String, log: DebugLog) async -> (mediaGUID: String, duration: Int?, itemDict: [String: Any]?)? {
        let body = "{\"item_guid\":\"\(Self.escape(itemGUID))\"}"
        guard let json = try? await post(path: "api/v1/play/info", body: body),
              let data = json["data"] as? [String: Any],
              let mediaGUID = data["media_guid"] as? String,
              !mediaGUID.isEmpty
        else {
            log.add("play/info 失败")
            return nil
        }
        let itemDict = data["item"] as? [String: Any]
        let duration = (itemDict?["duration"] as? NSNumber)?.intValue
        return (mediaGUID, duration, itemDict)
    }

    /// 防御性评分解析：飞牛 play/info 的 item 字典按常见键名找评分。
    /// 字段名未实测（需一份真实返回核对）；找不到就返回空 → 详情页不显示评分行。
    static func parseRatings(_ itemDict: [String: Any]?) -> [String: Double] {
        guard let itemDict else { return [:] }
        var out: [String: Double] = [:]
        for (key, value) in itemDict {
            let k = key.lowercased()
            guard let num = (value as? NSNumber)?.doubleValue, num > 0 else { continue }
            if k.contains("douban"), out["douban"] == nil, num <= 10 {
                out["douban"] = num
            } else if k.contains("imdb"), out["imdb"] == nil, num <= 10 {
                out["imdb"] = num
            } else if (k.contains("tomato") || k.contains("rotten")), out["tomato"] == nil, num <= 100 {
                out["tomato"] = num
            }
        }
        return out
    }

    /// 详情页信息增强：色彩档位徽章 + 评分。
    /// - 电影：标题 → 条目 guid → play/info（media_guid + item 字典）→ /stream 探测
    /// - 剧集：剧名 + 第 1 集（代表整剧档位）
    /// 一次调用同时拿色彩与评分（共用同一次 search + play/info）。
    func detailEnrichment(itemTitle: String?, seriesTitle: String?, episodeNumber: Int?) async -> (badge: String?, imdb: Double?, douban: Double?, tomato: Double?)? {
        let log = DebugLog()
        var guid: String?
        if let seriesTitle, !seriesTitle.isEmpty, let episodeNumber, episodeNumber > 0 {
            if let hit = await searchItem(title: seriesTitle, isSeries: true, log: log) {
                if let seasonGUID = await firstSeasonGUID(tvGuid: hit.guid, log: log) {
                    let eps = await episodeRefs(seasonGuid: seasonGUID, log: log)
                    guid = eps.first { $0.number == episodeNumber }?.guid
                }
            }
        }
        if guid == nil, let itemTitle, !itemTitle.isEmpty {
            guid = await searchItem(title: itemTitle, isSeries: false, log: log)?.guid
        }
        guard let guid, let info = await playInfo(itemGUID: guid, log: log) else {
            print("FNOS❗️Hero 增强失败: \(log.lines.joined(separator: " | "))")
            return nil
        }
        let ratings = Self.parseRatings(info.itemDict)

        var badge: String?
        if let traits = await videoTraits(mediaGUID: info.mediaGUID) {
            if let p = traits.dvProfile {
                badge = "杜比视界 P\(p)"
            } else if let depth = traits.bitDepth, depth >= 10 {
                // 无 DoVi 报告的 10bit HEVC/AV1 在电影库里基本都是 HDR10/HLG；
                // 杜比视界只认 dv_profile（compat 层 VideoRangeType 不可信，见 probeProfile 注释）
                badge = "HDR10"
            } else {
                badge = "SDR"
            }
        }
        return (badge, ratings["imdb"], ratings["douban"], ratings["tomato"])
    }

    /// 视频轨真实格式（来自 `POST /v/api/v1/stream` 的能力协商响应）
    ///
    /// 为什么需要它：兼容层（8005）根本不映射色彩信息（`media_stream.color_range_type` 恒为 null，
    /// `VideoRangeType` 也拿不到），没法从元数据判断杜比视界档位；而不同档位对播放器的要求完全不同：
    /// - **P5**：IPTPQc2，没有 HDR10 基线层（`dv_bl_signal_compatibility_id=0`）→ KSPlayer 解出来必然紫绿
    /// - **P7**：带增强层，KS 用不了 EL
    /// - **P8**：带 HDR10 兼容基线层（实测《阿凡达：火与烬》`dv_profile=8, compat_id=1`）→ KS 解基线层就是正确 HDR10
    /// 所以只有 P5 / P7 才需要切 mpv，P8 留在 KS 反而画质和功能都更好。
    struct VideoTraits {
        let dvProfile: Int?
        let codec: String?
        let bitDepth: Int?
        let width: Int?
        let height: Int?

        var needsMPV: Bool {
            if let dvProfile { return dvProfile == 5 || dvProfile == 7 }
            return (codec ?? "").lowercased() == "av1"
        }

        var summary: String {
            var parts: [String] = []
            if let dvProfile { parts.append("DoVi P\(dvProfile)") }
            if let codec { parts.append(codec.uppercased()) }
            if let bitDepth { parts.append("\(bitDepth)bit") }
            if let width, let height { parts.append("\(width)×\(height)") }
            return parts.isEmpty ? "未知" : parts.joined(separator: " · ")
        }
    }

    /// 查询视频轨真实格式。实测 0.06s 返回，只做能力协商、不产生转码会话。
    func videoTraits(mediaGUID: String) async -> VideoTraits? {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let nonce = Int.random(in: 100_000...999_999)
        let body = """
        {"header":{"User-Agent":["FNOS-tvOS/1.0"]},"level":1,"media_guid":"\(Self.escape(mediaGUID))","ip":"0.0.0.0","nonce":"\(nonce)","timestamp":\(now)}
        """
        guard let json = try? await post(path: "api/v1/stream", body: body),
              let data = json["data"] as? [String: Any],
              let video = data["video_stream"] as? [String: Any]
        else { return nil }

        let rawProfile = (video["dv_profile"] as? NSNumber)?.intValue
        return VideoTraits(
            dvProfile: (rawProfile ?? 0) > 0 ? rawProfile : nil,
            codec: video["codec_name"] as? String,
            bitDepth: (video["bit_depth"] as? NSNumber)?.intValue,
            width: (video["width"] as? NSNumber)?.intValue,
            height: (video["height"] as? NSNumber)?.intValue
        )
    }

    /// 剧集 → 第一个季的 guid（`GET /v/api/v1/season/list/{tv_guid}`，只支持 GET）
    private func firstSeasonGUID(tvGuid: String, log: DebugLog) async -> String? {
        do {
            let json = try await get(path: "api/v1/season/list/\(tvGuid)")
            let list = Self.extractList(json["data"])
            log.add("季:\(list.count)")
            return list.first?["guid"] as? String
        } catch {
            log.add("季列表失败")
            return nil
        }
    }

    /// 季 → 全部分集（`GET /v/api/v1/episode/list/{season_guid}`）
    private func episodeRefs(seasonGuid: String, log: DebugLog) async -> [EpisodeRef] {
        do {
            let json = try await get(path: "api/v1/episode/list/\(seasonGuid)")
            let list = Self.extractList(json["data"])
            log.add("集:\(list.count)")
            return list.compactMap { item in
                guard let guid = item["guid"] as? String else { return nil }
                let number = (item["episode_number"] as? NSNumber)?.intValue
                    ?? (item["index_number"] as? NSNumber)?.intValue
                guard let number, number > 0 else { return nil }
                return EpisodeRef(number: number, guid: guid)
            }
            .sorted { $0.number < $1.number }
        } catch {
            log.add("分集列表失败")
            return []
        }
    }
}
