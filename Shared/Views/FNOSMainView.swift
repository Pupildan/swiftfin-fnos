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
    /// 所属剧 Id（v87：剧集续播位置记录用）
    var seriesID: String? = nil
    /// 继续播放起点（0~1 比例；由服务端/本地进度换算，与飞牛 tick 单位无关）
    var startFraction: Double? = nil
    /// 继续播放起点（秒，v91 直通——绕开条目 RunTimeTicks 缺失导致的换算失败）
    var startSeconds: Double? = nil
    /// v96 原生直通条目（直播频道等）：播放器走原生 play/info → media/range 直链（mpv）
    var nativeItemGUID: String? = nil
}

/// 单个媒体库的横向海报墙数据
struct FNOSLibrarySection: Identifiable {
    let library: FNOSLibrary
    var items: [FNOSItem]

    var id: String { library.Id }
}

/// 继续播放条目（v91）：服务端记录（多端）+ 本地记录兜底合并后的展示单元。
/// startSeconds 非空 = 本机记录（直接按秒续播）；否则按 fraction（服务端 UserData 比例）。
/// runtimeSeconds = v93 归一化后的最优时长（秒）；posSeconds = v95 归一化后的观看位置（秒），
/// 剩余时间用 pos×(1-f)/f 反推——完全绕开时长字段的单位坑。
struct FNOSResumeEntry: Identifiable {
    let item: FNOSItem
    let fraction: Double
    let startSeconds: Double?
    let runtimeSeconds: Double?
    var posSeconds: Double? = nil
    var id: String { item.Id }
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
    /// v95 原生客户端（TV直播/古风MV 数据行 + sys/img 鉴权头）
    @State private var nativeClient: FNOSNativeClient?
    /// 继续播放（v91：服务端记录 + 本地记录兜底合并）；为空 → 行隐藏
    @State private var resumeEntries: [FNOSResumeEntry] = []
    @State private var isLoading = false
    @State private var didBootstrap = false

    @State private var playbackTarget: FNOSPlaybackTarget?
    @State private var seriesItem: FNOSItem?
    // 影视详情页（1:1 复刻 ATV+）
    @State private var detailItem: FNOSItem?

    // ---- 详情过渡动画（方案 B+：混合飞行层，v75/v76 实装失败根因全在此解决）----
    // matchedGeometryEffect 命名空间：卡片(A端) ↔ 飞行层起跳横图(B端) 必须同树共享。
    // 用 @Namespace 而非全局，保证 A/B 端在同一坐标系里插值（这是 Demo 跑通 70 分的根基）。
    @Namespace private var transitionNS
    /// 飞行层上下文；非 nil = 过渡进行中。落地后置 nil（真实详情页已全屏接管）。
    @State private var flight: FNOSDetailFlightContext?
    /// v82：最近一次正向起跳的上下文——Menu 反向缩回需要同一份几何（行/焦点卡 frame）
    @State private var lastFlightCtx: FNOSDetailFlightContext?
    /// 最近打开的卡片 Id：关闭过渡后把焦点显式还给它（否则焦点悬空，Menu 失灵）
    @State private var lastOpenedCardID: String?
    /// 每个媒体库行的内容 frame（全局坐标，含水平滚动偏移），供行副本 1:1 对齐。
    /// 非响应式引用类型：滚动时只写不触发重渲染（避免海报墙滚动掉帧）。
    @State private var rowFrames = FNOSRowFrameStore()

