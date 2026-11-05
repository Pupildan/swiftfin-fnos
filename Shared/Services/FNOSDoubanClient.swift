//
// FNOSDoubanClient.swift
// v126: 豆瓣热门抓取（无公开 API，走豆瓣网页自用的 JSON 端点）
// 端点：https://movie.douban.com/j/search_subjects?type={movie|tv}&tag={热门|综艺}&sort=recommend
// 三分类各 20 条 = 电视剧 20 + 热门电影 20 + 热门综艺 20，共 60 条
//

import Foundation
import CryptoKit

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
            // v130：s_ratio_poster（小图）放大糊 → 升级 m_ratio_poster（中图）
            var coverURL: URL? = nil
            if let cover = cover {
                let upgraded = cover.replacingOccurrences(of: "s_ratio_poster", with: "m_ratio_poster")
                coverURL = URL(string: upgraded)
            }
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

    // MARK: - v129 frodo 私有 API（参考 MoviePilot apiv2.py，拿完整详情：简介/类型/年份/主演）

    private static let frodoSecret = "bf7dddc7c9cfe6f7"
    private static let frodoAPIKey = "0dad551ec0f84ed02907ff5c42e8ec70"   // _api_key（GET 请求用这个，非 _api_key2）
    private static let frodoBase = "https://frodo.douban.com/api/v2"
    private static let frodoUA = "api-client/1 com.douban.frodo/7.22.0.beta9(231) Android/23 product/Mate 40 vendor/HUAWEI model/Mate 40 brand/HUAWEI  rom/android  network/wifi  platform/AndroidPad"

    /// 复刻 MoviePilot apiv2.py 的 __sign：base64(HMAC-SHA1(secret, "GET&{quote(path,safe='')}&{ts}"))
    private static func frodoSign(path: String, ts: Int, method: String = "GET") -> String {
        // Python parse.quote(path, safe='')：把 / 编码成 %2F，其余（字母数字/_.-~）不动
        let quoted = path.replacingOccurrences(of: "/", with: "%2F")
        let raw = "\(method.uppercased())&\(quoted)&\(ts)"
        let key = SymmetricKey(data: Data(frodoSecret.utf8))
        let sig = HMAC<Insecure.SHA1>.authenticationCode(for: Data(raw.utf8), using: key)
        return Data(sig).base64EncodedString()
    }

    /// frodo 完整详情（简介/类型/年份/主演/导演）
    struct FNOSDoubanFrodoDetail {
        var summary: String = ""
        var genres: [String] = []
        var year: String = ""
        var castNames: [String] = []
        var directors: [String] = []
    }

    /// 抓 frodo 完整详情（movie_detail / tv_detail），失败返回 nil 降级
    static func frodoDetail(id: String, category: String) async -> FNOSDoubanFrodoDetail? {
        // v129：id 在路径里（MoviePilot apiv2.py：__invoke(self._urls["movie_detail"] + subject_id)）
        // 电影走 /movie/{id}；电视剧、综艺走 /tv/{id}
        let subPath = category == "电影" ? "/movie/\(id)" : "/tv/\(id)"
        let path = "/api/v2\(subPath)"
        let ts = Int(Date().timeIntervalSince1970)
        let sig = frodoSign(path: path, ts: ts)

        var comps = URLComponents(string: frodoBase + subPath)
        comps?.queryItems = [
            URLQueryItem(name: "apiKey", value: frodoAPIKey),
            URLQueryItem(name: "os_rom", value: "android"),
            URLQueryItem(name: "_ts", value: String(ts)),
            URLQueryItem(name: "_sig", value: sig),
        ]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(frodoUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("FNOS⚠️豆瓣 frodo 详情失败 id=\(id) HTTP=\((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            var d = FNOSDoubanFrodoDetail()
            // 简介（frodo 字段名是 intro，不是 summary）
            d.summary = (json["intro"] as? String) ?? (json["summary"] as? String) ?? ""
            // 类型
            d.genres = (json["genres"] as? [String]) ?? []
            // 年份
            d.year = (json["year"] as? String) ?? ""
            // 主演/导演（actors/directors 都是 {name} 对象数组）
            if let actors = json["actors"] as? [[String: Any]] {
                d.castNames = actors.prefix(6).compactMap { $0["name"] as? String }
            }
            if let directors = json["directors"] as? [[String: Any]] {
                d.directors = directors.compactMap { $0["name"] as? String }
            }
            return d
        } catch {
            print("FNOS⚠️豆瓣 frodo 详情异常: \(error.localizedDescription)")
            return nil
        }
    }
}
