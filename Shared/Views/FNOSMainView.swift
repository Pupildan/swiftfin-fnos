//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import SwiftUI

/// 播放目标（把 client/userID 与条目一起带进播放器）
struct FNOSPlaybackTarget: Identifiable {
    let id = UUID()
    let item: FNOSItem
    let client: FNOSDirectClient
    let userID: String
}

/// 飞牛影视（fnOS）Liquid Glass 沉浸式主界面。
///
/// 网络层（FNOSDirectClient）不动：全部数据仍来自已跑通的裸 URLSession 直连。
/// 本层只负责：毛玻璃顶栏、LazyVGrid、tvOS 焦点特效、播放器与弹幕的衔接。
struct FNOSMainView: View {

    @InjectedObject(\.userSessionManager)
    private var userSessionManager: UserSessionManager

    @State private var client: FNOSDirectClient?
    @State private var userID = ""
    @State private var serverDescription = ""

    @State private var libraries: [FNOSLibrary] = []
    @State private var selectedLibraryID: String?
    @State private var items: [FNOSItem] = []

    @State private var logs: [String] = []
    @State private var isLoading = false
    @State private var didBootstrap = false

    @State private var playbackTarget: FNOSPlaybackTarget?
    @State private var seriesItem: FNOSItem?
    @FocusState private var focusedItemID: String?

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 18)]

    // MARK: - Body

    var body: some View {
        ZStack {
            // 聚焦海报的模糊背景（Liquid Glass 氛围光）
            backdrop

            LinearGradient(
                colors: [Color(white: 0.13), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(0.86)
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                topBar
                libraryRow
                contentArea
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

    // MARK: - 聚焦海报模糊背景

    @ViewBuilder
    private var backdrop: some View {
        if let focused = items.first(where: { $0.Id == focusedItemID }) {
            FNOSAsyncImage(
                url: client?.posterURL(
                    itemID: focused.Id,
                    tag: focused.ImageTags?["Primary"],
                    maxWidth: 200
                ),
                headers: client?.mediaHeaders ?? [:]
            )
            .blur(radius: 40)
            .opacity(0.30)
            .scaleEffect(1.15)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.4), value: focusedItemID)
        }
    }

    // MARK: - 毛玻璃顶栏（版本 + 服务器 + 刷新）

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
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
    }

    // MARK: - 媒体库标签

    private var libraryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(libraries) { library in
                    Button {
                        selectedLibraryID = library.Id
                        Task { await loadItems(for: library) }
                    } label: {
                        Text(library.Name ?? "未命名")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .background(
                        selectedLibraryID == library.Id
                            ? Color.accentColor
                            : Color.white.opacity(0.12)
                    )
                    .cornerRadius(10)
                }
            }
        }
    }

    // MARK: - 内容网格

    @ViewBuilder
    private var contentArea: some View {
        if isLoading {
            VStack {
                Spacer()
                ProgressView("加载中…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            VStack(spacing: 12) {
                Text("暂无内容")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Text("如果媒体库已列出但这里为空，请把下方日志拍照反馈")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(items) { item in
                        Button {
                            open(item: item)
                        } label: {
                            FNOSItemCard(item: item, client: client)
                        }
                        .focused($focusedItemID, equals: item.Id)
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

    // MARK: - 底部实时日志

    private var logArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(logs.suffix(4).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.green.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

        guard let session = userSessionManager.currentSession else {
            log("❗️未登录：无当前会话")
            print("FNOS❗️bootstrap: userSessionManager.currentSession 为 nil")
            return
        }

        let baseURL = session.server.effectiveServerURL
        let token = session.user.accessToken
        userID = session.user.id
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

            libraries = envelope.Items
            log("✅ 媒体库 \(libraries.count) 个")

            if let first = libraries.first {
                selectedLibraryID = first.Id
                await loadItems(for: first)
            }
        } catch {
            print("FNOS❗️加载媒体库失败: \(error)")
            log("❗️媒体库加载失败: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func loadItems(for library: FNOSLibrary) async {
        guard let client else {
            log("❗️客户端未初始化")
            print("FNOS❗️loadItems: client 为 nil")
            return
        }

        isLoading = true
        items = []

        do {
            let data = try await client.get(
                path: "Users/\(userID)/Items",
                query: [
                    "ParentId": library.Id,
                    "Recursive": "true",
                    "Limit": "200",
                    "SortBy": "SortName",
                    "SortOrder": "Ascending",
                    "Fields": "PrimaryImageAspectRatio,ProductionYear,Overview",
                ]
            )

            let envelope: FNOSItemsEnvelope
            do {
                envelope = try JSONDecoder().decode(FNOSItemsEnvelope.self, from: data)
            } catch {
                let raw = String(data: data.prefix(400), encoding: .utf8) ?? "(非文本)"
                print("FNOS❗️解析 /Items 失败: \(error) 原文: \(raw)")
                throw FNOSDirectError("解析 /Items 失败: \(error.localizedDescription)")
            }

            items = envelope.Items
            log("✅ 「\(library.Name ?? "?")」\(items.count) 条")
        } catch {
            print("FNOS❗️加载内容失败: \(error)")
            log("❗️内容加载失败: \(error.localizedDescription)")
        }

        isLoading = false
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

// MARK: - 内容卡片（2:3 海报，圆角 12，文字恒显）

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
