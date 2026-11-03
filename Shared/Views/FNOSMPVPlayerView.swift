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
// 焦点设计（v59）：
// - `.surface`（画面层）**始终存在**，控制条隐藏时它是唯一可聚焦对象，方向键按下去就能唤回
//   控制条。之前版本把"可聚焦性"挂在根视图上反复开关，导致焦点当场丢失、按键彻底失灵。
// - 控制条 5 秒无操作自动淡出（暂停 / 选集展开 / 弹幕设置打开时不隐藏），任何按键或调整都
//   会刷新活动时间。
// - 选集条每一集都有明确的焦点态（白底黑字 + 放大）与"正在播放"标记，不再分不清焦点在哪。

@MainActor
struct FNOSMPVPlayerView: View {

    let item: FNOSItem
    let title: String
    let authToken: String
    let native: FNOSNativeClient
    let range: FNOSNativeClient.MediaRange
    /// 引擎切换时带过来的播放进度（无感续播）
    var initialSeek: Double? = nil
    /// 由自动分流选中（而不是用户手动开 mpv）→ 顶部提示一次
    var autoSelected: Bool = false
    /// v86：播放进度回调（ticker 每 ~4s 触发一次；容器做 10s 节流后上报服务端）。
    /// v92：带总时长（本地记录存 runtime 供首页进度条换算）
    var onProgress: ((Double, Double) -> Void)? = nil
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
    @State private var showDanmuSettings = false
    @State private var showInfo = false
    @State private var infoText = ""
    @State private var switching = false
    /// 自动分流提示（只在自动切换时出现一次）
    @State private var engineToast: String?

    /// 控制条是否可见（自动隐藏）
    @State private var controlsVisible = true
    /// 最近一次用户操作时间（刷新自动隐藏计时）
    @State private var lastActivity = Date()

    @State private var lastPersist: Double = 0
    @State private var lastSeekAt = Date.distantPast
    @State private var seekBurst = 0

    // 弹幕外观（与 FNOSDanmuView 共用同一批键）
    @AppStorage("fnos.danmu.fontSize") private var danmuFontSize: Double = 26
    @AppStorage("fnos.danmu.opacity") private var danmuOpacity: Double = 1
    @AppStorage("fnos.danmu.speed") private var danmuSpeed: Double = 1
    @AppStorage("fnos.danmu.offsetY") private var danmuOffsetY: Double = 0

    @FocusState private var focus: Control?
    @FocusState private var danmuFocus: DanmuRow?

    private enum Control: Hashable {
        case surface
        case rewind, playPause, forward, danmuToggle, danmuSettings, episode, info, scrubber
        case episodeItem(String)
    }

    private enum DanmuRow: Hashable {
        case size, speed, opacity, offsetY, toggle
    }

    init(
        item: FNOSItem,
        title: String,
        authToken: String,
        native: FNOSNativeClient,
        range: FNOSNativeClient.MediaRange,
        initialSeek: Double? = nil,
        autoSelected: Bool = false,
        onProgress: ((Double) -> Void)? = nil,
        onExit: @escaping () -> Void
    ) {
        self.item = item
        self.title = title
        self.authToken = authToken
        self.native = native
        self.range = range
        self.initialSeek = initialSeek
        self.autoSelected = autoSelected
        self.onProgress = onProgress
        self.onExit = onExit
        _currentURL = State(initialValue: range.url)
        _currentGUID = State(initialValue: range.itemGUID)
        _currentNumber = State(initialValue: range.episodeNumber)
        _episodes = State(initialValue: range.episodes)
        _engineToast = State(
            initialValue: autoSelected ? "已自动切换 mpv 引擎（杜比视界色彩转换）" : nil
        )
    }

    private var resumeKey: String { "fnos.resume.native.\(currentGUID)" }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            if let player {
                videoSurface(player)

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

                if controlsVisible {
                    controlBar(player)
                        .transition(.opacity)
                }

                if showDanmuSettings {
                    danmuSettingsPanel
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                if showInfo {
                    infoPanel
                        .allowsHitTesting(false)
                }

                if let engineToast {
                    Text(engineToast)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.62), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 54)
                        .allowsHitTesting(false)
                        .transition(.opacity)
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
        .onExitCommand(perform: handleExitCommand)
        .onPlayPauseCommand {
            bumpActivity()
            showControls()
            togglePlayPause()
        }
        .onChange(of: focus) { _, newValue in
            // 焦点落到画面层说明是自动隐藏造成的，不算用户活动
            if newValue == .surface { return }
            if newValue != nil { bumpActivity() }
        }
    }

