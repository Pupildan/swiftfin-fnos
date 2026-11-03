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

    // MARK: - 继续播放（服务端多端同步）

    /// Jellyfin 标准 `/Items/Resume`：飞牛服务端统一维护多端播放进度
    /// （手机 App / 网页 / 本机播到哪，这里就能续到哪）。
    /// 兼容层若未实现该路由，走 catch 返回空数组 → 首页隐藏「继续播放」行，不阻塞。
    func fetchResumeItems(userID: String, limit: Int = 20) async -> [FNOSItem] {
        do {
            let data = try await get(
                path: "Users/\(userID)/Items/Resume",
                query: [
                    "Limit": String(limit),
                    "Recursive": "true",
                    "MediaTypes": "Video",
                    "Fields": "Overview,ProductionYear,RunTimeTicks,OfficialRating,Genres,SeriesName,ParentIndexNumber,IndexNumber,BackdropImageTags",
                    "EnableImageTypes": "Primary,Backdrop,Thumb",
                    "EnableTotalRecordCount": "false",
                ]
            )
            let envelope = try JSONDecoder().decode(FNOSItemsEnvelope.self, from: data)
            let items = envelope.Items.filter { ($0.UserData?.PlaybackPositionTicks ?? 0) > 0 }
            print("FNOSℹ️继续播放 \(items.count) 条")
            FNOSDiag.shared.add("继续播放服务端记录 \(items.count) 条")
            return items
        } catch {
            print("FNOS❗️加载继续播放失败（首页将隐藏该行）: \(error)")
            FNOSDiag.shared.add("继续播放拉取失败: \(error.localizedDescription)", dedupeKey: "resume.err")
            return []
        }
    }

    /// POST JSON（播放进度上报用；Jellyfin 标准 /Sessions/Playing* 端点）。
    /// 兼容层若未实现这些路由，静默失败（打印），绝不影响播放。
    private func post(path: String, body: [String: Any]) async {
        guard let url = try? self.url(path: path) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if !(200..<300).contains(code) {
                print("FNOS⚠️POST \(path) → \(code)（进度上报未生效，不影响播放）")
                FNOSDiag.shared.add("POST \(path) → \(code)（上报未生效）", dedupeKey: "post.\(path).\(code)")
            } else {
                // v89：首次成功也留痕（验证上报链路是否真被服务端接受）
                FNOSDiag.shared.add("POST \(path) → \(code) 上报成功", dedupeKey: "post.ok.\(path)")
            }
        } catch {
            print("FNOS⚠️POST \(path): \(error)（进度上报未生效，不影响播放）")
            FNOSDiag.shared.add("POST \(path) 失败: \(error.localizedDescription)", dedupeKey: "post.\(path).err")
        }
    }

    /// 播放进度上报：本机记录同步到飞牛服务端 → 各端「继续播放」可见。
    /// v89 单位修正：按标准 Jellyfin 的 100ns（1e7/秒）上报。v86 曾按微秒（1e6）发，
    /// 服务端接受了请求（无失败日志）但进度被存成 1/10 → 低于续播阈值永不进 Resume
    ///（用户实测：上报无报错但记录不同步）。条目 RunTimeTicks 的微秒怪癖只影响
    /// 兼容层条目响应，不代表 Sessions 通道的单位。
    /// 注意：续播主链路是本地记录（FNOSProgressStore），上报失败不影响任何功能。
    func reportPlayback(itemID: String, positionSeconds: Double, stage: String) async {
        let ticks = Int64(max(0, positionSeconds) * 10_000_000)
        let path: String
        switch stage {
        case "start": path = "Sessions/Playing"
        case "stopped": path = "Sessions/Playing/Stopped"
        default: path = "Sessions/Playing/Progress"
        }
        await post(path: path, body: ["ItemId": itemID, "PositionTicks": ticks])
    }
}

// MARK: - 本地播放进度（v87 续播主链路：UserDefaults，无服务端依赖）

/// 本地进度存储。服务端 /Sessions/Playing* 上报的兼容性未验证（真机无日志），
/// 续播功能以本地记录为可靠主链路；服务端上报继续尽力而为（多端同步）。
enum FNOSProgressStore {
    private static let prefix = "fnos.prog."
    private static let seriesPrefix = "fnos.prog.series."

    /// 条目播放进度（秒）
    static func save(itemID: String, seconds: Double) {
        guard seconds > 0 else { return }
        UserDefaults.standard.set(seconds, forKey: prefix + itemID)
    }

    static func load(itemID: String) -> Double? {
        let v = UserDefaults.standard.double(forKey: prefix + itemID)
        return v > 0 ? v : nil
    }

    static func clear(itemID: String) {
        UserDefaults.standard.removeObject(forKey: prefix + itemID)
    }

    /// 剧集观看位置：剧 Id → 最近看的集（详情页「继续播放 第N集」用）。
    /// v90：位置秒数随映射一起存（[epItemID, epNumber, seconds]）——单集条目记录
    /// 若缺失（如换引擎/清缓存），剧级秒数仍能续播，不再回退到第 1 集从头播。
    static func saveSeriesProgress(seriesID: String, episodeItemID: String, episodeNumber: Int, seconds: Double) {
        UserDefaults.standard.set([episodeItemID, episodeNumber, seconds], forKey: seriesPrefix + seriesID)
    }

