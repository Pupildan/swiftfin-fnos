//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

/// 播放目标（把 client/userID 与条目一起带进播放器）
struct FNOSPlaybackTarget: Identifiable {
    let id = UUID()
    let item: FNOSItem
    let client: FNOSDirectClient
    let userID: String
}

/// 单个媒体库的横向海报墙数据
struct FNOSLibrarySection: Identifiable {
    let library: FNOSLibrary
    var items: [FNOSItem]

    var id: String { library.Id }
}

/// 飞牛影视（fnOS）主界面 —— Apple TV+ 沉浸式布局。
///
/// 沉浸式第一原则：
/// - 无顶栏、无 URL、无日志输出，画面只有海报与内容；
/// - Hero Banner 真·全屏铺满（含安全区），刷新/退出做成右上角半透明小图标；
/// - 行卡片加大，全部 .buttonStyle(.card) 原生焦点质感。
struct FNOSMainView: View {

    @ObservedObject var auth: FNOSAuthStore
    let credentials: FNOSCredentials

    @State private var client: FNOSDirectClient?
    @State private var userID = ""

    @State private var sections: [FNOSLibrarySection] = []
    @State private var isLoading = false
    @State private var didBootstrap = false

    @State private var playbackTarget: FNOSPlaybackTarget?
    @State private var seriesItem: FNOSItem?

    // Hero 每日随机抽选（每天首次进入重新抽 6 部电影）
    @AppStorage("fnos.hero.date") private var heroDate = ""
    @AppStorage("fnos.hero.ids") private var heroIDs = 

