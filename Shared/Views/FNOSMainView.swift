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
/// - Hero Banner 真·全屏铺满（含安全区），左上角设置入口（刷新/退出集成在面板里）；
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
    // 影视详情页（1:1 复刻 ATV+）
    @State private var detailItem: FNOSItem?

    // 首页设置面板（刷新/退出集成在内）
    @State private var showSettings = false
    // 媒体库卡片焦点（下键从 Hero 跳入海报墙的落点）
    @FocusState private var shelfCardFocused: String?

    // Hero 每日随机抽选（每天首次进入重新抽 6 部电影）
    @AppStorage("fnos.hero.date") private var heroDate = ""
    @AppStorage("fnos.hero.ids") private var heroIDs = ""
    // Hero 快照：只在 bootstrap / 刷新时赋值一次，绝不在 body 渲染中重新洗牌（洗牌会图文错位）
    @State private var heroSnapshot: [FNOSItem] = []

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
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 0) {
                                // Apple TV+ 式全屏 Hero Banner（当日抽选的 6 部电影快照）
                                if !heroSnapshot.isEmpty, let heroClient = client {
                                    FNOSHeroBanner(
                                        items: heroSnapshot,
                                        client: heroClient,
                                        userID: userID,
                                        onPlay: { item in
                                            open(item: item)
                                        },
                                        onDetail: { item in
                                            open(item: item)
                                        },
                                        onDownToShelf: {
                                            // 下键从 Hero 跳入海报墙：先滚动让媒体库行出现，再把焦点落到第一张卡
                                            withAnimation(.easeInOut(duration: 0.4)) {
                                                proxy.scrollTo("fnos-shelf-top", anchor: .top)
                                            }
                                            Task { @MainActor in
                                                try? await Task.sleep(for: .milliseconds(450))
                                                if let lead = sections.first(where: { !$0.items.isEmpty })?.items.first?.Id {
                                                    shelfCardFocused = lead
                                                }
                                            }
                                        }
                                    )
                                    .frame(width: geo.size.width, height: geo.size.height)
                                }

                                // 媒体库横向海报墙（非懒容器：保证屏外行存在，焦点引擎才有落点）
                                VStack(alignment: .leading, spacing: 44) {
                                    ForEach(sections) { section in
                                        shelf(section, screenWidth: geo.size.width)
                                    }
                                }
                                .padding(.vertical, 40)
                                .id("fnos-shelf-top")
                                #if os(tvOS)
                                    .focusSection()
                                #endif
                            }
                        }
                        .ignoresSafeArea()
                    }

                    // 左上角设置按钮（刷新/退出集成在设置面板里）
                    VStack {
                        HStack {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white.opacity(0.7))
                                    .padding(10)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        .padding(.leading, 36)
                        .padding(.top, 20)
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
        .fullScreenCover(item: $detailItem) { item in
            FNOSItemDetailView(
                item: item,
                client: client,
                onPlay: {
                    detailItem = nil
                    if item.type == "Series" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            seriesItem = item
                        }
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            openPlayback(item: item)
                        }
                    }
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            FNOSHomeSettingsView(
                onRefresh: {
                    // 清掉当日抽选标记 → 刷新后 Hero 强制重新随机抽选
                    heroDate = ""
                    // 清全部图片缓存（内存图 + URL 缓存），排除缓存导致的错图
                    FNOSImageCache.shared.memory.removeAllObjects()
                    URLCache.shared.removeAllCachedResponses()
                    // 关键：旧 sections / heroSnapshot 必须清空。
                    // 否则新库数据回来前，Hero 仍按旧快照渲染，新数据到达后
                    // 索引与页面错位 → 标题与海报不是同一部（图文错位）。
                    sections = []
                    heroSnapshot = []
                    // 立即进入加载态：避免清空数据到新数据回来之间闪一下「暂无内容」
                    isLoading = true
                    didBootstrap = false
                    Task { await bootstrapIfNeeded() }
                },
                onLogout: {
                    auth.logout()
                }
            )
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

    // MARK: - Hero Banner 数据：只抓电影（排除剧集），快照只在加载/刷新时生成一次

    /// 按当日抽选的 id 生成 Hero 快照；取不满时兜底随机（只在此函数内洗牌，body 渲染绝不重抽）
    @MainActor
    private func refreshHeroSnapshot() {
        let movies = sections
            .flatMap(\.items)
            .filter { item in
                guard item.type == "Movie", let tags = item.ImageTags else { return false }
                return !tags.isEmpty
            }
        // 关键去重：同一部电影可能出现在多个库视图里，重复 Id 会破坏 ForEach 恒等 → 图文错位
        var seen = Set<String>()
        let uniqueMovies = movies.filter { seen.insert($0.Id).inserted }
        guard !uniqueMovies.isEmpty else {
            heroSnapshot = []
            return
        }

        let ids = heroIDs.split(separator: ",").map(String.init)
        var picked: [FNOSItem] = []
        var pickedSeen = Set<String>()
        for id in ids {
            if let movie = uniqueMovies.first(where: { $0.Id == id }), pickedSeen.insert(id).inserted {
                picked.append(movie)
            }
        }
        // 库变化导致抽选结果大部分失效时兜底重抽（只发生在快照刷新时，不影响渲染稳定性）
        if picked.count >= min(3, uniqueMovies.count) {
            heroSnapshot = Array(picked.prefix(6))
        } else {
            heroSnapshot = Array(uniqueMovies.shuffled().prefix(6))
        }
        let summary = heroSnapshot.map { item -> String in
            let tags = item.ImageTags ?? [:]
            let img = tags["Backdrop"] != nil ? "Backdrop" : "Primary"
            return "\(item.Name ?? "?")[\(img)]"
        }
        print("FNOSℹ️Hero 快照(\(heroSnapshot.count)): \(summary.joined(separator: " | "))")
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
        // 同样去重：抽选池不能有重复 Id
        var seen = Set<String>()
        let uniqueMovies = movies.filter { seen.insert($0.Id).inserted }
        guard !uniqueMovies.isEmpty else { return }
        heroIDs = uniqueMovies.shuffled().prefix(6).map(\.Id).joined(separator: ",")
        print("FNOSℹ️Hero 今日抽选: \(heroIDs)")
    }

    // MARK: - 海报墙（每行一个媒体库，横向滚动）

    private func shelf(_ section: FNOSLibrarySection, screenWidth: CGFloat) -> some View {
        // ATV+ 版式：左右 72 边距，一屏正好 6 张，间距与上下留白接近（28）
        let hPadding: CGFloat = 72
        let spacing: CGFloat = 28
        let visibleCount: CGFloat = 6
        let tileWidth = max(
            140,
            (screenWidth - hPadding * 2 - spacing * (visibleCount - 1)) / visibleCount
        )

        return VStack(alignment: .leading, spacing: 14) {
            Text(section.library.Name ?? "未命名")
                .font(.title2.bold())
                .padding(.horizontal, hPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(section.items) { item in
                        let isFocused = shelfCardFocused == item.Id
                        Button {
                            open(item: item)
                        } label: {
                            FNOSPosterTile(
                                item: item,
                                client: client,
                                width: tileWidth,
                                isFocused: isFocused
                            )
                        }
                        // 自定义 ButtonStyle：彻底去掉系统焦点板（ScrollView 内的 Button
                        // 对 focusEffectDisabled 不生效，这是 tvOS 已知行为）
                        .buttonStyle(FNOSBareButtonStyle())
                        // 每张卡注册独立焦点值（条目 Id 唯一，避免 Bool 歧义），供下键直达
                        .focused($shelfCardFocused, equals: item.Id)
                    }
                }
                .padding(.horizontal, hPadding)
                // 给聚焦放大（1.06）与阴影留出空间，避免被 ScrollView 裁掉
                .padding(.vertical, 26)
                // 双保险：把焦点特效关闭挂到内容容器上
                .focusEffectDisabled()
            }
            .focusEffectDisabled()
        }
        .focusEffectDisabled()
    }

    // MARK: - 导航

    private func open(item: FNOSItem) {
        // 统一进入详情页，详情页里的播放按钮再决定是直播还是选集
        detailItem = item
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
        // 从零重建：清空 Hero 快照，避免刷新过程中新旧条目混排
        heroSnapshot = []

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
            // Hero 快照只在此处（bootstrap / 下拉刷新）生成一次
            refreshHeroSnapshot()
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
                "Fields": "PrimaryImageAspectRatio,ProductionYear,Overview,BackdropImageTags,RunTimeTicks,OfficialRating,Genres",
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

// MARK: - 首页设置面板（刷新媒体库 / 退出登录 / 版本信息）

struct FNOSHomeSettingsView: View {

    let onRefresh: () -> Void
    let onLogout: () -> Void

    @Environment(\.dismiss) private var dismiss

    // Hero 图源：backdrop（横图，默认）/ primary（海报）
    // 若发现某些电影 Hero 图文对不上，多为飞牛刮削把 Backdrop 挂错条目，切到海报可规避。
    @AppStorage("fnos.hero.imageSource") private var heroImageSource = "backdrop"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        dismiss()
                        onRefresh()
                    } label: {
                        Label("刷新媒体库", systemImage: "arrow.clockwise")
                    }

                    Button(role: .destructive) {
                        dismiss()
                        onLogout()
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } header: {
                    Text("操作")
                }

                Section {
                    Button {
                        heroImageSource = "backdrop"
                    } label: {
                        Label(
                            "Hero 横版大图（推荐）",
                            systemImage: heroImageSource == "backdrop" ? "checkmark.circle.fill" : "circle"
                        )
                    }

                    Button {
                        heroImageSource = "primary"
                    } label: {
                        Label(
                            "Hero 竖版海报（图文对不上时切换）",
                            systemImage: heroImageSource == "primary" ? "checkmark.circle.fill" : "circle"
                        )
                    }
                } header: {
                    Text("Hero 图源")
                } footer: {
                    Text("若 Hero 标题与画面不一致，通常是飞牛刮削的横图挂错了电影，切换到竖版海报即可规避。")
                }

                Section {
                    LabeledContent("适配版本", value: FNOSAdapterBuild.version)
                    Text(FNOSAdapterBuild.changes)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("关于")
                }
            }
            .navigationTitle("设置")
        }
    }
}

