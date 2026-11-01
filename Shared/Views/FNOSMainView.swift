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

/// 飞牛影视（fnOS）主界面 —— Apple TV+ 式横向海报墙布局。
///
/// 性能要点（tvOS 焦点引擎最顺滑的组合）：
/// - 纵向 LazyVStack 分行（每行一个媒体库），横向 ScrollView(.horizontal) + LazyHStack 海报墙；
/// - 无任何 .blur / matchedGeometryEffect（大面积高斯模糊在 tvOS 必掉帧，已按用户要求彻底移除）；
/// - 焦点表现全部交给原生 .buttonStyle(.card)。
struct FNOSMainView: View {

    @ObservedObject var auth: FNOSAuthStore
    let credentials: FNOSCredentials

    @State private var client: FNOSDirectClient?
    @State private var userID = ""
    @State private var serverDescription = ""

    @State private var sections: [FNOSLibrarySection] = []
    @State private var logs: [String] = []
    @State private var isLoading = false
    @State private var didBootstrap = false

    @State private var playbackTarget: FNOSPlaybackTarget?
    @State private var seriesItem: FNOSItem?

    private let cardWidth: CGFloat = 240

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                shelves
                logArea
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
    }

    // MARK: - 毛玻璃顶栏（导航）

    private var topBar: some View {
        HStack(spacing: 16) {
            Text("FNOS v\(FNOSAdapterBuild.version)")
                .font(.title3)
                .bold()
            Text(serverDescription)
                .font(.footnote)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                didBootstrap = false
                Task { await bootstrapIfNeeded() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            Button {
                auth.logout()
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    // MARK: - 海报墙（每行一个媒体库，横向滚动）

    @ViewBuilder
    private var shelves: some View {
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
                Text("请把下方日志拍照反馈")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 36) {
                    ForEach(sections) { section in
                        shelf(section)
                    }
                }
                .padding(.vertical, 24)
            }
        }
    }

    private func shelf(_ section: FNOSLibrarySection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(section.library.Name ?? "未命名")
                    .font(.title3)
                    .bold()
                Text("\(section.items.count)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 48)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
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
                .padding(.horizontal, 48)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - 底部实时日志

    private var logArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(logs.suffix(3).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.green.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 48)
        .padding(.vertical, 6)
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
            log("❗️客户端未初始化")
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
        log("启动 FNOS v\(FNOSAdapterBuild.version)")

        let baseURL = credentials.serverURL
        let token = credentials.token
        userID = credentials.userID
        serverDescription = baseURL.absoluteString

        log("服务器 \(serverDescription) · 令牌 \(token.count) 字符")

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
            log("✅ 媒体库 \(libraries.count) 个")

            isLoading = true

            // 每个库一行海报墙；单库失败不拖垮整页（打印真实报错后继续下一库）
            var loaded: [FNOSLibrarySection] = []
            for library in libraries {
                do {
                    let items = try await loadItems(for: library, client: newClient)
                    loaded.append(FNOSLibrarySection(library: library, items: items))
                    log("✅ 「\(library.Name ?? "?")」\(items.count) 条")
                } catch {
                    print("FNOS❗️加载「\(library.Name ?? "?")」失败: \(error)")
                    log("❗️「\(library.Name ?? "?")」加载失败: \(error.localizedDescription)")
                    loaded.append(FNOSLibrarySection(library: library, items: []))
                }
                sections = loaded
            }

            isLoading = false
        } catch {
            isLoading = false
            print("FNOS❗️加载媒体库失败: \(error)")
            log("❗️媒体库加载失败: \(error.localizedDescription)")
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

    @MainActor
    private func log(_ line: String) {
        print("FNOSℹ️ \(line)")
        logs.append(line)
        if logs.count > 40 {
            logs.removeFirst(logs.count - 40)
        }
    }
}

// MARK: - 海报卡片（2:3，圆角 12，文字恒显）

fileprivate struct FNOSItemCard: View {

    let item: FNOSItem
    let client: FNOSDirectClient?

    var body: some View {
        VStack(spacing: 8) {
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