    // v81 屏显诊断（真机无控制台；确认根因后 v82 移除）
    @State private var diagMessage: String?
    @State private var diagToken = 0

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
                                            // Hero 无卡片可起跳：直接出详情页
                                            openDetailDirect(item: item)
                                        },
                                        onDownToShelf: {
                                            // 下键从 Hero 跳入海报墙：先滚动让媒体库行出现，再把焦点落到第一张卡
                                            withAnimation(.easeInOut(duration: 0.4)) {
                                                proxy.scrollTo("fnos-shelf-top", anchor: .top)
                                            }
                                            Task { @MainActor in
                                                try? await Task.sleep(for: .milliseconds(450))
                                                // 有继续播放记录时优先落「继续播放」首卡，其次媒体库首卡
                                                if let lead = resumeEntries.first?.item.Id
                                                    ?? sections.first(where: { !$0.items.isEmpty })?.items.first?.Id {
                                                    shelfCardFocused = lead
                                                }
                                            }
                                        }
                                    )
                                    .frame(width: geo.size.width, height: geo.size.height)
                                }

                                // 媒体库横向海报墙（非懒容器：保证屏外行存在，焦点引擎才有落点）
                                VStack(alignment: .leading, spacing: 44) {
                                    // 继续播放（服务端 + 本机记录合并）：有记录才显示
                                    if !resumeEntries.isEmpty {
                                        resumeShelf(screenWidth: geo.size.width)
                                    }
                                    ForEach(sections.filter { !$0.items.isEmpty }) { section in
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
                    // 仅飞行期（cover 呈现前 0~0.74s）禁用主页：此时飞行层盖住底层，
                    // 焦点会漏到被盖住的可聚焦元素上 → Menu 失灵（v76 根因）。
                    // 注意：主页保持可见（不 opacity 0），由飞行层半透明压暗盖住。
                    // v80 关键修复：cover presented 之后底层被系统拦截、根本不可达，
                    // 禁用纯属多余且【摧毁焦点归还锚点】——详情期间保持来源卡可聚焦，
                    // dismiss 时焦点引擎才有合法落点（返回高概率丢焦点的根因）。
                    .disabled(flight != nil)

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
                    .disabled(flight != nil)
                }

                // ---- 详情过渡（方案 B+ v78：cover-at-land）----
                // 关键：详情页【不】原地嵌入 —— v77 嵌入导致 .onExitCommand 在 tvOS 对
                // 非呈现视图不可靠，焦点没落稳时 Menu 穿透到系统 → 退出到桌面。
                // 改为：飞行层在主视图做 matched（同树，A/B 端共享命名空间），
                // 落地瞬间才 present 详情页 cover（系统原生处理 Menu，可靠）。
                // 详情 cover 的 Hero（全屏横图）与飞行层终点同位同尺寸 → 零跳位。
                if let flight {
                    FNOSDetailFlightOverlay(ctx: flight, ns: transitionNS)
                        .zIndex(30)
                        // v83 关键修复：正向飞行层在 withAnimation(spring) 事务内插入，
                        // SwiftUI 默认给新视图套 .opacity 过渡 → 整层（含行副本）从 0 淡入
                        // ~0.45s，副本未显形就被放大的横图盖住 → 「进入时同行不参与动画」。
                        // 反向是在 nil 动画事务里插入的（无过渡）→ 反而正常，正好印证。
                        // .identity = 插入帧即全量渲染；matched 几何插值不受影响
                        //（那是 GeometryEffect，不是 transition）。
                        .transition(.identity)
                        .onExitCommand { cancelFlight() }
                }

                // v81 诊断 toast（zIndex 40 高于飞行层：起跳确认不被动画盖住；
                // cover 呈现后属主视图内容，被系统呈现层自然盖住，无碍）
                if let diag = diagMessage {
                    Text(diag)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(36)
                        .allowsHitTesting(false)
                        .zIndex(40)
                }
            }
        }
        .task {
            await bootstrapIfNeeded()
        }
        .fullScreenCover(item: $playbackTarget, onDismiss: {
            rebuildResumeEntries()
        }) { target in
            FNOSPlayerContainerView(
                item: target.item,
                client: target.client,
                userID: target.userID,
                seriesName: target.seriesName,
                seriesID: target.seriesID,
                startFraction: target.startFraction,
                startSeconds: target.startSeconds,
                nativeItemGUID: target.nativeItemGUID
            )
        }
        // 详情页走 fullScreenCover（系统原生处理 Menu，可靠关闭，v77 嵌入已回滚）。
        // v82：Menu 改由 cover 内容内 onExitCommand 拦截 → closeDetailWithReverse()
        // （有卡片来源时反向缩回）；onDismiss 兜底系统路径并负责还焦点 + v89 刷新继续播放。
        .fullScreenCover(item: $detailItem, onDismiss: {
            closeDetail()
            rebuildResumeEntries()
        }) { item in
            FNOSItemDetailView(
                item: item,
                client: client,
                userID: userID,
                onEpisodes: { _ in },
                onMenuClose: { closeDetailWithReverse() }
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
                    resumeEntries = []
                    // 立即进入加载态：避免清空数据到新数据回来之间闪一下「暂无内容」
                    isLoading = true
                    didBootstrap = false
                    Task { await bootstrapIfNeeded() }
                },
                onLogout: {
                    auth.logout()
                },
                demoClient: client,
                demoItems: Array(demoPool)
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
        // 焦点落到卡片即预取 1920 横图进内存缓存：点按起跳必高清（不预取=起跳灰底转圈）
        .onChange(of: shelfCardFocused) { _, focused in
            guard let focused, let client else { return }
            prefetchDetailBackdrop(itemID: focused, client: client)
        }
        .ignoresSafeArea()
    }

    /// 预取详情 1920 横图进共享内存缓存（FNOSAsyncImage 命中缓存即秒显）。
    /// key = URL.absoluteString，与 FNOSAsyncImage 读缓存的口径一致。
    private func prefetchDetailBackdrop(itemID: String, client: FNOSDirectClient) {
        guard let item = allItems.first(where: { $0.Id == itemID }) else { return }
        guard let url = detailBackdropURL(for: item, client: client) else { return }
        let key = url.absoluteString as NSString
        guard FNOSImageCache.shared.memory.object(forKey: key) == nil else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (field, value) in client.mediaHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            FNOSImageCache.shared.memory.setObject(image, forKey: key)
        }.resume()
    }

    /// 详情横图 URL：1920 Backdrop 优先，退 1280 Primary（与 Demo backdropURL 一致）
    private func detailBackdropURL(for item: FNOSItem, client: FNOSDirectClient) -> URL? {
        if let tag = item.BackdropImageTags?.first, !tag.isEmpty,
           let url = try? client.url(
               path: "Items/\(item.Id)/Images/Backdrop",
               query: ["maxWidth": "1920", "quality": "90", "tag": tag]
           ) {
            return url
        }
        if let tag = item.ImageTags?["Primary"], !tag.isEmpty,
           let url = try? client.url(
               path: "Items/\(item.Id)/Images/Primary",
               query: ["maxWidth": "1280", "quality": "90", "tag": tag]
           ) {
            return url
        }
        return nil
    }

    /// 全部条目（去重，供预取查 Id→Item）
    private var allItems: [FNOSItem] {
        var seen = Set<String>()
        return sections.flatMap(\.items).filter { seen.insert($0.Id).inserted }
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
        // 行副本对齐需要 tileWidth（行内容 frame 已由 .onPreferenceChange 写入）
        rowFrames.tileWidths[section.id] = tileWidth

        return VStack(alignment: .leading, spacing: 14) {
            Text(section.library.Name ?? "未命名")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, hPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(section.items) { item in
                        let isFocused = shelfCardFocused == item.Id
                        let rowIndex = section.items.firstIndex(where: { $0.Id == item.Id })
                        // 详情打开期间（飞行中+落地后）该卡都保持隐藏 & 去 matched，
                        // 避免落地时 flight=nil 导致 matched 几何反向触发（A 端突然回归）。
                        // 关键（v79）：必须同时看 flight 与 detailItem —— v78 用 cover-at-land，
                        // detailItem 延迟到 0.46s 才设置，若只看 detailItem，则 0~0.46s 飞行期间
                        // 起跳卡保留 matched，与飞行层 B 端横图形成同一 id 双 source（v77 已验证
                        // 的配置是 A 端去掉 matched，B 端从最后 frame 起跳，故需在 flight 起就隐藏）。
                        let isFlightCard = flight?.item.Id == item.Id || detailItem?.Id == item.Id
                            // 飞行行窗口内的卡也隐藏（交给行副本渲染），避免与副本「重影」。
                            // 窗口宽度与飞行层 window 共用 FNOSDetailFlightContext.windowHalf。
                            let isInFlightWindow: Bool = {
                                guard let f = flight, f.rowSectionID == section.id, let rowIndex else { return false }
                                return abs(rowIndex - f.focusIndex) <= FNOSDetailFlightContext.windowHalf
                            }()
                        Button {
                            openCard(item: item)
                        } label: {
                            Group {
                                if isFlightCard {
                                    // 起跳卡：海报隐藏（opacity 0）让位给飞行层横图 matched 视图。
                                    // 关键：此卡必须【去掉】matchedGeometryEffect ——
                                    // 同一 id 全树只能有一个 source，保留会让 A/B 双 source 冲突。
                                    // 去掉后，飞行层 B 端会从这张卡的最后 frame 起跳（Demo 已验证）。
                                    FNOSPosterTile(
                                        item: item,
                                        client: client,
                                        width: tileWidth,
                                        isFocused: isFocused,
                                        nativePosterURL: item.nativePosterURL,
                                        nativeHeaders: nativeClient?.imageHeaders
                                    )
                                    .opacity(0)
                                } else {
                                    // A 端：卡片海报（matched 起点）。Demo 结论：起跳内容不是海报，
                                    // 而是预取横图，所以这里只提供【几何起点】，内容由 B 端覆盖。
                                    // 窗口内非焦点卡：opacity 0（副本渲染），保留 matched（无配对即惰性）。
                                    FNOSPosterTile(
                                        item: item,
                                        client: client,
                                        width: tileWidth,
                                        isFocused: isFocused,
                                        nativePosterURL: item.nativePosterURL,
                                        nativeHeaders: nativeClient?.imageHeaders
                                    )
                                    .opacity(isInFlightWindow ? 0 : 1)
                                    .matchedGeometryEffect(id: item.Id, in: transitionNS)
                                }
                            }
                        }
                        // v85：系统 .card 液态玻璃（与 Demo 同款，用户点名）。
                        // 注意：使用 .card 时周围不能再挂 focusEffectDisabled（会吞掉玻璃），
                        // shelf 内三处已同步拆除（HANDOVER 红线）。
                        .buttonStyle(.card)
                        // 每张卡注册独立焦点值（条目 Id 唯一，避免 Bool 歧义），供下键直达
                        .focused($shelfCardFocused, equals: item.Id)
                        // v81：卡片级全局 frame 捕获（起跳 frame 的主来源）。焦点卡点按
                        // 瞬间必然可见，GeometryReader 必然已上报最新 frame（含滚动偏移）。
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: FNOSCardFrameKey.self,
                                    value: [item.Id: g.frame(in: .global)]
                                )
                            }
                        )
                    }
                }
                // 行内容 frame 捕获（全局坐标，含水平滚动偏移）：
                // 行副本用它把「焦点卡中心」对齐到屏幕上的真实位置，1:1 起跳。
                .background(
                    GeometryReader { g in
                        Color.clear.preference(
                            key: FNOSRowContentFrameKey.self,
                            value: g.frame(in: .global)
                        )
                    }
                )
                .padding(.horizontal, hPadding)
                // 给聚焦放大与玻璃留出空间，避免被 ScrollView 裁掉
                .padding(.vertical, 26)
                .onPreferenceChange(FNOSRowContentFrameKey.self) { frame in
                    rowFrames.frames[section.id] = frame
                }
                // v81：卡片级 frame 汇总。可见卡各自上报，reduce 合并为整行可见字典；
                // 直接覆盖写即可——点按瞬间焦点卡必在可见集合里，frame 必新鲜。
                .onPreferenceChange(FNOSCardFrameKey.self) { dict in
                    rowFrames.cardFrames[section.id] = dict
                }
            }
        }
    }

    // MARK: - 继续播放（服务端多端同步）

    /// 继续播放横向列表（ATV 版式：一屏 4 张 16:9 卡，底部进度条）
    private func resumeShelf(screenWidth: CGFloat) -> some View {
        let hPadding: CGFloat = 72
        let spacing: CGFloat = 28
        let visibleCount: CGFloat = 4
        let cardWidth = max(
            200,
            (screenWidth - hPadding * 2 - spacing * (visibleCount - 1)) / visibleCount
        )

        return VStack(alignment: .leading, spacing: 14) {
            Text("继续播放")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, hPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(resumeEntries) { entry in
                        resumeCard(entry, width: cardWidth)
                    }
                }
                .padding(.horizontal, hPadding)
                .padding(.vertical, 26)
            }
        }
    }

    private func resumeCard(_ entry: FNOSResumeEntry, width: CGFloat) -> some View {
        let item = entry.item
        let fraction = entry.fraction
        // ATV+ 版式：名称直接叠在图上；信息行 = 剧集「第N集 · 剩X分」/ 电影「剩 X小时Y分钟」
        let cardTitle: String = item.type == "Episode"
            ? (item.SeriesName ?? item.Name ?? "剧集")
            : (item.Name ?? "未命名")
        let infoText: String = {
            var parts: [String] = []
            if item.type == "Episode", let ep = item.IndexNumber {
                parts.append("第\(ep)集")
            }
            // v95：剩余时间 = 位置 × (1-f)/f 反推——绕开时长字段的单位坑；
            // 无位置时退回时长基准
            let remain: Double?
            if let pos = entry.posSeconds, fraction > 0.02 {
                remain = pos * (1 - fraction) / fraction
            } else if let runtime = entry.runtimeSeconds {
                remain = runtime * (1 - fraction)
            } else {
                remain = nil
            }
            if let remain {
                parts.append("剩 " + Self.durationCN(max(0, remain)))
            }
            return parts.joined(separator: " · ")
        }()

        return Button {
            openResume(entry: entry)
        } label: {
            ZStack(alignment: .bottomLeading) {
                FNOSAsyncImage(
                    url: client?.resumeStillURL(item: item),
                    headers: client?.mediaHeaders ?? [:],
                    usePosterCache: true
                )
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // 底部渐变（保证白字可读）
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.45),
                        .init(color: .black.opacity(0.85), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text(cardTitle)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 9) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                        // 短进度条（74pt，ATV 同款，不再是横贯全宽的粗条）
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.32))
                            Capsule().fill(Color.white).frame(width: max(2, 74 * fraction))
                        }
                        .frame(width: 74, height: 4)
                        Text(infoText)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.95))
                            .lineLimit(1)
                    }
                }
                .padding(14)
            }
        }
        .buttonStyle(.card)
        .focused($shelfCardFocused, equals: item.Id)
    }

    /// ATV 风格中文时长：1小时30分钟 / 42分钟
    private static func durationCN(_ seconds: Double) -> String {
        let total = max(1, Int((seconds / 60).rounded()))
        let h = total / 60, m = total % 60
        if h > 0 { return "\(h)小时\(m)分钟" }
        return "\(m)分钟"
    }

    /// 继续播放卡点击：本机记录按秒直续；服务端记录按比例续播（剧集单集直开，不弹选集面板）
    private func openResume(entry: FNOSResumeEntry) {
        guard let client else { return }
        let item = entry.item
        lastOpenedCardID = nil
        lastFlightCtx = nil
        print("FNOSℹ️继续播放: \(item.Name ?? "?") @\(String(format: "%.0f", entry.fraction * 100))%")
        playbackTarget = FNOSPlaybackTarget(
            item: item,
            client: client,
            userID: userID,
            seriesName: item.SeriesName,
            seriesID: item.SeriesId,
            startFraction: entry.startSeconds == nil ? entry.fraction : nil,
            startSeconds: entry.startSeconds,
            nativeItemGUID: item.nativePosterURL != nil ? item.Id : nil
        )
    }

    // MARK: - 导航（详情过渡）

    /// v92：重建「继续播放」——本机记录优先（用户正在看的），服务端多端记录随后补位。
    /// 服务端 /Sessions 上报是空壳 204（接受不入库，诊断面板证实），本机播过的必须走本地兜底才可见。
    private func rebuildResumeEntries() {
        guard let client else { return }
        Task {
            var entries: [FNOSResumeEntry] = []
            var seen = Set<String>()
            // 1) 本机记录（>30s 才上榜）：直接解码完整条目（单集自带海报/集号）——
            //    不从海报墙反查：单集不在条目池里，反查会漏掉所有剧集记录。
            //    v96：时长基准重排——播放器实测时长（ totalTime，秒，最可靠）优先，
            //    条目 ticks 归一化次之（兼容层时长 ticks 不可信，诊断证实 runtime=100/42 垃圾值）
            for p in FNOSProgressStore.localList() {
                guard seen.insert(p.item.Id).inserted, p.seconds > 30 else { continue }
                let runtime = (p.runtimeSeconds.flatMap { $0 > 60 ? $0 : nil })
                    ?? FNOSItem.plausibleSeconds(ticks: p.item.RunTimeTicks, isEpisode: p.item.type == "Episode")
                    ?? FNOSItem.secondsFromTicks(p.item.RunTimeTicks)
                let fraction = (runtime ?? 0) > 0 ? min(0.98, max(0.01, p.seconds / runtime!)) : 0
                entries.append(FNOSResumeEntry(item: p.item, fraction: fraction, startSeconds: p.seconds, runtimeSeconds: runtime, posSeconds: p.seconds))
            }
            let localCount = entries.count
            // 2) 服务端多端记录补位（其他设备的进度）。
            //    v96：时长基准优先用原生 /play/list 的 duration（秒，唯一可靠来源，
            //    按标题匹配）——兼容层 Resume 条目的 RunTimeTicks 已证实是垃圾值
            var nativeDurationByTitle: [String: Double] = [:]
            if let credentials = FNOSAuthStore.shared.credentials,
               let nativeToken = credentials.nativeToken, !nativeToken.isEmpty {
                let native = FNOSNativeClient(baseURL: credentials.serverURL, token: nativeToken)
                for rec in await native.playList() {
                    if rec.duration > 0 { nativeDurationByTitle[rec.title] = rec.duration }
                }
            }
            for item in await client.fetchResumeItems(userID: userID, limit: 6) {
                guard seen.insert(item.Id).inserted else { continue }
                let posSec = FNOSItem.secondsFromTicks(item.UserData?.PlaybackPositionTicks, lower: 5)
                let runtimeSec = nativeDurationByTitle[item.Name ?? ""]
                    ?? FNOSItem.plausibleSeconds(ticks: item.RunTimeTicks, isEpisode: item.type == "Episode")
                    ?? FNOSItem.secondsFromTicks(item.RunTimeTicks)
                var fraction = 0.0
                // v95：PlayedPercentage（服务端自算，天然一致）优先；tick 比值为兜底
                if let pct = item.UserData?.PlayedPercentage, pct > 0, pct < 100 {
                    fraction = min(0.98, max(0.01, pct / 100))
                } else if let posSec, let runtimeSec, runtimeSec > 0 {
                    fraction = min(0.98, max(0.01, posSec / runtimeSec))
                }
                entries.append(FNOSResumeEntry(item: item, fraction: fraction, startSeconds: nil, runtimeSeconds: runtimeSec, posSeconds: posSec))
            }
            let serverCount = entries.count - localCount
            FNOSDiag.shared.add("继续播放合并: 本机\(localCount) + 服务端\(serverCount) → \(min(entries.count, 6)) 条")
            // v95：前 3 条的数值基准进诊断（进度条/剩余时间争议的判决数据）
            for e in entries.prefix(3) {
                FNOSDiag.shared.add(String(
                    format: "续播条目: %@ frac=%.2f pos=%@ runtime=%@",
                    e.item.Name ?? "?",
                    e.fraction,
                    e.posSeconds.map { Int($0) }.map(String.init) ?? "-",
                    e.runtimeSeconds.map { Int($0) }.map(String.init) ?? "-"
                ))
            }
            resumeEntries = Array(entries.prefix(6))
        }
    }

    /// v96/v97：原生条目直接播放（直播频道 / MV 文件：play/info → media_guid → mpv media/range 直链）
    private func playNativeDirect(item: FNOSItem, guid: String) {
        guard let client else { return }
        lastOpenedCardID = nil
        lastFlightCtx = nil
        FNOSDiag.shared.add("原生播放: \(item.Name ?? "?") guid=\(guid.prefix(12))…")
        playbackTarget = FNOSPlaybackTarget(
            item: item,
            client: client,
            userID: userID,
            nativeItemGUID: guid
        )
    }

    /// 海报墙卡片点击：起飞行层（方案 B+ v78）。
    /// 单次 withAnimation(.spring) 是底线 —— v62~v67 用 Task.sleep 分段动画导致卡顿割裂。
    private func openCard(item: FNOSItem) {
        // 📴【搁置 · TV直播/古风MV】v98 起原生行不上墙，此分支不会触发；保留待启用。
        // 直播频道直接播；MV 目录树递归下钻找可播文件后播（resolvePlayableGUID）。
        if item.nativePosterURL != nil {
            if item.type == "LiveChannel" {
                playNativeDirect(item: item, guid: item.Id)
            } else {
                showDiag("MV 解析中…")
                guard let nativeClient else { showDiag("原生客户端未就绪"); return }
                Task {
                    if let guid = await nativeClient.resolvePlayableGUID(startGUID: item.Id) {
                        await MainActor.run {
                            showDiag("MV 就绪：\(item.Name ?? "?")")
                            playNativeDirect(item: item, guid: guid)
                        }
                    } else {
                        await MainActor.run { showDiag("MV 未找到可播放文件") }
                    }
                }
            }
            return
        }
        guard let client else {
            print("FNOS❗️客户端未初始化，无法打开详情")
            return
        }
        let flightResult = buildFlightContext(item: item, client: client)
        guard let ctx = flightResult.ctx else {
            // 找不到行/frame：退化直出详情保证不卡死；屏显原因（v81 诊断，真机无控制台）
            print("FNOS❗️未取到飞行上下文(\(flightResult.reason))，退化直出详情: \(item.Name ?? "?")")
            showDiag("⚠️退化直出：\(flightResult.reason)")
            openDetailDirect(item: item)
            return
        }
        // v83：✓起跳诊断 toast 已撤（动画链路已验收）；⚠️退化直出的失败路径诊断保留
        lastOpenedCardID = item.Id
        lastFlightCtx = ctx   // v82：Menu 反向缩回需要起跳时的同一份几何上下文
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            flight = ctx
        }
        // 落地时序（与弹簧 0.45s 对齐）：
        // 0.46s → present 详情页 cover，抑制其动画（fullScreenCover 默认会滑入 → 跳位）。
        //          cover 的 Hero（全屏横图）与飞行层终点同位同尺寸 → 零跳位。
        // 0.74s → 移除飞行层（cover 已全屏接管，位于飞行层之上）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) {
            guard flight?.item.Id == item.Id else { return }
            var tx = Transaction()
            tx.animation = nil
            withTransaction(tx) { detailItem = item }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.74) {
            guard flight?.item.Id == item.Id else { return }
            flight = nil
        }
        print("FNOSℹ️详情过渡起跳: \(item.Name ?? "?")")
    }

    /// 构造飞行上下文：定位条目所在行，取焦点卡 frame，组装行副本数据。
    /// v81：frame 来源改双层——「卡片级实时捕获为主 + 行级推算兜底」，并返回失败原因
    /// （真机无控制台，退化直出时屏显诊断）。v80 实测真机恒退化直出（动画消失），
    /// 主嫌疑是行级 LazyHStack background preference 不触发 → 行 frame 永远缺失；
    /// 而卡片级 background GeometryReader 在点按瞬间必然已上报（焦点卡必可见）。
    private func buildFlightContext(item: FNOSItem, client: FNOSDirectClient) -> (ctx: FNOSDetailFlightContext?, reason: String) {
        guard let section = sections.first(where: { $0.items.contains(where: { $0.Id == item.Id }) }) else {
            return (nil, "未找到所在行")
        }
        guard let rowIndex = section.items.firstIndex(where: { $0.Id == item.Id }) else {
            return (nil, "行内无下标")
        }
        // 主来源：卡片级实时 frame（含水平滚动偏移，最新鲜）
        let cardFrame = rowFrames.cardFrames[section.id]?[item.Id]
        // 兜底：行内容 frame + 下标推算（v78 原逻辑；行级 preference 真机疑似不触发）
        var computed: CGRect?
        if let contentFrame = rowFrames.frames[section.id], contentFrame != .zero,
           let tileW = rowFrames.tileWidths[section.id] {
            computed = CGRect(
                x: contentFrame.minX + CGFloat(rowIndex) * (tileW + 28),
                y: contentFrame.minY,
                width: tileW,
                height: tileW * 1.5
            )
        }
        guard let focusFrame = cardFrame ?? computed, focusFrame != .zero,
              let tileWidth = rowFrames.tileWidths[section.id] ?? cardFrame.map({ $0.width }) else {
            let hasRow = rowFrames.frames[section.id] != nil
            let hasTile = rowFrames.tileWidths[section.id] != nil
            let hasCard = cardFrame != nil
            return (nil, "帧缺失 row=\(hasRow) tile=\(hasTile) card=\(hasCard)")
        }
        return (FNOSDetailFlightContext(
            item: item,
            client: client,
            userID: userID,
            rowSectionID: section.id,
            rowItems: section.items,
            focusIndex: rowIndex,
            tileWidth: tileWidth,
            spacing: 28,
            hPadding: 72,
            focusCardFrame: focusFrame
        ), cardFrame != nil ? "card-frame" : "row-frame")
    }

    /// Hero 详情入口（无卡片可起跳，直接出详情页，不走飞行动画）
    private func openDetailDirect(item: FNOSItem) {
        detailItem = item
        lastOpenedCardID = nil
        lastFlightCtx = nil   // 无卡片几何 → Menu 走系统默认收场，不做反向缩回
    }

    /// 详情 cover 关闭（系统 Menu 已把 detailItem 置 nil）：只负责清飞行层 + 还焦点。
    /// v80 关键修复：cover dismiss 动画（约 0.4s）进行中焦点引擎会重建焦点，
    /// 单发 asyncAfter(0.18)（Demo 校准值，Demo 无 present 生命周期）落在动画中
    /// 会被吞掉 → 高概率返回后无焦点环 / 首次按遥控乱跳。改为多次兜底：
    /// 已落位则跳过（幂等）；用户已开新过渡或新导航则停止，不与用户抢焦点。
    private func closeDetail() {
        // v82：反向飞行进行中时不清 flight（overlay 正在播缩回动画，0.55s 后自撤）
        if flight?.isReverse != true { flight = nil }
        guard let returning = lastOpenedCardID else { return }
        for delay in [0.1, 0.3, 0.6, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard flight == nil, detailItem == nil, lastOpenedCardID == returning else { return }
                if shelfCardFocused != returning { shelfCardFocused = returning }
            }
        }
    }

    /// v82：详情页 Menu 的关闭入口（cover 内容内 onExitCommand，可靠——Demo 同款已真机验证；
    /// v77 的失败是「嵌入非呈现视图」场景，与此不同）。有卡片来源 → 反向飞行：
    /// 横图全屏单段弹簧缩回卡片 + 行副本 3→1 + 压暗淡出（对齐 Demo 反向缩回）；
    /// Hero 来源（无卡片几何可缩）→ 系统默认 dismiss 动画普通收场。
    private func closeDetailWithReverse() {
        guard let src = lastFlightCtx, detailItem != nil else {
            detailItem = nil
            return
        }
        let rev = FNOSDetailFlightContext(
            item: src.item,
            client: src.client,
            userID: src.userID,
            rowSectionID: src.rowSectionID,
            rowItems: src.rowItems,
            focusIndex: src.focusIndex,
            tileWidth: src.tileWidth,
            spacing: src.spacing,
            hPadding: src.hPadding,
            focusCardFrame: src.focusCardFrame,
            isReverse: true
        )
        // cover 瞬时消失 + 反向飞行层同帧接管（同一事务，无闪白）；
        // overlay 内部先渲染全屏一帧，50ms 后单段弹簧缩回（与正向同一根弹簧）
        var tx = Transaction()
        tx.animation = nil
        withTransaction(tx) {
            detailItem = nil
            flight = rev
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard flight?.isReverse == true else { return }
            flight = nil
        }
    }

    /// 飞行层期间按 Menu：取消过渡（此时详情 cover 尚未 present）。
    private func cancelFlight() {
        withAnimation(.easeOut(duration: 0.2)) { flight = nil }
        if let returning = lastOpenedCardID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                shelfCardFocused = returning
            }
        }
    }

    /// v81 屏显诊断 toast：真机无控制台，用短命 toast 区分「退化直出」与「已起跳」。
    private func showDiag(_ msg: String, duration: Double = 2.5) {
        diagToken += 1
        let token = diagToken
        diagMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if diagToken == token { diagMessage = nil }
        }
    }

    /// 过渡动画 Demo 的真实电影池：全部媒体库条目去重，取前 6 部（有海报图）
    private var demoPool: [FNOSItem] {
        var seen = Set<String>()
        return sections
            .flatMap(\.items)
            .filter { $0.ImageTags?["Primary"] != nil && seen.insert($0.Id).inserted }
            .prefix(6)
            .map { $0 }
    }

    /// Hero 播放入口：直接开始播放，不经过详情页
    private func playDirectly(item: FNOSItem) {
        if item.type == "Series" {
            seriesItem = item
        } else {
            openPlayback(item: item)
        }
    }

    private func openPlayback(item: FNOSItem, startFraction: Double? = nil) {
        guard let client else {
            print("FNOS❗️客户端未初始化，无法播放")
            return
        }
        playbackTarget = FNOSPlaybackTarget(item: item, client: client, userID: userID, startFraction: startFraction)
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
                    // v89：HTTP 级失败也进诊断（此前只埋了解析分支，古风mv 这类无痕消失就是漏在这）
                    FNOSDiag.shared.add("「\(library.Name ?? "?")」加载失败: \(error.localizedDescription)", dedupeKey: "load.\(library.Id)")
                    loaded.append(FNOSLibrarySection(library: library, items: []))
                }
                sections = loaded
            }

            // 📴【搁置 · TV直播/古风MV · v98 · 2026-11-04】数据行暂不上墙，原因与现状：
            //   - 数据通道已通：X-Trim-Client 头修复权限后，TV直播 81 频道 / MV 文件条目
            //     均可经原生 item/list + ancestor_guid 拉取（诊断「原生库…N 条」可证）
            //   - 直播播放未通：play/info(频道guid)→media_guid→media/range 直链 mpv 起播
            //     失败（诊断「原生播放: CCTV-9…」有行无画面），疑直播源中继不支持 range
            //     拉流，或需专用 live 播放端点——待抓飞牛自家播放器的直播流请求再接
            //   - MV 播放：目录树递归下钻已实现（resolvePlayableGUID，parent_guid 逐层
            //     + play/info 探测），最深层文件 guid 的 play/info 返回 -6 Not Found，
            //     需再探文件型条目的正确 guid 形态
            // 重新启用步骤：解开下方两行调用即可——全部关联代码保留未删：
            //   loadNativeSections / listByAncestor / listItemChildren / resolvePlayableGUID /
            //   playNativeDirect / openCard 原生分支 / FNOSPlaybackTarget.nativeItemGUID /
            //   容器 mpvLayer 原生分支 / FNOSPosterTile.nativePosterURL
            // await loadNativeSections(into: &loaded, libraries: libraries)
            // sections = loaded

            isLoading = false
            rollHeroIfNeeded()
            // Hero 快照只在此处（bootstrap / 下拉刷新）生成一次
            refreshHeroSnapshot()
            // 继续播放（v91：服务端 + 本机记录合并；只展示最近 6 条，ATV 版式）
            rebuildResumeEntries()
        } catch {
            isLoading = false
            print("FNOS❗️加载媒体库失败: \(error)")
        }
    }

    /// 📴【搁置 · TV直播/古风MV】v95 原生库数据行——v98 起调用点已注释（见 bootstrap
    /// 内搁置标记），本函数与全部关联代码保留，解开调用即恢复。
    /// 库定位用兼容层 /Views 的名称匹配（其 Id == 原生 ancestor_guid，探测证实）。
    @MainActor
    private func loadNativeSections(into loaded: inout [FNOSLibrarySection], libraries: [FNOSLibrary]) async {
        guard let credentials = FNOSAuthStore.shared.credentials,
              let nativeToken = credentials.nativeToken, !nativeToken.isEmpty else { return }
        let native = FNOSNativeClient(baseURL: credentials.serverURL, token: nativeToken)
        nativeClient = native
        let targets: [(keyword: String, label: String)] = [
            ("直播", "TV直播"),
            ("MV", "古风热歌MV"),
        ]
        for target in targets {
            guard let lib = libraries.first(where: {
                ($0.Name ?? "").contains(target.keyword) ||
                ($0.Name ?? "").lowercased().contains(target.keyword.lowercased())
            }) else {
                FNOSDiag.shared.add("原生库「\(target.label)」未在 /Views 找到", dedupeKey: "nlib.\(target.label)")
                continue
            }
            // compat 行有数据就不需要原生（正常不该发生：兼容层对这两类库返回空）
            if let existing = loaded.first(where: { $0.id == lib.Id }), !existing.items.isEmpty { continue }
            let natives = await native.listByAncestor(ancestorGUID: lib.Id, pageSize: 60)
            let items: [FNOSItem] = natives.compactMap { li -> FNOSItem? in
                let cleanTitle = li.title
                    .replacingOccurrences(of: ".mp4", with: "")
                    .replacingOccurrences(of: ".mkv", with: "")
                guard !cleanTitle.isEmpty else { return nil }
                let poster = native.posterImageURL(posterPath: li.posterPath)?.absoluteString
                return FNOSItem(
                    Id: li.guid,
                    Name: cleanTitle,
                    ItemType: li.type,
                    ProductionYear: nil,
                    Overview: nil,
                    ImageTags: nil,
                    BackdropImageTags: nil,
                    RunTimeTicks: li.durationSeconds.map { Int64($0 * 1_000_000) },
                    OfficialRating: nil,
                    Genres: nil,
                    ParentIndexNumber: nil,
                    IndexNumber: nil,
                    PremiereDate: nil,
                    SeriesName: nil,
                    People: nil,
                    UserData: nil,
                    SeriesId: nil,
                    nativePosterURL: poster
                )
            }
            loaded.append(FNOSLibrarySection(library: lib, items: items))
            FNOSDiag.shared.add("原生库「\(target.label)」\(items.count) 条")
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
            if envelope.Items.isEmpty {
                // v87：LiveTV（电视直播）/特殊库类型在 /Items?ParentId 下常为空。
                // 服务端原始返回进诊断面板（设置里可见），据此决定接哪个专用端点。
                let raw = String(data: data.prefix(300), encoding: .utf8) ?? "(非文本)"
                print("FNOS⚠️「\(library.Name ?? "?")」返回 0 条（可能为 LiveTV/特殊库类型，需专用端点支持）")
                FNOSDiag.shared.add("「\(library.Name ?? "?")」0条 raw=\(raw)", dedupeKey: "empty.\(library.Id)")
            }
            return envelope.Items
        } catch {
            let raw = String(data: data.prefix(400), encoding: .utf8) ?? "(非文本)"
            print("FNOS❗️解析 /Items 失败: \(error) 原文: \(raw)")
            FNOSDiag.shared.add("「\(library.Name ?? "?")」解析失败 raw=\(raw)", dedupeKey: "decode.\(library.Id)")
            throw FNOSDirectError("解析 /Items 失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - 首页设置面板（刷新媒体库 / 退出登录 / 版本信息）

struct FNOSHomeSettingsView: View {

    let onRefresh: () -> Void
    let onLogout: () -> Void
    /// 过渡动画 Demo 数据（真实电影：真海报 + 预取横图）
    var demoClient: FNOSDirectClient? = nil
    var demoItems: [FNOSItem] = []

    @Environment(\.dismiss) private var dismiss

    // Hero 图源：backdrop（横图，默认）/ primary（海报）
    // 若发现某些电影 Hero 图文对不上，多为飞牛刮削把 Backdrop 挂错条目，切到海报可规避。
    @AppStorage("fnos.hero.imageSource") private var heroImageSource = "backdrop"

    // 杜比视界按 HDR10 输出（规避紫绿偏色）
    @AppStorage("fnos.play.hdr10Compat") private var hdr10Compat = true

    // v91 全屏诊断入口
    @State private var showDiagFull = false

    // 播放器引擎：默认 KSPlayer；开启后走 mpv（MPVUI），用于杜比视界 P5 的色彩转换
    @AppStorage("fnos.play.engineMPV") private var engineMPV = false
    // 自动分流：KSPlayer 处理不了的片源（杜比视界 / AV1）自动切 mpv
    @AppStorage("fnos.play.autoEngine") private var autoEngine = true

    // 弹幕外观（与播放器内「弹幕设置」共用同一批键）
    @AppStorage("fnos.danmu.fontSize") private var danmuFontSize: Double = 26
    @AppStorage("fnos.danmu.speed") private var danmuSpeed: Double = 1
    @AppStorage("fnos.danmu.opacity") private var danmuOpacity: Double = 1
    @AppStorage("fnos.danmu.offsetY") private var danmuOffsetY: Double = 0

    // 过渡动画 Demo（验证 matchedGeometryEffect 在真机上的顺滑度，确认后再决定是否集成到海报墙）
    @State private var showTransitionDemo = false

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
                        FNOSSettingRow(
                            title: "过渡动画 Demo（实验）",
                            systemImage: "wand.and.stars"
                        ) {
                            showTransitionDemo = true
                        }
                    }

                    section(
                        "诊断信息（真机无控制台）",
                        footer: "遇到「继续播放没记录 / 某媒体库没数据」时，打开全屏诊断整屏截图发给开发者。"
                    ) {
                        FNOSSettingRow(
                            title: "打开全屏诊断（整屏截图用）",
                            systemImage: "stethoscope"
                        ) {
                            showDiagFull = true
                        }
                        .fullScreenCover(isPresented: $showDiagFull) {
                            FNOSDiagView()
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
            .fullScreenCover(isPresented: $showTransitionDemo) {
                FNOSHeroTransitionDemo(client: demoClient, items: demoItems)
            }
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

/// 纯海报瓦片：不显示标题/年份。v85 起焦点视觉（液态玻璃 + 抬升）
/// 全权交给 Button 的系统 .card 样式（与 Demo 同款，用户点名），
/// 自绘的描边/阴影/放大在此版拆除——叠在系统玻璃上会双重高亮。
fileprivate struct FNOSPosterTile: View {

    let item: FNOSItem
    let client: FNOSDirectClient?
    let width: CGFloat
    /// 保留入参以兼容既有调用点；焦点视觉已由 .card 接管（当前未使用）
    let isFocused: Bool
    /// v95 原生条目直通海报（TV直播/古风MV；nil = 走 compat posterURL）
    var nativePosterURL: String? = nil
    var nativeHeaders: [String: String]? = nil

    private var height: CGFloat { width * 3 / 2 }
    private var cornerRadius: CGFloat { 14 }

    private var posterURL: URL? {
        if let nativePosterURL, !nativePosterURL.isEmpty {
            return URL(string: nativePosterURL)
        }
        return client?.posterURL(itemID: item.Id, tag: item.ImageTags?["Primary"])
    }

    private var posterHeaders: [String: String] {
        // v96 修复：头跟 URL 走——compat 条目用 compat 头（此前无条件传原生 Authx 头
        // 导致整面海报 401 丢失）；仅原生直通条目用 sys/img 头
        if let nativePosterURL, !nativePosterURL.isEmpty {
            return nativeHeaders ?? [:]
        }
        return client?.mediaHeaders ?? [:]
    }

    var body: some View {
        FNOSAsyncImage(
            url: posterURL,
            headers: posterHeaders,
            usePosterCache: true
        )
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
                headers: client?.mediaHeaders ?? [:],
                usePosterCache: true
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



// MARK: - 过渡动画 Demo v3（真图 + 同行海报参与进出场，对齐 Apple TV 参考行为）
//
// v3 对齐参考的三个关键点：
// 1. 起跳的不是海报：点按瞬间卡片位置切换为预取好的详情横图（1920 Backdrop），
//    matchedGeometryEffect 从卡片位置放大到全屏 —— 海报在同一事务里淡出（参考逐帧结论）
// 2. 同一行其他海报参与动画：详情打开时当前行以焦点卡为锚点整体放大，
//    其他卡被推出屏幕外；返回时反向缩回
// 3. 焦点预取：焦点落到卡片即预取横图进内存缓存，点按起跳必高清
//
// v2 返回失败根因：详情关闭后焦点引擎不会自动把焦点还给刚解除 disabled 的海报行，
// 焦点悬空，再按 Menu 走系统默认行为直接 dismiss 整个 Demo。
// 修复：关闭后显式把焦点还给来源卡片；详情层焦点多次兜底。

struct FNOSHeroTransitionDemo: View {

    let client: FNOSDirectClient?
    let items: [FNOSItem]

    @Namespace private var ns
    @State private var selected: FNOSItem?
    @State private var infoVisible = false
    @FocusState private var cardFocused: String?
    @FocusState private var playFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var rows: [[FNOSItem]] {
        [Array(items.prefix(3)), Array(items.dropFirst(3).prefix(3))]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 56) {
                shelfRow(row: 0)
                shelfRow(row: 1)
                Spacer()
            }
            .padding(.top, 70)
            // 详情打开时整页海报行禁用（焦点必须转移到详情层）
            .disabled(selected != nil)

            if let item = selected {
                detailOverlay(item)
                    .zIndex(10)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if selected == nil { cardFocused = items.first?.Id }
            }
            // 全量预取横图（6 张，点按起跳必高清）
            for item in items { prefetchBackdrop(item) }
        }
        .onChange(of: cardFocused) { _, focused in
            if let focused, let item = items.first(where: { $0.Id == focused }) {
                prefetchBackdrop(item)
            }
        }
        // 详情未打开时按 Menu = 退出 Demo
        .onExitCommand {
            if selected == nil { dismiss() }
        }
    }

    // MARK: 海报行（详情打开时：当前行以焦点卡为锚点整体放大，其他卡推出屏幕外）

    private func shelfRow(row: Int) -> some View {
        let rowItems = row < rows.count ? rows[row] : []
        let selIndex = selected.flatMap { s in items.firstIndex(where: { $0.Id == s.Id }) }
        let isActive = selIndex != nil && selIndex! / 3 == row
        let anchor: UnitPoint = {
            guard let idx = selIndex, idx / 3 == row, !rowItems.isEmpty else { return .center }
            let col = idx % 3
            return UnitPoint(x: (CGFloat(col) + 0.5) / 3, y: 0.5)
        }()

        return VStack(alignment: .leading, spacing: 20) {
            Text("演示片单 · \(row + 1)")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 90)

            HStack(spacing: 34) {
                ForEach(rowItems) { item in
                    cardButton(item)
                }
            }
            .padding(.horizontal, 90)
            // 同行整体放大（参考：焦点卡以外的同行卡片一起被放大推出屏幕外；返回反向缩回）
            .scaleEffect(isActive ? 3.0 : 1.0, anchor: anchor)
        }
    }

    private func cardButton(_ item: FNOSItem) -> some View {
        Button {
            open(item)
        } label: {
            Group {
                if selected?.Id == item.Id {
                    // 该卡起跳中：海报占位隐藏，让位给详情层的横图 matched 视图
                    cardPoster(item).opacity(0)
                } else {
                    cardPoster(item)
                        .matchedGeometryEffect(id: item.Id, in: ns)
                }
            }
            .frame(width: 300, height: 450)
        }
        .buttonStyle(.card)
        .focused($cardFocused, equals: item.Id)
    }

    // 卡片海报（竖版 Primary）
    private func cardPoster(_ item: FNOSItem) -> some View {
        FNOSAsyncImage(
            url: client?.posterURL(itemID: item.Id, tag: item.ImageTags?["Primary"]),
            headers: client?.mediaHeaders ?? [:],
            usePosterCache: true
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 详情覆盖层（放大层内容 = 预取的详情横图，起跳即高清）

    private func detailOverlay(_ item: FNOSItem) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Color.black.ignoresSafeArea()

                // 放大层：从卡片位置（matched 起点）连续插值到顶部 16:9 全屏
                FNOSAsyncImage(
                    url: backdropURL(for: item),
                    headers: client?.mediaHeaders ?? [:],
                    contentMode: .fill
                )
                .matchedGeometryEffect(id: item.Id, in: ns)
                .frame(width: geo.size.width, height: geo.size.width * 9 / 16)
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)

                // 底部渐变 + 信息层（延迟淡入，独立于几何插值）
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.4),
                        .init(color: .black.opacity(0.9), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(infoVisible ? 1 : 0)
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 20) {
                    Text(item.Name ?? "未命名")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundColor(.white)

                    HStack(spacing: 14) {
                        if let year = item.ProductionYear { Text(String(year)) }
                        if let genres = item.Genres, !genres.isEmpty {
                            Text(genres.prefix(2).joined(separator: " · "))
                        }
                    }
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.85))

                    Text("Demo v3 —— 按 Menu 键返回")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.55))

                    Button {
                        // Demo 占位
                    } label: {
                        Text("立即播放")
                            .font(.system(size: 24, weight: .semibold))
                    }
                    .buttonStyle(.card)
                    .focused($playFocused)
                }
                .padding(90)
                .opacity(infoVisible ? 1 : 0)
                .offset(y: infoVisible ? 0 : 16)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // 焦点立即落 + 两次兜底（防插入动画期间设置丢失 → Menu 失灵）
            playFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                withAnimation(.easeOut(duration: 0.35)) { infoVisible = true }
                playFocused = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                playFocused = true
            }
        }
        // 按 Menu = 关闭详情（此时海报行 disabled，焦点必在本层）
        .onExitCommand { close() }
    }

    // MARK: 横图 URL 与预取

    private func backdropURL(for item: FNOSItem) -> URL? {
        guard let client else { return nil }
        if let tag = item.BackdropImageTags?.first, !tag.isEmpty,
           let url = try? client.url(
               path: "Items/\(item.Id)/Images/Backdrop",
               query: ["maxWidth": "1920", "quality": "90", "tag": tag]
           ) {
            return url
        }
        // 无横图退高清海报
        if let tag = item.ImageTags?["Primary"], !tag.isEmpty,
           let url = try? client.url(
               path: "Items/\(item.Id)/Images/Primary",
               query: ["maxWidth": "1280", "quality": "90", "tag": tag]
           ) {
            return url
        }
        return nil
    }

    /// 预取横图进共享内存缓存（FNOSAsyncImage 命中缓存即秒显）
    private func prefetchBackdrop(_ item: FNOSItem) {
        guard let url = backdropURL(for: item) else { return }
        let key = url.absoluteString as NSString
        guard FNOSImageCache.shared.memory.object(forKey: key) == nil else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (field, value) in client?.mediaHeaders ?? [:] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            FNOSImageCache.shared.memory.setObject(image, forKey: key)
        }.resume()
    }

    // MARK: 打开 / 关闭

    private func open(_ item: FNOSItem) {
        infoVisible = false
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            selected = item
        }
    }

    private func close() {
        let returning = selected?.Id
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            infoVisible = false
            selected = nil
        }
        // 关键修复：焦点显式还给来源卡片（等海报行恢复 enabled 后再设）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let returning { cardFocused = returning }
        }
    }
}

