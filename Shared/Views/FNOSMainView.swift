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
    /// 单集所属剧名（弹幕「剧名+集数」匹配用）
    var seriesName: String? = nil
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

    // MARK: 海报 → 详情页 自定义过渡（对齐 Apple TV 的"镜头推进"）
    //
    // 关键认知（逐帧比对参考录屏得出）：
    // - 参考实现放大的**不是海报**，而是详情页那张横图本身：卡片位置的窗口先换成横图，
    //   再连同整页一起被推近。所以全屏那一刻屏幕上就是详情页内容，根本不存在"溶解两张不同的图"。
    // - 竖版海报（我们卡片请求 maxWidth=400）放大到 1920 会糊 4.8 倍，且和详情页横图是两张不同素材，
    //   拿它当飞行层必然又糊又割裂 —— v63 的教训。
    // - 参考实现里焦点卡以外的同行卡片也一起放大、被推出画面（整页一个变换），不是静止压暗。
    //
    // 本实现四段：
    // ① 卡片位置先把内容由海报换成横图（0.12s，紧接着就开始运动，人眼跟着运动走） 0.06~0.18s
    // ② 横图窗口从卡片真实 frame 长到全屏，同时整页放大 1.12 倍并压暗        0.34s
    // ③ 详情页用同一张图淡入接管（同 URL 同缓存，接缝为零，只交接交互）       0.14s
    // ④ 静置 1.1s 无 UI → 信息层淡入 + 上移 16pt                            0.45s
    @State private var detailPhase: FNOSDetailPhase = .preview
    /// 过渡中的飞行窗口（内容 = 详情页那张横图）
    @State private var flightItem: FNOSItem?
    /// 窗口矩形：起点 = 卡片真实 frame，终点 = 全屏
    @State private var flightFrame: CGRect = .zero
    @State private var flightRadius: CGFloat = 14
    /// true = 还在显示卡片原来的竖版海报；false = 已换成横图
    @State private var flightShowsPoster = true
    /// 飞行层用的横图（与详情页首帧完全同一个 URL）
    @State private var flightBackdrop: URL?
    @State private var detailOpacity: Double = 0
    /// 整页跟随缩放（背景卡片一起被推近，制造纵深，而不是钉在原地被压暗）
    @State private var pageScale: CGFloat = 1
    @State private var pageAnchor: UnitPoint = .center
    @State private var pageDim: Double = 0
    /// 来源卡片位置（返回时缩回这里）
    @State private var sourceCardFrame: CGRect = .zero
    /// 每张卡片在根坐标系里的位置（点按时取用）
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var screenSize: CGSize = .zero
    /// 过渡期焦点盾：吸收方向键/Menu，避免焦点钻到被遮住的主页
    @FocusState private var shieldFocused: Bool
    /// 开场过渡的分段任务（中途按 Menu 要能立刻接管）
    @State private var transitionTask: Task<Void, Never>?
    /// 电影感过渡开关（出问题可一键回到"直接切"）
    @AppStorage("fnos.ui.heroTransition") private var heroTransition = true

    // 首页设置面板（刷新/退出集成在内）
    @State private var showSettings = false
    // 设置按钮焦点（与 Hero 按钮同一套视觉）
    @FocusState private var settingsButtonFocused: Bool
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

                Group {
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
                                            // Hero 播放 = 立即播放，不跳详情页
                                            playDirectly(item: item)
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
                                FNOSFocusButtonLabel(
                                    isFocused: settingsButtonFocused,
                                    isPrimary: false
                                ) {
                                    Image(systemName: "gearshape.fill")
                                        .font(.system(size: 22, weight: .semibold))
                                }
                            }
                            .buttonStyle(FNOSBareButtonStyle())
                            .focused($settingsButtonFocused)
                            Spacer()
                        }
                        .padding(.leading, 36)
                        .padding(.top, 20)
                        Spacer()
                    }
                }
                }
                .disabled(detailItem != nil)
                // 整页跟随推近：锚点 = 被点的那张卡，背景卡片随之被"推"出画面（参考实现同款纵深）
                .scaleEffect(pageScale, anchor: pageAnchor)

                // 过渡期压暗（在页面上再叠一层，避免整页放大后背景太抢）
                Color.black
                    .opacity(pageDim * 0.45)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .zIndex(5)

                // 过渡期焦点盾（详情页信息层出现前，方向键/Menu 都由它接住）
                if detailItem != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .focusable(detailPhase != .info)
                        .focusEffectDisabled()
                        .focused($shieldFocused)
                        .onExitCommand { closeDetail() }
                        .zIndex(15)
                }

                // 详情页（预览阶段只有画面，信息层由 phase 控制）
                if let current = detailItem {
                    FNOSItemDetailView(
                        item: current,
                        client: client,
                        userID: userID,
                        phase: detailPhase,
                        onClose: { closeDetail() },
                        onEpisodes: { _ in
                            // 剧集现在直接在详情页内选集，不再回调
                        }
                    )
                    .id(current.Id)
                    .opacity(detailOpacity)
                    .allowsHitTesting(detailPhase == .info && detailOpacity > 0.6)
                    .zIndex(20)
                }

                // 飞行海报（放大 / 缩回）
                if let flying = flightItem, let imageClient = client {
                    flightLayer(item: flying, client: imageClient)
                        .zIndex(30)
                }
            }
            .coordinateSpace(name: "fnosRootSpace")
            .onPreferenceChange(FNOSCardFramePreference.self) { frames in
                cardFrames = frames
            }
            .onAppear { screenSize = geo.size }
            .onChange(of: geo.size) { _, newSize in screenSize = newSize }
            // 卡片一聚焦就预取该条目的全屏横图 → 点按瞬间命中缓存，可以直接换图起跳
            .onChange(of: shelfCardFocused) { _, focusedID in
                guard let focusedID else { return }
                let allItems = sections.flatMap { $0.items }
                guard let item = allItems.first(where: { $0.Id == focusedID }),
                      let url = prefetchBackdropURL(for: item)
                else { return }
                let headers = client?.mediaHeaders ?? [:]
                Task { await FNOSImagePrefetcher.prefetch(url, headers: headers) }
            }
        }
        .task {
            await bootstrapIfNeeded()
        }
        .fullScreenCover(item: $playbackTarget) { target in
            FNOSPlayerContainerView(
                item: target.item,
                client: target.client,
                userID: target.userID,
                seriesName: target.seriesName
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
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
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
                            // 记录卡片在根坐标系中的位置，供"海报 → 详情"过渡起止使用
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: FNOSCardFramePreference.self,
                                        value: [item.Id: proxy.frame(in: .named("fnosRootSpace"))]
                                    )
                                }
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

    /// 详情页入口：卡片位置换横图 → 窗口长到全屏（整页同时推近）→ 详情页接管 → 静置 → 信息层淡入
    private func open(item: FNOSItem) {
        guard detailItem == nil, flightItem == nil else { return }

        let size = screenSize == .zero ? CGSize(width: 1920, height: 1080) : screenSize
        let card = cardFrames[item.Id] ?? defaultCardFrame(in: size)
        sourceCardFrame = card

        guard heroTransition else {
            // 关闭电影感过渡：直接呈现（无飞行层）
            pageScale = 1
            pageDim = 0
            detailPhase = .info
            detailOpacity = 1
            detailItem = item
            return
        }

        // 整页推近的锚点 = 被点这卡的中心（归一化）
        pageAnchor = UnitPoint(
            x: min(max(card.midX / max(size.width, 1), 0.02), 0.98),
            y: min(max(card.midY / max(size.height, 1), 0.02), 0.98)
        )

        detailPhase = .preview
        detailOpacity = 0
        pageScale = 1
        pageDim = 0
        flightFrame = card
        flightRadius = 14
        flightShowsPoster = true
        flightBackdrop = prefetchBackdropURL(for: item)
        flightItem = item
        // 提前挂载详情页：横图与详情数据在放大这段时间里就绪
        detailItem = item

        let backdropURL = flightBackdrop
        let prefetch = Task {
            await FNOSImagePrefetcher.prefetch(backdropURL, headers: client?.mediaHeaders ?? [:])
        }

        // 焦点盾要等这一帧布局完成才能接住焦点
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            shieldFocused = true
        }

        transitionTask?.cancel()
        transitionTask = Task { @MainActor in
            // 先让「海报还在卡片里」这一帧真正上屏，否则看不到起点，等于凭空冒出来
            try? await Task.sleep(for: .milliseconds(60))
            if !imageIsCached(backdropURL) {
                await waitForReady(prefetch, timeoutMilliseconds: 220)
            }

            // ① 内容换图：竖版海报 → 详情页横图（短淡化，与紧接着开始的运动重叠）
            withAnimation(.easeInOut(duration: 0.12)) { flightShowsPoster = false }
            try? await Task.sleep(for: .milliseconds(40))

            // ② 窗口长到全屏 + 整页一起被推近（背景卡片跟着出画，制造纵深）
            withAnimation(.easeOut(duration: 0.34)) {
                flightFrame = CGRect(origin: .zero, size: size)
                flightRadius = 0
                pageScale = 1.12
                pageDim = 1
            }
            try? await Task.sleep(for: .milliseconds(350))

            // ③ 详情页用同一张图淡入接管（同 URL、同尺寸 → 视觉无变化，只是把交互交出去）
            withAnimation(.linear(duration: 0.14)) { detailOpacity = 1 }
            try? await Task.sleep(for: .milliseconds(150))
            flightItem = nil

            // ④ 静置约 1.1s（无任何 UI），再让信息层上移淡入
            try? await Task.sleep(for: .milliseconds(1100))
            withAnimation(.easeOut(duration: 0.45)) { detailPhase = .info }
            shieldFocused = false
        }
    }

    /// 返回：文字淡出 → 飞行窗口就位成全屏横图 → 摘掉详情页 → 窗口缩回来源卡片（整页同步复原）→ 焦点回卡
    private func closeDetail() {
        guard let item = detailItem else { return }
        transitionTask?.cancel()
        transitionTask = nil

        guard heroTransition else {
            detailItem = nil
            detailPhase = .preview
            detailOpacity = 0
            shelfCardFocused = item.Id
            return
        }

        shieldFocused = true
        withAnimation(.easeOut(duration: 0.18)) { detailPhase = .closing }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))

            let size = screenSize == .zero ? CGSize(width: 1920, height: 1080) : screenSize
            // 飞行层先跳到「全屏横图」（与详情页当前画面同图同尺寸），随后摘掉详情页不会闪
            flightBackdrop = prefetchBackdropURL(for: item)
            flightShowsPoster = false
            flightFrame = CGRect(origin: .zero, size: size)
            flightRadius = 0
            flightItem = item
            try? await Task.sleep(for: .milliseconds(30))
            detailOpacity = 0
            try? await Task.sleep(for: .milliseconds(50))

            // 缩回来源卡片，同时整页恢复原比例
            withAnimation(.easeInOut(duration: 0.32)) {
                flightFrame = sourceCardFrame
                flightRadius = 14
                pageScale = 1
                pageDim = 0
            }
            // 缩到中途把内容换回竖版海报，落位时正好是卡片原本的样子
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.linear(duration: 0.12)) { flightShowsPoster = true }
            try? await Task.sleep(for: .milliseconds(150))

            flightItem = nil
            detailItem = nil
            detailPhase = .preview
            detailOpacity = 0
            shieldFocused = false

            // 焦点回来源卡（主页一直挂在下面，滚动位置天然保留）
            try? await Task.sleep(for: .milliseconds(40))
            shelfCardFocused = item.Id
        }
    }

    /// 卡片位置没被记录时（例如从 Hero 的「详情」进入）的兜底起点
    private func defaultCardFrame(in size: CGSize) -> CGRect {
        let height = size.height * 0.42
        let width = height * 2 / 3
        return CGRect(
            x: size.width * 0.16,
            y: size.height * 0.30,
            width: width,
            height: height
        )
    }

    /// 详情页首帧那张横图的 URL（与详情页内部构造方式完全一致：不带 index 的 Backdrop 接口）
    private func prefetchBackdropURL(for item: FNOSItem) -> URL? {
        guard let client, let tag = item.BackdropImageTags?.first, !tag.isEmpty else { return nil }
        return try? client.url(
            path: "Items/\(item.Id)/Images/Backdrop",
            query: ["maxWidth": "1920", "quality": "90", "tag": tag]
        )
    }

    /// 图是否已在内存缓存（命中就不用等，点按瞬间直接换图）
    private func imageIsCached(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FNOSImageCache.shared.memory.object(forKey: url.absoluteString as NSString) != nil
    }

    /// 等预取完成，但不超过超时时间
    private func waitForReady(_ task: Task<Void, Never>, timeoutMilliseconds: Int) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: .milliseconds(timeoutMilliseconds)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// 飞行窗口：内容 = 详情页那张横图（4K 源、1920 请求 → 放大到全屏依旧清晰）
    @ViewBuilder
    private func flightLayer(item: FNOSItem, client: FNOSDirectClient) -> some View {
        let posterURL = client.posterURL(itemID: item.Id, tag: item.ImageTags?["Primary"])

        ZStack {
            if let backdrop = flightBackdrop {
                FNOSAsyncImage(url: backdrop, headers: client.mediaHeaders, contentMode: .fill)
                    .opacity(flightShowsPoster ? 0 : 1)
            }
            // 起点那一瞬间仍在卡片里显示原来那张竖版海报，保证「从这张卡长出来」的因果不断
            FNOSAsyncImage(url: posterURL, headers: client.mediaHeaders, contentMode: .fill)
                .opacity(flightShowsPoster ? 1 : 0)
        }
        .frame(width: max(flightFrame.width, 1), height: max(flightFrame.height, 1))
        .clipShape(RoundedRectangle(cornerRadius: flightRadius, style: .continuous))
        .position(x: flightFrame.midX, y: flightFrame.midY)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Hero 播放入口：直接开始播放，不经过详情页
    private func playDirectly(item: FNOSItem) {
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

// MARK: - 卡片位置收集（详情页过渡用）

private struct FNOSCardFramePreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
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

    // 杜比视界按 HDR10 输出（规避紫绿偏色）
    @AppStorage("fnos.play.hdr10Compat") private var hdr10Compat = true

    // 播放器引擎：默认 KSPlayer；开启后走 mpv（MPVUI），用于杜比视界 P5 的色彩转换
    @AppStorage("fnos.play.engineMPV") private var engineMPV = false
    // 自动分流：KSPlayer 处理不了的片源（杜比视界 / AV1）自动切 mpv
    @AppStorage("fnos.play.autoEngine") private var autoEngine = true

    // 弹幕外观（与播放器内「弹幕设置」共用同一批键）
    @AppStorage("fnos.danmu.fontSize") private var danmuFontSize: Double = 26
    @AppStorage("fnos.danmu.speed") private var danmuSpeed: Double = 1
    @AppStorage("fnos.danmu.opacity") private var danmuOpacity: Double = 1
    @AppStorage("fnos.danmu.offsetY") private var danmuOffsetY: Double = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    section("操作") {
                        FNOSSettingRow(title: "刷新媒体库", systemImage: "arrow.clockwise") {
                            dismiss()
                            onRefresh()
                        }
                        FNOSSettingRow(
                            title: "退出登录",
                            systemImage: "rectangle.portrait.and.arrow.right",
                            destructive: true
                        ) {
                            dismiss()
                            onLogout()
                        }
                    }

                    section(
                        "Hero 图源",
                        footer: "若 Hero 标题与画面不一致，通常是飞牛刮削的横图挂错了电影，切换到竖版海报即可规避。"
                    ) {
                        FNOSSettingRow(
                            title: "Hero 横版大图（推荐）",
                            selected: heroImageSource == "backdrop"
                        ) {
                            heroImageSource = "backdrop"
                        }
                        FNOSSettingRow(
                            title: "Hero 竖版海报（图文对不上时切换）",
                            selected: heroImageSource == "primary"
                        ) {
                            heroImageSource = "primary"
                        }
                    }

                    section(
                        "界面",
                        footer: "开启后：点海报时卡片位置先换成详情页那张横图，再连同整页一起被推近到全屏，随后信息层才淡入。关掉则直接进入详情页（用于排查动画相关的异常）。"
                    ) {
                        FNOSSettingRow(
                            title: "详情页电影感过渡",
                            systemImage: "sparkles",
                            isOn: heroTransition
                        ) {
                            heroTransition.toggle()
                        }
                    }

                    section(
                        "播放（引擎 / 色彩）",
                        footer: "自动切换：起播时向飞牛查一次真实格式 —— 杜比视界 P5（IPTPQc2，没有 HDR10 基线层）和 P7 用 mpv 才不会偏色；P8 自带 HDR10 基线层，KSPlayer 解开就是正确画面，会继续留在 KS。切换时会带着当前进度续播。下面的开关用于强制所有片源都走 mpv。"
                    ) {
                        FNOSSettingRow(
                            title: "自动切换播放引擎",
                            systemImage: "arrow.triangle.branch",
                            isOn: autoEngine
                        ) {
                            autoEngine.toggle()
                        }
                        FNOSSettingRow(
                            title: "始终使用 mpv 引擎播放",
                            systemImage: "play.rectangle",
                            isOn: engineMPV
                        ) {
                            engineMPV.toggle()
                        }
                        FNOSSettingRow(
                            title: "杜比视界按 HDR10 输出（KS）",
                            systemImage: "tv",
                            isOn: hdr10Compat
                        ) {
                            hdr10Compat.toggle()
                        }
                    }

                    section(
                        "弹幕",
                        footer: "字号、速度、不透明度、垂直位置对两个播放引擎都生效；播放中也可以按「弹幕设置」实时调。"
                    ) {
                        FNOSSettingAdjustRow(
                            title: "字号",
                            systemImage: "textformat.size",
                            value: "\(Int(danmuFontSize)) pt"
                        ) { step in
                            danmuFontSize = min(max(danmuFontSize + Double(step) * 2, 18), 48)
                        }
                        FNOSSettingAdjustRow(
                            title: "滚动速度",
                            systemImage: "speedometer",
                            value: String(format: "%.1fx", danmuSpeed)
                        ) { step in
                            let next = ((danmuSpeed + Double(step) * 0.1) * 10).rounded() / 10
                            danmuSpeed = min(max(next, 0.5), 3.0)
                        }
                        FNOSSettingAdjustRow(
                            title: "不透明度",
                            systemImage: "circle.lefthalf.filled",
                            value: "\(Int((danmuOpacity * 100).rounded()))%"
                        ) { step in
                            let next = ((danmuOpacity + Double(step) * 0.05) * 100).rounded() / 100
                            danmuOpacity = min(max(next, 0.2), 1)
                        }
                        FNOSSettingAdjustRow(
                            title: "垂直位置",
                            systemImage: "arrow.up.and.down",
                            value: danmuOffsetY == 0
                                ? "默认"
                                : (danmuOffsetY > 0 ? "下移 \(Int(danmuOffsetY)) pt" : "上移 \(Int(-danmuOffsetY)) pt")
                        ) { step in
                            danmuOffsetY = min(max(danmuOffsetY + Double(step) * 20, -80), 420)
                        }
                    }

                    section("关于") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("适配版本")
                                    .font(.system(size: 24, weight: .medium))
                                Spacer()
                                Text(FNOSAdapterBuild.version)
                                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Text(FNOSAdapterBuild.changes)
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 26)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.10))
                        )
                    }
                }
                .padding(.horizontal, 96)
                .padding(.vertical, 44)
                .frame(maxWidth: 1400, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .navigationTitle("设置")
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.secondary)

            VStack(spacing: 10) {
                content()
            }

            if let footer {
                Text(footer)
                    .font(.system(size: 17))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 设置行（自绘焦点，避免 Form 的系统灰色焦点板）

private struct FNOSSettingRow: View {

    let title: String
    var systemImage: String? = nil
    /// 单选组的选中态（非空时显示勾选圈）
    var selected: Bool? = nil
    /// 开关态（非空时显示开/关胶囊）
    var isOn: Bool? = nil
    var destructive: Bool = false

    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 21, weight: .semibold))
                        .frame(width: 28)
                }

                Text(title)
                    .font(.system(size: 24, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 16)

                if let selected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21, weight: .semibold))
                }

                if let isOn {
                    Text(isOn ? "开" : "关")
                        .font(.system(size: 18, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(Color.black.opacity(focused ? 0.12 : 0.0))
                        )
                        .overlay(
                            Capsule().stroke(
                                Color.black.opacity(focused ? 0.25 : 0.35),
                                lineWidth: 1.5
                            )
                        )
                }
            }
            .foregroundColor(rowForeground)
            .padding(.horizontal, 26)
            .frame(height: 72)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(focused ? Color.white : Color.white.opacity(0.10))
            )
            .scaleEffect(focused ? 1.015 : 1.0)
            .animation(.easeOut(duration: 0.14), value: focused)
        }
        .buttonStyle(FNOSBareButtonStyle())
        .focused($focused)
    }

    private var rowForeground: Color {
        if focused { return destructive ? Color(red: 0.75, green: 0.1, blue: 0.1) : .black }
        return destructive ? Color(red: 1, green: 0.36, blue: 0.36) : .white
    }
}

// MARK: - 可调节设置行（← → 调整数值，Select 加一档）

private struct FNOSSettingAdjustRow: View {

    let title: String
    var systemImage: String? = nil
    let value: String
    /// step = -1 减一档，+1 加一档
    let onAdjust: (Int) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .frame(width: 28)
            }

            Text(title)
                .font(.system(size: 24, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 16)

            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .bold))
                .opacity(focused ? 0.55 : 0.15)

            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 130, alignment: .center)

            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .bold))
                .opacity(focused ? 0.55 : 0.15)
        }
        .foregroundColor(focused ? .black : .white)
        .padding(.horizontal, 26)
        .frame(height: 72)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(focused ? Color.white : Color.white.opacity(0.10))
        )
        .scaleEffect(focused ? 1.015 : 1.0)
        .animation(.easeOut(duration: 0.14), value: focused)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .left: onAdjust(-1)
            case .right: onAdjust(1)
            default: break
            }
        }
        .onTapGesture { onAdjust(1) }
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
