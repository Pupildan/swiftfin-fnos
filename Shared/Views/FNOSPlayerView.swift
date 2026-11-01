//
// FNOSPlayerView.swift
// 飞牛影视播放器 —— KSPlayer 裸播放视图 + 自绘 Apple TV+ 式控制条。
//
// 设计要点：
// - 不用 KSVideoPlayerView（其内置 tvOS 控制条按钮样式无法定制），
//   改用裸 KSVideoPlayer(UIViewRepresentable) + 完全自绘控制层；
// - 控制条按钮一律 .plain 无背景（按用户要求删除音量/画中画）；
// - 弹幕开关移入控制条；顶部区域彻底删除；
// - 3 秒无操作自动隐藏控制条；隐藏状态下任意方向键/触摸唤出；
// - MENU(onExitCommand) 退出播放。
//

import KSPlayer
import SwiftUI

/// AVURLAsset 请求头 Key（ObjC 常量未暴露给 Swift，按官方字符串手动声明）
private let fnosAVHTTPHeaderFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

// MARK: - 播放源扩展（只读 FNOSDirectClient 公开属性，不修改网络层文件）

extension FNOSDirectClient {

    /// 条目播放源（fnOS 硬性要求：stream 的 MediaSourceId 必须传真实值，空值一律 400）
    func playbackSource(itemID: String, userID: String) async throws -> (mediaSourceID: String, container: String?) {
        let data = try await get(path: "Users/\(userID)/Items/\(itemID)")

        struct Detail: Decodable {
            let MediaSources: [FNOSMediaSource]?
        }
        struct FNOSMediaSource: Decodable {
            let Id: String
            let Container: String?
            let Path: String?
        }

        let detail: Detail
        do {
            detail = try JSONDecoder().decode(Detail.self, from: data)
        } catch {
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? "(非文本)"
            print("FNOS❗️解析条目详情失败: \(error) 原文: \(raw)")
            throw FNOSDirectError("解析条目详情失败: \(error.localizedDescription)")
        }

        guard let source = detail.MediaSources?.first, !source.Id.isEmpty else {
            throw FNOSDirectError("条目缺少 MediaSources，无法取播放源")
        }
        return (source.Id, source.Container ?? source.Path)
    }