// MARK: - 详情过渡飞行层（方案 B+ v78：核心缩放 + 同行推出）
//
// v75/v76 实装失败的三座大山（垂直 ScrollView 裁剪 / LazyHStack 懒加载空洞 / 焦点泄漏）
// 全是因为动画放在主页容器【内部】。本飞行层放在 FNOSMainView 顶层 ZStack（ScrollView 之外），
// 所以：
//   - 起跳横图（matched B 端）从卡片位置插值到全屏，不受任何 ScrollView 裁剪；
//   - 同行推出（行副本 scale 3.0）也在飞行层内，不触发 LazyHStack 懒加载空洞；
//   - 主页在该层下方整体 .disabled(true)，焦点不可能漏进被盖住的元素。
//
// 为什么不用截图（方案 B 原案）：
//   截图里卡片位置是【竖版海报】，放大 4.8 倍会糊、且违背「起跳即横图」铁律；
//   全屏不透明截图会遮死「同行推出」。故改用【压暗背景 + live 飞行层】——
//   既遮住裁剪/空洞/焦点，又让起跳内容是真正的 1920 横图。
//
// 终点（方案甲）：飞行层横图终点 = 全屏 = 真实详情页 Hero 的同位同尺寸（见 FNOSItemDetailView
//   heroSection: frame(width: size.width, height: size.height)）。落地才 present 详情 cover，
//   cover 的 Hero 与飞行层终点同位同尺寸 → 零跳位（cover-at-land，v78 修 Menu 退桌面）。
//
// 同行推出：行副本 = 焦点卡 ±3 张的 HStack（非懒），scale 1→3 锚定焦点卡中心。
//   真实行的窗口卡 opacity 0（交给副本），避免与副本重影；远端的卡保持可见（被压暗）。
//   行副本位置用「行内容 frame + 焦点下标」算出（FNOSRowFrameStore，含水平滚动偏移）。