// MARK: - 无焦点视觉按钮样式（彻底屏蔽 tvOS 系统焦点板）

/// tvOS 的 .plain / .borderless 在 ScrollView 内仍会画系统焦点板（白圆角框）。
/// 用空 ButtonStyle 让系统拿不到任何可绘制的 focus 外观。
struct FNOSBareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 媒体库海报瓦片（ATV+ 风格：无文字、圆角矩形、焦点放大 + 液态玻璃高光）

/// 纯海报瓦片：不显示标题/年份，聚焦时轻微放大 + 自绘玻璃描边。
///
/// 注意：这里刻意不用系统 glassEffect / Material ——
/// tvOS 焦点引擎检测到材质会在聚焦视图上叠系统高亮板（HANDOVER 红线 5）。
/// 玻璃感全部由「渐变描边 + 顶部高光 + 阴影」自绘实现。
fileprivate struct FNOSPosterTile: View {

    let item: FNOSItem
    let client: FNOSDirectClient?
    let width: CGFloat
    let isFocused: Bool

    private var height: CGFloat { width * 3 / 2 }
    private var cornerRadius: CGFloat { 14 }

    var body: some View {
        FNOSAsyncImage(
            url: client?.posterURL(
                itemID: item.Id,
                tag: item.ImageTags?["Primary"]
            ),
            headers: client?.mediaHeaders ?? [:]
        )
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(isFocused ? 0.55 : 0), radius: isFocused ? 22 : 0, y: 10)
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

// MARK: - 海报卡片（2:3，圆角 12，文字恒显）—— 剧集选集用

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