    static func loadSeriesProgress(seriesID: String) -> (episodeItemID: String, episodeNumber: Int, seconds: Double?)? {
        guard let arr = UserDefaults.standard.array(forKey: seriesPrefix + seriesID),
              arr.count >= 2,
              let epID = arr[0] as? String,
              let num = arr[1] as? Int else { return nil }
        let seconds = arr.count >= 3 ? (arr[2] as? Double) : nil
        return (epID, num, seconds)
    }
}

// MARK: - 应用内诊断（v87：tvOS 真机无控制台，关键链路留痕供设置面板截图回报）

final class FNOSDiag {
    static let shared = FNOSDiag()
    private let lock = NSLock()
    private var lines: [String] = []
    private var seen: Set<String> = []

    /// dedupeKey 相同的记录只留第一条（周期性失败不刷屏）
    func add(_ line: String, dedupeKey: String? = nil) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let entry = "\(fmt.string(from: Date())) \(line)"
        lock.lock()
        if let key = dedupeKey {
            if seen.contains(key) { lock.unlock(); return }
            seen.insert(key)
        }
        lines.append(entry)
        if lines.count > 30 { lines.removeFirst(lines.count - 30) }
        lock.unlock()
        print("FNOSDiag \(entry)")
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
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
    // 首播日期（ISO8601 字符串，剧集卡片底部展示）
    let PremiereDate: String?
    // 单集所属剧名（弹幕按「剧名+集数」匹配）
    let SeriesName: String?
    // 演职人员（请求时带 Fields=People 才会返回，Jellyfin 标准结构）
    let People: [FNOSPeopleEntry]?
    // 播放进度（继续播放 shelf 用；多端同步由飞牛服务端统一维护）
    let UserData: FNOSUserData?
    // 所属剧 Id（剧集续播：剧→最近集映射用）
    let SeriesId: String?

    var id: String { Id }
    var type: String? { ItemType }

    /// fnOS 的内容类型键叫 "Type"（Swift 属性不能用 Type 命名，故改名映射）
    enum CodingKeys: String, CodingKey {
        case Id, Name
        case ItemType = "Type"
        case ProductionYear, Overview, ImageTags, BackdropImageTags
        case RunTimeTicks, OfficialRating, Genres
        case ParentIndexNumber, IndexNumber, PremiereDate, SeriesName, SeriesId
        case People, UserData
    }
}

/// 播放进度（Jellyfin UserData 标准结构；/Items/Resume 默认返回）
struct FNOSUserData: Decodable {
    let PlaybackPositionTicks: Int64?
    let PlayedPercentage: Double?
    let Played: Bool?
}

/// 条目上的演职人员（Jellyfin BaseItemPerson 结构）
struct FNOSPeopleEntry: Decodable {
    let Name: String?
    let Id: String?
    let Role: String?
    /// JSON 里叫 "Type"（Actor/Director），Swift 不能用这个属性名（与 .Type 冲突）
    let JobType: String?
    let PrimaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case Name, Id, Role
        case JobType = "Type"
        case PrimaryImageTag
    }
}

extension FNOSItem {
    /// 时长秒数（飞牛 RunTimeTicks 单位不统一：标准 100ns / 微秒 / 秒都见过）。
    /// 按候选单位换算，取第一个落在合理区间的结果：剧集 20 分钟~4 小时，电影 5 分钟~4 小时。
    static func plausibleSeconds(ticks: Int64?, isEpisode: Bool) -> Double? {
        guard let ticks, ticks > 0 else { return nil }
        let lower: Double = isEpisode ? 20 * 60 : 5 * 60
        let upper: Double = 6 * 3600
        // 飞牛兼容层实测单位是**微秒**（4.2e9 → 4200 秒 = 70 分钟），所以 1e6 排第一；
        // 标准 Jellyfin 是 100ns，放到第二档；再退毫秒/秒。
        // 上限 6 小时是为了让 100ns 的值（4.2e10）不会在 /1e6 时被误判成 11 小时。
        for factor in [1_000_000.0, 10_000_000.0, 1_000.0, 1.0] {
            let seconds = Double(ticks) / factor
            if seconds >= lower, seconds <= upper { return seconds }
        }
        return nil
    }

    static func durationText(ticks: Int64?, isEpisode: Bool) -> String? {
        guard let secondsDouble = plausibleSeconds(ticks: ticks, isEpisode: isEpisode) else { return nil }
        return format(seconds: secondsDouble)
    }

    /// 秒 → "1 小时 10 分钟" / "54 分钟"
    static func format(seconds: Double) -> String? {
        let total = Int(seconds)
        guard total >= 60 else { return nil }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(hours) 小时"
        }
        return "\(minutes) 分钟"
    }

    var plausibleSeconds: Double? {
        Self.plausibleSeconds(ticks: RunTimeTicks, isEpisode: type == "Episode")
    }

    /// 时长展示文案
    var durationString: String? {
        Self.durationText(ticks: RunTimeTicks, isEpisode: type == "Episode")
    }

    /// 卡片角标用的紧凑时长（"54分钟" / "1小时6分钟"）
    var compactDuration: String? {
        durationString?.replacingOccurrences(of: " ", with: "")
    }

    /// 首播日期文案：PremiereDate(ISO8601) → "2022年3月25日"，失败退年份
    var premiereDateText: String? {
        if let raw = PremiereDate, raw.count >= 10 {
            let head = String(raw.prefix(10))
            let parts = head.split(separator: "-")
            if parts.count == 3,
               let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
            {
                return "\(y)年\(m)月\(d)日"
            }
        }
        if let year = ProductionYear { return String(year) }
        return nil
    }
}
