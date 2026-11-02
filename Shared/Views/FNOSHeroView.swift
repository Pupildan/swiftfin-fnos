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
    func heroImageURL(item: FNOSItem, maxWidth: Int = 1600) -> URL? {
        let tags = item.ImageTags ?? [:]
        let imageType = tags["Backdrop"] != nil ? "Backdrop" : "Primary"
        guard let tag = tags[imageType], !tag.isEmpty else {
            print("FNOS❗️Hero 无可用图片: \(item.Name ?? "?")")
            return nil
        }
        do {
            return try url(
                path: "Items/\(item.Id)/Images/\(imageType)",
                query: ["maxWidth": String(maxWidth), "quality": "85", "tag": tag]
            )
        } catch {
            print("FNOS❗️Hero 图片 URL 构造失败 \(item.Id): \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Apple TV+ 式全屏 Hero Banner（TabView 分页 + 渐变 + 智能视频预告）

/// 智能预告：切页 2 秒无操作后自动淡入静音循环视频（仅 AVPlayer 兼容容器）；
/// 再次滑动立即停止。绝不动 KSPlayer 底层 —— 预告用原生 AVPlayer 独立实例。
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
            ZStack {
                TabView(selection: $currentIndex) {
                    ForEach(Array(items.enumerated()), id: \.element.Id) { index, item in
                        heroPage(item: item, isActive: index == currentIndex)
                            .tag(index)
                    }
                }
                #if os(tvOS)
                    .tabViewStyle(.page(indexDisplayMode: .never))
                #endif
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

                // 自定义轮播指示器（底部正中 6 个白点）
                HStack(spacing: 10) {
                    ForEach(items.indices, id: \.self) { index in
                        Circle()
                            .fill(Color.white.opacity(index == currentIndex ? 1 : 0.35))
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)
                .allowsHitTesting(false)
            }
            .frame(height: geo.size.height)
        }
        .onDisappear {
            stopPreview()
        }
    }

    // MARK: 单页

    private func heroPage(item: FNOSItem, isActive: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            // 底层：全屏海报大图
            FNOSAsyncImage(
                url: client.heroImageURL(item: item),
                headers: client.mediaHeaders
            )
            .ignoresSafeArea()

            // 智能预告视频层（海报之上、渐变之下）
            if previewVisible, previewItemID == item.Id, let player = previewPlayer {
                FNOSPreviewPlayerView(player: player)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // 左侧深黑 → 右侧透明
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.85), location: 0),
                    .init(color: .black.opacity(0.45), location: 0.45),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .allowsHitTesting(false)

            // 底部黑色渐变（文字清晰可见）
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.8), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            // 左下角信息与操作区
            VStack(alignment: .leading, spacing: 14) {
                Text(item.Name ?? "未命名")
                    .font(.system(size: 52, weight: .bold))
                    .lineLimit(2)

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
                        .frame(maxWidth: 760, alignment: .leading)
                }

                HStack(spacing: 20) {
                    // ▶ 播放
                    Button {
                        onPlay(item)
                    } label: {
                        Label(item.type == "Series" ? "选集" : "播放", systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
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
                        .padding(.vertical, 10)
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
                            .padding(.vertical, 10)
                    }
                    #if os(tvOS)
                        .buttonStyle(.card)
                    #endif
                }
                .padding(.top, 4)
            }
            .padding(.leading, 64)
            .padding(.bottom, 56)
            .disabled(!isActive)
        }
    }

    // MARK: 智能预告（切页 2 秒无操作 → 静音循环视频）

    @MainActor
    private func startPreview(item: FNOSItem) async {
        // 仅电影/单集可预告；Series 无单一媒体流
        guard item.type == "Movie" || item.type == "Episode" else { return }

        do {
            let source = try await client.playbackSource(itemID: item.Id, userID: userID)
            let container = (source.container ?? "").lowercased()
            // 仅 AVPlayer 原生兼容容器（预告用独立 AVPlayer，与正片 KSPlayer 完全隔离）
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
            // 跳到正片中间开始播
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

// MARK: - 原生 AVPlayerLayer 视图（预告专用，与正片 KSPlayer 完全隔离）

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