struct FNOSDetailFlightContext {
    /// 行副本窗口半径（焦点卡 ±N 张）。飞行层 window 与主页 isInFlightWindow
    /// 必须同宽（重影/空洞都从两处硬编码不同步来），故收敛为单一常量。
    /// v80 由 ±3 放宽到 ±6：1920 宽下一张卡占 ~300pt，焦点两侧可见 ≤3.2 张，
    /// ±6 留足余量；窗口外的静止原卡在 scale 1.0 时已全部出屏，观感接近 Demo 整行推出。
    static let windowHalf = 6

    let item: FNOSItem
    let client: FNOSDirectClient?
    let userID: String
    /// 条目所在行的 section.id（窗口卡隐藏判断用）
    let rowSectionID: String?
    /// 该行全部条目（行副本数据源）
    let rowItems: [FNOSItem]
    /// 焦点卡在 rowItems 里的下标
    let focusIndex: Int
    /// 卡片布局参数（与 shelf() 完全一致，副本才能 1:1 对齐）
    let tileWidth: CGFloat
    let spacing: CGFloat
    let hPadding: CGFloat
    /// 焦点卡全局 frame（行内容 frame + 下标算出，含水平滚动偏移）
    let focusCardFrame: CGRect
    /// v82：false=正向起跳（matched 卡片→全屏）；true=反向缩回（显式 frame 全屏→卡片）
    var isReverse: Bool = false
}

