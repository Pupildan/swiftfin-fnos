import Foundation
import MPVUI
import SwiftUI

// MARK: - MPV 引擎播放页（实验）
//
// 为什么要它：KSPlayer 免费版不解 DoVi 的 IPTPQc2，P5 片源必然紫绿；MPVUI 的 gpu-next
// （libplacebo）能做 DoVi → BT.709 的 reshape + tonemap，PC 端已用同一套管线实测通过。
//
// 三个关键配置，缺一不可：
// 1. `videoOutput: .metal` —— 默认 `.sampleBuffer` 走 AVFoundation 自己转色彩，会绕过
//    gpu-next 的着色器与 tone mapping，换了 mpv 也照样偏色。
// 2. `additionalOptions["http-header-fields"]` —— 原生 media/range 只需要 Authorization，
//    值里没有逗号（该选项按逗号切分多值，含逗号的 X-Emby-Authorization 会切坏）。
// 3. `setTextSubtitleInterceptionEnabled(true)` —— mpv 侧不带字体，内封中文字幕会因缺字体
//    变乱码；拦截成文本交给我们用系统字体渲染，编码与字体问题一次解决。
//
// 焦点设计（v58 修正）：控制条常显，不再自动隐藏。
// 之前体验差的原因：控制条隐藏时把根视图设成 `focusable(true)`，唤出控制条后根视图又变回
// 不可聚焦，焦点当场丢失 → 方向键彻底没反应、按钮再也够不着。

@MainActor
struct FNOSMPVPlayerView: View {

    let item: FNOSItem
    let title: String
    let authToken: String
    let native: FNOSNativeClient
    let range: FNOSNativeClient.MediaRange
    var onExit: () -> Void

    @State private var player: MPVPlayer?
    @StateObject private var danmu = FNOSDanmuEngine()

    @State private var currentURL: URL
    @State private var currentGUID: String
    @State private var currentNumber: Int?
    @State private var episodes: [FNOSNativeClient.EpisodeRef]

    @State private var ticker: Task<Void, Never>?
    @State private var subtitleTask: Task<Void, Never>?
    @State private var subtitleText: String = ""

    @State private var showDanmu = true
    @State private var showEpisodeStrip = false
    @State private var showInfo = false
    @State private var infoText = ""
    @State private var switching = false

    @State private var lastPersist: Double = 0
    @State private var lastSeekAt = Date.distantPast
    @State private var seekBurst = 0

    @FocusState private var focus: Control?

    private enum Control: Hashable {
        case rewind, playPause, forward, danmuToggle, episode, info, scrubber
    }

    init(
        item: FNOSItem,
        title: String,
        authToken: String,
        native: FNOSNativeClient,
        range: FNOSNativeClient.MediaRange,
        onExit: @escaping () -> Void
    ) {
        self.item = item
        self.title = title
        self.authToken = authToken
        self.native = native
        self.range = range
        self.onExit = onExit
        _currentURL = State(initialValue: range.url)
        _currentGUID = State(initialValue: range.itemGUID)
        _currentNumber = State(initialValue: range.episodeNumber)
        _episodes = State(initialValue: range.episodes)
    }

    private var resumeKey: String { "fnos.resume.native.\(currentGUID)" }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            if let player {
                MPVVideoPlayer(player: player)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // 弹幕层
                if showDanmu {
                    FNOSDanmuView(engine: danmu)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // 字幕层（mpv 文本拦截 + 系统字体渲染）
                if !subtitleText.isEmpty {
                    subtitleOverlay
                        .allowsHitTesting(false)
                }

                controlBar(player)

                if showInfo {
                    infoPanel
                        .allowsHitTesting(false)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在启动 mpv…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear(perform: startIfNeeded)
        .onDisappear(perform: teardown)
        .onExitCommand { onExit() }
        .onPlayPauseCommand { togglePlayPause() }
    }

    // MARK: - 字幕

    private var subtitleOverlay: some View {
        VStack {
            Spacer()
            Text(subtitleText)
                .font(.system(size: 42, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.9), radius: 6, y: 2)
                .padding(.horizontal, 120)
                .padding(.bottom, 170)
        }
    }

    // MARK: - 控制条

    private func controlBar(_ player: MPVPlayer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showEpisodeStrip, !episodes.isEmpty {
                episodeStrip
            }

            HStack(spacing: 20) {
                controlButton(.rewind, systemImage: "gobackward.10") {
                    player.seek(by: .seconds(-10))
                }

                controlButton(
                    .playPause,
                    systemImage: player.isPaused ? "play.fill" : "pause.fill",
                    wide: true
                ) {
                    togglePlayPause()
                }

                controlButton(.forward, systemImage: "goforward.10") {
                    player.seek(by: .seconds(10))
                }

                controlButton(
                    .danmuToggle,
                    systemImage: showDanmu ? "text.bubble.fill" : "text.bubble",
                    subtitle: showDanmu ? "弹幕开" : "弹幕关"
                ) {
                    showDanmu.toggle()
                    danmu.setRate(showDanmu ? 1 : 0)
                }

                if episodes.count > 1 {
                    controlButton(
                        .episode,
                        systemImage: "rectangle.stack",
                        subtitle: showEpisodeStrip ? "收起" : "选集",
                        wide: showEpisodeStrip
                    ) {
                        showEpisodeStrip.toggle()
                    }
                }

                controlButton(.info, systemImage: "info.circle") {
                    showInfo.toggle()
                    infoText = infoSummary(player)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 52)
            .focusSection()

            HStack(spacing: 16) {
                Text(timeText(seconds(player.position)))
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 80, alignment: .leading)

                scrubber(player)

                Text(timeText(seconds(player.duration)))
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 80, alignment: .trailing)
            }
            .padding(.horizontal, 52)
            .focusSection()
        }
        .padding(.top, 24)
        .padding(.bottom, 40)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .defaultFocus($focus, .playPause)
    }

