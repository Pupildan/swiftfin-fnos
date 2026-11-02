//
// FNOSPlayerView.swift
// 飞牛影视播放器 —— KSPlayer 裸播放视图 + 自绘 Apple TV+ 式控制条。
//
// 设计要点：
// - 裸 KSVideoPlayer(UIViewRepresentable) + 完全自绘控制层；
// - 快进/快退/播放暂停三个主按钮相对进度条居中；倍速/弹幕/设置/音轨靠右；
// - 选中背景 = tvOS26 液态玻璃 .clear（圆形，比按钮略大，底部压暗保证可读）；
// - 进度条可聚焦：左右键步进预览（连按加速 10s→180s），停手 1 秒提交；
// - 遥控器转盘/触摸滑动 = UIPanGestureRecognizer 桥接，直接连续拖动进度；
// - 倍速 0.5/1.0/1.5/2.0 循环，弹幕时钟跟随倍速；
// - 3 秒无操作自动隐藏控制条；MENU 退出播放。
//

import AVFoundation
import KSPlayer
import SwiftUI
import UIKit

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

// MARK: - 液态玻璃辅助（tvOS26，选中才挂；.clear 更透明，底部压暗保证可读）

extension View {
    @ViewBuilder
    func fnosGlass(_ active: Bool, in shape: some Shape) -> some View {
        if active {
            self
                .background(Color.white.opacity(0.10), in: shape)
                .overlay(shape.stroke(.white.opacity(0.45), lineWidth: 1.5))
        } else {
            self
        }
    }
}

// MARK: - 转盘/触摸滑动桥接（SwiftUI 无公开 scroll wheel API，走 UIKit 手势）

final class FNOSPanBridge: NSObject {
    static let shared = FNOSPanBridge()
    var onPan: ((UIPanGestureRecognizer) -> Void)?

