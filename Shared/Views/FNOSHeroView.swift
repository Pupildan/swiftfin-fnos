//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import SwiftUI

// MARK: - Hero Banner 专用扩展（只读 FNOSDirectClient 公开属性，不修改网络层文件）

extension FNOSDirectClient {

    /// Hero 大图 URL：优先 Backdrop（16:9 横图），退化用 Primary 海报
    func heroImageURL(item: FNOSItem, maxWidth: Int = 1920) -> URL? {
        let tags = item.ImageTags ?? [:]
        let imageType = tags["Backdrop"] != nil ? "Backdrop" : "Primary"
        guard let tag = tags[imageType], !tag.isEmpty else {
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

    @State private var currentIndex = 0

    // 智能预告状态
    @State private var previewPlayer: AVPlayer?
    @State private var previewItemID: String?
    @State private var previewVisible = false

    // 「稍后观看」本地标记（加号按钮）
    @AppStorage("fnos.watchlater") private var watchLaterIDs = ""

    private var current: FNOSItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // ---- 底层：全屏海报轮播（页内只有图）----
                TabView(selection: $currentIndex) {
                    ForEach(Array(items.enumerated()), id: \.element.Id) { index, item in
                        heroBackdrop(item: item, size: geo.size)
                            .tag(index)
                    }
                }
                #if os(tvOS)
                    .tabViewStyle(.page(indexDisplayMode: .never))
                #endif
                .ignoresSafeArea()
                .onMoveCommand { direction in
                    // 焦点在 Hero 内且左右无可移动目标时翻页
                    switch direction {
                    case .left:
                        guard currentIndex > 0 else { return }
                        withAnimation(.easeInOut(duration: 0.35)) { currentIndex -= 1 }
                    case .right:
                        guard currentIndex < items.count - 1 else { return }
                        withAnimation(.easeInOut(duration: 0.35)) { currentIndex += 1 }
                    default:
                        break
                    }
                }

                // ---- 智能预告视频层（海报之上、遮罩之下）----
                if previewVisible, let player = previewPlayer {
                    FNOSPreviewPlayerView(player: player)
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

                // ---- 底部正中：轮播指示圆点 ----
                HStack(spacing: 10) {
                    ForEach(items.indices, id: \.self) { index in
                        Circle()
                            .fill(Color.white.opacity(index == currentIndex ? 1 : 0.35))
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 40)
                .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeInOut(duration: 0.3), value: currentIndex)
        }
        .task(id: currentIndex) {
            // 智能预告：3 秒无操作 → 正片中间 30 秒静音预览；滑动立即打断
            stopPreview()
            guard let item = current else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await startPreview(item: item)
            // 播 30 秒后淡出回海报
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            stopPreview()
        }
        .onDisappear {
            stopPreview()
        }
    }

    // MARK: 轮播页（只有全屏海报图）

    private func heroBackdrop(item: FNOSItem, size: CGSize) -> some View {
        FNOSAsyncImage(
            url: client.heroImageURL(item: item),
            headers: client.mediaHeaders
        )
        .frame(width: size.width, height: size.height)
        .clipped()
        .ignoresSafeArea()
    }

    // MARK: 左下角信息与操作区

    private func infoStack(item: FNOSItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
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

            if let overview = item.Overview, !overview.isEmpty {
                Text(overview)
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 720, alignment: .leading)
            }

            HStack(spacing: 20) {
                // ▶ 播放（剧集走选集，电影直进 KSPlayer+弹幕）
                Button {
                    onPlay(item)
                } label: {
                    Label(item.type == "Series" ? "选集" : "播放", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                #if os(tvOS)
                    .buttonStyle(.card)
                #endif

                // + 稍后观看
                Button {
                    toggleWatchLater(item)
                } label: {
                    Label(
                        isWatchLater(item) ? "已加入" : "稍后看",
                        systemImage: isWatchLater(item) ? "checkmark.circle.fill" : "plus.circle"
                    )
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
                #if os(tvOS)
                    .buttonStyle(.card)
                #endif

                // 详情
                Button {
                    onDetail(item)
                } label: {
                    Label("详情", systemImage: "info.circle")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }
                #if os(tvOS)
                    .buttonStyle(.card)
                #endif
            }
            .padding(.top, 6)
        }
    }

    // MARK: 智能预告（独立 AVPlayer，与正片 KSPlayer 完全隔离）

    @MainActor
    private func startPreview(item: FNOSItem) async {
        // 仅电影/单集可预告；Series 无单一媒体流
        guard item.type == "Movie" || item.type == "Episode" else { return }

        do {
            let source = try await client.playbackSource(itemID: item.Id, userID: userID)
            let container = (source.container ?? "").lowercased()
            let playable = ["mp4", "mov", "m4v", "m3u8"].contains { container.contains($0) }
            guard playable else {
                print("FNOSℹ️Hero 预告跳过（容器 \(container) 非 AVPlayer 原生兼容）")
                return
            }
            guard let url = client.streamURL(itemID: item.Id, mediaSourceID: source.mediaSourceID) else { return }

            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": client.mediaHeaders])
            // 取总时长，定位正片中间
            let total = try await asset.load(.duration).seconds
            guard total.isFinite, total > 60 else {
                print("FNOSℹ️Hero 预告跳过（时长异常 \(total)）")
                return
            }

            let playerItem = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: playerItem)
            player.isMuted = true
            player.actionAtItemEnd = .none
            previewPlayer = player
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
        previewItemID = nil
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