    private var episodeStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(episodes) { ep in
                    Button {
                        switchEpisode(to: ep)
                    } label: {
                        Text("第 \(ep.number) 集")
                            .font(.system(size: 19, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(
                                Capsule()
                                    .fill(ep.number == currentNumber ? Color.white : Color.white.opacity(0.16))
                            )
                            .foregroundColor(ep.number == currentNumber ? .black : .white)
                            .overlay(
                                Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1)
                            )
                    }
                    .buttonStyle(FNOSBareButtonStyle())
                }
            }
            .padding(.horizontal, 52)
        }
        .frame(height: 54)
        .focusSection()
    }

    private func scrubber(_ player: MPVPlayer) -> some View {
        let total = max(seconds(player.duration), 1)
        let current = seconds(player.position)
        let fraction = min(max(current / total, 0), 1)

        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(proxy.size.width * fraction, 4))
            }
            .frame(height: 8)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .offset(x: max(proxy.size.width * fraction - 9, -9))
                    .opacity(focus == .scrubber ? 1 : 0.85)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(focus == .scrubber ? Color.white.opacity(0.14) : Color.clear)
            )
        }
        .frame(height: 26)
        .focusable()
        .focused($focus, equals: .scrubber)
        .onMoveCommand { direction in
            switch direction {
            case .left:
                quickSeek(player, by: -1)
            case .right:
                quickSeek(player, by: 1)
            case .up:
                focus = .playPause
            default:
                break
            }
        }
    }

    private func controlButton(
        _ control: Control,
        systemImage: String,
        subtitle: String? = nil,
        wide: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == control
        return Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 17, weight: .medium))
                }
            }
            .modifier(FNOSControlChrome(isFocused: isFocused, wide: wide))
        }
        .buttonStyle(FNOSBareButtonStyle())
        .focused($focus, equals: control)
    }

    // MARK: - 诊断面板

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(infoText)
                .font(.system(size: 15, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(16)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .padding(.leading, 52)
        .padding(.bottom, 180)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func infoSummary(_ player: MPVPlayer) -> String {
        let diagnostics = player.playbackDiagnostics

        func num(_ value: Int64?) -> String { value.map(String.init) ?? "-" }
        func fps(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "-" }
            return String(format: "%.1f", value)
        }

        let decoder = diagnostics.decoder.selectedDecoder ?? "-"
        let hardware = diagnostics.decoder.videoToolboxSessionUsesHardware.map { $0 ? "硬解" : "软解" } ?? "-"

        return """
        解码 \(decoder) \(hardware)
        丢帧 解码 \(num(diagnostics.decoderDroppedFrames)) / 输出 \(num(diagnostics.outputDroppedFrames)) / 错时 \(num(diagnostics.mistimedFrames))
        帧率 容器 \(fps(diagnostics.containerFramesPerSecond)) → 解码 \(fps(diagnostics.estimatedDecodedFramesPerSecond)) / 显示 \(fps(diagnostics.estimatedDisplayFramesPerSecond)) (面板 \(fps(diagnostics.nominalDisplayFramesPerSecond)))
        色彩 \(shortDV(player))
        """
    }

    // MARK: - 生命周期

    private func startIfNeeded() {
        guard player == nil else { return }

        let configuration = MPVPlayerConfiguration(
            additionalOptions: [
                "http-header-fields": "Authorization: \(authToken)",
            ],
            autoPlay: true,
            hardwareDecoding: .videoToolbox,
            initialBufferSeconds: .seconds(2),
            logLevel: .warning,
            networkCacheSeconds: .seconds(15),
            videoOutput: .metal
        )

        let player = MPVPlayer(configuration: configuration)
        player.setTextSubtitleInterceptionEnabled(true)
        self.player = player

        let resume = UserDefaults.standard.double(forKey: resumeKey)
        if resume > 30 {
            player.load(currentURL, startTime: .seconds(resume))
        } else {
            player.load(currentURL)
        }

        loadDanmu()
        startTicker(player)
        startSubtitleStream(player)

        // 按钮要等 player 出现后才存在，这里延迟一次把焦点落到播放键
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            focus = .playPause
        }
    }

    private func loadDanmu() {
        Task { @MainActor in
            await danmu.load(
                title: item.Name ?? title,
                seriesTitle: item.SeriesName,
                episodeNumber: currentNumber ?? item.IndexNumber
            )
        }
    }

    private func startTicker(_ player: MPVPlayer) {
        ticker?.cancel()
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                let position = seconds(player.position)
                danmu.sync(mediaTime: position)
                danmu.setRate(player.isPaused ? 0 : 1)

                if abs(position - lastPersist) > 4 {
                    lastPersist = position
                    UserDefaults.standard.set(position, forKey: resumeKey)
                }

                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func startSubtitleStream(_ player: MPVPlayer) {
        subtitleTask?.cancel()
        subtitleTask = Task { @MainActor in
            for await snapshot in player.textSubtitleStream() {
                subtitleText = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func teardown() {
        if let player {
            UserDefaults.standard.set(seconds(player.position), forKey: resumeKey)
            player.stop()
        }
        ticker?.cancel()
        subtitleTask?.cancel()
        danmu.setRate(0)
    }

    // MARK: - 行为

    private func togglePlayPause() {
        guard let player else { return }
        if player.isPaused {
            player.play()
        } else {
            player.pause()
        }
    }

    /// 连续按左右时自动加速：10s → 30s → 60s
    private func quickSeek(_ player: MPVPlayer, by direction: Double) {
        let now = Date()
        if now.timeIntervalSince(lastSeekAt) < 1.2 {
            seekBurst = min(seekBurst + 1, 4)
        } else {
            seekBurst = 0
        }
        lastSeekAt = now

        let step: Double = seekBurst >= 3 ? 60 : (seekBurst >= 1 ? 30 : 10)
        let target = min(max(seconds(player.position) + direction * step, 0), seconds(player.duration))
        player.seek(to: .seconds(target))
    }

    private func switchEpisode(to ep: FNOSNativeClient.EpisodeRef) {
        guard !switching, ep.number != currentNumber else { return }
        switching = true

        Task { @MainActor in
            defer { switching = false }
            guard let next = await native.mediaRange(itemGUID: ep.guid) else { return }

            if let player, seconds(player.position) > 0 {
                UserDefaults.standard.set(seconds(player.position), forKey: resumeKey)
            }

            currentGUID = ep.guid
            currentNumber = ep.number
            currentURL = next.url
            lastPersist = 0
            subtitleText = ""

            guard let player else { return }
            let resume = UserDefaults.standard.double(forKey: resumeKey)
            let start: Duration? = resume > 30 ? .seconds(resume) : nil
            player.load(next.url, startTime: start)
            loadDanmu()
            focus = .playPause
        }
    }

    // MARK: - 格式化

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    private func timeText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let total = Int(value.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func shortDV(_ player: MPVPlayer) -> String {
        let text = String(describing: player.dolbyVisionStatus)

        func pick(_ key: String) -> String? {
            guard let range = text.range(of: "\(key): ") else { return nil }
            let rest = text[range.upperBound...]
            let end = rest.firstIndex { $0 == "," || $0 == ")" } ?? rest.endIndex
            let value = rest[..<end].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }

        let source = pick("sourceProfile") ?? "-"
        let conversion = pick("conversion") ?? "-"
        return "源 \(source) / \(conversion)"
    }
}

// MARK: - 控制按钮外观

private struct FNOSControlChrome: ViewModifier {

    let isFocused: Bool
    let wide: Bool

    func body(content: Content) -> some View {
        content
            .foregroundColor(isFocused ? .black : .white)
            .padding(.horizontal, wide ? 28 : 18)
            .frame(height: 54)
            .background(
                Capsule()
                    .fill(isFocused ? Color.white : Color.black.opacity(0.45))
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(isFocused ? 0 : 0.28), lineWidth: 1.5)
            )
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .animation(.easeOut(duration: 0.14), value: isFocused)
    }
}
