//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVKit
import Combine
import SwiftUI

// MARK: - AVPlayerViewController 包装（tvOS 原生遥控器操作 + 原生进度条）

private struct FNOSPlayerControllerView: UIViewControllerRepresentable {

    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// MARK: - 播放器持有者（时钟回调 + 倍率回调）

@MainActor
final class FNOSPlayerHolder: ObservableObject {

    let player = AVPlayer()

    private var timeObserver: Any?
    private var rateCancellable: AnyCancellable?

    /// 0.25 秒周期回调（媒体时间，秒）
    var onTick: ((Double) -> Void)?
    /// 播放/暂停/等待 状态回调（1 = 播放，0 = 暂停）
    var onRateChange: ((Double) -> Void)?

    func configure(item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
        player.play()

        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 4),
                queue: .main
            ) { [weak self] time in
                let seconds = time.seconds
                Task { @MainActor in
                    self?.onTick?(seconds)
                }
            }
        }

        rateCancellable = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                let rate: Double
                switch status {
                case .paused:
                    rate = 0
                default:
                    rate = 1
                }
                Task { @MainActor in
                    self?.onRateChange?(rate)
                }
            }
    }

    func teardown() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        rateCancellable?.cancel()
        rateCancellable = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - 播放容器（鉴权注入 + Liquid Glass 顶栏 + 弹幕层）

struct FNOSPlayerContainerView: View {

    let item: FNOSItem
    let client: FNOSDirectClient
    let userID: String

    @Environment(\.dismiss)
    private var dismiss

    @StateObject private var playerHolder = FNOSPlayerHolder()
    @StateObject private var danmuEngine = FNOSDanmuEngine()

    @State private var showDanmu = true
    @State private var danmuNotice = ""
    @State private var didSetup = false

    var body: some View {
        ZStack(alignment: .top) {
            // 原生播放器（黑底防黑屏穿透）
            FNOSPlayerControllerView(player: playerHolder.player)
                .ignoresSafeArea()
                .background(Color.black.ignoresSafeArea())

            // 弹幕层：位于视频上方、顶栏下方；关闭时仅隐藏图层，
            // 引擎时钟继续随播放器走，重新打开无缝衔接
            if showDanmu {
                FNOSDanmuView(engine: danmuEngine)
                    .ignoresSafeArea()
            }

            // Liquid Glass 悬浮顶栏
            HStack(spacing: 20) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                        .padding(12)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.Name ?? "播放")
                        .font(.headline)
                        .lineLimit(1)
                    if !danmuNotice.isEmpty {
                        Text(danmuNotice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button {
                    showDanmu.toggle()
                } label: {
                    Label(
                        showDanmu ? "弹幕 开" : "弹幕 关",
                        systemImage: showDanmu ? "text.bubble" : "text.bubble.slash"
                    )
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .cornerRadius(18)
            .padding(.horizontal, 48)
            .padding(.top, 20)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            setupIfNeeded()
        }
        .onDisappear {
            playerHolder.teardown()
        }
    }

    private func setupIfNeeded() {
        guard !didSetup else { return }
        didSetup = true

        // 弹幕时钟绑定播放器：绝对不用系统时间
        playerHolder.onTick = { mediaTime in
            danmuEngine.sync(mediaTime: mediaTime)
        }
        playerHolder.onRateChange = { rate in
            danmuEngine.setRate(rate)
        }

        // 播放直链 + 鉴权头注入（防止飞牛直链 401 黑屏）
        guard let url = client.streamURL(itemID: item.Id) else {
            danmuNotice = "❗️播放地址构造失败"
            return
        }

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetHTTPHeaderFieldsKey: client.mediaHeaders]
        )
        playerHolder.configure(item: AVPlayerItem(asset: asset))

        // 弹幕加载（真实服务端，按标题匹配）
        let title = item.Name ?? "视频"
        danmuNotice = "弹幕匹配中…"
        Task {
            await danmuEngine.load(title: title)
            switch danmuEngine.status {
            case .ready:
                danmuNotice = "弹幕 \(danmuEngine.commentCount) 条"
            case .failed(let message):
                danmuNotice = "弹幕失败: \(message)"
            default:
                danmuNotice = ""
            }
        }
    }
}
