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

    /// frodo 完整详情（简介/类型/年份/主演/导演 + v167 制作信息卡字段）
    struct FNOSDoubanFrodoDetail {
        var summary: String = ""
        var genres: [String] = []
        var year: String = ""
        var castNames: [String] = []
        var directors: [String] = []
        var countries: [String] = []
        var languages: [String] = []
        var durations: [String] = []
        var pubdate: [String] = []
        var originalTitle: String = ""
        var ratingValue: Double = 0
        var ratingCount: Int = 0
        var commentCount: Int = 0
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
            // v167: 制作信息卡字段（全部防御性解析，缺字段=空）
            d.countries = (json["countries"] as? [String]) ?? []
            d.languages = (json["languages"] as? [String]) ?? []
            d.durations = (json["durations"] as? [String]) ?? []
            d.pubdate = (json["pubdate"] as? [String]) ?? []
            d.originalTitle = json["original_title"] as? String ?? ""
            if let rating = json["rating"] as? [String: Any] {
                d.ratingValue = (rating["value"] as? Double) ?? 0
                d.ratingCount = (rating["count"] as? Int) ?? 0
            }
            d.commentCount = (json["comment_count"] as? Int) ?? 0
            return d
        } catch {
            print("FNOS⚠️豆瓣 frodo 详情异常: \(error.localizedDescription)")
            return nil
        }
    }

    /// frodo 通用 GET（对象根）——v168: 修签名缺 /api/v2 前缀（见 frodoGetAny）
    private static func frodoGet(path: String, extra: [URLQueryItem] = []) async -> [String: Any]? {
        await frodoGetAny(path: path, extra: extra) as? [String: Any]
    }

    /// frodo 通用 GET（任意 JSON 根：对象给详情类，数组给 recommendations）
    /// v168 根因修复：签名串必须含 /api/v2 前缀（实测缺前缀=HTTP 400，带前缀=200）。
    /// 此前自 v129 起 celebrities/reviews/photos 三条 frodoGet 通道全部静默 400 →
    /// 演员头像退化文字、短评弹幕不出现、Hero 横图退回竖版——一个根因三个症状。
    /// （MoviePilot apiv2.py 的 sign 用完整实际路径，照抄时漏了前缀。）
    private static func frodoGetAny(path: String, extra: [URLQueryItem] = []) async -> Any? {
        let signPath = "/api/v2" + path          // 签名 = 完整实际路径
        let ts = Int(Date().timeIntervalSince1970)
        let sig = frodoSign(path: signPath, ts: ts)
        var comps = URLComponents(string: frodoBase + path)   // frodoBase 已含 /api/v2，URL 不重复拼
        comps?.queryItems = [
            URLQueryItem(name: "apiKey", value: frodoAPIKey),
            URLQueryItem(name: "os_rom", value: "android"),
            URLQueryItem(name: "_ts", value: String(ts)),
            URLQueryItem(name: "_sig", value: sig),
        ] + extra
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(frodoUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                print("FNOS⚠️豆瓣 frodo GET 失败 \(path) HTTP=\((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            return try? JSONSerialization.jsonObject(with: data)
        } catch {
            print("FNOS⚠️豆瓣 frodo GET 异常: \(error.localizedDescription)")
            return nil
        }
    }

    /// 豆瓣演员/导演（带头像，圆形头像行用）
    struct FNOSDoubanCelebrity: Identifiable {
        let id: String
        let name: String
        let character: String
        let avatarURL: URL?
    }

    /// frodo 演员 + 导演（/movie/{id}/celebrities 或 /tv/{id}/celebrities）
    /// 注意：frodoBase 已含 /api/v2，frodoGet 的 path 参数不要再拼 /api/v2
    static func frodoCelebrities(id: String, category: String) async -> [FNOSDoubanCelebrity] {
        let sub = category == "电影" ? "/movie/\(id)" : "/tv/\(id)"
        guard let json = await frodoGet(path: "\(sub)/celebrities") else { return [] }
        var result: [FNOSDoubanCelebrity] = []
        for group in ["actors", "directors"] {
            guard let arr = json[group] as? [[String: Any]] else { continue }
            for c in arr.prefix(15) {
                guard let cid = c["id"] as? String ?? (c["id"] as? Int).map(String.init) else { continue }
                let name = c["name"] as? String ?? ""
                guard !name.isEmpty else { continue }
                let character = c["character"] as? String ?? ""
                let avatar = c["avatar"] as? [String: Any]
                let avatarPath = (avatar?["normal"] as? String) ?? (avatar?["large"] as? String)
                let avatarURL = avatarPath.flatMap { URL(string: $0) }
                result.append(FNOSDoubanCelebrity(id: cid, name: name, character: character, avatarURL: avatarURL))
            }
        }
        return result
    }

    // MARK: - v167 Hero 横屏高清剧照

    /// 把 frodo 图片 URL 规范化为高清直链：
    /// 提取 pXXXX.扩展名 文件名 → https://img1.doubanio.com/view/photo/l/public/{文件名}
    /// （raw 是 418 防盗图不可用；/l/ 实测 200，qnmob3 签名 CDN 的临时链接也归一到长效域名）
    private static func canonicalPhotoURL(_ raw: String) -> URL? {
        let noQuery = raw.components(separatedBy: "?").first ?? raw
        guard let file = noQuery.split(separator: "/").last,
              file.range(of: #"^p\d+\.(jpg|jpeg|png|webp)$"#, options: .regularExpression) != nil
        else { return nil }
        // 原 host 本身是 img*.doubanio.com 就沿用（webp 扩展名在原 host 实测可用），否则统一 img1
        var host = "img1.doubanio.com"
        if let h = URL(string: raw)?.host, h.hasPrefix("img"), h.hasSuffix("doubanio.com") {
            host = h
        }
        return URL(string: "https://\(host)/view/photo/l/public/\(file)")
    }

    /// v167: Hero 横屏高清剧照——frodo /photos?kind=s 两页窗口(0/50)，
    /// 过滤横屏(w>h)按分辨率降序取最优；首页已有横屏则不翻第二页（TV 番剧横图稀疏，需翻页）。
    /// 失败/无横屏返回 nil → 详情页竖版海报垫底兜底（不拉伸变形由视图层 aspectFill 负责）。
    static func frodoLandscapeURL(id: String, category: String) async -> URL? {
        let sub = category == "电影" ? "/movie/\(id)" : "/tv/\(id)"
        var best: (width: Int, url: URL)? = nil
        // 查询计划：kind=s 两页（常规）→ 全量兜底一页（kind=s 空洞时）
        let plans: [(kind: String?, start: Int)] = [("s", 0), ("s", 50), (nil, 0)]
        for plan in plans {
            var extra = [
                URLQueryItem(name: "count", value: "50"),
                URLQueryItem(name: "start", value: String(plan.start)),
            ]
            if let k = plan.kind {
                extra.insert(URLQueryItem(name: "kind", value: k), at: 0)
            }
            let json = await frodoGet(path: "\(sub)/photos", extra: extra)
            guard let photos = json?["photos"] as? [[String: Any]], !photos.isEmpty else { continue }
            for p in photos {
                guard let img = p["image"] as? [String: Any],
                      let large = img["large"] as? [String: Any],
                      let w = large["width"] as? Int, let h = large["height"] as? Int,
                      w > h,
                      let raw = large["url"] as? String,
                      let url = canonicalPhotoURL(raw)
                else { continue }
                if best == nil || w > best!.width {
                    best = (w, url)
                }
            }
            if best != nil { break }
        }
        return best?.url
    }

    // MARK: - v168 相似推荐（frodo /recommendations，电影/剧集同款，实测 200）

    struct FNOSDoubanRec: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let posterURL: URL?
        let rating: Double?
        let mediaType: String      // movie / tv
        let subjectURL: String
    }

    /// /recommendations 返回 JSON 数组（非对象根）——走 frodoGetAny
    static func frodoRecommendations(id: String, category: String) async -> [FNOSDoubanRec] {
        let sub = category == "电影" ? "/movie/\(id)" : "/tv/\(id)"
        guard let arr = await frodoGetAny(
            path: "\(sub)/recommendations",
            extra: [
                URLQueryItem(name: "count", value: "12"),
                URLQueryItem(name: "start", value: "0"),
            ]
        ) as? [[String: Any]] else { return [] }
        return arr.prefix(12).compactMap { d in
            guard let rid = d["id"] as? String ?? (d["id"] as? Int).map(String.init),
                  let title = d["title"] as? String, !title.isEmpty else { return nil }
            let subtitle = d["card_subtitle"] as? String ?? ""
            let poster = (d["pic"] as? [String: Any])?["large"] as? String
            let posterURL = poster.flatMap { URL(string: $0) }
            let rating = (d["rating"] as? [String: Any])?["value"] as? Double
            let mediaType = d["type"] as? String ?? "movie"
            let subjectURL = d["url"] as? String ?? ""
            return FNOSDoubanRec(
                id: rid, title: title, subtitle: subtitle, posterURL: posterURL,
                rating: rating, mediaType: mediaType, subjectURL: subjectURL
            )
        }
    }

    /// 豆瓣评论（短评）
    struct FNOSDoubanReview: Identifiable {
        let id: String
        let author: String
        let rating: Double?
        let content: String
        let title: String
    }

    /// frodo 评论（/movie/{id}/reviews 或 /tv/{id}/reviews）
    /// 注意：frodoBase 已含 /api/v2，frodoGet 的 path 参数不要再拼 /api/v2
    static func frodoReviews(id: String, category: String) async -> [FNOSDoubanReview] {
        let sub = category == "电影" ? "/movie/\(id)" : "/tv/\(id)"
        guard let json = await frodoGet(path: "\(sub)/reviews") else { return [] }
        guard let reviews = json["reviews"] as? [[String: Any]] else { return [] }
        return reviews.prefix(20).compactMap { r in
            guard let rid = r["id"] as? String ?? (r["id"] as? Int).map(String.init) else { return nil }
            let content = r["abstract"] as? String ?? ""
            guard !content.isEmpty else { return nil }
            let author = (r["user"] as? [String: Any])?["name"] as? String ?? "匿名"
            let rating = (r["rating"] as? [String: Any])?["value"] as? Double
            let title = r["title"] as? String ?? ""
            return FNOSDoubanReview(id: rid, author: author, rating: rating, content: content, title: title)
        }
    }
}