    private let cardWidth: CGFloat = 300

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if isLoading {
                    VStack {
                        Spacer()
                        ProgressView("加载中…")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sections.isEmpty {
                    VStack(spacing: 12) {
                        Text("暂无内容")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            // Apple TV+ 式全屏 Hero Banner（媒体库前 6 个条目）
                            if !heroItems.isEmpty, let heroClient = client {
                                FNOSHeroBanner(
                                    items: Array(heroItems),
                                    client: heroClient,
                                    userID: userID,
                                    onPlay: { item in
                                        open(item: item)
                                    },
                                    onDetail: { item in
                                        open(item: item)
                                    }
                                )
                                .frame(width: geo.size.width, height: geo.size.height)
                            }

                            // 媒体库横向海报墙
                            LazyVStack(alignment: .leading, spacing: 44) {
                                ForEach(sections) { section in
                                    shelf(section)
                                }
                            }
                            .padding(.vertical, 40)
                        }
                    }
                    .ignoresSafeArea()

                    // 右上角悬浮小图标（半透明，不破坏画面）
                    VStack {
                        HStack(spacing: 22) {
                            Spacer()
                            Button {
                                didBootstrap = false
                                Task { await bootstrapIfNeeded() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)

                            Button {
                                auth.logout()
                            } label: {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.trailing, 36)
                        .padding(.top, 24)
                        Spacer()
                    }
                }
            }
        }
        .task {
            await bootstrapIfNeeded()
        }
        .fullScreenCover(item: $playbackTarget) { target in
            FNOSPlayerContainerView(item: target.item, client: target.client, userID: target.userID)
        }
        .sheet(item: $seriesItem) { series in
            FNOSSeasonsSheet(
                series: series,
                client: client,
                userID: userID,
                onPlay: { episode in
                    openPlayback(item: episode)
                }
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Hero Banner 数据：只抓电影（排除剧集），按当天抽选结果展示

    private var heroItems: [FNOSItem] {
        let movies = sections
            .flatMap(\.items)
            .filter { item in
                guard item.type == "Movie", let tags = item.ImageTags else { return false }
                return !tags.isEmpty
            }
        guard !movies.isEmpty else { return [] }

        // 按当日抽选的 id 顺序取
        let ids = heroIDs.split(separator: ",").map(String.init)
        var picked: [FNOSItem] = []
        for id in ids {
            if let movie = movies.first(where: { $0.Id == id }) {
                picked.append(movie)
            }
        }
        // 库变化导致抽选结果大部分失效时兜底重抽（不写回，避免频繁变更）
        if picked.count >= min(3, movies.count) {
            return Array(picked.prefix(6))
        }
        return Array(movies.shuffled().prefix(6))
    }

    /// 每天首次进入时重新随机抽 6 部电影
    @MainActor
    private func rollHeroIfNeeded() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        guard heroDate != today else { return }
        heroDate = today

        let movies = sections
            .flatMap(\.items)
            .filter { item in
                guard item.type == "Movie", let tags = item.ImageTags else { return false }
                return !tags.isEmpty
            }
        guard !movies.isEmpty else { return }
        heroIDs = movies.shuffled().prefix(6).map(\.Id).joined(separator: ",")
        print("FNOSℹ️Hero 今日抽选: \(heroIDs)")
    }

    // MARK: - 海报墙（每行一个媒体库，横向滚动）

    private func shelf(_ section: FNOSLibrarySection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(section.library.Name ?? "未命名")
                .font(.title2.bold())
                .padding(.horizontal, 72)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(section.items) { item in
                        Button {
                            open(item: item)
                        } label: {
                            FNOSItemCard(item: item, client: client)
                                .frame(width: cardWidth)
                        }
                        #if os(tvOS)
                            .buttonStyle(.card)
                        #else
                            .buttonStyle(.plain)
                        #endif
                    }
                }
                .padding(.horizontal, 72)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - 导航

    private func open(item: FNOSItem) {
        if item.type == "Series" {
            seriesItem = item
        } else {
            openPlayback(item: item)
        }
    }

    private func openPlayback(item: FNOSItem) {
        guard let client else {
            print("FNOS❗️客户端未初始化，无法播放")
            return
        }
        playbackTarget = FNOSPlaybackTarget(item: item, client: client, userID: userID)
    }

    // MARK: - 数据加载（沿用已跑通的网络层，全 do-catch）

    @MainActor
    private func bootstrapIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await bootstrap()
    }

    @MainActor
    private func bootstrap() async {
        print("FNOSℹ️启动 v\(FNOSAdapterBuild.version)")

        let baseURL = credentials.serverURL
        let token = credentials.token
        userID = credentials.userID

        let newClient = FNOSDirectClient(baseURL: baseURL, token: token)
        client = newClient

        do {
            let data = try await newClient.get(path: "Users/\(userID)/Views")

            let envelope: FNOSViewsEnvelope
            do {
                envelope = try JSONDecoder().decode(FNOSViewsEnvelope.self, from: data)
            } catch {
                let raw = String(data: data.prefix(400), encoding: .utf8) ?? "(非文本)"
                print("FNOS❗️解析 /Views 失败: \(error) 原文: \(raw)")
                throw FNOSDirectError("解析 /Views 失败: \(error.localizedDescription)")
            }

            let libraries = envelope.Items
            print("FNOSℹ️媒体库 \(libraries.count) 个")

            isLoading = true

            // 每个库一行海报墙；单库失败不拖垮整页（打印真实报错后继续下一库）
            var loaded: [FNOSLibrarySection] = []
            for library in libraries {
                do {
                    let items = try await loadItems(for: library, client: newClient)
                    loaded.append(FNOSLibrarySection(library: library, items: items))
                    print("FNOSℹ️「\(library.Name ?? "?")」\(items.count) 条")
                } catch {
                    print("FNOS❗️加载「\(library.Name ?? "?")」失败: \(error)")
                    loaded.append(FNOSLibrarySection(library: library, items: []))
                }
                sections = loaded
            }

            isLoading = false
            rollHeroIfNeeded()
        } catch {
            isLoading = false
            print("FNOS❗️加载媒体库失败: \(error)")
        }
    }

    private func loadItems(for library: FNOSLibrary, client: FNOSDirectClient) async throws -> [FNOSItem] {
        let data = try await client.get(
            path: "Users/\(userID)/Items",
            query: [
                "ParentId": library.Id,
                "Recursive": "true",
                "Limit": "100",
                "SortBy": "SortName",
                "SortOrder": "Ascending",
                "Fields": "PrimaryImageAspectRatio,ProductionYear,Overview",
            ]
        )

        do {
            let envelope = try JSONDecoder().decode(FNOSItemsEnvelope.self, from: data)
            return envelope.Items
        } catch {
            let raw = String(data: data.prefix(400), encoding: .utf8) ?? "(非文本)"
            print("FNOS❗️解析 /Items 失败: \(error) 原文: \(raw)")
            throw FNOSDirectError("解析 /Items 失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - 海报卡片（2:3，圆角 12，文字恒显）

fileprivate struct FNOSItemCard: View {

    let item: FNOSItem
    let client: FNOSDirectClient?

    var body: some View {
        VStack(spacing: 10) {
            FNOSAsyncImage(
                url: client?.posterURL(
                    itemID: item.Id,
                    tag: item.ImageTags?["Primary"]
                ),
                headers: client?.mediaHeaders ?? [:]
            )
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(item.Name ?? "未命名")
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)

            if let year = item.ProductionYear {
                Text(String(year))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - 剧集选择（Seasons → Episodes，端点均已实测）

fileprivate struct FNOSSeasonsSheet: View {

    let series: FNOSItem
    let client: FNOSDirectClient?
    let userID: String
    let onPlay: (FNOSItem) -> Void

    @Environment(\.dismiss)
    private var dismiss

    @State private var seasons: [FNOSItem] = []
    @State private var selectedSeasonID: String?
    @State private var episodes: [FNOSItem] = []
    @State private var message = "加载中…"

    private let episodeColumns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Text(series.Name ?? "剧集")
                    .font(.title3)
                    .bold()
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .padding(10)
                }
            }

            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(seasons) { season in
                            Button {
                                selectSeason(season)
                            } label: {
                                Text(season.Name ?? "季")
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                            }
                            .background(
                                selectedSeasonID == season.Id
                                    ? Color.accentColor
                                    : Color.white.opacity(0.12)
                            )
                            .cornerRadius(8)
                        }
                    }
                }
            }

            if episodes.isEmpty {
                Text(message)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: episodeColumns, spacing: 20) {
                        ForEach(episodes) { episode in
                            Button {
                                onPlay(episode)
                                dismiss()
                            } label: {
                                FNOSItemCard(item: episode, client: client)
                            }
                            #if os(tvOS)
                                .buttonStyle(.card)
                            #else
                                .buttonStyle(.plain)
                            #endif
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(28)
        .background(Color.black.ignoresSafeArea())
        .task {
            await loadSeasons()
        }
    }

    private func loadSeasons() async {
        guard let client else {
            message = "❗️客户端未初始化"
            print("FNOS❗️loadSeasons: client 为 nil")
            return
        }
        do {
            let data = try await client.get(
                path: "Shows/\(series.Id)/Seasons",
                query: ["UserId": userID]
            )
            let envelope = try Self.decode(FNOSItemsEnvelope.self, from: data, label: "Seasons")
            seasons = envelope.Items
            if let first = seasons.first {
                selectSeason(first)
            } else {
                message = "没有可播放的季"
            }
        } catch {
            print("FNOS❗️加载季失败: \(error)")
            message = "加载失败: \(error.localizedDescription)"
        }
    }

    private func selectSeason(_ season: FNOSItem) {
        selectedSeasonID = season.Id
        episodes = []
        message = "加载中…"
        Task {
            await loadEpisodes(season: season)
        }
    }

    private func loadEpisodes(season: FNOSItem) async {
        guard let client else {
            message = "❗️客户端未初始化"
            print("FNOS❗️loadEpisodes: client 为 nil")
            return
        }
        do {
            let data = try await client.get(
                path: "Shows/\(series.Id)/Episodes",
                query: [
                    "UserId": userID,
                    "SeasonId": season.Id,
                    "Fields": "PrimaryImageAspectRatio",
                ]
            )
            let envelope = try Self.decode(FNOSItemsEnvelope.self, from: data, label: "Episodes")
            episodes = envelope.Items
            message = episodes.isEmpty ? "本季暂无剧集" : ""
        } catch {
            print("FNOS❗️加载剧集失败: \(error)")
            message = "加载失败: \(error.localizedDescription)"
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, label: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? "(非文本)"
            print("FNOS❗️解析 \(label) 失败: \(error) 原文: \(raw)")
            throw FNOSDirectError("解析 \(label) 失败: \(error.localizedDescription)")
        }
    }
}
