//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import KSPlayer
import SwiftUI

/// AVURLAsset 请求头 Key（ObjC 常量未暴露给 Swift，按官方字符串手动声明）
private let fnosHeroAVHTTPKey = "AVURLAssetHTTPHeaderFieldsKey"

// MARK: - Hero Banner 专用扩展（只读 FNOSDirectClient 公开属性，不修改网络层文件）

extension FNOSDirectClient {

    /// Hero 大图 URL。
    /// - preferBackdrop = true：优先 Backdrop（16:9 高清横图）
    /// - preferBackdrop = false：强制 Primary 海报（当飞牛刮削的 Backdrop 挂错电影时可切换规避）
    func heroImageURL(item: FNOSItem, maxWidth: Int = 1920, preferBackdrop: Bool = true) -> URL? {
        let tags = item.ImageTags ?? [:]
        var imageType = "Primary"
        var imageTag: String?

        // 关键修复：Backdrop 的 tag 在独立的 BackdropImageTags 数组里，
        // 之前错误地在 ImageTags 字典里找 "Backdrop"，永远是 nil → 一直退化成竖版海报。
        let backdropTag = item.BackdropImageTags?.first

        if preferBackdrop, let backdropTag, !backdropTag.isEmpty {
            imageType = "Backdrop"
            imageTag = backdropTag
        } else if let primaryTag = tags["Primary"], !primaryTag.isEmpty {
            imageType = "Primary"
            imageTag = primaryTag
        } else if let backdropTag, !backdropTag.isEmpty {
            imageType = "Backdrop"
            imageTag = backdropTag
        }

        guard let tag = imageTag else {
            print("FNOS❗️Hero 无可用图片: \(item.Name ?? "?")")
            return nil
        }
        do {
            return try url(
                path: "Items/\(item.Id)/Images/\(imageType)",
                query: ["maxWidth": String(maxWidth), "quality": "90", "tag": tag]
            )
        } catch {
            print("FNOS❗️Hero 图片 URL 构造失败 \(item.Id): \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Apple TV+ 式全屏 Hero Banner

/// 结构与 ATV+ 一致：轮播页里只有图；标题/简介/按钮/遮罩/指示器全部是
/// 叠在 TabView 之上的静态覆盖层（随 currentIndex 切换数据，不随页滑动）。
/// 智能预告：3 秒无操作 → 独立 AVPlayer 静音播正片中间 30 秒 → 淡出回海报。
struct FNOSHeroBanner: View {

    let items: [FNOSItem]
    let client: FNOSDirectClient
    let userID: String
    let onPlay: (FNOSItem) -> Void
    let onDetail: (FNOSItem) -> Void
    let onDownToShelf: () -> Void
    /// v123：跨源 TMDB 主演/导演匹配（FNOSMainView 注入，返回 (cast, director)，匹配失败返回 nil）
    var fetchCredits: ((FNOSItem) async -> (cast: String, director: String)?)? = nil

    /// 轮播目标索引（驱动 HStack 横向偏移 + 动画）
    @State private var currentIndex = 0
    /// v125：翻页节流——Siri 遥控滑动一次会连续触发多次 onMoveCommand，
    /// 无节流则轻滑就连跳好几页/误判方向窜到海报墙。0.45s 内的后续翻页请求一律忽略。
    @State private var lastPageTime = Date.distantPast
    /// 文案索引（延迟到翻页动画结束才跟随 currentIndex）
    /// 根因：动画 0.35s 期间旧海报仍在屏幕中央，若文案瞬时切换就会「图文不匹配」。
    @State private var displayedIndex = 0

    /// v123：右下角主演/导演（当前 displayedIndex 条目的 TMDB credits）
    @State private var creditsInfo: (cast: String, director: String)?

    // 智能预告状态（AVPlayer 播 mp4/m3u8；MKV 等用第二个独立 KSPlayer 实例，与正片完全隔离）
    @State private var previewPlayer: AVPlayer?
    @State private var previewItemID: String?
    @State private var previewVisible = false
    // 每次预告新建一个 Coordinator（@State 可替换）：绝不在旧实例上重建 KSMEPlayer，
    // 这是「媒体库切回 Hero 闪退」的根因（旧 FFmpeg 实例尚未销毁就被复用）。
    @State private var previewKSCoordinator: KSVideoPlayer.Coordinator?
    @State private var previewUsesKS = false
    @State private var previewKSURL: URL?
    @State private var previewKSOptions: KSOptions?
    @State private var previewKSSeeked = false

    // Hero 按钮焦点（原生 defaultFocus：启动即锁定「播放」按钮）
    enum HeroButton { case play, plus, detail }
    @FocusState private var focusedButton: HeroButton?

    // 「稍后观看」本地标记（加号按钮）
    @AppStorage("fnos.watchlater") private var watchLaterIDs = ""

    // Hero 图源偏好：backdrop（默认，16:9 横图）/ primary（2:3 海报）
    // 若飞牛刮削把 Backdrop 挂错电影，可在此切到 Primary 规避（设置面板里可切换）
    @AppStorage("fnos.hero.imageSource") private var heroImageSource = "backdrop"

    /// 文案/圆点使用的条目：跟随 displayedIndex，与屏幕上的海报同步
    private var current: FNOSItem? {
        guard items.indices.contains(displayedIndex) else { return nil }
        return items[displayedIndex]
    }

    /// 当前页索引对应的条目（预告启动用，不等动画）
    private var itemAtCurrentIndex: FNOSItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    /// 焦点是否在 Hero 的三个按钮内（只有此时才允许播放静音预告）
    private var isHeroFocused: Bool { focusedButton != nil }

    /// 预告任务触发键：页索引变化，或焦点进出 Hero（有/无）时重估。
    /// 焦点在三个按钮之间移动不会打断已开始的预告，只有离开 Hero 才停播。
    private var previewTriggerKey: String {
        "\(currentIndex)-\(isHeroFocused ? "in" : "out")"
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // ---- 底层：自绘轮播（TabView 页控制器按安全区内缩导致黑边，弃用；
                //      整条 HStack 水平偏移实现翻页，尺寸完全自控）----
                ZStack {
                    HStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.Id) { index, item in
                            heroBackdrop(item: item, index: index, size: geo.size)
                                .frame(width: geo.size.width)
                        }
                    }
                    .offset(x: -CGFloat(currentIndex) * geo.size.width)
                    .animation(.easeInOut(duration: 0.35), value: currentIndex)
                }
                // 关键：HStack 宽 = N × 页宽，必须左对齐定位。
                // 若用默认 .center，6W 宽的 HStack 会被居中到 W 宽容器里（左边缘 -2.5W），
                // 叠加 offset 后屏幕显示的就是「相邻两页各占一半」= 图文错位的真正根因。
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
                .ignoresSafeArea()

                // ---- 智能预告视频层（海报之上、遮罩之下）----
                if previewVisible, !previewUsesKS, previewItemID == itemAtCurrentIndex?.Id, let player = previewPlayer {
                    FNOSPreviewPlayerView(player: player)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
                if previewVisible, previewUsesKS, previewItemID == itemAtCurrentIndex?.Id,
                   let url = previewKSURL, let coord = previewKSCoordinator
                {
                    KSVideoPlayer(coordinator: coord, url: url, options: previewKSOptions ?? KSOptions())
                        .onStateChanged { _, state in
                            // 只在缓冲完成这一时机做一次：静音 + 定位正片中间 + 播放
                            guard state == .bufferFinished else { return }
                            Task { @MainActor in
                                // 双重守卫：Coordinator 已被换掉（预告已停）就什么都不做
                                guard previewUsesKS,
                                      previewVisible,
                                      !previewKSSeeked,
                                      previewKSCoordinator === coord
                                else { return }
                                previewKSSeeked = true
                                coord.isMuted = true
                                coord.isScaleAspectFill = true
                                // 总时长从 KSPlayer 拿（AVAsset 读不了 MKV）
                                let total = Double(coord.timemodel.totalTime)
                                if total > 60 {
                                    coord.seek(time: total / 2)
                                }
                                coord.playerLayer?.play()
                            }
                        }
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // ---- 遮罩层：左黑右透 + 下黑上透 + 暗角 ----
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.8), location: 0),
                        .init(color: .black.opacity(0.4), location: 0.45),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .allowsHitTesting(false)

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.75), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                RadialGradient(
                    colors: [.clear, .black.opacity(0.35)],
                    center: .center,
                    startRadius: geo.size.width * 0.3,
                    endRadius: geo.size.width * 0.75
                )
                .allowsHitTesting(false)

                // ---- 左下角：大标题 + 分类 + 简介 + 按钮组 ----
                if let item = current {
                    infoStack(item: item)
                        .padding(.leading, 72)
                        .padding(.bottom, 72)
                }

                // ---- 右下角：主演/导演（v123 TMDB 跨源匹配，匹配失败隐藏）----
                if let credits = creditsInfo, !credits.cast.isEmpty || !credits.director.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        if !credits.cast.isEmpty {
                            Text("主演 \(credits.cast)")
                        }
                        if !credits.director.isEmpty {
                            Text("导演 \(credits.director)")
                        }
                    }
                    .font(.system(size: 17))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 72)
                    .padding(.bottom, 96)
                    .allowsHitTesting(false)
                }

                // ---- 底部正中：轮播指示圆点 ----
                HStack(spacing: 10) {
                    ForEach(items.indices, id: \.self) { index in
                        Circle()
                            .fill(Color.white.opacity(index == displayedIndex ? 1 : 0.35))
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 40)
                .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeInOut(duration: 0.3), value: currentIndex)
            .onAppear {
                // 双保险：启动/回前台时把初始焦点强制锁到「播放」按钮，不给设置按钮抢走
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    focusedButton = .play
                }
            }
        .onChange(of: items.count) { _, newCount in
            // 刷新媒体库后快照变短：索引越界会让 current 为 nil、HStack 偏移指向不存在页
            stopPreview()
            if newCount == 0 {
                currentIndex = 0
                displayedIndex = 0
            } else {
                if currentIndex >= newCount { currentIndex = newCount - 1 }
                if displayedIndex >= newCount { displayedIndex = newCount - 1 }
            }
        }
        }
        .task(id: previewTriggerKey) {
            // 智能预告：Hero 按钮持焦 + 5 秒无操作 → 正片中间 30 秒静音预览。
            // 焦点一旦离开 Hero（去媒体库/设置），trigger 变化 → 本 task 重跑 → 直接停止。
            stopPreview()
            guard isHeroFocused, let item = itemAtCurrentIndex else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, isHeroFocused else { return }
            await startPreview(item: item)
            // 播 30 秒后淡出回海报
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            stopPreview()
        }
        .task(id: "credits-\(displayedIndex)") {
            // v123：当前条目跨源 TMDB 主演/导演匹配（懒加载，失败留空）
            creditsInfo = nil
            guard let item = current, let fetch = fetchCredits else { return }
            let result = await fetch(item)
            // 动画期间可能已翻页，仅当仍是当前条目时才赋值
            if current?.Id == item.Id {
                creditsInfo = result
            }
        }
        .onDisappear {
            stopPreview()
        }
    }

    // MARK: 轮播页（纯展示海报，无焦点；翻页全部由按钮的 onMoveCommand 驱动）

    private func heroBackdrop(item: FNOSItem, index: Int, size: CGSize) -> some View {
        // 是否是竖版海报（无 Backdrop，或用户强制 Primary）
        let preferBackdrop = heroImageSource != "primary"
        let hasBackdrop = preferBackdrop && (item.BackdropImageTags?.isEmpty == false)
        let url = client.heroImageURL(item: item, preferBackdrop: preferBackdrop)

        return ZStack {
            if !hasBackdrop {
                // 竖版海报：底层放同图放大模糊 + 压暗，填满全屏不留黑边
                FNOSAsyncImage(
                    url: url,
                    headers: client.mediaHeaders,
                    contentMode: .fill
                )
                .blur(radius: 45)
                .overlay(Color.black.opacity(0.45))
            }

            // 主图：有横图 → 铺满；只有竖图 → 等比完整显示（不裁掉主体）
            FNOSAsyncImage(
                url: url,
                headers: client.mediaHeaders,
                contentMode: hasBackdrop ? .fill : .fit
            )
        }
        // 106% 过扫描后裁到本页：任何容器/舍入情况下四边都不露黑边
        .frame(width: size.width * 1.06, height: size.height * 1.06)
        .frame(width: size.width, height: size.height)
        .clipped()
        .id(item.Id)
    }

    // MARK: 左下角信息与操作区

    private func infoStack(item: FNOSItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // v123：荣誉徽章胶囊（用 OfficialRating 分级，如 PG-13/12；无则不显示）
            if let rating = item.OfficialRating, !rating.isEmpty {
                Text(rating)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Color.white.opacity(0.18))
                            .overlay(Capsule().stroke(Color.white.opacity(0.45), lineWidth: 1))
                    )
            }

            Text(item.Name ?? "未命名")
                .font(.largeTitle.bold())
                .lineLimit(2)
                .foregroundColor(.white)

            HStack(spacing: 12) {
                Text(Self.categoryName(item))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.white.opacity(0.55), lineWidth: 1)
                    )
                if let year = item.ProductionYear {
                    Text(String(year))
                }
            }
            .font(.callout)
            .foregroundColor(.white.opacity(0.85))

            // v123：格式徽章行（时长，从 RunTimeTicks；无有效时长不显示）
            if let duration = item.compactDuration, !duration.isEmpty {
                HStack(spacing: 10) {
                    Text(duration)
                }
                .font(.system(size: 17))
                .foregroundColor(.white.opacity(0.7))
            }

            if let overview = item.Overview, !overview.isEmpty {
                Text(overview)
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 720, alignment: .leading)
            }

            // Hero 按钮：视觉与详情页一致（未选中半透明玻璃 / 选中白底黑字），
            // 但样式在本文件独立实现，后续详情页改动不会影响 Hero。
            HStack(spacing: 28) {
                // ▶ 立即播放（剧集走选集，电影直进播放器）
                Button {
                    onPlay(item)
                } label: {
                    heroButtonLabel(.play, isPrimary: true) {
                        Text(item.type == "Series" ? "选集" : "立即播放")
                            .font(.system(size: 21, weight: .semibold))
                    }
                }
                .buttonStyle(FNOSBareButtonStyle())
                .focusEffectDisabled()
                .focused($focusedButton, equals: .play)
                .onMoveCommand { direction in
                    switch direction {
                    case .left:
                        pagePrevious()
                    case .down:
                        onDownToShelf()
                    default:
                        break
                    }
                }

                // + 稍后观看
                Button {
                    toggleWatchLater(item)
                } label: {
                    heroButtonLabel(.plus, isPrimary: false) {
                        Image(systemName: isWatchLater(item) ? "checkmark" : "plus")
                            .font(.system(size: 22, weight: .semibold))
                    }
                }
                .buttonStyle(FNOSBareButtonStyle())
                .focusEffectDisabled()
                .focused($focusedButton, equals: .plus)
                .onMoveCommand { direction in
                    if direction == .down {
                        onDownToShelf()
                    }
                }

                // 详情
                Button {
                    onDetail(item)
                } label: {
                    heroButtonLabel(.detail, isPrimary: false) {
                        Image(systemName: "info")
                            .font(.system(size: 22, weight: .semibold))
                    }
                }
                .buttonStyle(FNOSBareButtonStyle())
                .focusEffectDisabled()
                .focused($focusedButton, equals: .detail)
                .onMoveCommand { direction in
                    switch direction {
                    case .right:
                        pageNext()
                    case .down:
                        onDownToShelf()
                    default:
                        break
                    }
                }
            }
            .padding(.top, 8)
            #if os(tvOS)
                .defaultFocus($focusedButton, .play)
            #endif
        }
    }

    // MARK: Hero 按钮外观（独立实现，与详情页解耦）

    /// - 未聚焦：半透明液态玻璃（黑 35% + 白 25% 描边），白字
    /// - 聚焦：纯白背景，黑字，轻微放大
    @ViewBuilder
    private func heroButtonLabel<L: View>(
        _ id: HeroButton,
        isPrimary: Bool,
        @ViewBuilder label: () -> L
    ) -> some View {
        let isFocused = focusedButton == id
        // 与详情页同一套视觉：无外描边，未聚焦半透明黑胶囊，聚焦纯白胶囊
        label()
            .foregroundColor(isFocused ? .black : .white)
            .padding(.horizontal, isPrimary ? 34 : 0)
            .padding(.vertical, isPrimary ? 15 : 0)
            .frame(width: isPrimary ? nil : 54, height: isPrimary ? nil : 54)
            .background(
                Capsule()
                    .fill(isFocused ? Color.white : Color.black.opacity(0.35))
            )
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }

    // MARK: 焦点驱动的海报翻页（翻页后焦点强制留在原按钮上）

    private func pagePrevious() {
        // v125：滑动节流——轻滑一次只翻一页，过滤连续触发的多余命令
        guard Date().timeIntervalSince(lastPageTime) > 0.45 else { return }
        guard currentIndex > 0 else { return }
        lastPageTime = Date()
        let target = currentIndex - 1
        withAnimation(.easeInOut(duration: 0.35)) {
            currentIndex = target
        } completion: {
            // 海报滑到位后再切文案，避免动画期间「屏幕上是上一部、标题已是下一部」
            displayedIndex = target
        }
        focusedButton = .play
    }

    private func pageNext() {
        // v125：滑动节流——轻滑一次只翻一页，过滤连续触发的多余命令
        guard Date().timeIntervalSince(lastPageTime) > 0.45 else { return }
        guard currentIndex < items.count - 1 else { return }
        lastPageTime = Date()
        let target = currentIndex + 1
        withAnimation(.easeInOut(duration: 0.35)) {
            currentIndex = target
        } completion: {
            displayedIndex = target
        }
        focusedButton = .detail
    }

    // MARK: 智能预告（独立 AVPlayer，与正片 KSPlayer 完全隔离）

    @MainActor
    private func startPreview(item: FNOSItem) async {
        // 仅电影/单集可预告；Series 无单一媒体流
        guard item.type == "Movie" || item.type == "Episode" else { return }

        do {
            let source = try await client.playbackSource(itemID: item.Id, userID: userID)
            // 网络等待期间焦点可能已离开 Hero / 已翻页：任务取消则绝不再起播放
            guard !Task.isCancelled else { return }
            let container = (source.container ?? "").lowercased()
            guard let url = client.streamURL(itemID: item.Id, mediaSourceID: source.mediaSourceID) else { return }

            // MKV/Matroska 等非 AVPlayer 容器 → 第二个独立 KSPlayer 实例（静音预告）
            let avPlayable = ["mp4", "mov", "m4v", "m3u8"].contains { container.contains($0) }
            if !avPlayable {
                print("FNOSℹ️Hero 预告（KSPlayer 独立实例）容器: \(container)")
                let options = KSOptions()
                options.avOptions[fnosHeroAVHTTPKey] = client.mediaHeaders
                let headerString = client.mediaHeaders
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: "\r\n")
                options.formatContextOptions["headers"] = headerString
                KSOptions.firstPlayerType = KSMEPlayer.self

                previewPlayer = nil
                previewUsesKS = true
                previewKSSeeked = false
                // 每次预告全新 Coordinator：不复用旧实例，避免旧 FFmpeg 未销毁就被重建（闪退根因）
                let coord = KSVideoPlayer.Coordinator()
                coord.isScaleAspectFill = true
                coord.isMuted = true
                previewKSCoordinator = coord
                previewKSURL = url
                previewKSOptions = options
                previewItemID = item.Id
                withAnimation(.easeIn(duration: 0.6)) {
                    previewVisible = true
                }
                // 视图插入后立即补设填充模式，避免第一帧按原比例闪现约 1 秒
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard previewKSCoordinator === coord else { return }
                    coord.isScaleAspectFill = true
                }
                return
            }

            let asset = AVURLAsset(url: url, options: [fnosHeroAVHTTPKey: client.mediaHeaders])
            // 取总时长，定位正片中间
            let total = try await asset.load(.duration).seconds
            guard !Task.isCancelled else { return }
            guard total.isFinite, total > 60 else {
                print("FNOSℹ️Hero 预告跳过（时长异常 \(total)）")
                return
            }

            let playerItem = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: playerItem)
            player.isMuted = true
            player.actionAtItemEnd = .none
            previewPlayer = player
            previewUsesKS = false
            previewKSURL = nil
            previewItemID = item.Id

            withAnimation(.easeIn(duration: 0.6)) {
                previewVisible = true
            }
            await player.seek(to: CMTime(seconds: total / 2, preferredTimescale: 600))
            player.play()
            print("FNOSℹ️Hero 预告开始: \(item.Name ?? "?") @\(Int(total / 2))s / 总长 \(Int(total))s")
        } catch {
            print("FNOS❗️Hero 预告失败: \(error.localizedDescription)")
        }
    }

    private func stopPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        // 先暂停再丢引用：视图随 previewUsesKS/previewVisible 变 false 而移除，
        // 旧 Coordinator 与其 KSMEPlayer 会被整体释放，下一次预告用全新实例。
        previewKSCoordinator?.playerLayer?.pause()
        previewKSCoordinator = nil
        previewUsesKS = false
        previewKSURL = nil
        previewKSOptions = nil
        previewItemID = nil
        previewKSSeeked = false
        if previewVisible {
            withAnimation(.easeOut(duration: 0.2)) {
                previewVisible = false
            }
        }
    }

    // MARK: 稍后观看（本地 UserDefaults）

    private func isWatchLater(_ item: FNOSItem) -> Bool {
        watchLaterIDs.split(separator: ",").map(String.init).contains(item.Id)
    }

    private func toggleWatchLater(_ item: FNOSItem) {
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

// MARK: - 原生 AVPlayerLayer 视图（预告专用）

struct FNOSPreviewPlayerView: UIViewRepresentable {

    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let layer = AVPlayerLayer()
        layer.player = player
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let layer = uiView.layer.sublayers?.compactMap({ $0 as? AVPlayerLayer }).first {
            layer.frame = uiView.bounds
        }
    }
}
