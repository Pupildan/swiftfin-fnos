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

@MainActor
struct FNOSMPVPlayerView: View {

    let item: FNOSItem
    let url: URL
    let authToken: String
    let title: String
    /// 同剧分集（换集条）
    var episodes: [FNOSItem] = []
    var onSelectEpisode: ((FNOSItem) -> Void)? = nil
    var onExit: () -> Void

    @State private var player: MPVPlayer?
    @StateObject private var danmu = FNOSDanmuEngine()

    @State private var ticker: Task<Void, Never>?
    @State private var subtitleTask: Task<Void, Never>?
    @State private var subtitleText: String = ""

    @State private var showDanmu = true
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    @State private var scrubActive = false
    @State private var scrubValue: Double = 0
    @State private var lastPersist: Double = 0

    @State private var showEpisodeStrip = false
    @State private var showInfo = false
    @State private var infoText = ""

    @FocusState private var focus: Control?

    private enum Control: Hashable {
        case rewind, playPause, forward, danmuToggle, episode, info, scrubber
    }

    private var resumeKey: String { "fnos.resume.\(item.Id)" }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            if let player {
                MPVVideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            // 弹幕层
            if showDanmu {
                FNOSDanmuView(engine: danmu)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // 字幕层（mpv 文本拦截 + 系统字体渲染，规避缺字体乱码）
            if !subtitleText.isEmpty {
                subtitleOverlay
                    .allowsHitTesting(false)
            }

            if controlsVisible, let player {
                controlBar(player)
                    .transition(.opacity)
            }

            if showInfo {
                infoPanel
                    .allowsHitTesting(false)
            }
        }
        .onAppear(perform: startIfNeeded)
        .onDisappear(perform: teardown)
        .onExitCommand { onExit() }
        .onPlayPauseCommand { togglePlayPause() }
        // 控制条隐藏时自身可聚焦，任意方向键唤出控制条
        .focusable(!controlsVisible)
        .onMoveCommand { _ in revealControls() }
        .onTapGesture { revealControls() }
    }

    // MARK: - 字幕

    private var subtitleOverlay: some View {
        VStack {
            Spacer()
            Text(subtitleText)
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.9), radius: 6, y: 2)
                .padding(.horizontal, 120)
                .padding(.bottom, 150)
        }
    }

    // MARK: - 控制条

    private func controlBar(_ player: MPVPlayer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 换集条（按需展开，避免一上来渲染一堆缩略图）
            if showEpisodeStrip, !episodes.isEmpty {
                episodeStrip
            }

            HStack(spacing: 22) {
                controlButton(.rewind, systemImage: "gobackward.10") {
                    player.seek(by: .seconds(-10))
                    revealControls()
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
                    revealControls()
                }

                controlButton(
                    .danmuToggle,
                    systemImage: showDanmu ? "text.bubble.fill" : "text.bubble",
                    subtitle: showDanmu ? "弹幕开" : "弹幕关"
                ) {
                    showDanmu.toggle()
                    danmu.setRate(showDanmu ? 1 : 0)
                    revealControls()
                }

                if !episodes.isEmpty {
                    controlButton(.episode, systemImage: "rectangle.stack") {
                        showEpisodeStrip.toggle()
                        revealControls()
                    }
                }

                controlButton(.info, systemImage: "info.circle") {
                    showInfo.toggle()
                    infoText = infoSummary(player)
                    revealControls()
                }

                Spacer()
            }
            .padding(.horizontal, 60)

            HStack(spacing: 18) {
                Text(timeText(seconds(player.position)))
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 84, alignment: .leading)

                scrubber(player)

                Text(timeText(seconds(player.duration)))
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 84, alignment: .trailing)
            }
            .padding(.horizontal, 60)
        }
        .padding(.bottom, 46)
        .padding(.top, 26)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    private var episodeStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 14) {
                ForEach(episodes) { ep in
                    Button {
                        onSelectEpisode?(ep)
                    } label: {
                        Text("第 \(ep.IndexNumber ?? 0) 集")
                            .font(.system(size: 20, weight: .semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(ep.Id == item.Id ? Color.white : Color.white.opacity(0.18))
                            )
                            .foregroundColor(ep.Id == item.Id ? .black : .white)
                    }
                    .buttonStyle(FNOSBareButtonStyle())
                }
            }
            .padding(.horizontal, 60)
        }
        .frame(height: 56)
    }

    private func scrubber(_ player: MPVPlayer) -> some View {
        let total = max(seconds(player.duration), 1)
        let current = scrubActive ? scrubValue : seconds(player.position)
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
                    .opacity(focus == .scrubber ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .frame(height: 26)
        .focusable()
        .focused($focus, equals: .scrubber)
        .onMoveCommand { direction in
            switch direction {
            case .left:
                let target = max(seconds(player.position) - 10, 0)
                player.seek(to: .seconds(target))
            case .right:
                let target = min(seconds(player.position) + 10, seconds(player.duration))
                player.seek(to: .seconds(target))
            case .up:
                focus = .playPause
            default:
                break
            }
            revealControls()
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
                    .font(.system(size: 22, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 18, weight: .medium))
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
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(18)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .padding(.leading, 60)
        .padding(.bottom, 190)
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
        let startLatency = diagnostics.startLatencySeconds.map { String(format: "%.1fs", $0) } ?? "-"

        return """
        mpv 状态 \(String(describing: player.state)) · 起播 \(startLatency)
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
                // 中文字幕编码兜底（文本拦截失效时的保险）
                "sub-codepage": "auto",
            ],
            autoPlay: true,
            hardwareDecoding: .videoToolbox,
            initialBufferSeconds: .seconds(2),
            logLevel: .warning,
            networkCacheSeconds: .seconds(30),
            videoOutput: .metal
        )

        let player = MPVPlayer(configuration: configuration)
        player.setTextSubtitleInterceptionEnabled(true)
        self.player = player

        // 续播
        let resume = UserDefaults.standard.double(forKey: resumeKey)
        if resume > 30, resume < 3600 * 4 {
            player.load(url, startTime: .seconds(resume))
        } else {
            player.load(url)
        }

        danmu.load(
            title: item.Name ?? title,
            seriesTitle: item.SeriesName,
            episodeNumber: item.IndexNumber
        )

        startTicker(player)
        startSubtitleStream(player)
        revealControls()
        focus = .playPause
    }

    private func startTicker(_ player: MPVPlayer) {
        ticker?.cancel()
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                let position = seconds(player.position)
                if !scrubActive {
                    scrubValue = position
                }
                danmu.sync(mediaTime: position)
                danmu.setRate(player.isPaused ? 0 : 1)

                // 每 4 秒落一次进度，退出可续播
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
        revealControls()
    }

    private func revealControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            if focus == .scrubber { return }
            controlsVisible = false
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

    /// 把冗长的 MPVDolbyVisionStatus 浓缩成一行：源 profile / 生效 profile / 是否转换
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
        let effective = pick("effectiveProfile") ?? "-"
        let conversion = pick("conversion") ?? "-"
        return "源 \(source) / 生效 \(effective) / \(conversion)"
    }
}

// MARK: - 控制按钮外观

private struct FNOSControlChrome: ViewModifier {

    let isFocused: Bool
    let wide: Bool

    func body(content: Content) -> some View {
        content
            .foregroundColor(isFocused ? .black : .white)
            .padding(.horizontal, wide ? 30 : 20)
            .frame(height: 56)
            .background(
                Capsule()
                    .fill(isFocused ? Color.white : Color.black.opacity(0.45))
            )
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .animation(.easeOut(duration: 0.14), value: isFocused)
    }
}
