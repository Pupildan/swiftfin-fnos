import Foundation
import MPVUI
import SwiftUI
import UIKit

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
    /// v184: 服务器跳过配置（秒）——来自 play/info play_config，null = 不跳过
    /// v206: 改为 @State——设置面板改值后立即更新，tick 下一轮即生效
    @State private var skipOpening: Double? = nil
    @State private var skipEnding: Double? = nil
    /// 由自动分流选中（而不是用户手动开 mpv）→ 顶部提示一次
    var autoSelected: Bool = false
    /// v86：播放进度回调（ticker 每 ~4s 触发一次；容器做 10s 节流后上报服务端）。
    /// v92：带总时长（本地记录存 runtime 供首页进度条换算）
    var onProgress: ((Double, Double) -> Void)? = nil
    /// v119：播完回调（mpv 引擎自动连播下一集；KS 引擎同签名）
    var onFinished: (() -> Void)? = nil
    var onExit: () -> Void

    @State private var player: MPVPlayer?
    @StateObject private var danmu = FNOSDanmuEngine()

    @State private var currentURL: URL
    @State private var currentGUID: String
    @State private var currentNumber: Int?
    @State private var episodes: [FNOSNativeClient.EpisodeRef]
    /// v206: 当前剧集级 parent_guid（片头片尾设置推服务端用；切集时随 mediaRange 刷新）
    @State private var parentGUID: String?

    @State private var ticker: Task<Void, Never>?
    @State private var subtitleTask: Task<Void, Never>?
    @State private var subtitleText: String = ""

    @State private var showDanmu = true
    @State private var showEpisodeStrip = false
    @State private var showDanmuSettings = false
    /// v206: 片头片尾跳过设置弹层（独立按钮，与弹幕设置同款玻璃面板）
    @State private var showSkipSettings = false
    /// v206: 设置面板防抖推服务端的任务（0.5s 内连续改值只发一次，Web 端同语义）
    @State private var skipPushTask: Task<Void, Never>?
    /// v207: 片头片尾面板实时位置/总时长（面板打开期间由 ticker 更新，与 KS 同款）
    @State private var skipPanelPos: Double = 0
    @State private var skipPanelDur: Double = 0
    @State private var switching = false
    /// v192: 关闭弹层后焦点回到「打开该弹层的那个按钮」（用户令：不回播放键）
    @State private var sheetReturnFocus: Control? = nil
    /// 自动分流提示（只在自动切换时出现一次）
    @State private var engineToast: String?

    /// 控制条是否可见（自动隐藏）
    @State private var controlsVisible = true
    /// 最近一次用户操作时间（刷新自动隐藏计时）
    @State private var lastActivity = Date()

    @State private var lastPersist: Double = 0
    /// v184: 自动跳过片头/片尾（各单次触发）
    @State private var introSkipped = false
    @State private var endingSkipped = false
    /// v119：播放结束只回调一次
    @State private var didFinish = false

    // v191: 与 KS 播放器 1:1 对齐的状态（弹窗/续播选择窗/进度梯子/换集条焦点）
    @State private var showAudioSheet = false
    @State private var showSubtitleSheet = false
    @State private var showResumeChoice = false
    @State private var resumeChoiceTarget: Double = 0
    @State private var resumeAutoTask: Task<Void, Never>?
    @State private var scrubActive = false
    @State private var scrubValue: Double = 0
    @State private var scrubCommitTask: Task<Void, Never>?
    @State private var lastScrubMove: Date?
    @State private var scrubStep: Double = 10
    @State private var scrubLevel = 0
    @FocusState private var focusedChip: String?

    private let rateOptions: [Double] = [0.5, 1.0, 1.5, 2.0]

    @FocusState private var focus: Control?

    private enum Control: Hashable {
        case surface
        case rewind, playPause, forward, rate, danmu, danmuSettings, audio, subtitle, info, scrubber
        case skipSettings
        case resumeStartOver, resumeContinue
    }

    init(
        item: FNOSItem,
        title: String,
        authToken: String,
        native: FNOSNativeClient,
        range: FNOSNativeClient.MediaRange,
        initialSeek: Double? = nil,
        skipOpening: Double? = nil,
        skipEnding: Double? = nil,
        autoSelected: Bool = false,
        onProgress: ((Double, Double) -> Void)? = nil,
        onFinished: (() -> Void)? = nil,
        onExit: @escaping () -> Void
    ) {
        self.item = item
        self.title = title
        self.authToken = authToken
        self.native = native
        self.range = range
        self.initialSeek = initialSeek
        _skipOpening = State(initialValue: skipOpening)
        _skipEnding = State(initialValue: skipEnding)
        self.autoSelected = autoSelected
        self.onProgress = onProgress
        self.onFinished = onFinished
        self.onExit = onExit
        _currentURL = State(initialValue: range.url)
        _currentGUID = State(initialValue: range.itemGUID)
        _currentNumber = State(initialValue: range.episodeNumber)
        _episodes = State(initialValue: range.episodes)
        _parentGUID = State(initialValue: range.parentGUID)
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

                // v191: 续播选择窗（与 KS 同款，>30s 记录弹出，3s 未确认自动续播）
                if showResumeChoice {
                    resumeChoiceOverlay
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
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
            .onAppear {
                // v119：播放期间禁止系统屏保/休眠
                UIApplication.shared.isIdleTimerDisabled = true
                startIfNeeded()
            }
            .onDisappear {
                // v197: 屏保开关改由播放器容器统一持有（整个会话内禁屏保），此处不再置 false
                teardown()
            }
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
        // v191: 玻璃弹层（与 KS 同款 overlay 承载——锚定右下、玻璃折射播放画面）
        .overlay(alignment: .bottomTrailing) {
            if showDanmuSettings {
                FNOSDanmuSettingsSheet(onClose: { closeSheets() })
                    .padding(.trailing, 90)
                    .padding(.bottom, 170)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // v207: 片头片尾设置（实时位置 + 取当前位置 + ±1s 微调；与 KS 同款）
            if showSkipSettings {
                FNOSSkipSettingsSheet(
                    opening: skipOpening,
                    ending: skipEnding,
                    currentPosition: skipPanelPos,
                    totalDuration: skipPanelDur,
                    canSync: parentGUID?.isEmpty == false,
                    onClose: { closeSheets() },
                    onChange: { op, ed in commitSkipSettings(opening: op, ending: ed) },
                    onCapture: { isIntro in
                        // 捕捉 = 标记此处，本次播放不再自动跳（下次播放起效）
                        if isIntro { introSkipped = true } else { endingSkipped = true }
                    }
                )
                .padding(.trailing, 90)
                .padding(.bottom, 170)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if showAudioSheet {
                FNOSAudioTracksSheet(
                    title: "音轨切换",
                    tracks: trackOptions(player?.audioTracks ?? []),
                    onClose: { closeSheets() }
                ) { option in
                    if let player {
                        player.selectTrack(MPVMediaTrackIdentifier(type: .audio, mpvID: Int(option.id)))
                    }
                    closeSheets()
                }
                .padding(.trailing, 90)
                .padding(.bottom, 170)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if showSubtitleSheet {
                FNOSAudioTracksSheet(
                    title: "字幕切换",
                    tracks: trackOptions(player?.subtitleTracks ?? []),
                    onClose: { closeSheets() }
                ) { option in
                    if let player {
                        player.selectSubtitle(
                            MPVMediaTrackIdentifier(type: .subtitle, mpvID: Int(option.id)),
                            for: .primary
                        )
                    }
                    closeSheets()
                }
                .padding(.trailing, 90)
                .padding(.bottom, 170)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        // v191: 触摸板滑动拖动进度的手势宿主（与 KS FNOSPanBridge 同款体验）
        .background(FNOSMPVPanHostView())
        .onAppear {
            attachPanHandler()
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
        // v191: 与 KS 内嵌字幕同款——40pt 白字贴底、无阴影/描边（体验一致）
        Text(subtitleText)
            .font(.system(size: 40, weight: .medium))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 160)
            .padding(.bottom, 150)
    }

    // MARK: - 控制条

    private func controlBar(_ player: MPVPlayer) -> some View {
        VStack(spacing: 14) {
            if showEpisodeStrip, !episodes.isEmpty {
                episodeStrip
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // 主按钮组居中 + 功能按钮靠右（与 KS 同款布局）
            HStack(spacing: 22) {
                controlButton(.rewind, icon: "gobackward.15") {
                    player.seek(by: .seconds(-15))
                }
                controlButton(.playPause, icon: player.isPaused ? "play.fill" : "pause.fill", primary: true) {
                    togglePlayPause()
                }
                controlButton(.forward, icon: "goforward.15") {
                    player.seek(by: .seconds(15))
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                HStack(spacing: 14) {
                    rateButton(player)
                    controlButton(.danmu, icon: "text.bubble") {
                        showDanmu.toggle()
                    }
                    .opacity(showDanmu ? 1 : 0.35)
                    controlButton(.danmuSettings, icon: "slider.horizontal.3") {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showDanmuSettings = true
                            showAudioSheet = false
                            showSubtitleSheet = false
                            showSkipSettings = false
                            sheetReturnFocus = .danmuSettings
                        }
                    }
                    // v206: 片头片尾设置按钮（与弹幕设置同款功能键列）
                    controlButton(.skipSettings, icon: "tv.inset.filled") {
                        // v208: 打开瞬间立即同步真实位置（与 KS 同款，不等下一个 ticker tick）
                        skipPanelPos = seconds(player.position)
                        skipPanelDur = seconds(player.duration)
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showDanmuSettings = false
                            showAudioSheet = false
                            showSubtitleSheet = false
                            showSkipSettings = true
                            sheetReturnFocus = .skipSettings
                        }
                        // v207: 面板打开时的链路快照（与 KS 同款）
                        FNOSDiag.shared.add("跳过面板打开(mpv): intro=\(skipOpening.map { "\(Int($0))s" } ?? "关") ending=\(skipEnding.map { "\(Int($0))s" } ?? "关") parent=\(parentGUID?.isEmpty == false) type=\(item.type) pos=\(Int(skipPanelPos))s")
                    }
                    if !player.audioTracks.isEmpty {
                        controlButton(.audio, icon: "waveform") {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                showDanmuSettings = false
                                showSkipSettings = false
                                showAudioSheet = true
                                showSubtitleSheet = false
                                sheetReturnFocus = .audio
                            }
                        }
                    }
                    if !player.subtitleTracks.isEmpty {
                        controlButton(.subtitle, icon: "character.textbox") {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                showDanmuSettings = false
                                showSkipSettings = false
                                showAudioSheet = false
                                showSubtitleSheet = true
                                sheetReturnFocus = .subtitle
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.white)
            .focusSection()

            HStack(spacing: 14) {
                Text(timeText(displayTime(player)))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white)
                scrubber(player)
                Text(timeText(seconds(player.duration)))
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
        .onChange(of: focus) { _, newValue in
            if newValue != .scrubber {
                commitScrubIfNeeded(player)
                // 焦点离开进度条、又不在换集条上 → 把换集条收起来（KS 同款）
                if focusedChip == nil { showEpisodeStrip = false }
            }
            bumpActivity()
        }
        .onChange(of: focusedChip) { _, newValue in
            // 焦点进入换集条 → 取消自动隐藏；离开 → 重新计时
            if newValue == nil {
                bumpActivity()
            }
        }
    }

    // MARK: - 选集条（v191: 与 KS 4 大卡同版式；原生分集无缩略图/简介 → 渐变占位 + 集数）

    private var episodeStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(episodes) { ep in
                        let isCurrent = ep.number == currentNumber
                        let isFocused = focusedChip == ep.guid
                        Button {
                            guard !isCurrent else { return }
                            switchEpisode(to: ep)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                    Text("\(ep.number)")
                                        .font(.system(size: 56, weight: .bold, design: .rounded))
                                        .foregroundColor(.white.opacity(0.9))
                                }
                                .frame(width: 424, height: 238)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white, lineWidth: isCurrent ? 2.5 : 0)
                                )

                                HStack(spacing: 10) {
                                    Text("第 \(ep.number) 集")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(isCurrent ? .white : .white.opacity(0.75))
                                    Text("mpv 直连播放")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                Text("原生媒体流 · 倍速/音轨/字幕同 KS 引擎")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.62))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                            .padding(10)
                            .frame(width: 424, height: 324, alignment: .top)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(isFocused ? Color.white.opacity(0.26) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.white.opacity(isFocused ? 0.9 : 0), lineWidth: 2)
                            )
                            .scaleEffect(isFocused ? 1.05 : 1.0)
                            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 10, y: 4)
                            .animation(.easeOut(duration: 0.12), value: isFocused)
                        }
                        .buttonStyle(FNOSBareButtonStyle())
                        .focusEffectDisabled()
                        .focused($focusedChip, equals: ep.guid)
                        .onMoveCommand { direction in
                            // 上键收起换集条并回进度条（KS 同款）
                            if direction == .up {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showEpisodeStrip = false
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    focus = .scrubber
                                }
                            }
                        }
                        .id(ep.guid)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 348)
            .onAppear {
                proxy.scrollTo(currentGUID, anchor: .center)
            }
            .onChange(of: currentGUID) { _, guid in
                proxy.scrollTo(guid, anchor: .center)
            }
        }
        .onChange(of: focusedChip) { _ in
            bumpActivity()
        }
    }

    // MARK: - 进度条

    private func scrubber(_ player: MPVPlayer) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, geo.size.width * displayFraction(player)))
            }
            .frame(height: focus == .scrubber ? 14 : 6)
            .animation(.easeOut(duration: 0.15), value: focus == .scrubber)
            .contentShape(Rectangle())
        }
        .frame(height: 40)
        .focusable(true)
        .focused($focus, equals: .scrubber)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left:
                scrub(player, by: -1)
            case .right:
                scrub(player, by: 1)
            case .down:
                // 第一次按↓：展开换集条并把焦点交给当前集（KS 同款）
                guard !episodes.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    showEpisodeStrip = true
                }
                let target = episodes.first(where: { $0.number == currentNumber })?.guid
                    ?? episodes.first?.guid
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    focusedChip = target
                }
            default:
                break
            }
        }
    }

    /// 与 KS 完全同款的按钮外观（FNOSFocusButtonLabel：黑胶囊→白胶囊+黑图标+放大）
    private func controlButton(
        _ control: Control,
        icon: String,
        primary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            FNOSFocusButtonLabel(isFocused: focus == control, isPrimary: primary) {
                Image(systemName: icon)
                    .font(.system(size: primary ? 26 : 23, weight: .semibold))
            }
        }
        .buttonStyle(FNOSBareButtonStyle())
        .focused($focus, equals: control)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            // 下键明确落到进度条（KS 同款）
            if direction == .down { focus = .scrubber }
        }
    }

    /// 倍速按钮：0.5 → 1.0 → 1.5 → 2.0 循环（KS 同款）
    private func rateButton(_ player: MPVPlayer) -> some View {
        Button {
            cycleRate(player)
        } label: {
            FNOSFocusButtonLabel(isFocused: focus == .rate, isPrimary: true) {
                Text(String(format: "%.1fx", player.playbackRate))
                    .font(.system(size: 21, weight: .semibold).monospacedDigit())
            }
        }
        .buttonStyle(FNOSBareButtonStyle())
        .focused($focus, equals: .rate)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            if direction == .down { focus = .scrubber }
        }
    }

    private func cycleRate(_ player: MPVPlayer) {
        let index = rateOptions.firstIndex(of: player.playbackRate) ?? 1
        let next = rateOptions[(index + 1) % rateOptions.count]
        player.setPlaybackRate(next)
        danmu.setRate(player.isPaused ? 0 : next)
        bumpActivity()
    }

    // MARK: 进度梯子/拖动提交（与 KS 同款：0.2s 连按加速 10s→30s→60s→120s，停 1s 提交）

    private func displayTime(_ player: MPVPlayer) -> Double {
        if scrubActive { return scrubValue }
        return seconds(player.position)
    }

    private func displayFraction(_ player: MPVPlayer) -> Double {
        let total = max(seconds(player.duration), 1)
        return min(max(displayTime(player) / total, 0), 1)
    }

    private static let scrubLadder: [Double] = [10, 30, 60, 120]

    private func scrub(_ player: MPVPlayer, by direction: Double) {
        let now = Date()
        if let last = lastScrubMove, now.timeIntervalSince(last) < 0.2 {
            scrubLevel = min(scrubLevel + 1, Self.scrubLadder.count - 1)
        } else {
            scrubLevel = 0
        }
        lastScrubMove = now
        scrubStep = Self.scrubLadder[scrubLevel]

        let total = max(seconds(player.duration), 1)
        let base = scrubActive ? scrubValue : seconds(player.position)
        scrubActive = true
        scrubValue = min(max(base + direction * scrubStep, 0), total)
        scheduleScrubCommit()
        bumpActivity()
    }

    private func scheduleScrubCommit() {
        scrubCommitTask?.cancel()
        scrubCommitTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let player else { return }
            commitScrubIfNeeded(player)
        }
    }

    private func commitScrubIfNeeded(_ player: MPVPlayer) {
        guard scrubActive else { return }
        scrubActive = false
        player.seek(to: .seconds(scrubValue))
    }

    /// v191: MPVMediaTrack → 共享玻璃弹层选项模型（KS/MPV 1:1 同款弹窗）
    private func trackOptions(_ tracks: [MPVMediaTrack]) -> [FNOSTrackOption] {
        tracks.map { track in
            var parts: [String] = []
            if let title = track.title, !title.isEmpty { parts.append(title) }
            if let language = track.language, !language.isEmpty { parts.append(language) }
            if parts.isEmpty, let codec = track.codec, !codec.isEmpty { parts.append(codec) }
            let name = parts.isEmpty ? "轨道 \(track.mpvID + 1)" : parts.joined(separator: " · ")
            return FNOSTrackOption(id: Int32(track.mpvID), title: name, isCurrent: track.isSelected)
        }
    }

    /// v191: 玻璃弹层关闭（与 KS 同款：回焦点到播放键）
    private func closeSheets() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showDanmuSettings = false
            showAudioSheet = false
            showSubtitleSheet = false
            showSkipSettings = false
        }
        DispatchQueue.main.async {
            // v192: 关闭后焦点回到「打开该弹层的那个按钮」上，而不是播放键（用户令）
            focus = sheetReturnFocus ?? .playPause
        }
        bumpActivity()
    }

    /// v206: 片头片尾改值 → 本端立即生效 + 0.5s 防抖推服务端（Web 端同语义自动保存）。
    /// 未解析出 parent_guid 时只留诊断，不影响本地生效。
    private func commitSkipSettings(opening: Double?, ending: Double?) {
        skipOpening = opening
        skipEnding = ending
        guard let parent = parentGUID, !parent.isEmpty else {
            // v207: 走 FNOSDiag（9999 日志可查；电影等无 parent_guid 场景=仅本端生效）
            FNOSDiag.shared.add("跳过设置: 无 parent_guid，仅本端生效", dedupeKey: "mpv.skip.push.no")
            return
        }
        skipPushTask?.cancel()
        skipPushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let ok = await native.setSkipConfig(
                parentGUID: parent,
                skipOpening: Int(opening?.rounded() ?? 0),
                skipEnding: Int(ending?.rounded() ?? 0)
            )
            FNOSDiag.shared.add("跳过设置推送(mpv): \(ok ? "成功" : "失败") intro=\(Int(opening ?? 0))s ending=\(Int(ending ?? 0))s → \(parent.prefix(8))…")
        }
    }

    // MARK: - 续播选择弹窗（v191: 与 KS 同款——3s 未确认自动续播）

    private var resumeChoiceOverlay: some View {
        VStack(spacing: 14) {
            Text("检测到播放记录 · 已看到 \(timeText(resumeChoiceTarget))")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
            HStack(spacing: 26) {
                Button {
                    finishResumeChoice(startOver: true)
                } label: {
                    Text("从头开始")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(FNOSBareButtonStyle())
                .focused($focus, equals: .resumeStartOver)

                Button {
                    finishResumeChoice(startOver: false)
                } label: {
                    Text("继续播放")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                }
                .buttonStyle(FNOSBareButtonStyle())
                .focused($focus, equals: .resumeContinue)
            }
        }
        .padding(.bottom, 220)
        .frame(maxWidth: .infinity)
    }

    private func finishResumeChoice(startOver: Bool) {
        resumeAutoTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            showResumeChoice = false
        }
        if startOver, let player {
            player.seek(to: .zero)
        }
        DispatchQueue.main.async {
            focus = .playPause
        }
        bumpActivity()
    }

    /// v191: 触摸板滑动拖动进度（与 KS FNOSPanBridge 同款：进度条聚焦时 1px≈0.2s）
    private func attachPanHandler() {
        FNOSMPVPanCoordinator.shared.onPan = { gesture in
            guard let player, controlsVisible, focus == .scrubber,
                  !showDanmuSettings, !showSkipSettings, !showAudioSheet, !showSubtitleSheet else { return }
            switch gesture.state {
            case .began:
                scrubActive = true
                scrubValue = seconds(player.position)
            case .changed:
                guard scrubActive else { return }
                let translation = gesture.translation(in: gesture.view)
                gesture.setTranslation(.zero, in: gesture.view)
                let delta = Double(translation.x) * 0.2
                let total = max(seconds(player.duration), 1)
                scrubValue = min(max(scrubValue + delta, 0), total)
                scheduleScrubCommit()
            case .ended, .cancelled:
                if focus == .scrubber {
                    commitScrubIfNeeded(player)
                }
            default:
                break
            }
        }
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
        // v191: 逐层退出——续播窗按 Menu = 继续播放；弹层关闭；换集条收起；最后才是退出播放
        if showResumeChoice {
            finishResumeChoice(startOver: false)
            return
        }
        if showDanmuSettings || showSkipSettings || showAudioSheet || showSubtitleSheet {
            closeSheets()
            return
        }
        if showEpisodeStrip {
            withAnimation(.easeInOut(duration: 0.2)) {
                showEpisodeStrip = false
            }
            focus = .scrubber
            return
        }
        onExit()
    }

    // MARK: - 生命周期

    private func startIfNeeded() {
        guard player == nil else { return }

        let configuration = MPVPlayerConfiguration(
            additionalOptions: [
                "http-header-fields": "Authorization: \(authToken)",
                // v119：DoVi→SDR 转换别把字幕/弹幕压灰。显式纯白字幕色 + 覆盖 ASS 自带灰色样式。
                //（不能用 "vo=gpu-next" 这种无冒号写法——[String:String] 字典字面量
                //  必须 key: value，且 vo 已由 videoOutput:.metal 管理）
                // v192：用户实测 hable 偏亮+饱和度发灰 → 换 BT.2390 EETF（行业标准，
                // 对比更准亮度更中性）+ 逐通道色域映射（比 clip 硬裁剪还原饱和色更好）
                "tone-mapping": "bt.2390",
                "hdr-compute-peak": "yes",
                "gamut-mapping-mode": "per-channel",
                "sub-color": "#FFFFFFFF",
                "sub-border-color": "#FF000000",
                "sub-shadow-color": "#B4000000",
                "sub-ass-override": "force",
            ],
            autoPlay: true,
            // v204: 显示匹配也必须关掉——诊断日志实锤（弹幕数据纯白 100% 不透明 +
            // 渲染层已是 SDR，灰只能来自显示模式）：displayMatching .automatic 仍按
            // 杜比视界片源把电视切进 HDR 显示模式，HDR 模式下系统把 SDR 浮层压暗到
            // 203 尼特参考白 → 白弹幕变灰。关掉后电视留在 SDR 模式，弹幕恢复纯白。
            displayMatching: .disabled,
            hardwareDecoding: .videoToolbox,
            // v202: HDR 输出策略改为 .disabled——之前默认 .automatic 时杜比视界内容
            // 以 HDR 直出（Metal 层 EDR），电视切到 HDR 显示模式，系统把 App 的
            // SDR 浮层（弹幕/字幕/控制条）整体压暗 → 白色弹幕变灰（用户实测）。
            // 改 .disabled 后 Metal 层为 SDR，mpv 用上方 bt.2390 把 HDR 色调映射到 SDR，
            // 显示模式留在 SDR，弹幕/字幕/控制条恢复真实白色与准确色彩。
            hdrPolicy: .disabled,
            initialBufferSeconds: .seconds(2),
            logLevel: .warning,
            networkCacheSeconds: .seconds(15),
            // v205: SDR 输出层降级为 8-bit sRGB——之前是 linear float16 P3 层（MPVKit 默认），
            // 白色 UI 浮层（弹幕/字幕/控制条）在这类层上的合成亮度与 KS 的普通 sRGB 视频层
            // 不一致（用户实测弹幕白变灰）。改 .compatibility8Bit 后输出层与 KS 视频层同类，
            // UI 合成路径一致，弹幕恢复与 KS 相同的白色。
            sdrOutput: .compatibility8Bit,
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
            // v191: 与 KS 同款续播选择窗（3s 未确认自动续播）
            resumeChoiceTarget = resume
            withAnimation(.easeInOut(duration: 0.2)) {
                showResumeChoice = true
            }
            resumeAutoTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    showResumeChoice = false
                }
                focus = .playPause
            }
        } else {
            player.load(currentURL)
        }

            loadDanmu()
            startTicker(player)
            startSubtitleStream(player)

            // v203 诊断: 3 秒后上报 mpv 渲染管线状态（EDR/色彩空间/HDR 元数据/DV 状态），
            // 落 9999 日志——用于定位弹幕白变灰是渲染层还是显示合成层
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                FNOSDiagLog.send("mpv渲染诊断: hdrPolicy=\(configuration.hdrPolicy) 颜色=\(String(describing: player.renderColorStatus))")
                FNOSDiagLog.send("mpv渲染诊断: hdr=\(String(describing: player.mediaInformation.hdr)) DV=\(String(describing: player.dolbyVisionStatus))")
            }

        // 按钮要等 player 出现后才存在，这里延迟一次把焦点落到播放键
        // （有续播选择窗时落到「继续播放」键——KS 同款）
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            focus = showResumeChoice ? .resumeContinue : .playPause
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
        // v119：结束回调——先绑定到显式类型的局部变量。
        // 直接写 `if let finished = onFinished` 会让 Swift 把 `()` 元组
        // 和尾随闭包语法混在一起解析，导致 ticker 块被误认为字典字面量。
        let didFinishCallback: (() -> Void)? = onFinished
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                let position = seconds(player.position)
                danmu.sync(mediaTime: position)
                // v191 修复: 之前硬编码 1.0——倍速播放时弹幕速度不同步
                danmu.setRate(player.isPaused ? 0.0 : player.playbackRate)
                // v200: 每 tick 重申禁屏保（250ms 一次）——双保险，即使任何代码路径
                // 把 isIdleTimerDisabled 重置（如 Group 修饰符分发导致的内核切换残留），
                // 也在 250ms 内恢复为 true，播放中永不进系统屏保（用户实测两轮未修好）
                UIApplication.shared.isIdleTimerDisabled = true

                // v207: 片头片尾面板打开期间实时刷新当前位置（与 KS 同款）
                if showSkipSettings {
                    skipPanelPos = position
                    skipPanelDur = seconds(player.duration)
                }
                // v184: 自动跳过片头/片尾（服务器 play_config 数据，各单次触发）
                // v206: skipOpening/skipEnding 即生效值——设置面板改值后立刻更新，tick 下轮即生效
                // v208: 触发/后置状态留 9999 日志（与 KS 同款，跳过后选集/进度失效排查）
                if let so = skipOpening, !introSkipped, position > 0.5, position < so - 0.5 {
                    introSkipped = true
                    FNOSDiag.shared.add("自动跳过片头触发(mpv): so=\(Int(so)) pos=\(Int(position)) dur=\(Int(seconds(player.duration)))")
                    player.seek(by: .seconds(so - position))
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        FNOSDiag.shared.add("跳过seek后1.2s(mpv): pos=\(Int(seconds(player.position))) dur=\(Int(seconds(player.duration)))")
                    }
                }
                // v206: skip_ending 是「距结尾秒数」（Web 端语义），开始点 = 总时长 - se
                if let se = skipEnding, !endingSkipped, se > 0 {
                    let dur = seconds(player.duration)
                    let endingStart = dur - se
                    if dur > 2, endingStart > dur * 0.1, position >= endingStart, position < dur - 2 {
                        endingSkipped = true
                        FNOSDiag.shared.add("自动跳过片尾触发(mpv): se=\(Int(se)) pos=\(Int(position)) dur=\(Int(dur))")
                        player.seek(by: .seconds((dur - 1.5) - position))
                    }
                }

                if abs(position - lastPersist) > 4 {
                    lastPersist = position
                    UserDefaults.standard.set(position, forKey: resumeKey)
                    onProgress?(position, seconds(player.duration))
                }

                // v119：播放结束检测（MPVUI 无 eof 事件，用位置逼近时长判定）。
                // 只对剧集单集触发；容差 1.5s 吸收 ticker 250ms 粒度与关键帧抖动。
                // 防御：暂停状态下位置接近末尾不算「播完」（用户可能在片尾拖拽）
                let totalSeconds: Double = seconds(player.duration)
                let paused: Bool = player.isPaused
                let nearEnd: Bool = totalSeconds > 60 && (totalSeconds - position) <= 1.5
                if !didFinish && !paused && nearEnd {
                    didFinish = true
                    danmu.setRate(0)
                    if let callback = didFinishCallback {
                        callback()
                    }
                }

                // 自动隐藏：播放中、无面板/弹层展开、5 秒无操作
                if controlsVisible,
                   !player.isPaused,
                   !showEpisodeStrip,
                   !showDanmuSettings,
                   !showSkipSettings,
                   !showAudioSheet,
                   !showSubtitleSheet,
                   Date().timeIntervalSince(lastActivity) > 5 {
                    hideControls()
                }

                // 焦点兜底：任何原因导致焦点丢失都重新落到有效对象上
                // v192 修复: 弹层打开时焦点在弹层内（弹层自己的 FocusState 管理）——
                // 不能每 250ms 把焦点拽回播放键（表现为弹层焦点移不进/自动回退到播放键）
                if focus == nil {
                    if showDanmuSettings || showSkipSettings || showAudioSheet || showSubtitleSheet {
                        // 保持现状：焦点留在弹层内
                    } else {
                        focus = controlsVisible ? .playPause : .surface
                    }
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
            // v206: 切集后随 mediaRange 刷新剧集级 guid；重置跳过单次触发标记
            parentGUID = next.parentGUID ?? parentGUID
            introSkipped = false
            endingSkipped = false
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

// MARK: - v191 mpv 触摸板滑动拖动进度桥（与 KS FNOSPanBridge 同款模式：根视图挂一次手势，门控在闭包）

final class FNOSMPVPanCoordinator: NSObject, UIGestureRecognizerDelegate {
    static let shared = FNOSMPVPanCoordinator()

    weak private var hostView: UIView?
    private var recognizer: UIPanGestureRecognizer?
    var onPan: ((UIPanGestureRecognizer) -> Void)?

    func setHost(_ view: UIView) {
        guard hostView !== view else { return }
        hostView = view
        mountIfNeeded()
    }

    private func mountIfNeeded() {
        guard recognizer == nil, let host = hostView else { return }
        var root = host
        while let superview = root.superview, !(superview is UIWindow) {
            root = superview
        }
        if let existing = root.gestureRecognizers?.first(where: {
            ($0 as? UIPanGestureRecognizer)?.name == "fnos.mpv.scrub.pan"
        }) {
            recognizer = existing as? UIPanGestureRecognizer
            return
        }
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        recognizer.name = "fnos.mpv.scrub.pan"
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        root.addGestureRecognizer(recognizer)
        self.recognizer = recognizer
    }

    @objc private func handle(_ gesture: UIPanGestureRecognizer) {
        onPan?(gesture)
    }

    /// 门控全部在 onPan 闭包内（挂载即允许开始，state 变化由闭包自行过滤）
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        onPan != nil
    }
}

/// 手势宿主（本身不吃触摸），把视图交给协调器爬根挂载
private struct FNOSMPVPanHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        FNOSMPVPanCoordinator.shared.setHost(uiView)
    }
}

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
