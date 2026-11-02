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
import CoreMedia
import KSPlayer
import SwiftUI
import UIKit

/// AVURLAsset 请求头 Key（ObjC 常量未暴露给 Swift，按官方字符串手动声明）
private let fnosAVHTTPHeaderFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

// MARK: - 播放源扩展（只读 FNOSDirectClient 公开属性，不修改网络层文件）

extension FNOSDirectClient {

    /// PlaybackInfo 响应（Jellyfin/Emby 标准：POST Items/{id}/PlaybackInfo）
    struct FNOSPlaybackInfo: Decodable {
        let MediaSources: [FNOSPlaybackMediaSource]?

        struct FNOSPlaybackMediaSource: Decodable {
            let Id: String?
            let Container: String?
            let Path: String?
            let RunTimeTicks: Int64?
            let Name: String?
        }
    }

    /// 条目详情（宽松解析：飞牛各版本字段不完全一致，用 JSONSerialization 容错）。
    struct FNOSItemDetail {
        var mediaSourceID: String?
        var container: String?
        var runTimeTicks: Int64?
        var backdropTags: [String]?
        var people: [FNOSPerson] = []
        /// 视频流信息（判定杜比视界/HDR：VideoRangeType 形如 DOVI / DOVIWithHDR10 / HDR10 / SDR）
        var videoRangeType: String?
        var videoRange: String?
        var videoCodec: String?
        var videoProfile: String?
        var bitDepth: Int?
        /// 原始响应里出现过的键名（诊断用：确认 People 等字段服务端到底给不给）
        var rawKeys: [String] = []
        /// People 字段原始内容片段（诊断用）
        var peopleRaw: String = ""
    }

    struct FNOSPerson {
        let id: String?
        let name: String
        let role: String?
        let type: String?
        let imageTag: String?
    }

    /// GET Users/{uid}/Items/{itemId}
    /// 实测：这个端点会返回 MediaSources / People / RunTimeTicks（之前能播放正是靠它）。
    /// 解析一律走 JSONSerialization 手动取值，避免模型字段不匹配导致整体解码失败。
    func fetchItemDetail(itemID: String, userID: String) async throws -> FNOSItemDetail {
        // 显式声明需要的字段，尽量让服务端返回完整的 People / MediaSources
        let fields = "People,MediaSources,MediaStreams,Overview,Genres,OfficialRating,RunTimeTicks,ProductionYear,BackdropImageTags"
        let data = try await get(
            path: "Users/\(userID)/Items/\(itemID)",
            query: ["Fields": fields]
        )

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? "(非文本)"
            print("FNOS❗️条目详情非 JSON 对象: \(raw)")
            throw FNOSDirectError("条目详情格式异常")
        }

        var detail = FNOSItemDetail()
        detail.rawKeys = Array(root.keys).sorted()
        detail.runTimeTicks = (root["RunTimeTicks"] as? NSNumber)?.int64Value
        detail.backdropTags = root["BackdropImageTags"] as? [String]

        if let sources = root["MediaSources"] as? [[String: Any]], let first = sources.first {
            detail.mediaSourceID = (first["Id"] as? String) ?? (first["id"] as? String)
            detail.container = (first["Container"] as? String) ?? (first["container"] as? String)
            if let ticks = (first["RunTimeTicks"] as? NSNumber)?.int64Value, ticks > 0 {
                detail.runTimeTicks = ticks
            }
            if let streams = first["MediaStreams"] as? [[String: Any]],
               let video = streams.first(where: { (($0["Type"] as? String) ?? "").lowercased() == "video" })
            {
                detail.videoRangeType = video["VideoRangeType"] as? String
                detail.videoRange = video["VideoRange"] as? String
                detail.videoCodec = video["Codec"] as? String
                detail.videoProfile = video["Profile"] as? String
                detail.bitDepth = (video["BitDepth"] as? NSNumber)?.intValue
            }
            let depthText = detail.bitDepth.map { String($0) + "bit" } ?? ""
            let vCodec = detail.videoCodec ?? "?"
            let vProfile = detail.videoProfile ?? ""
            let vRange = detail.videoRange ?? "?"
            let vRangeType = detail.videoRangeType ?? "?"
            print("FNOS✅ 条目详情 \(itemID) → 媒体源 \(detail.mediaSourceID ?? "nil") 容器 \(detail.container ?? "?") 视频 \(vCodec) \(vProfile) range=\(vRange)/\(vRangeType) \(depthText)")
        } else {
            print("FNOS⚠️ 条目详情 \(itemID) 无 MediaSources")
        }