/// 行内容 frame 存储（非响应式：滚动只写不触发重渲染，避免海报墙掉帧）
final class FNOSRowFrameStore {
    var frames: [String: CGRect] = [:]        // section.id -> LazyHStack 内容 frame（全局）
    var tileWidths: [String: CGFloat] = [:]   // section.id -> tileWidth
    // v81：卡片级实时捕获（section.id -> [item.Id: 卡片全局 frame]）。
    // 行级 background preference 在真机上疑似不触发（v80 实测恒退化直出），
    // 而焦点卡点按瞬间必然可见、其卡片级 GeometryReader 必然已上报——最可靠来源。
    var cardFrames: [String: [String: CGRect]] = [:]
}

/// 行内容 frame 的 preference key
struct FNOSRowContentFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// v81 卡片级 frame 的 preference key：每张可见卡上报 [item.Id: 全局 frame]，
/// reduce 合并为整行可见卡的字典。焦点卡点按瞬间必然可见 → frame 必然存在。
struct FNOSCardFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct FNOSDetailFlightOverlay: View {

    let ctx: FNOSDetailFlightContext
    let ns: Namespace.ID

    @State private var infoVisible = false
    @State private var rowScale: CGFloat
    /// v82 反向：false=全屏起始（未缩回），true=已缩回卡片（frame/圆角/压暗随之动画）
    @State private var reverseDone: Bool
    @State private var revRadius: CGFloat

