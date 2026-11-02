//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

/// 影视详情页 —— 1:1 复刻 Apple TV+ 详情页版式。
struct FNOSItemDetailView: View {

    let item: FNOSItem
    let client: FNOSDirectClient?
    let userID: String
    /// 剧集：交给外层弹选集面板
    let onEpisodes: (FNOSItem) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 播放器在本页内打开（不先关详情页），避免 fullScreenCover 竞态导致请求被取消
    @State private var playbackTarget: FNOSPlaybackTarget?

    /// 详情页背景图轮播索引
    @State private var backdropIndex = 0

    // 详情数据（媒体源、时长、演员）
    @State private var mediaSourceID: String?
    @State private var runtimeTicks: Int64?
    @State private var people: [FNOSDirectClient.FNOSPerson] = []
    @State private var loadError: String?
    // 从海报提取的主色（动态液态玻璃背景）
    @State private var themeColor: Color?
    @State private var fetchedBackdropTags: [String]?

    // 剧集选集状态（季优先，无季数据时按 10 集分段）
    @State private var episodes: [FNOSItem] = []
    @State private var seasons: [FNOSItem] = []
    @State private var episodesBySeason: [String: [FNOSItem]] = [:]
    @State private var selectedTabIndex = 0
    @FocusState private var focusedTab: String?
    @FocusState private var focusedEpisode: String?
    /// 临时诊断行（确认服务端字段/分集端点真实返回）
    @State private var debugLines: [String] = []

    // 三个按钮的焦点
    private enum DetailButton { case play, plus, info }
    @FocusState private var focusedButton: DetailButton?

    /// 全部可用背景图（多张 Backdrop 用于轮播；没有横图时退化为竖版海报）
    private var backdropURLs: [URL] {
        guard let client else { return [] }
        var urls: [URL] = []

        // 优先使用详情接口返回的最新 tags，如果为空再退回列表传进来的 item
        let tags = fetchedBackdropTags ?? item.BackdropImageTags

        if let tags, !tags.isEmpty {
            for (index, tag) in tags.enumerated() where !tag.isEmpty {
                // 飞牛只支持不带 index 后缀的 Backdrop 接口
                let path = index == 0
                    ? "Items/\(item.Id)/Images/Backdrop"
                    : "Items/\(item.Id)/Images/Backdrop/\(index)"
                if let url = try? client.url(
                    path: path,
                    query: ["maxWidth": "1920", "quality": "90", "tag": tag]
                ) {
                    urls.append(url)
                }
            }
        }

        if urls.isEmpty, let primary = item.ImageTags?["Primary"], !primary.isEmpty {
            if let url = try? client.url(
                path: "Items/\(item.Id)/Images/Primary",
                query: ["maxWidth": "1920", "quality": "90", "tag": primary]
            ) {
                urls.append(url)
            }
        }

        return urls
    }

    /// 当前展示的背景图
    private var backdropURL: URL? {
        guard !backdropURLs.isEmpty else { return nil }
        return backdropURLs[min(backdropIndex, backdropURLs.count - 1)]
    }

