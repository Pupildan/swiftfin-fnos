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
}