    init(ctx: FNOSDetailFlightContext, ns: Namespace.ID) {
        self.ctx = ctx
        self.ns = ns
        // v82：初值由方向决定——正向从 1 起跳、反向从 3 缩回。
        // 状态初值直接给对，避免「插入事务把首帧合并成终值」这类时序坑
        // （Demo 缩的是已在树中的真实行，不存在插入时序问题；飞行层是新插入视图）。
        _rowScale = State(initialValue: ctx.isReverse ? 3.0 : 1.0)
        _reverseDone = State(initialValue: false)
        _revRadius = State(initialValue: ctx.isReverse ? 0 : 14)
    }

    /// 起跳横图：1920 Backdrop 优先，无横图退 1280 Primary（与 Demo backdropURL 一致）
    private var backdropURL: URL? {
        guard let client = ctx.client else { return nil }
        if let tag = ctx.item.BackdropImageTags?.first, !tag.isEmpty,
           let url = try? client.url(
               path: "Items/\(ctx.item.Id)/Images/Backdrop",
               query: ["maxWidth": "1920", "quality": "90", "tag": tag]
           ) {
            return url
        }
        if let tag = ctx.item.ImageTags?["Primary"], !tag.isEmpty,
           let url = try? client.url(
               path: "Items/\(ctx.item.Id)/Images/Primary",
               query: ["maxWidth": "1280", "quality": "90", "tag": tag]
           ) {
            return url
        }
        return nil
    }