    // MARK: - 画面层（唯一的兜底焦点）

    private func videoSurface(_ player: MPVPlayer) -> some View {
        ZStack {
            MPVVideoPlayer(player: player)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            Color.clear
                .contentShape(Rectangle())
                .focusable(!controlsVisible)
                .focused($focus, equals: .surface)
                .focusEffectDisabled()
                .onMoveCommand { _ in
                    // 控制条隐藏时任意方向键都能唤回
                    showControls()
                }
        }
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

            HStack(spacing: 18) {
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

                controlButton(.danmuSettings, systemImage: "slider.horizontal.3", subtitle: "弹幕设置") {
                    openDanmuSettings()
                }

                if episodes.count > 1 {
                    controlButton(
                        .episode,
                        systemImage: "rectangle.stack",
                        subtitle: showEpisodeStrip ? "收起" : "选集",
                        wide: showEpisodeStrip
                    ) {
                        toggleEpisodeStrip()
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
    }

    // MARK: - 选集条

    private var episodeStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(episodes) { ep in
                        episodeChip(ep)
                            .id(ep.guid)
                    }
                }
                .padding(.horizontal, 52)
                .padding(.vertical, 6)
            }
            .frame(height: 66)
            .focusSection()
            .onAppear {
                proxy.scrollTo(currentGUID, anchor: .center)
            }
            .onChange(of: currentGUID) { _, guid in
                proxy.scrollTo(guid, anchor: .center)
            }
        }
    }

    private func episodeChip(_ ep: FNOSNativeClient.EpisodeRef) -> some View {
        let isFocused = focus == .episodeItem(ep.guid)
        let isCurrent = ep.number == currentNumber

        return Button {
            switchEpisode(to: ep)
        } label: {
            HStack(spacing: 6) {
                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                }
                Text("第 \(ep.number) 集")
                    .font(.system(size: 19, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(
                        isFocused
                            ? Color.white
                            : (isCurrent ? Color.white.opacity(0.30) : Color.white.opacity(0.12))
                    )
            )
            .foregroundColor(isFocused ? .black : .white)
            .overlay(
                Capsule().stroke(
                    isFocused ? Color.clear : Color.white.opacity(isCurrent ? 0.6 : 0.18),
                    lineWidth: isCurrent ? 2 : 1
                )
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 10, y: 4)
            .animation(.easeOut(duration: 0.12), value: isFocused)
        }
        .buttonStyle(FNOSBareButtonStyle())
        .focused($focus, equals: .episodeItem(ep.guid))
    }

    private func toggleEpisodeStrip() {
        bumpActivity()
        let next = !showEpisodeStrip
        withAnimation(.easeInOut(duration: 0.18)) {
            showEpisodeStrip = next
        }
        if next {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                focus = .episodeItem(currentGUID)
                bumpActivity()
            }
        } else {
            focus = .episode
        }
    }

    // MARK: - 进度条

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
        .focusEffectDisabled()
        .focused($focus, equals: .scrubber)
        .onMoveCommand { direction in
            switch direction {
            case .left:
                bumpActivity()
                quickSeek(player, by: -1)
            case .right:
                bumpActivity()
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
        return Button {
            bumpActivity()
            action()
        } label: {
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

    // MARK: - 弹幕设置面板

    private var danmuSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("弹幕设置")
                    .font(.system(size: 24, weight: .bold))
                Spacer()
                Text("← → 调整　Menu 返回")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(.bottom, 2)

            danmuRow(.size, label: "字号", value: "\(Int(danmuFontSize)) pt")
            danmuRow(.speed, label: "滚动速度", value: String(format: "%.1fx", danmuSpeed))
            danmuRow(.opacity, label: "不透明度", value: "\(Int((danmuOpacity * 100).rounded()))%")
            danmuRow(.offsetY, label: "垂直位置", value: offsetLabel)
            danmuRow(.toggle, label: "显示弹幕", value: showDanmu ? "开" : "关")
        }
        .padding(28)
        .frame(width: 620)
        // 不用 Material：tvOS 焦点引擎见到材质会在聚焦视图上叠系统高亮板（HANDOVER 红线 5）
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 80)
        .padding(.bottom, 150)
        .onExitCommand(perform: closeDanmuSettings)
    }

    private var offsetLabel: String {
        if danmuOffsetY == 0 { return "默认" }
        return danmuOffsetY > 0 ? "下移 \(Int(danmuOffsetY)) pt" : "上移 \(Int(-danmuOffsetY)) pt"
    }

    private func danmuRow(_ row: DanmuRow, label: String, value: String) -> some View {
        let isFocused = danmuFocus == row
        return HStack {
            Text(label)
                .font(.system(size: 19, weight: .medium))
            Spacer()
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isFocused ? Color.white : Color.white.opacity(0.08))
        )
        .foregroundColor(isFocused ? .black : .white)
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.white.opacity(isFocused ? 0 : 0.14), lineWidth: 1)
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .focusable()
        .focusEffectDisabled()
        .focused($danmuFocus, equals: row)
        .onMoveCommand { direction in
            switch direction {
            case .left:
                bumpActivity()
                adjustDanmu(row, delta: -1)
            case .right:
                bumpActivity()
                adjustDanmu(row, delta: 1)
            default:
                break
            }
        }
        .onTapGesture {
            bumpActivity()
            if row == .toggle {
                showDanmu.toggle()
                danmu.setRate(showDanmu ? 1 : 0)
            }
        }
    }

    private func adjustDanmu(_ row: DanmuRow, delta: Double) {
        switch row {
        case .size:
            danmuFontSize = min(max(danmuFontSize + delta * 2, 18), 48)
        case .speed:
            let next = ((danmuSpeed + delta * 0.1) * 10).rounded() / 10
            danmuSpeed = min(max(next, 0.5), 3.0)
        case .opacity:
            let next = ((danmuOpacity + delta * 0.05) * 100).rounded() / 100
            danmuOpacity = min(max(next, 0.2), 1)
        case .offsetY:
            danmuOffsetY = min(max(danmuOffsetY + delta * 20, -80), 420)
        case .toggle:
            showDanmu.toggle()
            danmu.setRate(showDanmu ? 1 : 0)
        }
    }

    private func openDanmuSettings() {
        bumpActivity()
        withAnimation(.easeOut(duration: 0.18)) { showDanmuSettings = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            danmuFocus = .size
            bumpActivity()
        }
    }

    private func closeDanmuSettings() {
        withAnimation(.easeOut(duration: 0.16)) { showDanmuSettings = false }
        danmuFocus = nil
        focus = .danmuSettings
        bumpActivity()
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

    // MARK: - 控制条显隐

    private func bumpActivity() {
        lastActivity = Date()
    }

    private func showControls() {
        bumpActivity()
        guard !controlsVisible else { return }
        withAnimation(.easeOut(duration: 0.18)) { controlsVisible = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            focus = .playPause
            bumpActivity()
        }
    }

    private func hideControls() {
        guard controlsVisible else { return }
        // 顺序很关键：先把控制条从视图树里撤掉，surface 才变成可聚焦对象，然后把焦点落上去。
        // 反过来（先给一个即将消失的按钮设焦点）就会复现"焦点丢失、按键全无响应"的老问题。
        withAnimation(.easeInOut(duration: 0.22)) { controlsVisible = false }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            focus = .surface
        }
    }

    private func handleExitCommand() {
        bumpActivity()
        if showDanmuSettings {
            closeDanmuSettings()
        } else if showEpisodeStrip {
            toggleEpisodeStrip()
        } else {
            onExit()
        }
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
        // 切引擎带过来的进度优先；其次本地续播；都没有就从头播
        if let initialSeek, initialSeek > 1 {
            player.load(currentURL, startTime: .seconds(initialSeek))
        } else if resume > 30 {
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
            bumpActivity()
        }

        // 自动分流提示 3.5 秒后淡出
        if engineToast != nil {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                withAnimation(.easeOut(duration: 0.3)) { engineToast = nil }
            }
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
                    onProgress?(position, seconds(player.duration))
                }

                // 自动隐藏：播放中、无面板展开、5 秒无操作
                if controlsVisible,
                   !player.isPaused,
                   !showEpisodeStrip,
                   !showDanmuSettings,
                   !showInfo,
                   Date().timeIntervalSince(lastActivity) > 5 {
                    hideControls()
                }

                // 焦点兜底：任何原因导致焦点丢失都重新落到有效对象上
                if focus == nil {
                    focus = controlsVisible ? .playPause : .surface
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
        bumpActivity()
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
        bumpActivity()

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
            bumpActivity()
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
            .padding(.horizontal, wide ? 28 : 16)
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