    /// 播放直链（static=true 原始流；容器可能是 MKV，由 KSPlayer 引擎分流处理）
    func streamURL(itemID: String, mediaSourceID: String) -> URL? {
        do {
            return try url(
                path: "Videos/\(itemID)/stream",
                query: [
                    "static": "true",
                    "MediaSourceId": mediaSourceID,
                    "api_key": token,
                ]
            )
        } catch {
            print("FNOS❗️播放 URL 构造失败 \(itemID): \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - 播放容器

struct FNOSPlayerContainerView: View {

    let item: FNOSItem
    let client: FNOSDirectClient
    let userID: String

    @Environment(\.dismiss)
    private var dismiss

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @StateObject private var danmuEngine = FNOSDanmuEngine()

    @State private var showDanmu = true
    @State private var streamURL: URL?
    @State private var containerInfo: String?
    @State private var notice = "准备播放…"
    @State private var didSetup = false

    // 控制条状态
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var focus: Control?

    private enum Control: Hashable {
        case rewind, playPause, danmu, forward
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let streamURL {
                playerView(url: streamURL)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(notice)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 弹幕层：关闭时仅隐藏图层，时钟随播放器继续走，重开无缝衔接
            if showDanmu {
                FNOSDanmuView(engine: danmuEngine)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if controlsVisible, streamURL != nil {
                controlBar
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .onExitCommand {
            dismiss()
        }
        .onPlayPauseCommand {
            togglePlayPause()
        }
        .task {
            await prepare()
        }
        .onDisappear {
            hideTask?.cancel()
            danmuEngine.setRate(0)
        }
    }

    // MARK: 裸播放视图（无 KSPlayer 内置控制）

    private func playerView(url: URL) -> some View {
        KSVideoPlayer(coordinator: coordinator, url: url, options: makeOptions())
            .onPlay { currentTime, _ in
                danmuEngine.sync(mediaTime: currentTime)
            }
            .onStateChanged { _, state in
                switch state {
                case .paused, .playedToTheEnd, .error:
                    danmuEngine.setRate(0)
                default:
                    danmuEngine.setRate(1)
                }
            }
            .ignoresSafeArea()
            .focusable(!controlsVisible)
            .onMoveCommand { _ in
                // 控制条隐藏时：任意方向键唤出控制条
                revealControls()
            }
            .onTapGesture {
                revealControls()
            }
    }

    // MARK: 自绘控制条（无背景图标 + 进度 + 时间）

    private var controlBar: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.Name ?? "播放")
                        .font(.headline)
                        .lineLimit(1)
                    if !notice.isEmpty {
                        Text(notice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }

            HStack(spacing: 64) {
                controlButton(.rewind, icon: "gobackward.15") {
                    coordinator.skip(interval: -15)
                }
                controlButton(.playPause, icon: isPlaying ? "pause.fill" : "play.fill") {
                    togglePlayPause()
                }
                controlButton(.danmu, icon: showDanmu ? "text.bubble" : "text.bubble.slash") {
                    showDanmu.toggle()
                }
                controlButton(.forward, icon: "goforward.15") {
                    coordinator.skip(interval: 15)
                }
            }
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(.white)

            FNOSPlayerTimeBar(timemodel: coordinator.timemodel)
        }
        .padding(.horizontal, 90)
        .padding(.bottom, 56)
        .padding(.top, 24)
        .background(
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.65), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .onChange(of: focus) { _ in
            scheduleHide()
        }
    }

    private func controlButton(_ control: Control, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .scaleEffect(focus == control ? 1.3 : 1.0)
                .animation(.easeOut(duration: 0.15), value: focus == control)
        }
        .buttonStyle(.plain)
        .focused($focus, equals: control)
    }

    // MARK: 状态助手

    private var isPlaying: Bool {
        coordinator.state.isPlaying
    }

    private func togglePlayPause() {
        if isPlaying {
            coordinator.playerLayer?.pause()
        } else {
            coordinator.playerLayer?.play()
        }
        revealControls()
    }

    /// 任意操作 → 显示控制条并重置 3 秒隐藏计时
    private func revealControls() {
        hideTask?.cancel()
        if !controlsVisible {
            withAnimation(.easeInOut(duration: 0.2)) {
                controlsVisible = true
            }
            DispatchQueue.main.async {
                focus = .playPause
            }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                controlsVisible = false
            }
            focus = nil
        }
    }

    // MARK: 准备（真实 MediaSourceId → 直链 → 弹幕）

    private func prepare() async {
        guard !didSetup else { return }
        didSetup = true

        // 1) 取真实 MediaSourceId（fnOS 硬性要求）
        let source: (mediaSourceID: String, container: String?)
        do {
            source = try await client.playbackSource(itemID: item.Id, userID: userID)
        } catch {
            print("FNOS❗️获取播放源失败: \(error)")
            notice = "❗️获取播放源失败: \(error.localizedDescription)"
            return
        }

        // 2) 构造直链
        guard let url = client.streamURL(itemID: item.Id, mediaSourceID: source.mediaSourceID) else {
            notice = "❗️播放地址构造失败"
            return
        }
        streamURL = url
        containerInfo = source.container
        notice = ""

        // 3) 弹幕（真实服务端，按标题匹配）
        danmuEngine.setRate(1)
        let title = item.Name ?? "视频"
        notice = "弹幕匹配中…"
        await danmuEngine.load(title: title)
        switch danmuEngine.status {
        case .ready:
            notice = "弹幕 \(danmuEngine.commentCount) 条"
        case .failed(let message):
            notice = "弹幕失败: \(message)"
        default:
            notice = ""
        }
        revealControls()
    }

    // MARK: 引擎分流（.mkv → FFmpeg；.mp4/.m3u8 → AVPlayer）

    private func makeOptions() -> KSOptions {
        let container = (containerInfo ?? "").lowercased()
        let isMKV = container.contains("matroska") || container.contains("mkv")

        KSOptions.firstPlayerType = isMKV ? KSMEPlayer.self : KSAVPlayer.self
        print("FNOSℹ️播放引擎: \(isMKV ? "FFmpeg (KSMEPlayer)" : "AVPlayer (KSAVPlayer)") · 容器: \(container.isEmpty ? "未知" : container)")

        let options = KSOptions()

        // 鉴权头：fnOS 播放流必须带 X-Emby-Authorization（实测仅 api_key 会 400）
        // AVPlayer 引擎：通过 avOptions 注入 AVURLAsset 请求头
        options.avOptions[fnosAVHTTPHeaderFieldsKey] = client.mediaHeaders
        // FFmpeg 引擎：http 协议的 headers 选项（\r\n 分隔）
        let headerString = client.mediaHeaders
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        options.formatContextOptions["headers"] = headerString

        return options
    }
}

// MARK: - 时间/进度条（单独观察 ControllerTimeModel，秒级刷新不重绘整个控制条）

struct FNOSPlayerTimeBar: View {

    @ObservedObject var timemodel: ControllerTimeModel

    var body: some View {
        HStack(spacing: 14) {
            Text(timeString(timemodel.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundColor(.white)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                    Capsule()
                        .fill(.white)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
            Text(timeString(timemodel.totalTime))
                .font(.caption.monospacedDigit())
                .foregroundColor(.white)
        }
    }

    private var fraction: Double {
        let total = Double(max(timemodel.totalTime, 1))
        return min(max(Double(timemodel.currentTime) / total, 0), 1)
    }

    private func timeString(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%02d:%02d", m, sec)
    }
}
