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
}