    /// 行副本窗口：焦点卡 ±windowHalf 张（至少含焦点卡本身），与主页隐藏窗口同宽
    private var window: [FNOSItem] {
        let items = ctx.rowItems
        guard !items.isEmpty else { return [] }
        let lo = max(0, ctx.focusIndex - FNOSDetailFlightContext.windowHalf)
        let hi = min(items.count - 1, ctx.focusIndex + FNOSDetailFlightContext.windowHalf)
        return Array(items[lo...hi])
    }

    /// 焦点卡在窗口内的列下标
    private var focusColInWindow: Int {
        let lo = max(0, ctx.focusIndex - FNOSDetailFlightContext.windowHalf)
        return ctx.focusIndex - lo
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 压暗背景：整页 0.35（ATV 式）。主页在其下方保持可见、只被压暗不隐藏。
                // v82 反向：缩回时压暗同步淡出（同一弹簧事务）
                Color.black.opacity(ctx.isReverse ? (reverseDone ? 0.0 : 0.35) : 0.35)
                    .ignoresSafeArea()

                // 同行推出副本：scale 1→3 锚定焦点卡中心（焦点卡中心屏幕坐标不变）
                rowReplica(in: geo)

                // 起跳/缩回横图。正向（B 端）：matched 从卡片位置单段弹簧插值到全屏。
                // v82 反向：cover 的 Hero 与主树不共享命名空间，matched 配不上对，
                // 改显式 frame/position/圆角插值：全屏 → 焦点卡 frame（同一根弹簧）。
                // 单段连续动画是底线（v62~v67 分段 Task.sleep = 卡顿割裂，禁用）。
                if ctx.isReverse {
                    FNOSAsyncImage(
                        url: backdropURL,
                        headers: ctx.client?.mediaHeaders ?? [:],
                        contentMode: .fill
                    )
                    .frame(
                        width: reverseDone ? ctx.focusCardFrame.width : geo.size.width,
                        height: reverseDone ? ctx.focusCardFrame.height : geo.size.height
                    )
                    .clipShape(RoundedRectangle(cornerRadius: revRadius, style: .continuous))
                    .position(
                        x: reverseDone ? ctx.focusCardFrame.midX : geo.size.width / 2,
                        y: reverseDone ? ctx.focusCardFrame.midY : geo.size.height / 2
                    )
                } else {
                    FNOSAsyncImage(
                        url: backdropURL,
                        headers: ctx.client?.mediaHeaders ?? [:],
                        contentMode: .fill
                    )
                    .matchedGeometryEffect(id: ctx.item.Id, in: ns)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                }

                // 底部渐变 + 信息层（延迟 0.3s 独立淡入，不参与几何插值）
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.4),
                        .init(color: .black.opacity(0.9), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(infoVisible ? 1 : 0)
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 20) {
                    Text(ctx.item.Name ?? "未命名")
                        .font(.system(size: 62, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 14) {
                        if let year = ctx.item.ProductionYear { Text(String(year)) }
                        if let genres = ctx.item.Genres, !genres.isEmpty {
                            Text(genres.prefix(2).joined(separator: " · "))
                        }
                    }
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.85))
                }
                .padding(90)
                .opacity(infoVisible ? 1 : 0)
                .offset(y: infoVisible ? 0 : 16)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            if ctx.isReverse {
                // v82 反向：先以「全屏横图 + scale3 + 压暗」渲染一帧（cover 消失的同帧
                // 接管，无闪白），50ms 后单段弹簧缩回——与正向同一根弹簧，视觉语言一致
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                        reverseDone = true
                        rowScale = 1.0
                        revRadius = 14
                    }
                }
            } else {
                // ⏸️【搁置标记 · 2026-11-04】进入方向「同行推出」真机仍不可见（用户决定搁置）。
                // v80~v84 已排除项，恢复时勿重复：
                //   ①插入默认 .opacity 过渡吞副本 → v83 .transition(.identity) 已修，无效
                //   ②插入事务合并首帧即 3.0 → v82 asyncAfter(0.05) 已修，无效
                //   ③副本锚点坐标系错误（.position 占满全屏）→ v80 已修，无效
                //   ④同速弹簧相对运动≈0 → v84 提速 0.26，真机仍不可见（未验收通过）
                // 下一步候选方向：
                //   A. 飞行期间把真实行整体 scale（需解决垂直 ScrollView 裁剪/懒加载/焦点三山）
                //   B. 详情 cover 内复刻行副本背景（浏览详情时行也在背后，Demo 终形态）
                // 反向缩回（rowScale 3→1）真机已验收可见，勿动。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        rowScale = 3.0
                    }
                }
                // 信息层延迟淡入：单段连续动画
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                    withAnimation(.easeOut(duration: 0.35)) { infoVisible = true }
                }
            }
        }
    }

    // MARK: 同行推出副本

    private func rowReplica(in geo: GeometryProxy) -> some View {
        let win = window
        let n = CGFloat(win.count)
        let tileW = ctx.tileWidth
        let tileH = tileW * 1.5
        let spacing = ctx.spacing
        // 副本 HStack 宽（无左右 padding，位置由 .position 绝对定位）
        let hW = n * tileW + (n - 1) * spacing
        // 焦点卡中心在副本内的 x（从副本左边缘起）
        let focusCX = CGFloat(focusColInWindow) * (tileW + spacing) + tileW / 2
        let posX = ctx.focusCardFrame.midX - focusCX + hW / 2
        let posY = ctx.focusCardFrame.midY

        // v80 关键修复：.position 的包装视图会填满父级（全屏），其后挂的
        // .scaleEffect 的 anchor 按【全屏 bounds】解析，不是副本自身 hW×tileH
        // 的 bounds。旧代码用 focusCX/hW（副本内部占比）+ y:0.5（屏幕中心）作锚，
        // 参照系整体错误 → 缩放时焦点卡中心漂移、邻居推出方向/幅度全错，
        // 表现为「同行其他海报不像 Demo 一样参与动画」。正确锚点 =
        // 焦点卡真实屏幕中心（focusCardFrame 中心）占全屏的比例。
        let anchor = UnitPoint(
            x: ctx.focusCardFrame.midX / geo.size.width,
            y: ctx.focusCardFrame.midY / geo.size.height
        )

        return HStack(spacing: spacing) {
            ForEach(win) { w in
                FNOSAsyncImage(
                    url: ctx.client?.posterURL(itemID: w.Id, tag: w.ImageTags?["Primary"]),
                    headers: ctx.client?.mediaHeaders ?? [:],
                    usePosterCache: true
                )
                .frame(width: tileW, height: tileH)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(width: hW, height: tileH)
        .position(x: posX, y: posY)
        .scaleEffect(rowScale, anchor: anchor)
    }
}

// MARK: - 全屏诊断页（v91：真机无控制台，整屏截图回报用；最新在最上）

struct FNOSDiagView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("诊断信息")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)
                Text("最新在最上 · 整屏截图发给开发者 · 按 Menu 返回")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.55))
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: 17, design: .monospaced))
                        .foregroundColor(index == 0 ? .green : .white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if lines.isEmpty {
                    Text("暂无诊断记录")
                        .font(.system(size: 17))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            .padding(50)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { lines = Array(FNOSDiag.shared.snapshot().reversed()) }
        .task {
            // 停留期间新留痕每秒上屏（最新置顶）
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let snap = Array(FNOSDiag.shared.snapshot().reversed())
                if snap != lines { lines = snap }
            }
        }
        .onExitCommand { dismiss() }
    }
}