    /// 每 2 秒切换到下一张剧照（只有 1 张时不动）
    @MainActor
    private func rotateBackdrops() async {
        let count = backdropURLs.count
        guard count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.7)) {
                backdropIndex = (backdropIndex + 1) % count
            }
        }
    }

    /// 时长文案：优先 PlaybackInfo 的 RunTimeTicks（Jellyfin 单位 100ns）
    private var durationString: String? {
        guard let ticks = runtimeTicks ?? item.RunTimeTicks, ticks > 0 else { return nil }
        let seconds = ticks / 10_000_000
        guard seconds > 0 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(hours) 小时"
        }
        return "\(minutes) 分钟"
    }

    private var genreLine: String {
        var parts: [String] = [Self.categoryName(item)]
        if let genres = item.Genres, !genres.isEmpty {
            parts.append(genres.prefix(2).joined(separator: " · "))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 动态液态玻璃背景：从海报自动取色，向下逐渐过渡到纯黑
                ZStack {
                    Color.black
                    if let themeColor {
                        RadialGradient(
                            colors: [themeColor.opacity(0.55), themeColor.opacity(0.18), .clear],
                            center: .top,
                            startRadius: 0,
                            endRadius: geo.size.height * 1.1
                        )
                    }
                }
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: themeColor)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            heroSection(size: geo.size, proxy: proxy)

                            if item.type == "Series" && !episodeTabs.isEmpty {
                                episodeSection
                                    .padding(.top, 36)
                                    .padding(.bottom, 12)
                            }

                            infoSection
                                .padding(.horizontal, 60)
                                .padding(.top, item.type == "Series" ? 24 : 10)
                                .padding(.bottom, 40)
                                .id("detail-info")

                            debugSection
                        }
                    }
                    .ignoresSafeArea()
                }

                // 右上角关闭
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 52, height: 52)
                                .background(Circle().fill(Color.black.opacity(0.45)))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 44)
                        .padding(.top, 40)
                    }
                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .task {
            await loadDetail()
        }
        .task(id: item.Id) {
            await rotateBackdrops()
        }
        .fullScreenCover(item: $playbackTarget) { target in
            FNOSPlayerContainerView(
                item: target.item,
                client: target.client,
                userID: target.userID
            )
        }
    }

    // MARK: - 顶部全屏 Hero

    private func heroSection(size: CGSize, proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .bottomLeading) {
            FNOSAsyncImage(
                url: backdropURL,
                headers: client?.mediaHeaders ?? [:],
                contentMode: .fill
            )
            .frame(width: size.width, height: size.height)
            .clipped()
            .animation(.easeInOut(duration: 0.7), value: backdropIndex)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.92), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.42),
                    .init(color: .clear, location: 0.92),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.85), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 20) {
                Text("飞牛影视 · 精选")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.16)))

                Text(item.Name ?? "未命名")
                    .font(.system(size: 62, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 10) {
                    Image(systemName: "appletv.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                    Text(genreLine)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    if let rating = item.OfficialRating, !rating.isEmpty {
                        Text(rating)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.yellow))
                    }
                }

                if let overview = item.Overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 19))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 760, alignment: .leading)
                }

                HStack(spacing: 12) {
                    if let duration = durationString {
                        Text(duration)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    if let year = item.ProductionYear {
                        Text(String(year))
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    Text("4K")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.white.opacity(0.6))
                        )
                }

                if let loadError {
                    Text(loadError)
                        .font(.system(size: 15))
                        .foregroundColor(.red.opacity(0.9))
                }

                HStack(spacing: 28) {
                    // 立即播放（白色主按钮）
                    detailButton(.play, isPrimary: true) {
                        playNow()
                    } label: {
                        Text(item.type == "Series" ? "播放第 1 集" : "立即播放")
                            .font(.system(size: 21, weight: .semibold))
                    }
                    .onMoveCommand { direction in
                        if direction == .down {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo("detail-info", anchor: .top)
                            }
                        }
                    }

                    // 稍后观看
                    detailButton(.plus, isPrimary: false) {
                        toggleWatchLater()
                    } label: {
                        Image(systemName: isWatchLater ? "checkmark" : "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 54, height: 54)
                    }
                    .onMoveCommand { direction in
                        if direction == .down {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo("detail-info", anchor: .top)
                            }
                        }
                    }

                    // 信息
                    detailButton(.info, isPrimary: false) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo("detail-info", anchor: .top)
                        }
                    } label: {
                        Image(systemName: "info")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 54, height: 54)
                    }
                    .onMoveCommand { direction in
                        if direction == .down {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo("detail-info", anchor: .top)
                            }
                        }
                    }
                }
                .padding(.top, 10)
                .defaultFocus($focusedButton, .play)
            }
            .padding(.leading, 60)
            .padding(.bottom, 130)
            .padding(.top, size.height * 0.40)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - 详情页按钮（未选中：半透明液态玻璃；选中：纯白背景 + 黑字）

    @ViewBuilder
    private func detailButton<Label: View>(
        _ id: DetailButton,
        isPrimary: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let isFocused = focusedButton == id
        Button(action: action) {
            FNOSFocusButtonLabel(isFocused: isFocused, isPrimary: isPrimary) {
                label()
            }
        }
        .buttonStyle(FNOSBareButtonStyle())
        .focused($focusedButton, equals: id)
        .focusEffectDisabled()
    }

    // MARK: - 剧集选集区域（ATV+ 版式：季标签 + 横图卡片 + 简介/日期/分级）

    struct EpisodeTab: Identifiable {
        let id: String
        let title: String
        let episodes: [FNOSItem]
    }

    /// 有季数据 → 每季一个标签；否则把全部剧集按 10 集分段
    private var episodeTabs: [EpisodeTab] {
        if seasons.count > 1 {
            return seasons.map { season in
                EpisodeTab(
                    id: season.Id,
                    title: season.Name ?? "第 \(season.IndexNumber ?? 0) 季",
                    episodes: episodesBySeason[season.Id] ?? []
                )
            }
        }
        guard !episodes.isEmpty else { return [] }
        return stride(from: 0, to: episodes.count, by: 10).map { start in
            let slice = Array(episodes[start..<min(start + 10, episodes.count)])
            let first = slice.first?.IndexNumber ?? (start + 1)
            let last = slice.last?.IndexNumber ?? (start + slice.count)
            return EpisodeTab(
                id: "chunk-\(start)",
                title: first == last ? "第 \(first) 集" : "第 \(first)-\(last) 集",
                episodes: slice
            )
        }
    }

    private var currentTabEpisodes: [FNOSItem] {
        let tabs = episodeTabs
        guard tabs.indices.contains(selectedTabIndex) else { return [] }
        return tabs[selectedTabIndex].episodes
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            // 季 / 分段标签
            if episodeTabs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 28) {
                        ForEach(Array(episodeTabs.enumerated()), id: \.element.id) { index, tab in
                            let isSelected = selectedTabIndex == index
                            let isFocused = focusedTab == tab.id
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    selectedTabIndex = index
                                }
                            } label: {
                                Text(tab.title)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(
                                        isFocused ? .black : (isSelected ? .white : .white.opacity(0.55))
                                    )
                                    .padding(.horizontal, 22)
                                    .padding(.vertical, 9)
                                    .background(
                                        Capsule().fill(
                                            isFocused
                                                ? Color.white
                                                : (isSelected ? Color.white.opacity(0.22) : Color.clear)
                                        )
                                    )
                            }
                            .buttonStyle(FNOSBareButtonStyle())
                            .focusEffectDisabled()
                            .focused($focusedTab, equals: tab.id)
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 10)
                }
            }

            // 集数卡片横排
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 24) {
                    ForEach(currentTabEpisodes) { ep in
                        let isFocused = focusedEpisode == ep.Id
                        Button {
                            playEpisode(ep)
                        } label: {
                            episodeCard(ep: ep, isFocused: isFocused)
                        }
                        .buttonStyle(FNOSBareButtonStyle())
                        .focusEffectDisabled()
                        .focused($focusedEpisode, equals: ep.Id)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 18)
            }
        }
    }

    private func episodeCard(ep: FNOSItem, isFocused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 16:9 剧照 + 左下角时长角标
            ZStack(alignment: .bottomLeading) {
                FNOSAsyncImage(
                    url: client?.episodeStillURL(item: ep, maxWidth: 640),
                    headers: client?.mediaHeaders ?? [:],
                    contentMode: .fill
                )
                .frame(width: 420, height: 236)
                .clipped()

                if let duration = ep.compactDuration {
                    Text(duration)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(.leading, 14)
                        .padding(.bottom, 12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // 文本区：集号 / 标题 / 简介 / 日期 + 分级
            VStack(alignment: .leading, spacing: 9) {
                Text("第 \(ep.IndexNumber ?? 0) 集")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.5))

                Text(ep.Name ?? "未命名")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(ep.Overview?.isEmpty == false ? (ep.Overview ?? "") : " ")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)

                HStack(spacing: 8) {
                    if let dateText = ep.premiereDateText {
                        Text(dateText)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    if let rating = ep.OfficialRating, !rating.isEmpty {
                        Text(rating)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.yellow))
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(width: 420, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.14) : Color.clear)
            )
        }
        .frame(width: 420)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }

    // MARK: - 临时诊断（确认服务端字段与分集端点真实返回后删除）

    @ViewBuilder
    private var debugSection: some View {
        if !debugLines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(debugLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.yellow.opacity(0.7))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 下方信息区块

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 40) {
            // 演员阵容
            if !people.isEmpty {
                castSection
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("信息")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)

                infoCard(
                    rows: [
                        ("发行时间", item.ProductionYear.map(String.init) ?? "—"),
                        ("片长", durationString ?? "—"),
                        ("分级", item.OfficialRating ?? "—"),
                        ("类型", (item.Genres ?? []).isEmpty
                            ? Self.categoryName(item)
                            : (item.Genres ?? []).joined(separator: "、")),
                    ]
                )
            }
        }
    }

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("演员阵容")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                        VStack(spacing: 8) {
                            FNOSAsyncImage(
                                url: person.id.flatMap { id in
                                    client?.personImageURL(personID: id, tag: person.imageTag)
                                },
                                headers: client?.mediaHeaders ?? [:],
                                contentMode: .fill
                            )
                            .frame(width: 124, height: 124)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))

                            Text(person.name)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Text(person.role ?? " ")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        .frame(width: 150)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func infoCard(rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.0)
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.5))
                    Text(row.1)
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.92))
                }
            }
        }
        .padding(28)
        .frame(width: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.09))
        )
    }

    // MARK: - 数据与动作

    @MainActor
    private func loadDetail() async {
        guard let client else { return }

        // 1) 详情接口：失败不阻断选集与背景图
        do {
            let detail = try await client.fetchItemDetail(itemID: item.Id, userID: userID)
            mediaSourceID = detail.mediaSourceID
            runtimeTicks = detail.runTimeTicks
            people = detail.people
            if let tags = detail.backdropTags, !tags.isEmpty {
                fetchedBackdropTags = tags
            }
            debugLines.append("详情: 演员\(detail.people.count) 源\(detail.mediaSourceID == nil ? "无" : "有") 字段[\(detail.rawKeys.joined(separator: ","))]")
            print("FNOSℹ️详情 \(item.Name ?? "?") 时长ticks=\(runtimeTicks ?? -1) 源=\(mediaSourceID ?? "nil") 演员=\(people.count) 字段=\(detail.rawKeys)")
        } catch {
            debugLines.append("详情失败: \(error.localizedDescription)")
            print("FNOS⚠️ 详情接口失败（继续展示页面）: \(error.localizedDescription)")
            if item.type != "Series" {
                loadError = "获取播放信息失败：\(error.localizedDescription)"
            }
        }

        // 2) 剧集：无论详情接口成败都要拉分集（选集是剧集详情页的核心）
        if item.type == "Series" {
            await loadEpisodes(client: client)
        }

        // 3) 主题色
        if let url = backdropURL {
            themeColor = await FNOSDominantColor.color(for: url, headers: client.mediaHeaders)
        }
    }

    /// 拉取分集：季列表 → 逐季取集（复用旧季面板验证过的 UserId/SeasonId 调用），
    /// 失败再走两级兜底。任何失败只打日志，绝不影响详情页主体。
    @MainActor
    private func loadEpisodes(client: FNOSDirectClient) async {
        debugLines.removeAll(where: { $0.hasPrefix("季") || $0.hasPrefix("分集") })

        // 端点 A：季列表（关键：必须带 UserId，这是旧季面板实测可用的调用）
        do {
            let data = try await client.get(
                path: "Shows/\(item.Id)/Seasons",
                query: ["UserId": userID]
            )
            seasons = try JSONDecoder().decode(FNOSItemsEnvelope.self, from: data).Items
            debugLines.append("季列表: \(seasons.count) 季")
            print("FNOSℹ️季列表 \(seasons.count) 季")
        } catch {
            seasons = []
            debugLines.append("季列表失败: \(error.localizedDescription)")
            print("FNOS⚠️ 季列表失败: \(error.localizedDescription)")
        }

        // 端点 A2：逐季取集（UserId + SeasonId）
        for season in seasons {
            do {
                let data = try await client.get(
                    path: "Shows/\(item.Id)/Episodes",
                    query: [
                        "UserId": userID,
                        "SeasonId": season.Id,
                        "Fields": "Overview,RunTimeTicks,OfficialRating,ParentIndexNumber,IndexNumber,PremiereDate",
                    ]
                )
                let list = try JSONDecoder().decode(FNOSItemsEnvelope.self, from: data).Items
                episodesBySeason[season.Id] = list
                print("FNOSℹ️季「\(season.Name ?? season.Id)」\(list.count) 集")
            } catch {
                debugLines.append("季「\(season.Name ?? "?")」取集失败: \(error.localizedDescription)")
                print("FNOS⚠️ 季取集失败: \(error.localizedDescription)")
            }
        }

        var all: [FNOSItem] = []
        if !seasons.isEmpty {
            for season in seasons {
                all.append(contentsOf: episodesBySeason[season.Id] ?? [])
            }
        }

        // 端点 B：全部剧集（仍带 UserId）
        if all.isEmpty {
            do {
                let data = try await client.get(
                    path: "Shows/\(item.Id)/Episodes",
                    query: [
                        "UserId": userID,
                        "Fields": "Overview,RunTimeTicks,OfficialRating,ParentIndexNumber,IndexNumber,PremiereDate",
                    ]
                )
                all = try JSONDecoder().decode(FNOSItemsEnvelope.self, from: data).Items
                debugLines.append("全剧集(带UserId): \(all.count) 集")
                print("FNOSℹ️全剧集 \(all.count) 集")
            } catch {
                debugLines.append("全剧集失败: \(error.localizedDescription)")
                print("FNOS⚠️ 全剧集失败: \(error.localizedDescription)")
            }
        }

        // 端点 C：通用条目查询兜底
        if all.isEmpty {
            do {
                let data = try await client.get(
                    path: "Users/\(userID)/Items",
                    query: [
                        "ParentId": item.Id,
                        "Recursive": "true",
                        "Limit": "500",
                        "SortBy": "ParentIndexNumber,IndexNumber",
                        "SortOrder": "Ascending",
                        "Fields": "Overview,RunTimeTicks,OfficialRating,ParentIndexNumber,IndexNumber,PremiereDate",
                    ]
                )
                let items = try JSONDecoder().decode(FNOSItemsEnvelope.self, from: data).Items
                all = items.filter { $0.type == "Episode" || $0.IndexNumber != nil }
                debugLines.append("Items兜底: 共\(items.count) 条 取\(all.count) 集 类型[\(Set(items.compactMap(\.type)).sorted().joined(separator: ","))]")
                print("FNOSℹ️Items兜底 \(items.count) 条 → \(all.count) 集")
            } catch {
                debugLines.append("Items兜底失败: \(error.localizedDescription)")
                print("FNOS❗️Items兜底失败: \(error)")
            }
        }

        guard !all.isEmpty else {
            debugLines.append("结论: 没有拿到任何分集")
            print("FNOS⚠️ 剧集 \(item.Name ?? "?") 没有可用的分集数据")
            return
        }

        episodes = all.sorted { a, b in
            let sa = a.ParentIndexNumber ?? 0
            let sb = b.ParentIndexNumber ?? 0
            if sa != sb { return sa < sb }
            return (a.IndexNumber ?? 0) < (b.IndexNumber ?? 0)
        }
        selectedTabIndex = 0
        debugLines.append("结论: 共 \(episodes.count) 集，分 \(episodeTabs.count) 组")
        print("FNOSℹ️剧集 \(item.Name ?? "?") 共 \(episodes.count) 集，分 \(episodeTabs.count) 组")
    }

    private func playNow() {
        if item.type == "Series" {
            if let first = episodes.first {
                playEpisode(first)
            } else {
                loadError = "暂无剧集数据"
            }
            return
        }
        guard let client else {
            loadError = "客户端未初始化"
            return
        }
        loadError = nil
        playbackTarget = FNOSPlaybackTarget(item: item, client: client, userID: userID)
    }

    private func playEpisode(_ ep: FNOSItem) {
        guard let client else { return }
        playbackTarget = FNOSPlaybackTarget(item: ep, client: client, userID: userID)
    }

    @AppStorage("fnos.watchlater") private var watchLaterIDs = ""

    private var isWatchLater: Bool {
        watchLaterIDs.split(separator: ",").map(String.init).contains(item.Id)
    }

    private func toggleWatchLater() {
        var ids = watchLaterIDs.split(separator: ",").map(String.init)
        if let index = ids.firstIndex(of: item.Id) {
            ids.remove(at: index)
        } else {
            ids.append(item.Id)
        }
        watchLaterIDs = ids.joined(separator: ",")
    }

    private static func categoryName(_ item: FNOSItem) -> String {
        switch item.type {
        case "Movie": return "电影"
        case "Series": return "剧集"
        case "Episode": return "单集"
        default: return item.type ?? "影片"
        }
    }
}
