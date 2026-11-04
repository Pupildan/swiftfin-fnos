//
// FNOSTMDBDetailView.swift
// v113: TMDB 条目详情页 — 数据全从 TMDB 抓取，风格与媒体库详情页一致
//

import SwiftUI

struct FNOSTMDBDetail: Identifiable {
    let id: Int
    let title: String
    let overview: String
    let backdropURL: URL?
    let posterURL: URL?
    let releaseDate: String?
    let voteAverage: Double
    let mediaType: String
    var cast: [TMDBCastMember] = []
    var genres: [String] = []

    struct TMDBCastMember: Identifiable {
        let id: Int
        let name: String
        let character: String
        let profileURL: URL?
    }
}

struct FNOSTMDBDetailView: View {
    let item: FNOSTMDBItem
    let apiKey: String
    let onDismiss: () -> Void

    @State private var detail: FNOSTMDBDetail?
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 背景：backdrop 图 + 渐变压暗
                ZStack {
                    Color.black
                    if let backdrop = detail?.backdropURL {
                        FNOSAsyncImage(url: backdrop, headers: [:])
                            .ignoresSafeArea()
                            .overlay(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.3),
                                        .init(color: .black.opacity(0.7), location: 0.7),
                                        .init(color: .black, location: 1.0),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                }
                .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Hero 区
                        heroSection(size: geo.size)
                        // 信息区
                        infoSection
                            .padding(.horizontal, 60)
                            .padding(.top, 20)
                            .padding(.bottom, 40)
                    }
                }
                .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
        .task { await loadDetail() }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            // backdrop 或 poster
            if let backdrop = detail?.backdropURL ?? item.backdropURL {
                FNOSAsyncImage(url: backdrop, headers: [:])
                    .frame(width: size.width, height: size.width * 9 / 16)
                    .clipped()
            }

            // 渐变压暗底部
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.4),
                    .init(color: .black.opacity(0.9), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 12) {
                Text(detail?.title ?? item.title)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)

                HStack(spacing: 12) {
                    if let year = detailYear {
                        Text(year)
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    if let rating = detail?.voteAverage, rating > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", rating))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .font(.system(size: 17))
                    }
                    if let type = detail?.mediaType {
                        Text(type == "tv" ? "剧集" : "电影")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }

                // 加入影视库按钮
                Button {
                    // Phase 3：PT 搜种 + QBT 推送（暂未实现）
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .bold))
                        Text("加入影视库")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(0.4), lineWidth: 1.5)
                            )
                    )
                }
                .buttonStyle(.card)
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 30)
        }
        .frame(width: size.width, height: size.width * 9 / 16)
    }

    private var detailYear: String? {
        detail?.releaseDate ?? item.releaseDate
    }

    // MARK: - Info

    @ViewBuilder
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            // 简介
            if let overview = detail?.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 19))
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(6)
            }

            // 类型
            if let genres = detail?.genres, !genres.isEmpty {
                HStack(spacing: 10) {
                    ForEach(genres, id: \.self) { genre in
                        Text(genre)
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Color.white.opacity(0.12))
                            )
                    }
                }
            }

            // 演员
            if let cast = detail?.cast, !cast.isEmpty {
                Text("主要演员")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 20) {
                        ForEach(cast) { member in
                            VStack(spacing: 8) {
                                if let profile = member.profileURL {
                                    FNOSAsyncImage(url: profile, headers: [:])
                                        .frame(width: 80, height: 80)
                                        .clipShape(Circle())
                                } else {
                                    Circle()
                                        .fill(Color.white.opacity(0.1))
                                        .frame(width: 80, height: 80)
                                }
                                Text(member.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .lineLimit(1)
                                Text(member.character)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                            .frame(width: 80)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Load

    private func loadDetail() async {
        do {
            let json = try await FNOSTMDBClient.detail(
                id: item.id,
                mediaType: item.mediaType,
                apiKey: apiKey
            )

            let overview = json["overview"] as? String ?? item.overview
            let releaseDate = json["release_date"] as? String ?? item.releaseDate
            let voteAverage = json["vote_average"] as? Double ?? item.voteAverage
            let backdropPath = json["backdrop_path"] as? String
            let posterPath = json["poster_path"] as? String

            // 类型
            let genreList = (json["genres"] as? [[String: Any]])?.compactMap { g in
                g["name"] as? String
            } ?? []

            // 演员
            let credits = json["credits"] as? [String: Any]
            let castList = (credits?["cast"] as? [[String: Any]])?.prefix(10).compactMap { c -> FNOSTMDBDetail.TMDBCastMember? in
                guard let cid = c["id"] as? Int else { return nil }
                let name = c["name"] as? String ?? ""
                let character = c["character"] as? String ?? ""
                let profilePath = c["profile_path"] as? String
                let profileURL = profilePath.map { URL(string: "https://image.tmdb.org/t/p/w185\($0)")! }
                return FNOSTMDBDetail.TMDBCastMember(id: cid, name: name, character: character, profileURL: profileURL)
            } ?? []

            let backdropURL = backdropPath.map { URL(string: "https://image.tmdb.org/t/p/w1280\($0)")! }
            let posterURL = posterPath.map { URL(string: "https://image.tmdb.org/t/p/w500\($0)")! }

            detail = FNOSTMDBDetail(
                id: item.id,
                title: item.title,
                overview: overview,
                backdropURL: backdropURL,
                posterURL: posterURL,
                releaseDate: releaseDate,
                voteAverage: voteAverage,
                mediaType: item.mediaType,
                cast: castList,
                genres: genreList
            )
            isLoading = false
        } catch {
            print("FNOS⚠️TMDB 详情加载失败: \(error.localizedDescription)")
            isLoading = false
        }
    }
}
