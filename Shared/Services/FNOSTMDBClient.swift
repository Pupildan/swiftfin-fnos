//
// FNOSTMDBClient.swift
// v111: TMDB API 客户端 — 热门推荐数据抓取
//

import Foundation

// MARK: - TMDB 条目数据模型

struct FNOSTMDBItem: Identifiable, Codable {
    let id: Int
    let title: String
    let posterPath: String?
    let backdropPath: String?
    let overview: String
    let releaseDate: String?
    let voteAverage: Double
    let mediaType: String   // "movie" / "tv"

    var posterURL: URL? {
        guard let posterPath, !posterPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(posterPath)")
    }

    var backdropURL: URL? {
        guard let backdropPath, !backdropPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w1280\(backdropPath)")
    }

    var year: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }
}

// MARK: - TMDB API 调用

enum FNOSTMDBClient {
    static let baseURL = "https://api.themoviedb.org/3"

    /// 每日热门（trending/all/day，混合电影+剧集，中文）
    static func trending(apiKey: String) async throws -> [FNOSTMDBItem] {
        let urlString = "\(baseURL)/trending/all/day?api_key=\(apiKey)&language=zh-CN"
        guard let url = URL(string: urlString) else {
            throw FNOSDirectError("TMDB URL 构造失败")
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FNOSDirectError("TMDB HTTP \(code)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else {
            throw FNOSDirectError("TMDB 响应无 results")
        }

        return results.compactMap { dict in
            guard let id = dict["id"] as? Int else { return nil }
            let mediaType = dict["media_type"] as? String ?? "movie"
            let title = (dict["title"] as? String) ?? (dict["name"] as? String) ?? "?"
            let posterPath = dict["poster_path"] as? String
            let backdropPath = dict["backdrop_path"] as? String
            let overview = dict["overview"] as? String ?? ""
            let releaseDate = (dict["release_date"] as? String) ?? (dict["first_air_date"] as? String)
            let voteAverage = dict["vote_average"] as? Double ?? 0

            return FNOSTMDBItem(
                id: id,
                title: title,
                posterPath: posterPath,
                backdropPath: backdropPath,
                overview: overview,
                releaseDate: releaseDate,
                voteAverage: voteAverage,
                mediaType: mediaType
            )
        }
    }

    /// v194: TMDB 多类型搜索（电影+剧集，中文；过滤掉 person 结果）
    static func search(query: String, apiKey: String) async throws -> [FNOSTMDBItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        let urlString = "\(baseURL)/search/multi?api_key=\(apiKey)&language=zh-CN&query=\(encoded)"
        guard let url = URL(string: urlString) else {
            throw FNOSDirectError("TMDB 搜索 URL 构造失败")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FNOSDirectError("TMDB 搜索 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw FNOSDirectError("TMDB 搜索响应无 results")
        }
        return results.compactMap { dict in
            guard let id = dict["id"] as? Int else { return nil }
            let mediaType = dict["media_type"] as? String ?? "movie"
            // search/multi 会混入 person 结果——只保留电影/剧集
            guard mediaType == "movie" || mediaType == "tv" else { return nil }
            let title = (dict["title"] as? String) ?? (dict["name"] as? String) ?? "?"
            let posterPath = dict["poster_path"] as? String
            let backdropPath = dict["backdrop_path"] as? String
            let overview = dict["overview"] as? String ?? ""
            let releaseDate = (dict["release_date"] as? String) ?? (dict["first_air_date"] as? String)
            let voteAverage = dict["vote_average"] as? Double ?? 0
            return FNOSTMDBItem(
                id: id,
                title: title,
                posterPath: posterPath,
                backdropPath: backdropPath,
                overview: overview,
                releaseDate: releaseDate,
                voteAverage: voteAverage,
                mediaType: mediaType
            )
        }
    }

    /// 电影/剧集详情（Phase 2 用，先预留）
    static func detail(id: Int, mediaType: String, apiKey: String) async throws -> [String: Any] {
        let urlString = "\(baseURL)/\(mediaType)/\(id)?api_key=\(apiKey)&language=zh-CN&append_to_response=credits"
        guard let url = URL(string: urlString) else {
            throw FNOSDirectError("TMDB detail URL 构造失败")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FNOSDirectError("TMDB detail 响应非 JSON")
        }
        return json
    }

    // MARK: - v123 富数据端点

    /// 标题匹配：按标题(+年份)查 TMDB，返回最优候选 (id, mediaType, title)
    static func searchMatch(title: String, year: String?, apiKey: String) async -> (id: Int, mediaType: String, title: String)? {
        guard !apiKey.isEmpty, !title.isEmpty else { return nil }
        var query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        // 带年份精确匹配率更高；year 只对 movie/tv 有意义
        var urlString = "\(baseURL)/search/multi?api_key=\(apiKey)&language=zh-CN&query=\(query)"
        if let year, year.count == 4 {
            urlString += "&year=\(year)"
        }
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        // 过滤 person，只留 movie/tv，取第一个有标题的
        for r in results {
            guard let type = r["media_type"] as? String, type == "movie" || type == "tv" else { continue }
            guard let id = r["id"] as? Int else { continue }
            let t = (r["title"] as? String) ?? (r["name"] as? String) ?? ""
            if !t.isEmpty { return (id, type, t) }
        }
        return nil
    }

    /// 富详情：一次拉 credits + images + videos + similar + external_ids + release_dates/content_ratings
    static func richDetail(id: Int, mediaType: String, apiKey: String) async throws -> [String: Any] {
        let urlString = "\(baseURL)/\(mediaType)/\(id)?api_key=\(apiKey)&language=zh-CN"
            + "&append_to_response=credits,images,videos,similar,external_ids,release_dates,content_ratings"
            + "&include_image_language=zh,en,null"
        guard let url = URL(string: urlString) else {
            throw FNOSDirectError("TMDB richDetail URL 构造失败")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FNOSDirectError("TMDB richDetail 响应非 JSON")
        }
        return json
    }

    /// v180: TMDB 人物详情（人物弹窗用；biography 官方简介）
    static func personDetail(id: Int, apiKey: String) async -> [String: Any]? {
        let urlString = "\(baseURL)/person/\(id)?api_key=\(apiKey)&language=zh-CN"
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    /// 从 richDetail JSON 提取 logo（优先 zh，退 en/any）
    static func logoURL(from json: [String: Any]) -> URL? {        guard let images = json["images"] as? [String: Any],
              let logos = images["logos"] as? [[String: Any]], !logos.isEmpty else { return nil }
        let path = logos.first?["file_path"] as? String ?? logos.first?["logo_path"] as? String
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }

    /// TMDB 视频条目
    struct TMDBVideo: Identifiable {
        let id: String       // 用 key 当 id
        let key: String      // YouTube video key
        let name: String
        let type: String     // Trailer / Teaser / Clip / Featurette / Behind the Scenes
        let official: Bool
        var isTrailer: Bool { type == "Trailer" || type == "Teaser" }
        var isBonus: Bool { type == "Behind the Scenes" || type == "Featurette" }
        var thumbnailURL: URL? {
            URL(string: "https://img.youtube.com/vi/\(key)/hqdefault.jpg")
        }
    }

    /// 从 richDetail JSON 提取视频列表（YouTube only）
    static func videos(from json: [String: Any]) -> [TMDBVideo] {
        guard let vids = json["videos"] as? [String: Any],
              let results = vids["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { v in
            guard let key = v["key"] as? String, !key.isEmpty else { return nil }
            guard let site = v["site"] as? String, site == "YouTube" else { return nil }
            let name = v["name"] as? String ?? ""
            let type = v["type"] as? String ?? ""
            let official = v["official"] as? Bool ?? false
            return TMDBVideo(id: key, key: key, name: name, type: type, official: official)
        }
        // 预告优先、官方优先排序
        .sorted { a, b in
            if a.isTrailer != b.isTrailer { return a.isTrailer }
            if a.official != b.official { return a.official }
            return false
        }
    }

    /// 从 richDetail JSON 提取相似推荐（复用 FNOSTMDBItem）
    static func similarItems(from json: [String: Any]) -> [FNOSTMDBItem] {
        guard let sim = json["similar"] as? [String: Any],
              let results = sim["results"] as? [[String: Any]] else { return [] }
        return results.prefix(20).compactMap { dict in
            guard let id = dict["id"] as? Int else { return nil }
            let mediaType = dict["media_type"] as? String ?? "movie"
            let title = (dict["title"] as? String) ?? (dict["name"] as? String) ?? "?"
            let posterPath = dict["poster_path"] as? String
            let backdropPath = dict["backdrop_path"] as? String
            let overview = dict["overview"] as? String ?? ""
            let releaseDate = (dict["release_date"] as? String) ?? (dict["first_air_date"] as? String)
            let voteAverage = dict["vote_average"] as? Double ?? 0
            guard let posterPath, !posterPath.isEmpty else { return nil }
            return FNOSTMDBItem(id: id, title: title, posterPath: posterPath, backdropPath: backdropPath,
                                overview: overview, releaseDate: releaseDate, voteAverage: voteAverage, mediaType: mediaType)
        }
    }
}
