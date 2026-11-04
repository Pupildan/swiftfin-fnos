//
// FNOSBangumiClient.swift
// v115: Bangumi API 客户端 — 番剧推荐数据抓取（公开 API，无需 key）
// 文档：https://bangumi.github.io/api/
//

import Foundation

// MARK: - Bangumi 番剧数据模型

struct FNOSBangumiItem: Identifiable {
    let id: Int
    let name: String
    let nameCN: String
    let imageURL: URL?
    let summary: String
    let score: Double
    let airDate: String?
    let weekday: String?

    var displayTitle: String { nameCN.isEmpty ? name : nameCN }
}

// MARK: - Bangumi API 调用

enum FNOSBangumiClient {
    static let baseURL = "https://api.bgm.tv"

    /// 每日放送日历 → 扁平化为番剧列表
    static func calendar() async throws -> [FNOSBangumiItem] {
        let url = URL(string: "\(baseURL)/calendar")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FNOSDirectError("Bangumi calendar HTTP \(code)")
        }

        guard let weekdays = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FNOSDirectError("Bangumi calendar 响应非 JSON")
        }

        var items: [FNOSBangumiItem] = []
        for weekday in weekdays {
            let wdName = (weekday["weekday"] as? [String: Any])?["cn"] as? String
            guard let dayItems = weekday["items"] as? [[String: Any]] else { continue }
            for dict in dayItems {
                guard let id = dict["id"] as? Int else { continue }
                let name = dict["name"] as? String ?? ""
                let nameCN = dict["name_cn"] as? String ?? ""
                let summary = dict["summary"] as? String ?? ""
                let score = dict["score"] as? Double ?? 0
                let airDate = dict["air_date"] as? String

                let images = dict["images"] as? [String: Any]
                let imgPath = (images?["common"] as? String) ?? (images?["large"] as? String) ?? (images?["medium"] as? String)
                let imageURL = imgPath.flatMap { URL(string: $0) }

                items.append(FNOSBangumiItem(
                    id: id,
                    name: name,
                    nameCN: nameCN,
                    imageURL: imageURL,
                    summary: summary,
                    score: score,
                    airDate: airDate,
                    weekday: wdName
                ))
            }
        }
        return items
    }

    /// 番剧详情（subject 端点）
    static func subject(id: Int) async throws -> [String: Any] {
        let url = URL(string: "\(baseURL)/v0/subjects/\(id)")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FNOSDirectError("Bangumi subject 响应非 JSON")
        }
        return json
    }
}
