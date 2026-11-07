//
// FNOSBangumiClient.swift
// v115: Bangumi API 客户端 — 番剧数据抓取（公开接口，无需 key）
// v117: 数据源改为「近期注目」https://bangumi.tv/anime/browser?sort=trends
//        （官方 API 无此端点，走网站 HTML 解析：li[id=item_XXX] + 封面 img + h3 标题）
// 文档：https://bangumi.github.io/api/
//

import Foundation

// MARK: - Bangumi 番剧数据模型（v117: Codable 供每日缓存持久化）

struct FNOSBangumiItem: Identifiable, Codable {
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

// MARK: - Bangumi 客户端

enum FNOSBangumiClient {
    static let baseURL = "https://api.bgm.tv"
    /// 近期注目列表页（网站 HTML，官方 API 无对应 JSON 端点）
    static let trendingURL = "https://bangumi.tv/anime/browser?sort=trends"

    /// v117: 近期注目（Top 30）——解析网站 HTML，封面直取 800px（r/800 实测可用）
    static func trending() async throws -> [FNOSBangumiItem] {
        guard let url = URL(string: trendingURL) else {
            throw FNOSDirectError("Bangumi trending URL 构造失败")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FNOSDirectError("Bangumi trending HTML HTTP \(code)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw FNOSDirectError("Bangumi trending HTML 非 UTF-8")
        }

        // 每个 <li id="item_XXX"> 块内依次有：封面 img → <h3><a>标题</a> → <p class="info tip">放送信息
        let pattern = #"<li id="item_(\d+)".*?<img src="([^"]+)".*?<h3>.*?<a [^>]*>(.*?)</a>.*?<p class="info tip">([\s\S]*?)</p>"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(html.startIndex..., in: html)
        var items: [FNOSBangumiItem] = []

        regex?.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 5 else { return }
            guard let idRange = Range(match.range(at: 1), in: html),
                  let imgRange = Range(match.range(at: 2), in: html),
                  let titleRange = Range(match.range(at: 3), in: html),
                  let infoRange = Range(match.range(at: 4), in: html) else { return }
            guard let id = Int(html[idRange]) else { return }

            var imgPath = String(html[imgRange])
            if imgPath.hasPrefix("//") { imgPath = "https:" + imgPath }
            // 400px 封面升 800px（实测 r/800 返回 200）
            imgPath = imgPath.replacingOccurrences(of: "/r/400/", with: "/r/800/")
            let imageURL = URL(string: imgPath)

            var title = String(html[titleRange])
            title = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            title = decodeHTMLEntities(title)

            let info = String(html[infoRange])
            // 放送信息形如「12话 / 2026年10月31日 / ...」，取年月做展示
            let yearMatch = info.range(of: #"(\d{4})年"#, options: .regularExpression)
            let airDate = yearMatch.flatMap { range -> String? in
                let yearPart = String(info[range])
                return yearPart.replacingOccurrences(of: "年", with: "")
            }

            items.append(FNOSBangumiItem(
                id: id,
                name: "",
                nameCN: title,
                imageURL: imageURL,
                summary: "",
                score: 0,
                airDate: airDate,
                weekday: nil
            ))
        }
        return items
    }

    /// HTML 常见实体解码（标题里可能有 & " 等）
    private static func decodeHTMLEntities(_ s: String) -> String {
        var out = s
        let amp = "&"   // 实体串拼接构造，避免字面量被工具链剥掉
        out = out.replacingOccurrences(of: amp + "amp;", with: amp)
        out = out.replacingOccurrences(of: amp + "quot;", with: "\"")
        out = out.replacingOccurrences(of: amp + "#39;", with: "'")
        out = out.replacingOccurrences(of: amp + "#x27;", with: "'")
        out = out.replacingOccurrences(of: amp + "apos;", with: "'")
        out = out.replacingOccurrences(of: amp + "lt;", with: "<")
        out = out.replacingOccurrences(of: amp + "gt;", with: ">")
        out = out.replacingOccurrences(of: amp + "nbsp;", with: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 番剧详情（v0 API）
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

    // MARK: - v123 富数据端点

    /// Bangumi 制作人员（v0 API）
    struct BangumiPerson: Identifiable {
        let id: Int
        let name: String
        let role: String
        let imageURL: URL?
    }

    /// 制作人员（/v0/subjects/{id}/persons）
    static func persons(id: Int) async -> [BangumiPerson] {
        guard let url = URL(string: "\(baseURL)/v0/subjects/\(id)/persons") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.prefix(20).compactMap { p in
            guard let pid = p["id"] as? Int else { return nil }
            let name = p["name"] as? String ?? ""
            let role = (p["role_name"] as? String) ?? (p["relation"] as? String) ?? ""
            let imgs = p["images"] as? [String: Any]
            let imgPath = (imgs?["medium"] as? String) ?? (imgs?["large"] as? String)
            let imgURL = imgPath.flatMap { URL(string: $0) }
            guard !name.isEmpty else { return nil }
            return BangumiPerson(id: pid, name: name, role: role, imageURL: imgURL)
        }
    }

    /// 相关条目（/v0/subjects/{id}/subjects）
    struct BangumiRelated: Identifiable {
        let id: Int
        let name: String
        let relation: String
        let imageURL: URL?
        var displayTitle: String { name }
    }

    static func relatedSubjects(id: Int) async -> [BangumiRelated] {
        guard let url = URL(string: "\(baseURL)/v0/subjects/\(id)/subjects") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.prefix(20).compactMap { r in
            guard let rid = r["id"] as? Int else { return nil }
            let name = r["name"] as? String ?? ""
            let relation = r["relation"] as? String ?? ""
            guard !name.isEmpty else { return nil }
            let images = r["images"] as? [String: Any]
            let imgPath = (images?["common"] as? String) ?? (images?["medium"] as? String)
            var finalPath = imgPath ?? ""
            if finalPath.contains("/r/400/") { finalPath = finalPath.replacingOccurrences(of: "/r/400/", with: "/r/800/") }
            let imgURL = URL(string: finalPath)
            return BangumiRelated(id: rid, name: name, relation: relation, imageURL: imgURL)
        }
    }

    // MARK: - v167 短评（网页 HTML 解析——官方 API 无评论端点）

    /// 短评（/subject/{id}/comments，取前 40 条；作者 + 正文，供 Hero 弹幕与评论区共用）
    /// 结构实测：<p class="comment">正文</p>，同条目内 <a href="/user/.." class="l">作者</a>
    struct BangumiComment: Identifiable {
        let id: String          // 序号（加载内稳定）
        let author: String
        let content: String
    }

    static func comments(id: Int) async -> [BangumiComment] {
        guard let url = URL(string: "https://bangumi.tv/subject/\(id)/comments") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) else {
            return []
        }
        // 作者锚（class="l"）与其后第一条 <p class="comment"> 配对
        let pattern = #"<a href="/user/[^"]*" class="l">([^<]*)</a>[\s\S]*?<p class="comment">([\s\S]*?)</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var out: [BangumiComment] = []
        regex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 3,
                  let authorR = Range(match.range(at: 1), in: html),
                  let contentR = Range(match.range(at: 2), in: html) else { return }
            let author = decodeHTMLEntities(String(html[authorR])).trimmingCharacters(in: .whitespacesAndNewlines)
            var text = String(html[contentR])
            text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            text = decodeHTMLEntities(text)
            text = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { return }
            out.append(BangumiComment(id: String(out.count), author: author.isEmpty ? "匿名" : author, content: text))
        }
        return Array(out.prefix(40))
    }

    /// infobox 键值对提取（放送日/原名/集数/时长/制作/官网等）
    static func infobox(from json: [String: Any]) -> [(key: String, value: String)] {
        guard let info = json["infobox"] as? [[String: Any]] else { return [] }
        return info.compactMap { item in
            guard let key = item["key"] as? String else { return nil }
            var value = ""
            if let v = item["value"] as? String {
                value = v
            } else if let arr = item["value"] as? [[String: Any]] {
                value = arr.compactMap { $0["v"] as? String }.joined(separator: " / ")
            }
            value = decodeHTMLEntities(value)
            guard !value.isEmpty else { return nil }
            return (key, value)
        }
    }
}
