//
// FNOSMoviePilotClient.swift
// v120: MoviePilot API 客户端 — 「加入影视库」订阅链路
//
// 探测确认（2026-11-05 实测 192.168.10.120:30033）：
// - 鉴权：X-API-KEY: <token> 头（Bearer JWT 是网页登录用的，API Token 走这个头）
// - 添加：POST /api/v1/subscribe/  body {"type":"movie"|"tv","name","year","tmdbid"}
//         → {"success":true,"data":{"id":N}}；重复订阅返回 success=true + "订阅已存在"
// - 查询：GET /api/v1/subscribe/media/{tmdbid}?media_source=themoviedb
//         → data.id 非空 = 已订阅；未订阅时 data 为全 null 字段
// - 删除：DELETE /api/v1/subscribe/media/{tmdbid}?media_source=themoviedb
// - 列表：GET /api/v1/subscribe/ → {"success":true,"data":[Subscribe...]}
//

import Foundation

enum FNOSMoviePilotClient {

    private struct Envelope: Decodable {
        let success: Bool?
        let message: String?
        let data: MPData?
    }

    private struct MPData: Decodable {
        let id: Int?
        let name: String?
        let state: String?
        let media_id: String?
        let media_source: String?
    }

    /// v121：订阅列表条目（番剧查询用——MP 会把 bangumi 订阅转存为 tmdb，
    /// `bangumi:` 前缀查询/删除会落空，只能拿列表按名匹配）
    struct MPSubscribeBrief: Decodable {
        let id: Int?
        let name: String?
        let state: String?
        let media_source: String?
        let media_id: String?
    }

    private static func normalize(_ base: String) -> String {
        base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    static func configured(base: String, apiKey: String) -> Bool {
        !base.isEmpty && !apiKey.isEmpty
    }

    /// 查询某 TMDB 条目是否已订阅（已订阅返回订阅 id；未订阅/未配置/网络失败返回 nil）
    static func lookupSubscribe(base: String, apiKey: String, tmdbid: Int) async -> Int? {
        guard configured(base: base, apiKey: apiKey) else { return nil }
        guard let url = URL(string: "\(normalize(base))/api/v1/subscribe/media/\(tmdbid)?media_source=themoviedb") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
              let env = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        return env.data?.id
    }

    /// v121：列出全部订阅
    static func listSubscribes(base: String, apiKey: String) async -> [MPSubscribeBrief] {
        guard configured(base: base, apiKey: apiKey) else { return [] }
        guard let url = URL(string: "\(normalize(base))/api/v1/subscribe/") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0)
        else { return [] }

        // data 可能是数组（有订阅）或 null（无订阅）
        struct ListEnvelope: Decodable {
            let success: Bool?
            let data: [MPSubscribeBrief]?
        }
        guard let env = try? JSONDecoder().decode(ListEnvelope.self, from: data) else { return [] }
        return env.data ?? []
    }

    /// v121：按名称匹配订阅（番剧入库查询——MP 转存后 bangumi: 前缀失效）
    static func lookupSubscribeByName(base: String, apiKey: String, name: String) async -> MPSubscribeBrief? {
        let list = await listSubscribes(base: base, apiKey: apiKey)
        return list.first { $0.name == name } ?? list.first { $0.name?.contains(name) ?? false }
    }

    /// 添加订阅；返回 (是否成功, 服务端消息)。「订阅已存在」时 success=true。
    /// type 传 "movie"/"tv"；番剧传 bangumiid（MoviePilot 经 Bangumi 源识别后转存 TMDB）。
    static func addSubscribe(base: String, apiKey: String, tmdbid: Int? = nil, type: String, name: String, year: String?, bangumiid: Int? = nil) async -> (Bool, String) {
        guard configured(base: base, apiKey: apiKey) else { return (false, "MoviePilot 未配置") }
        var body: [String: Any] = ["type": type, "name": name]
        if let tmdbid { body["tmdbid"] = tmdbid }
        if let bangumiid { body["bangumiid"] = bangumiid }
        if let year, !year.isEmpty { body["year"] = year }
        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return (false, "请求体构造失败") }
        guard let url = URL(string: "\(normalize(base))/api/v1/subscribe/") else { return (false, "URL 构造失败") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = json
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else {
                return (false, "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let env = try? JSONDecoder().decode(Envelope.self, from: data)
            return (env?.success ?? false, env?.message ?? "")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