    @objc func handle(_ gesture: UIPanGestureRecognizer) {
        onPan?(gesture)
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
    @State private var scrubCommitTask: Task<Void, Never>?
    @State private var scrubActive = false
    @State private var scrubValue: Double = 0
    @State private var scrubStep: Double = 10
    @State private var lastScrubMove: Date?
    @State private var isSheetPresented = false
    @State private var audioSheetPresented = false
    @FocusState private var focus: Control?

    private enum Control: Hashable {
        case rewind, playPause, forward, rate, danmu, danmuSettings, audio, scrubber
    }

    private let rateOptions: [Float] = [0.5, 1.0, 1.5, 2.0]

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
            scrubCommitTask?.cancel()
            danmuEngine.setRate(0)
        }
        .sheet(isPresented: $isSheetPresented, onDismiss: {
            audioSheetPresented = false
            DispatchQueue.main.async {
                focus = .playPause
            }
            revealControls()
        }) {
            if audioSheetPresented {
                FNOSAudioTracksSheet(
                    tracks: audioTracks,
                    currentID: audioTracks.first { $0.isEnabled }?.trackID
                ) { track in
                    coordinator.playerLayer?.player.select(track: track)
                }
            } else {
                FNOSDanmuSettingsSheet()
            }
        }
    }

    // MARK: 裸播放视图（无 KSPlayer 内置控制）+ 转盘滑动桥接

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
                    danmuEngine.setRate(Double(coordinator.playbackRate))
                }
            }
            .ignoresSafeArea()
            .focusable(!controlsVisible && !isSheetPresented)
            .onMoveCommand { _ in
                // 控制条隐藏时：任意方向键唤出控制条
                revealControls()
            }
            .onTapGesture {
                revealControls()
            }
            .onAppear {
                attachPanRecognizer()
            }
    }

    /// 在 KSPlayer 的 UIView 上挂 UIPanGestureRecognizer：遥控器转盘/触摸滑动 → 连续拖动进度
    private func attachPanRecognizer() {
        guard FNOSPanBridge.shared.onPan == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let videoView = coordinator.playerLayer?.player.view else {
                print("FNOS❗️挂滑动手势失败: 找不到播放器视图")
                return
            }
            let recognizer = UIPanGestureRecognizer(target: FNOSPanBridge.shared, action: #selector(FNOSPanBridge.handle(_:)))
            recognizer.cancelsTouchesInView = false
            videoView.addGestureRecognizer(recognizer)
            print("FNOSℹ️滑动手势已挂载")

            FNOSPanBridge.shared.onPan = { gesture in
                switch gesture.state {
                case .began:
                    revealControls()
                case .changed:
                    let translation = gesture.translation(in: gesture.view)
                    gesture.setTranslation(.zero, in: gesture.view)
                    // 速度门控：慢速滑动=移动焦点（不拖进度）；快速滑动/转盘旋转=拖动进度
                    // 一旦进入拖动就保持到松手（粘滞），方便快滑后减速微调
                    let vx = gesture.velocity(in: gesture.view).x
                    if !scrubActive, abs(vx) < 1600 { return }
                    let delta = Double(translation.x) * 0.2
                    let total = Double(max(coordinator.timemodel.totalTime, 1))
                    let base = scrubActive ? scrubValue : Double(coordinator.timemodel.currentTime)
                    scrubActive = true
                    scrubValue = min(max(base + delta, 0), total)
                    scheduleScrubCommit()
                case .ended, .cancelled:
                    commitScrubIfNeeded()
                default:
                    break
                }
            }
        }
    }

    // MARK: 自绘控制条

    private var controlBar: some View {
        VStack(spacing: 20) {
            // 片名 + 状态（左）
            HStack(alignment: .center) {
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

            // 主按钮（快进/快退/播放暂停）相对进度条居中；功能按钮靠右
            HStack(spacing: 44) {
                controlButton(.rewind, icon: "gobackward.15") {
                    coordinator.skip(interval: -15)
                }
                controlButton(.playPause, icon: isPlaying ? "pause.fill" : "play.fill") {
                    togglePlayPause()
                }
                controlButton(.forward, icon: "goforward.15") {
                    coordinator.skip(interval: 15)
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                HStack(spacing: 24) {
                    rateButton
                    controlButton(.danmu, icon: "text.bubble") {
                        showDanmu.toggle()
                    }
                    .opacity(showDanmu ? 1 : 0.35)
                    controlButton(.danmuSettings, icon: "slider.horizontal.3") {
                        audioSheetPresented = false
                        isSheetPresented = true
                    }
                    if !audioTracks.isEmpty {
                        controlButton(.audio, icon: "waveform") {
                            audioSheetPresented = true
                            isSheetPresented = true
                        }
                    }
                }
            }
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(.white)

            // 进度条（可聚焦拖动/快滑）+ 时间
            HStack(spacing: 14) {
                Text(timeString(displayTime))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white)
                scrubber
                Text(timeString(Double(coordinator.timemodel.totalTime)))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 90)
        .padding(.bottom, 48)
        .padding(.top, 24)
        .background(
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.55), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .onChange(of: focus) { newValue in
            if newValue != .scrubber {
                commitScrubIfNeeded()
            }
            scheduleHide()
        }
    }

    /// 可聚焦进度条：选中后左右键步进预览，连按自动加速
    private var scrubber: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, geo.size.width * displayFraction))
            }
            .frame(height: 6)
            .contentShape(Rectangle())
        }
        .frame(height: 28)
        .focusable(true)
        .focused($focus, equals: .scrubber)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left:
                scrub(by: -1)
            case .right:
                scrub(by: 1)
            default:
                break
            }
        }
    }

    /// 圆形玻璃选中背景（比图标略大）
    private func controlButton(_ control: Control, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 76, height: 76)
                .fnosGlass(focus == control, in: Circle())
        }
        .buttonStyle(.plain)
        .focused($focus, equals: control)
        .focusEffectDisabled()
    }

    /// 倍速按钮：0.5 → 1.0 → 1.5 → 2.0 循环
    private var rateButton: some View {
        Button {
            cycleRate()
        } label: {
            Text(String(format: "%.1fx", coordinator.playbackRate))
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .frame(width: 92, height: 76)
                .fnosGlass(focus == .rate, in: Capsule())
        }
        .buttonStyle(.plain)
        .focused($focus, equals: .rate)
        .focusEffectDisabled()
    }

    private func cycleRate() {
        let index = rateOptions.firstIndex(of: coordinator.playbackRate) ?? 1
        let next = rateOptions[(index + 1) % rateOptions.count]
        coordinator.playbackRate = next
        danmuEngine.setRate(Double(next))
        print("FNOSℹ️倍速: \(next)")
        revealControls()
    }

    // MARK: 快滑/拖动逻辑

    /// 当前展示时间：拖动预览优先，否则真实时间
    private var displayTime: Double {
        if scrubActive {
            return scrubValue
        }
        return Double(coordinator.timemodel.currentTime)
    }

    private var displayFraction: Double {
        let total = Double(max(coordinator.timemodel.totalTime, 1))
        return min(max(displayTime / total, 0), 1)
    }

    /// 方向键步进：0.45 秒内连续触发视为"长按/转盘滚动"，步长逐级加速（10s→180s）
    private func scrub(by direction: Double) {
        let now = Date()
        if let last = lastScrubMove, now.timeIntervalSince(last) < 0.45 {
            scrubStep = min(scrubStep * 1.6, 180)
        } else {
            scrubStep = 10
        }
        lastScrubMove = now

        let total = Double(max(coordinator.timemodel.totalTime, 1))
        let base = scrubActive ? scrubValue : Double(coordinator.timemodel.currentTime)
        scrubActive = true
        scrubValue = min(max(base + direction * scrubStep, 0), total)
        scheduleScrubCommit()
    }

    private func scheduleScrubCommit() {
        scrubCommitTask?.cancel()
        scrubCommitTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            commitScrubIfNeeded()
        }
    }

    private func commitScrubIfNeeded() {
        guard scrubActive else { return }
        scrubActive = false
        coordinator.seek(time: scrubValue)
        print("FNOSℹ️进度提交: \(Int(scrubValue))s")
    }

    // MARK: 状态助手

    private var isPlaying: Bool {
        coordinator.state.isPlaying
    }

    private var audioTracks: [MediaPlayerTrack] {
        coordinator.playerLayer?.player.tracks(mediaType: .audio) ?? []
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%02d:%02d", m, sec)
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
        guard !isSheetPresented else { return }
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

// MARK: - 弹幕设置面板

struct FNOSDanmuSettingsSheet: View {

    @AppStorage("fnos.danmu.fontSize") private var fontSize: Double = 26
    @AppStorage("fnos.danmu.opacity") private var opacity: Double = 1
    @AppStorage("fnos.danmu.speed") private var speed: Double = 1

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        VStack(spacing: 32) {
            Text("弹幕设置")
                .font(.title2.bold())

            stepRow(title: "字号", text: "\(Int(fontSize)) px") {
                fontSize = max(16, min(44, fontSize - 2))
            } up: {
                fontSize = min(44, fontSize + 2)
            }
            stepRow(title: "不透明度", text: "\(Int(opacity * 100)) %") {
                opacity = max(0.2, opacity - 0.05)
            } up: {
                opacity = min(1, opacity + 0.05)
            }
            stepRow(title: "速度", text: String(format: "%.1fx", speed)) {
                speed = max(0.5, speed - 0.1)
            } up: {
                speed = min(2.5, speed + 0.1)
            }

            Button {
                dismiss()
            } label: {
                Text("完成")
                    .frame(width: 260, height: 56)
            }
            .buttonStyle(.plain)
            .fnosGlass(true, in: Capsule())
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85).ignoresSafeArea())
    }

    /// tvOS 稳妥步进行：[-] 值 [+]（SwiftUI Slider 在 tvOS 焦点行为不可靠）
    private func stepRow(
        title: String,
        text: String,
        down: @escaping () -> Void,
        up: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 28) {
            Text(title)
                .font(.headline)
                .frame(width: 140, alignment: .leading)
            Button(action: down) {
                Image(systemName: "minus")
                    .frame(width: 72, height: 48)
            }
            .buttonStyle(.plain)
            .fnosGlass(true, in: Capsule())
            Text(text)
                .font(.title3.monospacedDigit())
                .frame(width: 140)
            Button(action: up) {
                Image(systemName: "plus")
                    .frame(width: 72, height: 48)
            }
            .buttonStyle(.plain)
            .fnosGlass(true, in: Capsule())
        }
    }
}

// MARK: - 音轨选择面板

struct FNOSAudioTracksSheet: View {

    let tracks: [MediaPlayerTrack]
    let currentID: Int32?
    let onSelect: (MediaPlayerTrack) -> Void

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Text("音轨")
                .font(.title2.bold())

            if tracks.isEmpty {
                Text("没有可切换的音轨")
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(tracks, id: \.trackID) { track in
                            Button {
                                onSelect(track)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: track.trackID == currentID ? "checkmark.circle.fill" : "circle")
                                    Text(track.description)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 28)
                                .padding(.vertical, 16)
                            }
                            .buttonStyle(.plain)
                            .fnosGlass(true, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 60)
                }
            }

            Button {
                dismiss()
            } label: {
                Text("完成")
                    .frame(width: 260, height: 56)
            }
            .buttonStyle(.plain)
            .fnosGlass(true, in: Capsule())
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85).ignoresSafeArea())
    }
}