        if let peopleDict = root["People"] {
            detail.peopleRaw = String(describing: peopleDict).prefix(80).description
        } else {
            detail.peopleRaw = "nil(无该键)"
        }

        if let people = root["People"] as? [[String: Any]] {
            detail.people = Self.parsePeople(people)
            print("FNOSℹ️ 演员/制作 \(detail.people.count) 人（Items/{id}）")
        }

        // People 键存在但为空：换 Items/{id} 路径 + UserId 再试一次
        if detail.people.isEmpty {
            if let altData = try? await get(
                path: "Items/\(itemID)",
                query: ["UserId": userID, "Fields": "People"]
            ),
                let altRoot = try? JSONSerialization.jsonObject(with: altData) as? [String: Any]
            {
                if let people = altRoot["People"] as? [[String: Any]] {
                    detail.people = Self.parsePeople(people)
                    print("FNOSℹ️ 演员(备用端点 Items/{id}) \(detail.people.count) 人")
                } else {
                    print("FNOS⚠️ 演员备用端点无 People 键")
                    detail.peopleRaw += " | 备用: 无People键"
                }
            }
        }

        return detail
    }

    static func parsePeople(_ people: [[String: Any]]) -> [FNOSPerson] {
        people.compactMap { dict in
            guard let name = dict["Name"] as? String, !name.isEmpty else { return nil }
            return FNOSPerson(
                id: dict["Id"] as? String,
                name: name,
                role: dict["Role"] as? String,
                type: dict["Type"] as? String,
                imageTag: dict["PrimaryImageTag"] as? String
            )
        }
    }

    /// 播放源信息（含视频色彩信息，用于杜比视界/HDR 分流）
    struct FNOSPlaybackSourceInfo {
        let mediaSourceID: String
        let container: String?
        let videoRangeType: String?
        let videoRange: String?
        let videoCodec: String?
        let videoProfile: String?
        let bitDepth: Int?

        /// 杜比视界（兼容层 VideoRangeType 有时会漏报成 SDR，所以还有解码轨实测作为第二道判断）
        var isDolbyVision: Bool {
            let hay = [(videoRangeType ?? ""), (videoRange ?? "")].joined(separator: " ").lowercased()
            return hay.contains("dovi") || hay.contains("dolby") || hay.contains("dvhe") || hay.contains("dvav")
        }

        var isAV1: Bool {
            (videoCodec ?? "").lowercased().contains("av1")
        }

        /// KSPlayer 免费版处理不了的片源：杜比视界（IPTPQc2 不转色彩会紫绿）、AV1（无解码器）
        var needsMPV: Bool { isDolbyVision || isAV1 }

        var summary: String {
            [
                videoRangeType ?? videoRange ?? "-",
                videoCodec ?? "-",
                bitDepth.map { "\($0)bit" } ?? "-",
            ].joined(separator: " · ")
        }
    }

    /// 条目播放源（fnOS 硬性要求：stream 的 MediaSourceId 必须传真实值，空值一律 400）
    func playbackSource(itemID: String, userID: String) async throws -> FNOSPlaybackSourceInfo {
        let detail = try await fetchItemDetail(itemID: itemID, userID: userID)
        guard let id = detail.mediaSourceID, !id.isEmpty else {
            throw FNOSDirectError("该条目没有可用的媒体源")
        }
        return FNOSPlaybackSourceInfo(
            mediaSourceID: id,
            container: detail.container,
            videoRangeType: detail.videoRangeType,
            videoRange: detail.videoRange,
            videoCodec: detail.videoCodec,
            videoProfile: detail.videoProfile,
            bitDepth: detail.bitDepth
        )
    }

    /// 演员头像 URL
    func personImageURL(personID: String, tag: String?, maxWidth: Int = 300) -> URL? {
        guard let tag, !tag.isEmpty else { return nil }
        return try? url(
            path: "Items/\(personID)/Images/Primary",
            query: ["maxWidth": String(maxWidth), "quality": "85", "tag": tag]
        )
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
    /// 选中背景：纯色半透明 + 自定义放大动画（阻断焦点引擎对材质的识别，无系统默认高亮底色）
    func fnosGlass(_ active: Bool, in shape: some Shape) -> some View {
        self
            .background(active ? Color.black.opacity(0.4) : Color.clear, in: shape)
            .scaleEffect(active ? 1.12 : 1.0)
            .animation(.easeOut(duration: 0.15), value: active)
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
    /// 单集所属剧名（弹幕按剧名+集数匹配；item.SeriesName 缺失时用这个兜底）
    var seriesName: String? = nil
    /// 同剧全部分集（进度条下方换集条；电影为空即不显示）
    var episodes: [FNOSItem] = []
    /// 点击换集回调（由详情页重建播放目标实现切集）
    var onSelectEpisode: ((FNOSItem) -> Void)? = nil

    @Environment(\.dismiss)
    private var dismiss

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @StateObject private var danmuEngine = FNOSDanmuEngine()

    @State private var showDanmu = true
    @State private var streamURL: URL?
    @State private var containerInfo: String?
    /// 视频色彩信息（杜比视界/HDR 分流用）
    @State private var videoRangeType: String?
    @State private var videoCodec: String?
    @State private var videoBitDepth: Int?
    /// 杜比视界/HDR10 兼容输出开关（首页设置可关，用于 A/B 对比）
    @AppStorage("fnos.play.hdr10Compat") private var hdr10Compat = true
    /// 解码后视频轨真实的色彩范围（飞牛兼容层的 VideoRangeType 常报 SDR，不可信，以播放器轨道为准）
    @State private var streamDynamicRange: String?
    @State private var notice = "准备播放…"
    @State private var didSetup = false

    // MARK: mpv 引擎（实验）—— 解决杜比视界 P5 偏色
    /// 设置里可强制所有片源走 mpv（默认 false：KS 优先）
    @AppStorage("fnos.play.engineMPV") private var useMPVEngine = false
    /// 自动分流：KSPlayer 处理不了的片源（杜比视界 / AV1）自动切 mpv
    @AppStorage("fnos.play.autoEngine") private var autoEngine = true
    /// 片源检测完成前不渲染任何播放器，避免"先 KS 后 mpv"抖动
    @State private var engineProbeDone = false
    /// 本条目是否强制走 mpv（元数据命中或解码轨实测命中）
    @State private var forceMPV = false
    /// 元数据没报、播放中才发现是杜比视界时，记住已切过一次，避免来回跳
    @State private var didAutoSwitch = false
    /// 引擎切换时把播放进度带过去（无感续播）
    @State private var handoffPosition: Double = 0
    /// 检测到的片源摘要（显示在控制条上）
    @State private var sourceSummary: String?
    /// mpv 用的原生直链解析结果（含整季分集，供播放器内换集）
    @State private var mpvRange: FNOSNativeClient.MediaRange?
    @State private var mpvClient: FNOSNativeClient?
    @State private var mpvToken: String?
    /// 解析失败 → 自动退回 KSPlayer，避免停在黑屏
    @State private var mpvFailed = false
    @State private var mpvNotice = "准备 mpv…"

    // 控制条状态
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubCommitTask: Task<Void, Never>?
    @State private var scrubActive = false
    @State private var scrubValue: Double = 0
    @State private var scrubStep: Double = 10
    @State private var scrubLevel = 0
    @State private var lastScrubMove: Date?
    @State private var isSheetPresented = false
    @State private var audioSheetPresented = false
    @FocusState private var focus: Control?
    // 换集条：默认不展开（一上来就渲染 24 张缩略图会跟弹幕争内存，拖动进度条容易闪退）
    @State private var showEpisodeStrip = false
    @FocusState private var focusedChip: String?

    private enum Control: Hashable {
        case rewind, playPause, forward, rate, danmu, danmuSettings, audio, scrubber
    }

    private let rateOptions: [Float] = [0.5, 1.0, 1.5, 2.0]

    var body: some View {
        Group {
            if !engineProbeDone {
                engineProbeView
            } else if useMPVEngine || forceMPV {
                mpvLayer
            } else {
                ksLayer
            }
        }
    }

    // MARK: 引擎预检（无感切换）

    /// 检测片源色彩格式 → 决定 KS / mpv。120ms 级别的本地接口调用，感知不到。
    private var engineProbeView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在检测片源…")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .task { await decideEngine() }
        .onExitCommand { dismiss() }
    }

    /// 判定规则：
    /// 1. 设置里强制 mpv / 关掉自动分流 → 直接按设置走
    /// 2. 兼容层元数据报杜比视界 / AV1 → 走 mpv（元数据漏报的情况由解码轨实测兜底）
    /// 3. 其余一律 KSPlayer（用户偏好，链路最稳）
    @MainActor
    private func decideEngine() async {
        guard !engineProbeDone else { return }
        defer { engineProbeDone = true }

        guard !useMPVEngine, autoEngine else { return }

        guard let source = try? await client.playbackSource(itemID: item.Id, userID: userID) else {
            return
        }
        sourceSummary = source.summary

        if source.needsMPV {
            print("FNOSℹ️片源 \(source.summary) → 自动切换 mpv")
            forceMPV = true
        } else {
            print("FNOSℹ️片源 \(source.summary) → KSPlayer")
        }
    }

    // MARK: mpv 引擎入口

    @ViewBuilder
    private var mpvLayer: some View {
        if let mpvRange, let mpvClient, let mpvToken {
            FNOSMPVPlayerView(
                item: item,
                title: item.Name ?? seriesName ?? "",
                authToken: mpvToken,
                native: mpvClient,
                range: mpvRange,
                initialSeek: handoffPosition > 1 ? handoffPosition : nil,
                autoSelected: !useMPVEngine
            ) {
                dismiss()
            }
        } else if mpvFailed {
            // 原生直链解析失败：不卡黑屏，直接回退到已跑通的 KSPlayer 链路
            ksLayer
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text(mpvNotice)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .task {
                await prepareMPV()
            }
            .onExitCommand {
                dismiss()
            }
        }
    }

    /// 解析原生直链：剧名 + 集数 → 季 → 集 → play/info → media/range
    @MainActor
    private func prepareMPV() async {
        guard let credentials = FNOSAuthStore.shared.credentials else {
            mpvNotice = "未登录"
            mpvFailed = true
            return
        }
        guard let nativeToken = credentials.nativeToken, !nativeToken.isEmpty else {
            mpvNotice = "缺少飞牛原生 token，请在设置里重新登录"
            mpvFailed = true
            return
        }

        let native = FNOSNativeClient(baseURL: credentials.serverURL, token: nativeToken)
        let series = item.SeriesName ?? seriesName

        guard let range = await native.mediaRange(
            itemTitle: item.Name,
            seriesTitle: series,
            episodeNumber: item.IndexNumber
        ) else {
            print("FNOS⚠️ mpv 直链解析失败，回退 KSPlayer")
            mpvFailed = true
            return
        }

        mpvToken = nativeToken
        mpvClient = native
        mpvRange = range
    }

    // MARK: - KSPlayer 引擎（原稳定链路）

    private var ksLayer: some View {
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
                // 开播后读取解码轨真实色彩范围（服务端 VideoRangeType 不可信）
                if streamDynamicRange == nil {
                    Task { @MainActor in probeStreamRange() }
                }
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

    /// 读取解码后视频轨的真实色彩范围；实测为杜比视界时把显示模式改回 HDR10。
    /// 免费版 KSPlayer 不解 DoVi 的 IPTPQc2，若让电视按「杜比视界」显示模式去解一路普通 PQ 画面就会紫绿。
    @MainActor
    private func probeStreamRange() {
        guard let player = coordinator.playerLayer?.player,
              let video = player.tracks(mediaType: .video).first
        else { return }

        let label: String
        switch video.dynamicRange {
        case .dolbyVision: label = "杜比视界"
        case .hdr10: label = "HDR10"
        case .hlg: label = "HLG"
        default: label = "SDR"
        }
        streamDynamicRange = label
        print("FNOSℹ️解码轨实测色彩: \(label) \(video.nominalFrameRate)fps")

        guard video.dynamicRange == .dolbyVision else { return }

        // 先按 HDR10 请求显示模式：即使随后切换 mpv 失败而留在 KS，也不至于进杜比视界模式乱解
        if hdr10Compat {
            applyHDR10DisplayCriteria(refreshRate: video.nominalFrameRate)
        }

        // 元数据没报杜比视界（兼容层常见漏报），播起来才从解码轨发现：
        // 无感切到 mpv，并把当前进度带过去续播。只切一次，避免来回跳。
        if autoEngine, !useMPVEngine, !forceMPV, !didAutoSwitch {
            didAutoSwitch = true
            let position = Double(coordinator.timemodel.currentTime)
            handoffPosition = position
            print("FNOSℹ️实测杜比视界 → 自动切换 mpv，续播 @\(String(format: "%.1f", position))s")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                forceMPV = true
            }
        }
    }

    /// 把 tvOS 的显示模式请求改成 HDR10（2），避免电视进杜比视界模式解错信号
    @MainActor
    private func applyHDR10DisplayCriteria(refreshRate: Float) {
        guard let window = UIApplication.shared.windows.first else { return }
        let displayManager = window.avDisplayManager
        guard displayManager.isDisplayCriteriaMatchingEnabled else { return }
        let rate = refreshRate > 0 ? refreshRate : 24
        displayManager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: rate,
            videoDynamicRange: 2
        )
        print("FNOSℹ️显示模式请求改为 HDR10 @\(rate)fps")
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
                // 门控：只有进度条聚焦时滑动才拖进度，否则转盘滑动用于移动焦点
                switch gesture.state {
                case .began:
                    if focus == .scrubber {
                        scrubActive = true
                        scrubValue = Double(coordinator.timemodel.currentTime)
                    } else if !controlsVisible {
                        revealControls()
                    }
                case .changed:
                    guard focus == .scrubber, scrubActive else { return }
                    let translation = gesture.translation(in: gesture.view)
                    gesture.setTranslation(.zero, in: gesture.view)
                    // 滑动灵敏度：1px ≈ 0.2s（转盘快速滚动可快速拖动）
                    let delta = Double(translation.x) * 0.2
                    let total = Double(max(coordinator.timemodel.totalTime, 1))
                    scrubValue = min(max(scrubValue + delta, 0), total)
                    scheduleScrubCommit()
                case .ended, .cancelled:
                    if focus == .scrubber {
                        commitScrubIfNeeded()
                    }
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
            HStack(spacing: 22) {
                controlButton(.rewind, icon: "gobackward.15") {
                    coordinator.skip(interval: -15)
                }
                controlButton(.playPause, icon: isPlaying ? "pause.fill" : "play.fill", primary: true) {
                    togglePlayPause()
                }
                controlButton(.forward, icon: "goforward.15") {
                    coordinator.skip(interval: 15)
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                HStack(spacing: 14) {
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

            // 换集条：只有「焦点在进度条 + 再按一次下键」才展开
            if !episodes.isEmpty && showEpisodeStrip {
                episodeStrip
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                // 焦点离开进度条、又不在换集条上 → 把换集条收起来
                if focusedChip == nil { showEpisodeStrip = false }
            }
            scheduleHide()
        }
        .onChange(of: focusedChip) { newValue in
            // 焦点进入换集条 → 取消自动隐藏；离开 → 重新计时
            if newValue == nil {
                scheduleHide()
            } else {
                hideTask?.cancel()
            }
        }
    }

    /// 进度条下方的换集条：缩略图横排，当前集描边高亮，点选即切集
    private var episodeStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(episodes) { ep in
                        let isCurrent = ep.Id == item.Id
                        let isFocused = focusedChip == ep.Id
                        Button {
                            guard !isCurrent else {
                                print("FNOSℹ️换集: 已是当前集，忽略")
                                return
                            }
                            print("FNOSℹ️换集点击 → 第 \(ep.IndexNumber ?? 0) 集《\(ep.Name ?? "?")》 id=\(ep.Id)")
                            onSelectEpisode?(ep)
                        } label: {
                            VStack(spacing: 6) {
                                FNOSAsyncImage(
                                    url: client.episodeStillURL(item: ep, maxWidth: 320),
                                    headers: client.mediaHeaders,
                                    contentMode: .fill
                                )
                                .frame(width: 168, height: 94)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.white, lineWidth: isCurrent ? 2 : 0)
                                )

                                Text("第 \(ep.IndexNumber ?? 0) 集")
                                    .font(.system(size: 13, weight: isCurrent ? .bold : .medium))
                                    .foregroundColor(isCurrent ? .white : .white.opacity(0.7))
                            }
                            .padding(7)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isFocused ? Color.white.opacity(0.26) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(isFocused ? 0.9 : 0), lineWidth: 2)
                            )
                            .scaleEffect(isFocused ? 1.06 : 1.0)
                            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 10, y: 4)
                            .animation(.easeOut(duration: 0.12), value: isFocused)
                        }
                        .buttonStyle(FNOSBareButtonStyle())
                        .focusEffectDisabled()
                        .focused($focusedChip, equals: ep.Id)
                        .onMoveCommand { direction in
                            // 上键收起换集条并回进度条
                            if direction == .up {
                                showEpisodeStrip = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    focus = .scrubber
                                }
                            }
                        }
                        .id(ep.Id)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 146)
            .onAppear {
                proxy.scrollTo(item.Id, anchor: .center)
            }
        }
        .onChange(of: focusedChip) { _ in
            revealControls()
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
                scrub(by: -1)
            case .right:
                scrub(by: 1)
            case .down:
                // 第一次按↓：展开换集条并把焦点交给当前集
                guard !episodes.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    showEpisodeStrip = true
                }
                let target = episodes.first(where: { $0.Id == item.Id })?.Id ?? episodes.first?.Id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    focusedChip = target
                }
            default:
                break
            }
        }
    }

    /// 与 Hero 三个按钮同一套外观（FNOSFocusButtonLabel）：
    /// 未聚焦 = 黑 35% 胶囊 + 白图标；聚焦 = 纯白胶囊 + 黑图标 + 1.06 放大。
    /// 关键点：用 FNOSBareButtonStyle 而不是 .plain —— tvOS 的 .plain 在 ScrollView /
    /// 播放器叠层里仍会画系统白色圆角焦点板（就是之前那个大白方块）。
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
            // 下键明确落到进度条：换集条插入后焦点引擎可能跳过 scrubber
            if direction == .down { focus = .scrubber }
        }
    }

    /// 倍速按钮：0.5 → 1.0 → 1.5 → 2.0 循环
    private var rateButton: some View {
        Button {
            cycleRate()
        } label: {
            FNOSFocusButtonLabel(isFocused: focus == .rate, isPrimary: true) {
                Text(String(format: "%.1fx", coordinator.playbackRate))
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

    /// 方向键步进：0.2 秒内连续触发加速一档（10s→30s→60s→120s），停顿重置 10s。
    /// 拖动期间仅实时更新进度条位置与时间文本，停止后由 scheduleScrubCommit 执行一次 seek。
    private func scrub(by direction: Double) {
        let now = Date()
        if let last = lastScrubMove, now.timeIntervalSince(last) < 0.2 {
            scrubLevel = min(scrubLevel + 1, Self.scrubLadder.count - 1)
        } else {
            scrubLevel = 0
        }
        lastScrubMove = now
        scrubStep = Self.scrubLadder[scrubLevel]

        let total = Double(max(coordinator.timemodel.totalTime, 1))
        let base = scrubActive ? scrubValue : Double(coordinator.timemodel.currentTime)
        scrubActive = true
        scrubValue = min(max(base + direction * scrubStep, 0), total)
        scheduleScrubCommit()
        // 拖进度时不让控制条到点自动消失（否则拖到一半整条连 scrubber 一起没了）
        revealControls()
    }

    private static let scrubLadder: [Double] = [10, 30, 60, 120]

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
        // 焦点停在换集条上 / 正在拖进度时保持控制条常显：否则 3 秒后整条一起消失，用户点不到
        guard focusedChip == nil, !scrubActive else { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                controlsVisible = false
                showEpisodeStrip = false
            }
            focus = nil
        }
    }

    // MARK: 准备（真实 MediaSourceId → 直链 → 弹幕）

    private func prepare() async {
        guard !didSetup else { return }
        didSetup = true

        // 1) 取真实 MediaSourceId（fnOS 硬性要求）
        let source: FNOSDirectClient.FNOSPlaybackSourceInfo
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
        videoRangeType = source.videoRangeType
        videoCodec = source.videoCodec
        videoBitDepth = source.bitDepth
        notice = ""

        // 3) 弹幕（真实服务端；剧集按「剧名 + 集数」匹配，电影按标题匹配）
        danmuEngine.setRate(1)
        let title = item.Name ?? "视频"
        let isEpisode = item.type == "Episode"
        let episodeNumber: Int? = isEpisode ? item.IndexNumber : nil
        let serieTitleResolved: String? = isEpisode
            ? ((item.SeriesName?.isEmpty == false ? item.SeriesName : seriesName))
            : nil
        notice = "弹幕匹配中…"
        await danmuEngine.load(title: title, seriesTitle: serieTitleResolved, episodeNumber: episodeNumber)
        switch danmuEngine.status {
        case .ready:
            notice = "弹幕 \(danmuEngine.commentCount) 条" + formatBadge
        case .failed(let message):
            notice = "弹幕失败: \(message)"
        default:
            notice = ""
        }
        revealControls()
    }

    // MARK: 色彩判定

    /// 杜比视界（Jellyfin 的 VideoRangeType：DOVI / DOVIWithHDR10 / DOVIWithEL / DOVIWithHDR10Plus…）
    private var isDolbyVision: Bool {
        if streamDynamicRange == "杜比视界" { return true }
        return (videoRangeType ?? "").uppercased().contains("DOVI")
    }

    private var isHDRContent: Bool {
        if let measured = streamDynamicRange {
            return measured != "SDR"
        }
        let t = (videoRangeType ?? "").uppercased()
        return t.contains("DOVI") || t.contains("HDR") || t.contains("HLG")
    }

    /// 控制条上的格式标记（识别结果一眼可见，便于确认分流是否生效）
    private var formatBadge: String {
        let t = (videoRangeType ?? "").uppercased()
        // 优先用解码后轨道实测（服务端元数据常把 DV 报成 SDR）
        var label: String
        if let measured = streamDynamicRange {
            label = measured
        } else if t.isEmpty {
            return ""
        } else if t.contains("DOVI") {
            label = t.contains("HDR10") ? "杜比视界 P8" : "杜比视界 P5"
        } else if t.contains("HLG") {
            label = "HLG"
        } else if t.contains("HDR") {
            label = "HDR10"
        } else {
            label = "SDR"
        }
        if let depth = videoBitDepth, depth > 8 {
            label += " \(depth)bit"
        }
        if isDolbyVision || isHDRContent {
            label += hdr10Compat ? " · HDR10 输出" : " · 直通"
        }
        return " · " + label
    }

    // MARK: 引擎分流（.mkv → FFmpeg；.mp4/.m3u8 → AVPlayer）

    private func makeOptions() -> KSOptions {
        let container = (containerInfo ?? "").lowercased()
        let isMKV = container.contains("matroska") || container.contains("mkv")

        KSOptions.firstPlayerType = isMKV ? KSMEPlayer.self : KSAVPlayer.self
        print("FNOSℹ️播放引擎: \(isMKV ? "FFmpeg (KSMEPlayer)" : "AVPlayer (KSAVPlayer)") · 容器: \(container.isEmpty ? "未知" : container) · \(formatBadge)")

        // 杜比视界：KSPlayer 免费版不做 DoVi(IPTPQc2)→RGB 的色彩转换，
        // 但 isDovi=true 会让 tvOS 把电视切到「杜比视界」显示模式，
        // 电视于是按 DV 去解一路普通 HDR10/PQ 画面 → 紫绿偏色。
        // 这里改为按 HDR10 请求显示模式，把 PQ 层交给电视自己色调映射（对 P7/P8 这类 HDR10 兼容层是正确的）。
        let options: KSOptions = (isDolbyVision && hdr10Compat) ? FNOSPlayerOptions() : KSOptions()
        if isHDRContent, hdr10Compat {
            options.destinationDynamicRange = .hdr10
        }

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

// MARK: - 播放选项（杜比视界 → HDR10 显示模式）

/// KSPlayer 免费版不解 DoVi 的 IPTPQc2 色彩空间，但 `updateVideo(isDovi: true)` 会把电视切到
/// 「杜比视界」显示模式，导致电视按 DV 去解一路普通 PQ 画面 → 紫绿偏色。
/// 这里把 DoVi 内容统一按 HDR10 请求显示模式，让电视自己做色调映射。
/// （P7/P8 这类带 HDR10 兼容层的片源效果正确；P5 因底层是 IPT 数据，仍需 mpv/libplacebo 才能完全还原）
final class FNOSPlayerOptions: KSOptions {

    @MainActor
    override func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription?) {
        super.updateVideo(refreshRate: refreshRate, isDovi: false, formatDescription: formatDescription)
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
            .background(Color.black.opacity(0.4), in: Capsule())
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
            .background(Color.black.opacity(0.4), in: Capsule())
            Text(text)
                .font(.title3.monospacedDigit())
                .frame(width: 140)
            Button(action: up) {
                Image(systemName: "plus")
                    .frame(width: 72, height: 48)
            }
            .buttonStyle(.plain)
            .background(Color.black.opacity(0.4), in: Capsule())
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
                            .background(Color.black.opacity(0.4), in: Capsule())
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
            .background(Color.black.opacity(0.4), in: Capsule())
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85).ignoresSafeArea())
    }
}
