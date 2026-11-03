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
    /// v82：Menu 关闭回调（外层做反向缩回动画）。cover 呈现视图内 onExitCommand 可靠。
    var onMenuClose: () -> Void = {}

    /// 播放器在本页内打开（不先关详情页），避免 fullScreenCover 竞态导致请求被取消
    @State private var playbackTarget: FNOSPlaybackTarget?
    /// 播放器内点了别的分集：先关闭播放器，onDismiss 里再以新目标重开（cover 展示中改 item 不会重建内容）
    @State private var pendingEpisode: FNOSItem?
    @State private var pendingSeriesName: String?

    /// 详情页背景图轮播索引
    @State private var backdropIndex = 0

    // 详情数据（媒体源、时长、演员）
    @State private var mediaSourceID: String?
    @State private var runtimeTicks: Int64?
    @State private var people: [FNOSDirectClient.FNOSPerson] = []
    // 飞牛原生 API（兼容层拿不到的演员/精确时长）——走 /v/api/v1/ + Authx
    @State private var nativePersons: [FNOSNativeClient.Person] = []
    /// 原生客户端（头像 URL / 鉴权头需要它）
    @State private var nativeClient: FNOSNativeClient?
    /// 集号 → 时长（秒），来自原生 episode/list
    @State private var nativeEpisodeDurations: [Int: Int] = [:]
    /// 电影/单集时长（秒），来自原生条目
    @State private var nativeDurationSeconds: Int?
    @State private var loadError: String?
    // 从海报提取的主色（动态液态玻璃背景）
    @State private var themeColor: Color?
    @State private var fetchedBackdropTags: [String]?

    // v85 信息增强：色彩档位徽章（原生 /stream 探测）+ 评分（play/info 防御性解析）
    @State private var colorBadge: String?
    @State private var imdbRating: Double?
    @State private var doubanRating: Double?
    @State private var tomatoRating: Double?

    // v87 本地续播：电影=条目进度秒；剧集=剧→最近看的集
    @State private var localResumeSeconds: Double?
    @State private var seriesResume: (episodeItemID: String, episodeNumber: Int)?

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

    /// 时长文案：原生 API 的秒数最可信；否则退回 ticks 量级判定。
    /// 剧集(Series)没有自己的 ticks，runtimeTicks 由第 1 集补齐，所以按剧集的时长区间判定。
    private var durationString: String? {
        if let seconds = nativeDurationSeconds, seconds >= 60 {
            return FNOSItem.format(seconds: Double(seconds))
        }
        return FNOSItem.durationText(
            ticks: runtimeTicks ?? item.RunTimeTicks,
            isEpisode: item.type != "Movie"
        )
    }

    /// 单集时长文案：原生 episode/list 的秒数优先
    private func episodeDurationText(_ ep: FNOSItem) -> String? {
        if let number = ep.IndexNumber,
           let seconds = nativeEpisodeDurations[number], seconds >= 60
        {
            return FNOSItem.format(seconds: Double(seconds))
        }
        return ep.compactDuration
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
                                    .id("detail-episodes")
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

            }
        }
        .ignoresSafeArea()
        .task {
            await loadDetail()
        }
        .onAppear {
            // defaultFocus 会被背景图/滚动容器抢走，延迟再压一次确保落在「播放第 1 集」
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                focusedButton = .play
            }
        }
        .task(id: item.Id) {
            await rotateBackdrops()
        }
        .task(id: item.Id) {
            loadLocalProgress()
            await loadHeroInfo()
        }
        .fullScreenCover(item: $playbackTarget, onDismiss: {
            // v89：播放器关闭后立刻重读本地进度（按钮「继续播放/立即播放」马上刷新）
            loadLocalProgress()
            reopenPendingEpisode()
        }) { target in
            FNOSPlayerContainerView(
                item: target.item,
                client: target.client,
                userID: target.userID,
                seriesName: target.seriesName,
                episodes: target.item.type == "Episode" ? episodes : [],
                onSelectEpisode: { ep in
                    // 换集：记下目标后关闭播放器；onDismiss 时再以新条目重新打开。
                    // 不能直接替换 playbackTarget —— cover 展示期间换 item 不会重建视图，
                    // 旧的 streamURL / didSetup 全都留着，表现就是「点了没反应」。
                    pendingEpisode = ep
                    pendingSeriesName = target.seriesName ?? item.Name
                    playbackTarget = nil
                },
                seriesID: target.seriesID,
                startFraction: target.startFraction
            )
        }
        // v82：拦截 Menu 交给外层——有卡片来源时反向缩回，无来源时普通关闭。
        // 呈现视图内的 onExitCommand 可靠（Demo 同款真机已验证；v77 失败是「嵌入非呈现视图」场景）。
        .onExitCommand { onMenuClose() }
    }

    // MARK: - 本地续播（v87）

    /// 读取本地播放进度：电影→条目进度；剧集→剧→最近集（跨季池查找在 playNow 里做）
    @MainActor
    private func loadLocalProgress() {
        if item.type == "Series" {
            seriesResume = FNOSProgressStore.loadSeriesProgress(seriesID: item.Id)
        } else {
            localResumeSeconds = FNOSProgressStore.load(itemID: item.Id)
        }
    }

    /// 播放按钮文字：有本地记录 → 「继续播放（第N集）」
    private var playButtonTitle: String {
        if item.type == "Series" {
            if let number = seriesResume?.episodeNumber, number > 0 {
                return "继续播放 第\(number)集"
            }
            return "播放第 1 集"
        }
        if let seconds = localResumeSeconds, seconds > 30 {
            return "继续播放"
        }
        return "立即播放"
    }

    /// 本地进度秒 → 0~1 播放比例（与播放器 resumeStartSeconds 同基准：plausibleSeconds 兜底单位换算）
    private func resumeFraction(seconds: Double?, for target: FNOSItem) -> Double? {
        guard let seconds, seconds > 30 else { return nil }
        guard let runtime = FNOSItem.plausibleSeconds(ticks: target.RunTimeTicks, isEpisode: target.type == "Episode") else { return nil }
        return min(0.98, seconds / runtime)
    }

    // MARK: - Hero 信息增强（v85：色彩档位 + 评分）

    /// 原生接口一次拿两样：/stream 探测出色彩档位（杜比视界 P 档 / HDR10 / SDR），
    /// play/info 的 item 字典防御性解析评分。找不到就不显示对应元素。
    @MainActor
    private func loadHeroInfo() async {
        guard colorBadge == nil, imdbRating == nil, doubanRating == nil else { return }
        guard let credentials = FNOSAuthStore.shared.credentials,
              let nativeToken = credentials.nativeToken, !nativeToken.isEmpty
        else { return }
        let native = FNOSNativeClient(baseURL: credentials.serverURL, token: nativeToken)
        let isSeries = item.type == "Series"
        // 剧集取第 1 集代表整剧档位；电影按标题直查
        let result = await native.detailEnrichment(
            itemTitle: isSeries ? nil : item.Name,
            seriesTitle: isSeries ? item.Name : nil,
            episodeNumber: isSeries ? 1 : nil
        )
        guard let result else { return }
        colorBadge = result.badge
        imdbRating = result.imdb
        doubanRating = result.douban
        tomatoRating = result.tomato
        print("FNOSℹ️Hero 增强: \(result.badge ?? "—") IMDb=\(result.imdb.map { String(format: "%.1f", $0) } ?? "—") 豆瓣=\(result.douban.map { String(format: "%.1f", $0) } ?? "—") 烂番茄=\(result.tomato.map { String(format: "%.0f%%", $0) } ?? "—")")
    }

    /// 评分胶囊（IMDb 黄 / 豆瓣 绿 / 烂番茄 红 —— 各家品牌色近似）
    private func ratingBadge(label: String, value: String, bg: Color, fg: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .heavy))
            Text(value)
                .font(.system(size: 13, weight: .bold))
        }
        .foregroundColor(fg)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(bg))
    }

    /// 色彩档位徽章：杜比视界 = 白底黑字（醒目）；HDR10 = 半透明白底；SDR = 低调灰
    @ViewBuilder
    private var colorBadgeView: some View {
        if let badge = colorBadge, !badge.isEmpty {
            let isDolby = badge.hasPrefix("杜比视界")
            let isSDR = badge == "SDR"
            Text(badge)
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(isDolby ? Color.black : (isSDR ? .white.opacity(0.65) : .white))
                .padding(.horizontal, isDolby ? 8 : 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isDolby ? Color.white : Color.white.opacity(isSDR ? 0.10 : 0.16))
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
                    // v85：评分（有数据才显示；IMDb/豆瓣/烂番茄按品牌色胶囊）
                    if let imdb = imdbRating {
                        ratingBadge(label: "IMDb", value: String(format: "%.1f", imdb),
                                    bg: Color(red: 0.96, green: 0.78, blue: 0.09), fg: .black)
                    }
                    if let douban = doubanRating {
                        ratingBadge(label: "豆瓣", value: String(format: "%.1f", douban),
                                    bg: Color(red: 0.0, green: 0.71, blue: 0.11), fg: .white)
                    }
                    if let tomato = tomatoRating {
                        ratingBadge(label: "烂番茄", value: String(format: "%.0f%%", tomato),
                                    bg: Color(red: 0.93, green: 0.11, blue: 0.14), fg: .white)
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
                    // v85：色彩档位徽章（杜比视界 P 档 / HDR10 / SDR，原生 /stream 实测）
                    colorBadgeView
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
                        Text(playButtonTitle)
                            .font(.system(size: 21, weight: .semibold))
                    }
                    .onMoveCommand { direction in
                        if direction == .down { goDownFromHero(proxy) }
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
                        if direction == .down { goDownFromHero(proxy) }
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
                        if direction == .down { goDownFromHero(proxy) }
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

            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // 文本区：集号 / 标题 / 简介 / 日期 + 分级
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text("第 \(ep.IndexNumber ?? 0) 集")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                    if let duration = episodeDurationText(ep) {
                        Text("·")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.28))
                        Text(duration)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }

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
            // 演员阵容（原生 API 或 Jellyfin People，任一有数据就展示）
            if !castEntries.isEmpty {
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
                    ForEach(castEntries) { person in
                        VStack(spacing: 8) {
                            FNOSAsyncImage(
                                url: person.imageURL,
                                headers: person.headers,
                                contentMode: .fill
                            )
                            .frame(width: 124, height: 124)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))

                            Text(person.name)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Text(person.role)
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

    // MARK: - 演职人员统一模型（原生 API 优先，Jellyfin People 兜底）

    private struct CastEntry: Identifiable {
        let id: String
        let name: String
        let role: String
        let imageURL: URL?
        let headers: [String: String]
    }

    private var castEntries: [CastEntry] {
        // 1) 飞牛原生 person/list：字段是 job(Actor/Director) / role / profile_path
        if !nativePersons.isEmpty {
            return nativePersons.prefix(24).enumerated().map { index, person in
                let roleText: String
                switch person.job {
                case "Director": roleText = "导演"
                case "Actor": roleText = (person.role?.isEmpty == false) ? (person.role ?? "演员") : "演员"
                default: roleText = person.role ?? person.job ?? " "
                }
                let url = person.profilePath.flatMap { path -> URL? in
                    guard !path.isEmpty else { return nil }
                    return nativeClient?.personImageURL(profilePath: path, width: 300)
                }
                return CastEntry(
                    id: "native-\(index)-\(person.name)",
                    name: person.name,
                    role: roleText,
                    imageURL: url,
                    headers: nativeClient?.imageHeaders ?? [:]
                )
            }
        }
        // 2) Jellyfin 兼容层的 People（多数情况下为空）
        return people.enumerated().map { index, person in
            CastEntry(
                id: "jf-\(index)-\(person.name)",
                name: person.name,
                role: person.role ?? " ",
                imageURL: person.id.flatMap { id in
                    client?.personImageURL(personID: id, tag: person.imageTag)
                },
                headers: client?.mediaHeaders ?? [:]
            )
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
            let peopleKey = detail.rawKeys.contains("People")
            debugLines.append("详情: 演员\(detail.people.count) 源\(detail.mediaSourceID == nil ? "无" : "有") People键=\(peopleKey ? "有" : "无") 原始[\(detail.peopleRaw)]")
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

        // 3) 飞牛原生 API：演员 + 精确时长（Jellyfin 兼容层根本不返回这些）
        await loadNativeMetadata(client: client)

        // 3) 主题色
        if let url = backdropURL {
            themeColor = await FNOSDominantColor.color(for: url, headers: client.mediaHeaders)
        }
    }

    /// 飞牛原生 API：按标题换 guid，再取演员与逐集时长。
    /// 兼容层只给 BaseItemDto（People 恒空、RunTimeTicks 单位混乱），这层才是飞牛 App 的真数据源。
    @MainActor
    private func loadNativeMetadata(client: FNOSDirectClient) async {
        // 原生接口要飞牛自己的 token（登录时换好存在凭据里），不是兼容层的 AccessToken
        let nativeToken = FNOSAuthStore.shared.credentials?.nativeToken
        if nativeToken == nil {
            debugLines.append("原生: 缺少飞牛 token —— 请退出重新登录一次")
        }
        let native = FNOSNativeClient(baseURL: client.baseURL, token: nativeToken ?? client.token)
        nativeClient = native

        let isSeries = item.type == "Series"
        let resolved = await native.resolve(title: item.Name, isSeries: isSeries)

        if !resolved.persons.isEmpty {
            nativePersons = resolved.persons
        }
        if !resolved.episodeDurations.isEmpty {
            nativeEpisodeDurations = resolved.episodeDurations
        }
        if let seconds = resolved.durationSeconds, seconds > 0 {
            nativeDurationSeconds = seconds
        }
        // 剧集自身没有时长 → 用第 1 集的
        if nativeDurationSeconds == nil, isSeries,
           let firstNumber = episodes.first?.IndexNumber,
           let seconds = resolved.episodeDurations[firstNumber]
        {
            nativeDurationSeconds = seconds
        }

        debugLines.append(contentsOf: resolved.debug)
        print("FNOSℹ️原生链路: \(resolved.debug.joined(separator: " | "))")
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
                        "Fields": "Overview,RunTimeTicks,OfficialRating,ParentIndexNumber,IndexNumber,PremiereDate,SeriesName",
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
                        "Fields": "Overview,RunTimeTicks,OfficialRating,ParentIndexNumber,IndexNumber,PremiereDate,SeriesName",
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
                        "Fields": "Overview,RunTimeTicks,OfficialRating,ParentIndexNumber,IndexNumber,PremiereDate,SeriesName",
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

        // 剧集(Series)自身没有 RunTimeTicks（飞牛返回 0 而不是缺失）→ 用第 1 集代表「单集片长」
        if runtimeTicks == nil || runtimeTicks == 0,
           let firstTicks = episodes.first?.RunTimeTicks, firstTicks > 0 {
            runtimeTicks = firstTicks
            print("FNOSℹ️片长取自第1集 ticks=\(firstTicks) → \(durationString ?? "nil")")
        }

        // 剧集(Series)自身的 People 通常为空，演员挂在单集上 → 拉第 1 集详情取阵容
        if people.isEmpty, let first = episodes.first {
            let epDetail = try? await client.fetchItemDetail(itemID: first.Id, userID: userID)
            if let epDetail, !epDetail.people.isEmpty {
                people = epDetail.people
                debugLines.append("演员取自第1集: \(epDetail.people.count) 人")
                print("FNOSℹ️演员取自第1集 \(epDetail.people.count) 人")
            } else {
                debugLines.append("第1集演员=\(epDetail?.people.count ?? -1) 原始[\(epDetail?.peopleRaw ?? "请求失败")]")
                print("FNOS⚠️ 第1集也没有演员数据 raw=\(epDetail?.peopleRaw ?? "请求失败")")
            }
        }

        let probe = episodes.first
        let probeSeconds = FNOSItem.plausibleSeconds(ticks: probe?.RunTimeTicks, isEpisode: probe?.type == "Episode")
        let div = (probe?.RunTimeTicks).map { String(Int(Double($0) / 1_000_000)) } ?? "nil"
        debugLines.append("结论: 共 \(episodes.count) 集 分 \(episodeTabs.count) 组；ticks=\(probe?.RunTimeTicks ?? -1) ÷1e6=\(div) 秒=\(probeSeconds.map { String(Int($0)) } ?? "nil") 角标=\(probe?.compactDuration ?? "nil")")
        print("FNOSℹ️剧集 \(item.Name ?? "?") 共 \(episodes.count) 集，分 \(episodeTabs.count) 组")
    }

    /// Hero 按钮按下键：剧集页优先落到「第 1-10 集」分段标签，电影才滚到信息卡。
    /// 之前一律滚到 detail-info，导致按一下下键画面与焦点一起飞走。
    private func goDownFromHero(_ proxy: ScrollViewProxy) {
        if item.type == "Series", let firstTab = episodeTabs.first {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo("detail-episodes", anchor: .top)
            }
            // 等滚动落位后把焦点交给第一个分段标签
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                focusedTab = firstTab.id
            }
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo("detail-info", anchor: .top)
            }
        }
    }

    private func playNow() {
        if item.type == "Series" {
            // v87 续播：优先本地记录的最近集（当前列表 + 跨季池查找），带进度
            if let resume = seriesResume {
                let pool = episodes + episodesBySeason.values.flatMap { $0 }
                let ep = pool.first { $0.Id == resume.episodeItemID }
                    ?? pool.first { $0.IndexNumber == resume.episodeNumber }
                if let ep {
                    playEpisode(ep, startFraction: resumeFraction(seconds: FNOSProgressStore.load(itemID: ep.Id), for: ep))
                    return
                }
            }
            if let first = episodes.first {
                playEpisode(first)
            } else {
                loadError = "暂无剧集数据"
            }
            return
        }
        guard let client else {
            loadError = "设备客户端未就绪"
            return
        }
        loadError = nil
        // v87：有本地记录 → 直接带进度续播
        playbackTarget = FNOSPlaybackTarget(
            item: item,
            client: client,
            userID: userID,
            startFraction: resumeFraction(seconds: localResumeSeconds, for: item)
        )
    }

    private func playEpisode(_ ep: FNOSItem, startFraction: Double? = nil) {
        guard let client else { return }
        // 保持传完整剧集列表给播放器（启用换集面板与集数信息）；seriesID 供剧集续播位置记录
        playbackTarget = FNOSPlaybackTarget(
            item: ep,
            client: client,
            userID: userID,
            seriesName: item.Name,
            seriesID: item.Id,
            startFraction: startFraction
        )
    }

    /// 播放器关闭后若有待切分集，立刻以新目标重新打开（全新视图实例 → 重新拉流 + 重新匹配弹幕）
    private func reopenPendingEpisode() {
        guard let ep = pendingEpisode, let client else { return }
        pendingEpisode = nil
        let name = pendingSeriesName ?? item.Name
        pendingSeriesName = nil
        print("FNOSℹ️换集 → 第 \(ep.IndexNumber ?? 0) 集：\(ep.Name ?? "？")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            playbackTarget = FNOSPlaybackTarget(
                item: ep,
                client: client,
                userID: userID,
                seriesName: name,
                seriesID: item.Id
            )
        }
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
