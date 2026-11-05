//
// FNOSDoubanClient.swift
// v126: 豆瓣热门抓取（无公开 API，走豆瓣网页自用的 JSON 端点）
// 端点：https://movie.douban.com/j/search_subjects?type={movie|tv}&tag={热门|综艺}&sort=recommend
// 三分类各 20 条 = 电视剧 20 + 热门电影 20 + 热门综艺 20，共 60 条
//

import Foundation

// MARK: - 豆瓣条目模型

struct FNOSDoubanItem: Identifiable, Codable {
    let id: String           // 豆瓣 subject id
    let title: String
    let rate: String         // 评分字符串（可能为空）
    let coverURL: URL?
    let subjectURL: String
    let episodesInfo: String // 集数信息（如「29集」，可能为空）
    let category: String     // 电影 / 电视剧 / 综艺

    var displayRating: Double? {
        let trimmed = rate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }
}

// MARK: - 豆瓣客户端

enum FNOSDoubanClient {

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let endpoint = "https://movie.douban.com/j/search_subjects"

    /// 单分类抓取（20 条）
    private static func fetchCategory(type: String, tag: String, category: String) async throws -> [FNOSDoubanItem] {
        // tag 中文需百分号编码
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag
        let urlString = "\(endpoint)?type=\(type)&tag=\(encodedTag)&sort=recommend&page_limit=20&page_start=0"
        guard let url = URL(string: urlString) else {
            throw FNOSDirectError("豆瓣 URL 构造失败")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FNOSDirectError("豆瓣 \(category) HTTP \(code)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subjects = json["subjects"] as? [[String: Any]] else {
            throw FNOSDirectError("豆瓣 \(category) 响应无 subjects")
        }

        return subjects.prefix(20).compactMap { dict in
            guard let id = dict["id"] as? String ?? (dict["id"] as? Int).map(String.init) else { return nil }
            let title = dict["title"] as? String ?? ""
            guard !title.isEmpty else { return nil }
            let rate = dict["rate"] as? String ?? ""
            let cover = dict["cover"] as? String
            let subjectURL = dict["url"] as? String ?? ""
            let eps = dict["episodes_info"] as? String ?? ""
            let coverURL = cover.flatMap { URL(string: $0) }
            return FNOSDoubanItem(
                id: id, title: title, rate: rate, coverURL: coverURL,
                subjectURL: subjectURL, episodesInfo: eps, category: category
            )
        }
    }

    /// 豆瓣热门 60 条：热门电影 20 + 电视剧（热门）20 + 综艺 20
    static func trending() async throws -> [FNOSDoubanItem] {
        var all: [FNOSDoubanItem] = []
        // 三个分类独立抓取；单个失败不影响其它（尽量凑满 60）
        let groups: [(type: String, tag: String, category: String)] = [
            ("movie", "热门", "电影"),
            ("tv", "热门", "电视剧"),
            ("tv", "综艺", "综艺"),
        ]
        for g in groups {
            do {
                let items = try await fetchCategory(type: g.type, tag: g.tag, category: g.category)
                all.append(contentsOf: items)
            } catch {
                print("FNOS⚠️豆瓣 \(g.category) 抓取失败: \(error.localizedDescription)")
            }
        }
        guard !all.isEmpty else {
            throw FNOSDirectError("豆瓣三个分类全部抓取失败")
        }
        return all
    }
}
